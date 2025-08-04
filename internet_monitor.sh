#!/bin/bash

#################################################################
# Internet Connection Monitor - Opravená verze pro diagnostiku hopů
# 
# Účel: Diagnostika připojení k ISP hop po hop pro evidenci výpadků
# Testuje každý hop v cestě k ISP - pokud jakýkoliv hop neodpovídá = výpadek
# Zaznamenává VŠECHNY výpadky do CSV pro řešení s poskytovatelem
#################################################################

set -euo pipefail

# ===== KONFIGURACE =====

# IP adresy hopů k ISP podle traceroute - každý hop je kritický!
readonly PING_TARGETS=(
    "192.168.1.1"      # Hop 1: Domácí router
    "10.4.40.1"        # Hop 2: První hop ISP (anténa/AP StarNet)
    "100.100.4.254"    # Hop 3: Druhý hop StarNet
    "172.31.255.2"     # Hop 4: Třetí hop StarNet (backbone)
)

# Intervaly a parametry testů
readonly PING_INTERVAL=30      # Jak často testovat (sekundy)
readonly PING_COUNT=2          # Kolik pingů na cíl
readonly PING_TIMEOUT=2        # Timeout pro 1 ping (s)
readonly SUCCESS_THRESHOLD=${#PING_TARGETS[@]}  # VŠECHNY hopy musí odpovídat!

# Cesty k souborům - vše v $HOME
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="$HOME/poruchy.csv"
readonly STATE_FILE="$HOME/.inet_monitor_state"
readonly LOCK_FILE="$HOME/.inet_monitor.lock"

# Cloud backup (rclone) - volitelné
readonly RCLONE_REMOTE="protondrive"
readonly RCLONE_PATH="monitoring/"
readonly UPLOAD_INTERVAL=3600

# Ostatní nastavení
readonly MAX_LOG_SIZE=10485760  # 10 MB
readonly VERBOSE=true

# ===== GLOBÁLNÍ PROMĚNNÉ =====

declare -g SHUTDOWN_REQUESTED=false
declare -g LAST_UPLOAD_TIME=0

# ===== UTILITY FUNKCE =====

log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        ERROR) echo "[$timestamp] ERROR: $message" >&2 ;;
        WARN)  echo "[$timestamp] WARN:  $message" >&2 ;;
        INFO)  echo "[$timestamp] INFO:  $message" ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo "[$timestamp] DEBUG: $message" ;;
    esac
    
    # Syslog pro Void Linux
    if command -v logger >/dev/null 2>&1; then
        logger -t "inet_monitor[$$]" "$level: $message" 2>/dev/null || true
    fi
}

error_exit() {
    local exit_code="$1"
    local message="$2"
    log_message ERROR "$message"
    cleanup_and_exit
    exit "$exit_code"
}

# ===== LOCK FILE MANAGEMENT =====

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local existing_pid
        if existing_pid=$(cat "$LOCK_FILE" 2>/dev/null) && [[ -n "$existing_pid" ]]; then
            if kill -0 "$existing_pid" 2>/dev/null; then
                error_exit 1 "Již běží jiná instance (PID: $existing_pid)"
            else
                log_message WARN "Odstraňuji starý lock file (proces už nežije)"
                rm -f "$LOCK_FILE"
            fi
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_message DEBUG "Lock získán (PID: $$)"
}

release_lock() {
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    log_message DEBUG "Lock uvolněn"
}

# ===== INICIALIZACE =====

