#!/bin/bash

#################################################################
# Internet Connection Monitor - Refactored v2.1
# 
# Účel: Monitoring připojení k ISP pro evidence výpadků
# Testuje cestu k ISP podle traceroute výstupu
# Zaznamenává výpadky do CSV pro stížnosti na ČTÚ/ISP
#################################################################

set -euo pipefail

# ===== KONFIGURACE =====

# Ping cíle podle traceroute k ISP (pevně dané)
readonly PING_TARGETS=(
    "192.168.1.1"      # Domácí router
    "10.4.40.1"        # První hop ISP (anténa/AP)
    "100.100.4.254"    # Druhý hop StarNet
    "172.31.255.2"     # Třetí hop (backbone)
    "88.86.97.137"     # StarNet customer router
)

# Parametry testování
readonly PING_INTERVAL=30
readonly PING_COUNT=2
readonly PING_TIMEOUT=2
readonly SUCCESS_THRESHOLD=${#PING_TARGETS[@]}  # Všechny musí odpovídat

# Soubory a cesty
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="$HOME/poruchy.csv"
readonly STATE_FILE="$HOME/.inet_monitor_state"
readonly LOCK_FILE="$HOME/.inet_monitor.lock"

# Cloud backup
readonly RCLONE_REMOTE="protondrive"
readonly RCLONE_PATH="monitoring/"
readonly UPLOAD_INTERVAL=3600

# Ostatní nastavení
readonly MAX_LOG_SIZE=10485760  # 10MB
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
    
    # Syslog pokud je dostupný
    if [[ "$VERBOSE" == "true" ]] && command -v logger >/dev/null 2>&1; then
        logger -t "inet_monitor" "$level: $message"
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
        existing_pid=$(cat "$LOCK_FILE")
        
        if kill -0 "$existing_pid" 2>/dev/null; then
            error_exit 1 "Již běží jiná instance (PID: $existing_pid)"
        else
            log_message WARN "Odstraňujem starý lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    log_message DEBUG "Lock získán"
}

release_lock() {
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    log_message DEBUG "Lock uvolněn"
}

# ===== INICIALIZACE =====

initialize() {
    log_message INFO "Inicializace monitoring skriptu"
    
    # Vytvoření adresářů
    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"
    
    # Vytvoření CSV hlavičky pokud neexistuje
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "timestamp,status,latency_ms,outage_duration,failed_targets,error_details" > "$LOG_FILE"
        log_message INFO "Vytvořen CSV log: $LOG_FILE"
    fi
    
    # Inicializace stavu
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "UP" > "$STATE_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
        log_message INFO "Inicializován stavový soubor"
    fi
    
    # Nastavení trap pro graceful shutdown  
    trap 'SHUTDOWN_REQUESTED=true; log_message INFO "Shutdown požadován"' SIGINT SIGTERM
}

# ===== PING TESTY =====

test_single_target() {
    local target="$1"
    local output exit_code latency
    
    output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" 2>&1)
    exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        # Extrakce latence
        latency=$(echo "$output" | grep -oE "time=[0-9]+(\.[0-9]+)?" | tail -1 | cut -d'=' -f2)
        latency=${latency%.*}  # Pouze celá čísla
        echo "SUCCESS:${latency:-0}"
    else
        # Určení typu chyby
        if echo "$output" | grep -q "Name or service not known"; then
            echo "FAIL:DNS_ERROR"
        elif echo "$output" | grep -q "Network is unreachable"; then
            echo "FAIL:NETWORK_UNREACHABLE"
        elif echo "$output" | grep -q "Destination Host Unreachable"; then
            echo "FAIL:HOST_UNREACHABLE"
        else
            echo "FAIL:TIMEOUT"
        fi
    fi
}

ping_test_all_targets() {
    local successful_targets=0
    local total_latency=0
    local failed_targets=""
    local error_details=""
    
    log_message DEBUG "Testování ${#PING_TARGETS[@]} cílů"
    
    for target in "${PING_TARGETS[@]}"; do
        local result
        result=$(test_single_target "$target")
        
        local status="${result%%:*}"
        local value="${result##*:}"
        
        if [[ "$status" == "SUCCESS" ]]; then
            ((successful_targets++))
            ((total_latency += value))
            log_message DEBUG "$target: OK (${value}ms)"
        else
            failed_targets="${failed_targets}$target,"
            error_details="${error_details}$target:$value,"
            log_message DEBUG "$target: FAIL ($value)"
        fi
    done
    
    # Odstranění koncových čárek
    failed_targets="${failed_targets%,}"
    error_details="${error_details%,}"
    
    if [[ $successful_targets -ge $SUCCESS_THRESHOLD ]]; then
        local avg_latency=$((total_latency / successful_targets))
        echo "UP:$avg_latency::$successful_targets/${#PING_TARGETS[@]}"
    else
        echo "DOWN:0:$failed_targets:$error_details"
    fi
}

# ===== STAV A LOGOVÁNÍ =====

read_previous_state() {
    if [[ -f "$STATE_FILE" ]]; then
        local previous_status previous_time
        {
            read -r previous_status
            read -r previous_time
        } < "$STATE_FILE" 2>/dev/null || {
            echo "UNKNOWN:$(date '+%Y-%m-%d %H:%M:%S')"
            return
        }
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
        echo "Updated by PID $$ at $(date)"
    } > "$STATE_FILE"
}