initialize() {
    log_message INFO "Inicializace hop-by-hop monitoring skriptu"
    log_message INFO "Void Linux $(uname -r)"
    
    # Vytvoření adresářů
    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"
    
    # Pokud není log, založ nový se záhlavím
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "timestamp,status,latency_ms,outage_duration,failed_hops,hop_details" > "$LOG_FILE"
        log_message INFO "Vytvořen CSV log: $LOG_FILE"
    fi
    
    # Inicializace stavového souboru
    if [[ ! -f "$STATE_FILE" ]]; then
        local current_time=$(date '+%Y-%m-%d %H:%M:%S')
        printf "UP\n%s\n" "$current_time" > "$STATE_FILE"
        log_message INFO "Inicializován stavový soubor"
    fi
    
    # Trap na ukončení
    trap 'SHUTDOWN_REQUESTED=true; log_message INFO "Shutdown požadován"' SIGINT SIGTERM
    
    # Test základní funkcionality
    if ! command -v ping >/dev/null 2>&1; then
        error_exit 1 "Ping utility není dostupný"
    fi
    
    # Validace hop konfigurace
    log_message INFO "Konfigurace hopů:"
    for i in "${!PING_TARGETS[@]}"; do
        log_message INFO "  Hop $((i+1)): ${PING_TARGETS[i]}"
    done
    log_message INFO "KRITICKÉ: Všech ${#PING_TARGETS[@]} hopů musí odpovídat pro stav UP"
}

# ===== PING TESTY =====

test_single_target() {
    local target="$1"
    local hop_number="$2"
    local output exit_code latency
    
    log_message DEBUG "Testuji hop $hop_number: $target"
    
    # Timeout jako záloha pro Void Linux
    if command -v timeout >/dev/null 2>&1; then
        output=$(timeout $((PING_TIMEOUT + 2)) ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" 2>&1)
        exit_code=$?
    else
        output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" 2>&1)
        exit_code=$?
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        # Extrakce latence
        if latency=$(echo "$output" | grep -oE "time=[0-9]+(\.[0-9]+)?" | tail -1 | cut -d'=' -f2); then
            latency=${latency%.*}  # Pouze celá čísla
            latency=${latency:-0}
        else
            latency=0
        fi
        log_message DEBUG "Hop $hop_number OK: ${latency}ms"
        echo "SUCCESS:${latency}"
    else
        # Detailní analýza pro diagnostiku
        local error_type="UNKNOWN"
        if echo "$output" | grep -qi "name or service not known\|not known\|nodename nor servname"; then
            error_type="DNS_ERROR"
        elif echo "$output" | grep -qi "network is unreachable"; then
            error_type="NETWORK_UNREACHABLE"
        elif echo "$output" | grep -qi "destination host unreachable\|host unreachable"; then
            error_type="HOST_UNREACHABLE"
        elif echo "$output" | grep -qi "no route to host"; then
            error_type="NO_ROUTE"
        else
            error_type="TIMEOUT"
        fi
        
        log_message DEBUG "Hop $hop_number FAIL: $error_type"
        echo "FAIL:$error_type"
    fi
}

ping_test_all_targets() {
    local successful_targets=0
    local total_latency=0
    local failed_hops=""
    local hop_details=""
    
    log_message DEBUG "Testování ${#PING_TARGETS[@]} hopů (všechny musí být UP)"
    
    for i in "${!PING_TARGETS[@]}"; do
        local target="${PING_TARGETS[i]}"
        local hop_number=$((i + 1))
        local result
        
        result=$(test_single_target "$target" "$hop_number")
        
        local status="${result%%:*}"
        local value="${result##*:}"
        
        if [[ "$status" == "SUCCESS" ]]; then
            ((successful_targets++))
            ((total_latency += value))
        else
            failed_hops="${failed_hops}hop${hop_number}($target),"
            hop_details="${hop_details}hop${hop_number}:$value,"
        fi
    done
    
    # Odstranění koncových čárek
    failed_hops="${failed_hops%,}"
    hop_details="${hop_details%,}"
    
    log_message DEBUG "Úspěšné hopy: $successful_targets/${#PING_TARGETS[@]}"
    
    # KRITICKÉ: Všechny hopy musí být UP!
    if [[ $successful_targets -eq ${#PING_TARGETS[@]} ]]; then
        local avg_latency=0
        if [[ $successful_targets -gt 0 ]]; then
            avg_latency=$((total_latency / successful_targets))
        fi
        echo "UP:$avg_latency::všechny_hopy_ok"
    else
        echo "DOWN:0:$failed_hops:$hop_details"
    fi
}

# ===== STAV A LOGOVÁNÍ =====

read_previous_state() {
    if [[ -f "$STATE_FILE" ]]; then
        local previous_status previous_time
        {
            read -r previous_status || previous_status="UNKNOWN"
            read -r previous_time || previous_time="$(date '+%Y-%m-%d %H:%M:%S')"
        } < "$STATE_FILE"
        echo "$previous_status:$previous_time"
    else
        echo "UNKNOWN:$(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

update_state() {
    local status="$1"
    local timestamp="$2"
    
    {
        echo "$status"
        echo "$timestamp"
        echo "# Updated by PID $$ at $(date)"
        echo "# Hop monitoring k ISP: ${PING_TARGETS[*]}"
    } > "$STATE_FILE"
    
    log_message DEBUG "Stav aktualizován: $status v $timestamp"
}

calculate_outage_duration() {
    local start_time="$1"
    local end_time="$2"
    
    local start_epoch end_epoch duration
    
    start_epoch=$(date -d "$start_time" +%s 2>/dev/null) || {
        log_message WARN "Nelze parsovat čas: $start_time"
        echo "N/A"
        return 1
    }
    
    end_epoch=$(date -d "$end_time" +%s 2>/dev/null) || {
        log_message WARN "Nelze parsovat čas: $end_time"
        echo "N/A"
        return 1
    }
    
    if [[ $start_epoch -gt $end_epoch ]]; then
        echo "N/A"
        return 1
    fi
    
    duration=$((end_epoch - start_epoch))
    
    local hours minutes seconds
    hours=$((duration / 3600))
    minutes=$(((duration % 3600) / 60))
    seconds=$((duration % 60))
    
    printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
}

log_to_csv() {
    local timestamp="$1"
    local status="$2"
    local latency="$3"
    local duration="$4"
    local failed_hops="$5"
    local hop_details="$6"
    
    # CSV escapování
    failed_hops="${failed_hops//,/;}"
    hop_details="${hop_details//,/;}"
    
    echo "$timestamp,$status,$latency,$duration,$failed_hops,$hop_details" >> "$LOG_FILE"
    log_message DEBUG "Zapsáno do CSV: $status v $timestamp"
}

# ===== CLOUD BACKUP (volitelné) =====

upload_to_cloud() {
    [[ ! -f "$LOG_FILE" ]] && return 1
    
    if ! command -v rclone >/dev/null 2>&1; then
        log_message DEBUG "rclone není nainstalován, přeskakuji upload"
        return 1
    fi
    
    if ! rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:$"; then
        log_message DEBUG "rclone remote '$RCLONE_REMOTE' není nakonfigurován"
        return 1
    fi
    
    log_message DEBUG "Uploading do cloudu..."
    if rclone copy "$LOG_FILE" "$RCLONE_REMOTE:$RCLONE_PATH" --quiet 2>/dev/null; then
        LAST_UPLOAD_TIME=$(date +%s)
        log_message INFO "Upload do cloudu úspěšný"
        return 0
    else
        log_message WARN "Upload do cloudu selhal"
        return 1
    fi
}

should_upload() {
    local current_time time_since_upload
    current_time=$(date +%s)
    time_since_upload=$((current_time - LAST_UPLOAD_TIME))
    [[ $time_since_upload -ge $UPLOAD_INTERVAL ]]
}

# ===== LOG ROTACE =====

check_log_rotation() {
    [[ ! -f "$LOG_FILE" ]] && return
    
    local log_size
    if command -v stat >/dev/null 2>&1; then
        log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    else
        log_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    fi
    
    if [[ $log_size -gt $MAX_LOG_SIZE ]]; then
        local backup_file="${LOG_FILE%.csv}-$(date '+%Y%m%d_%H%M%S').csv"
        cp "$LOG_FILE" "$backup_file"
        echo "timestamp,status,latency_ms,outage_duration,failed_hops,hop_details" > "$LOG_FILE"
        log_message INFO "Log rotován: $backup_file (velikost: $((log_size/1024))KB)"
        
        # Async upload rotovaného souboru
        if command -v rclone >/dev/null 2>&1; then
            (upload_to_cloud &) 2>/dev/null
        fi
    fi
}

# ===== CLEANUP =====

cleanup_and_exit() {
    log_message INFO "Ukončuji hop monitoring..."
    release_lock
    
    # Kill background procesy
    local jobs_list
    jobs_list=$(jobs -p 2>/dev/null || true)
    if [[ -n "$jobs_list" ]]; then
        echo "$jobs_list" | xargs -r kill 2>/dev/null || true
    fi
    
    exit 0
}

# ===== HLAVNÍ MONITORING LOOP =====

main_loop() {
    log_message INFO "Spouštím hop-by-hop monitoring loop"
    log_message INFO "Sledované hopy: ${PING_TARGETS[*]}"
    log_message INFO "Interval: ${PING_INTERVAL}s, Ping: -c $PING_COUNT -W $PING_TIMEOUT"
    log_message INFO "KRITÉRIUM: VŠECH ${#PING_TARGETS[@]} hopů k ISP musí odpovídat = UP"
    log_message INFO "VÝPADEK = jakýkoliv hop 1-4 neodpovídá (ISP infrastruktura)"
    
    local loop_count=0
    
    while [[ "$SHUTDOWN_REQUESTED" == "false" ]]; do
        ((loop_count++))
        log_message DEBUG "=== Loop #$loop_count ==="
        
        check_log_rotation
        
        local current_time
        current_time=$(date '+%Y-%m-%d %H:%M:%S')
        
        # Proveď ping testy všech hopů
        local test_result
        test_result=$(ping_test_all_targets)
        
        IFS=':' read -r current_status latency failed_hops hop_details <<< "$test_result"
        
        # Načtení předchozího stavu
        local previous_state
        previous_state=$(read_previous_state)
        IFS=':' read -r previous_status previous_time <<< "$previous_state"
        
        log_message DEBUG "Stav: $previous_status -> $current_status"
        
        # Zpracování změn stavu
        if [[ "$current_status" != "$previous_status" ]]; then
            log_message INFO "=== ZMĚNA STAVU: $previous_status -> $current_status ==="
            
            case "$current_status" in
                "DOWN")
                    log_to_csv "$current_time" "DOWN" "N/A" "N/A" "$failed_hops" "$hop_details"
                    log_message WARN "VÝPADEK DETEKOVÁN!"
                    log_message WARN "Selhaly hopy: $failed_hops"
                    log_message WARN "Detaily: $hop_details"
                    ;;
                "UP")
                    if [[ "$previous_status" == "DOWN" ]]; then
                        local outage_duration
                        outage_duration=$(calculate_outage_duration "$previous_time" "$current_time")
                        log_to_csv "$current_time" "UP" "$latency" "$outage_duration" "" ""
                        log_message INFO "PŘIPOJENÍ OBNOVENO!"
                        log_message INFO "Latence: ${latency}ms, Výpadek trval: $outage_duration"
                    else
                        # První start nebo jiná změna
                        log_to_csv "$current_time" "UP" "$latency" "" "" ""
                        log_message INFO "Všechny hopy UP (${latency}ms průměr)"
                    fi
                    ;;
            esac
            
            update_state "$current_status" "$current_time"
            
            # Okamžitý upload při změně stavu
            (upload_to_cloud &) 2>/dev/null
        else
            # Žádná změna stavu - pouze debug info
            if [[ "$current_status" == "UP" ]]; then
                log_message DEBUG "Všechny hopy stále UP (${latency}ms průměr)"
            else
                log_message DEBUG "Stále DOWN - selhaly: $failed_hops"
            fi
        fi
        
        # Pravidelný upload
        if should_upload; then
            (upload_to_cloud &) 2>/dev/null
        fi
        
        log_message DEBUG "Čekám ${PING_INTERVAL}s do dalšího testu..."
        
        # Čekání do dalšího cyklu s možností přerušení
        for ((i=0; i<PING_INTERVAL; i++)); do
            [[ "$SHUTDOWN_REQUESTED" == "true" ]] && break
            sleep 1
        done
    done
}

# ===== MAIN =====

main() {
    log_message INFO "Internet Hop Monitor - START (PID: $$)"
    log_message INFO "OS: $(uname -s) $(uname -r)"
    log_message INFO "Diagnostika: hop-by-hop monitoring k ISP"
    
    acquire_lock
    initialize
    main_loop
    cleanup_and_exit
}

# Spuštění pouze pokud je skript spuštěn přímo
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