calculate_outage_duration() {
    local start_time="$1"
    local end_time="$2"
    
    local start_epoch end_epoch duration
    
    start_epoch=$(date -d "$start_time" +%s 2>/dev/null) || {
        echo "N/A"
        return 1
    }
    
    end_epoch=$(date -d "$end_time" +%s 2>/dev/null) || {
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
    local failed_targets="$5"
    local error_details="$6"
    
    # Escape CSV fields (nahrazení čárek středníky)
    failed_targets="${failed_targets//,/;}"
    error_details="${error_details//,/;}"
    
    echo "$timestamp,$status,$latency,$duration,$failed_targets,$error_details" >> "$LOG_FILE"
}

# ===== CLOUD BACKUP =====

upload_to_cloud() {
    [[ ! -f "$LOG_FILE" ]] && return 1
    
    if ! command -v rclone >/dev/null 2>&1; then
        log_message WARN "rclone není nainstalován, přeskakuji upload"
        return 1
    fi
    
    if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:$"; then
        log_message WARN "rclone remote '$RCLONE_REMOTE' není nakonfigurován"
        return 1
    fi
    
    log_message DEBUG "Uploading do cloudu..."
    
    if rclone copy "$LOG_FILE" "$RCLONE_REMOTE:$RCLONE_PATH" --quiet; then
        LAST_UPLOAD_TIME=$(date +%s)
        log_message INFO "Upload do cloudu úspěšný"
        return 0
    else
        log_message ERROR "Upload do cloudu selhal"
        return 1
    fi
}

should_upload() {
    local current_time
    current_time=$(date +%s)
    local time_since_upload=$((current_time - LAST_UPLOAD_TIME))
    
    [[ $time_since_upload -ge $UPLOAD_INTERVAL ]]
}

# ===== LOG ROTACE =====

check_log_rotation() {
    [[ ! -f "$LOG_FILE" ]] && return
    
    local log_size
    log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    
    if [[ $log_size -gt $MAX_LOG_SIZE ]]; then
        local backup_file="${LOG_FILE%.csv}-$(date '+%Y%m%d_%H%M%S').csv"
        
        mv "$LOG_FILE" "$backup_file"
        echo "timestamp,status,latency_ms,outage_duration,failed_targets,error_details" > "$LOG_FILE"
        
        log_message INFO "Log rotován: $backup_file (velikost: $((log_size/1024))KB)"
        
        # Async upload rotovaného souboru
        (rclone copy "$backup_file" "$RCLONE_REMOTE:$RCLONE_PATH" --quiet &) 2>/dev/null
    fi
}

# ===== CLEANUP =====

cleanup_and_exit() {
    log_message INFO "Ukončuji monitoring..."
    release_lock
    
    # Ukončení background procesů
    jobs -p | xargs -r kill 2>/dev/null || true
    
    exit 0
}

# ===== HLAVNÍ MONITORING LOOP =====

main_loop() {
    log_message INFO "Spouštím monitoring loop"
    log_message INFO "Cíle: ${PING_TARGETS[*]}"
    log_message INFO "Interval: ${PING_INTERVAL}s, Ping: -c $PING_COUNT -W $PING_TIMEOUT"
    log_message INFO "Úspěch: $SUCCESS_THRESHOLD/${#PING_TARGETS[@]} cílů"
    
    while [[ "$SHUTDOWN_REQUESTED" == "false" ]]; do
        # Kontrola rotace logu
        check_log_rotation
        
        # Provedení ping testů
        local current_time
        current_time=$(date '+%Y-%m-%d %H:%M:%S')
        
        local test_result
        test_result=$(ping_test_all_targets)
        
        # Parsování výsledku
        IFS=':' read -r current_status latency failed_targets error_details <<< "$test_result"
        
        # Čtení předchozího stavu
        local previous_state
        previous_state=$(read_previous_state)
        IFS=':' read -r previous_status previous_time <<< "$previous_state"
        
        # Detekce změny stavu
        if [[ "$current_status" != "$previous_status" ]]; then
            log_message INFO "Změna stavu: $previous_status -> $current_status"
            
            case "$current_status" in
                "DOWN")
                    log_to_csv "$current_time" "DOWN" "N/A" "N/A" "$failed_targets" "$error_details"
                    log_message WARN "Připojení DOWN - selhaly cíle: $failed_targets"
                    ;;
                "UP")
                    if [[ "$previous_status" == "DOWN" ]]; then
                        local outage_duration
                        outage_duration=$(calculate_outage_duration "$previous_time" "$current_time")
                        
                        log_to_csv "$current_time" "UP" "$latency" "$outage_duration" "" ""
                        log_message INFO "Připojení obnoveno (${latency}ms) - výpadek: $outage_duration"
                    fi
                    ;;
            esac
            
            # Aktualizace stavu
            update_state "$current_status" "$current_time"
            
            # Okamžitý upload při změně stavu
            upload_to_cloud &
        fi
        
        # Pravidelný upload
        if should_upload; then
            upload_to_cloud &
        fi
        
        # Čekání do dalšího cyklu
        sleep "$PING_INTERVAL"
    done
}

# ===== MAIN =====

main() {
    # Kontrola argumentů
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                ;;
            -h|--help)
                echo "Použití: $0 [-v|--verbose] [-h|--help]"
                echo "  -v, --verbose    Podrobný výstup"
                echo "  -h, --help       Tato nápověda"
                exit 0
                ;;
            *)
                echo "Neznámý parametr: $1" >&2
                exit 1
                ;;
        esac
        shift
    done
    
    # Inicializace
    acquire_lock
    initialize
    
    # Spuštění hlavní smyčky
    main_loop
    
    # Cleanup
    cleanup_and_exit
}

# Spuštění pouze pokud je skript spuštěn přímo
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
