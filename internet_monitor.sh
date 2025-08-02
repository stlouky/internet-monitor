#!/bin/bash

#################################################################
# Internet Connection Monitor - Refactored v2.1
# 
# Účel: Monitoring připojení k ISP pro evidence výpadků
# Testuje cestu k ISP podle traceroute výstupu
# Zaznamenává výpadky do CSV pro stížnosti na ČTÚ/ISP
#################################################################

set -euo pipefail  # Bezpečné nastavení Bash: fail na chybu/nezadanou proměnnou

# ===== KONFIGURACE =====

# Staticky nastavené IP adresy pro ping (edituj podle své trasy, každý je 1 hop)
readonly PING_TARGETS=(
    "192.168.1.1"      # Domácí router
    "10.4.40.1"        # První hop ISP (anténa/AP)
    "100.100.4.254"    # Druhý hop StarNet
    "172.31.255.2"     # Třetí hop (backbone)
    "88.86.97.137"     # StarNet customer router
)

# Intervaly a parametry testů
readonly PING_INTERVAL=30      # Jak často testovat (sekundy)
readonly PING_COUNT=2          # Kolik pingů na cíl
readonly PING_TIMEOUT=2        # Timeout pro 1 ping (s)
readonly SUCCESS_THRESHOLD=${#PING_TARGETS[@]}  # Kolik cílů musí odpovědět (všechny)

# Cesty k souborům – EDITUJ dle potřeby!
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # Cesta k aktuálnímu skriptu
readonly LOG_FILE="$HOME/poruchy.csv"        # CSV log s výsledky
readonly STATE_FILE="$HOME/.inet_monitor_state"   # Soubor pro ukládání posledního stavu (UP/DOWN + čas)
readonly LOCK_FILE="$HOME/.inet_monitor.lock"     # Zámek proti více instancím

# Cloud backup (rclone)
readonly RCLONE_REMOTE="protondrive"    # Název vzdáleného úložiště v rclone
readonly RCLONE_PATH="monitoring/"      # Cílová složka na cloudu
readonly UPLOAD_INTERVAL=3600           # Minimální interval mezi uploady (s)

# Ostatní nastavení
readonly MAX_LOG_SIZE=10485760  # 10 MB (rotace logu)
readonly VERBOSE=true           # Detailní výstup (nastav na false pro ticho)

# ===== GLOBÁLNÍ PROMĚNNÉ =====

declare -g SHUTDOWN_REQUESTED=false      # Indikace požadavku na ukončení (přerušení/kill)
declare -g LAST_UPLOAD_TIME=0            # Čas posledního uploadu do cloudu

# ===== UTILITY FUNKCE =====

# Logování zpráv s úrovní (INFO/WARN/ERROR/DEBUG) na výstup i (případně) do syslogu
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Výpis na stdout/stderr podle úrovně
    case "$level" in
        ERROR) echo "[$timestamp] ERROR: $message" >&2 ;;
        WARN)  echo "[$timestamp] WARN:  $message" >&2 ;;
        INFO)  echo "[$timestamp] INFO:  $message" ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo "[$timestamp] DEBUG: $message" ;;
    esac
    
    # Zápis do syslogu (logger), pokud je zapnutý verbose a logger je dostupný
    if [[ "$VERBOSE" == "true" ]] && command -v logger >/dev/null 2>&1; then
        logger -t "inet_monitor" "$level: $message"
    fi
}

# Ukončení se zprávou a úklidem (log, release lock)
error_exit() {
    local exit_code="$1"
    local message="$2"
    log_message ERROR "$message"
    cleanup_and_exit
    exit "$exit_code"
}

# ===== LOCK FILE MANAGEMENT =====

# Získání locku (aby neběžely dvě instance)
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local existing_pid
        existing_pid=$(cat "$LOCK_FILE")
        
        if kill -0 "$existing_pid" 2>/dev/null; then
            error_exit 1 "Již běží jiná instance (PID: $existing_pid)"
        else
            log_message WARN "Odstraňuji starý lock file (proces už nežije)"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_message DEBUG "Lock získán"
}

# Uvolnění locku na konci
release_lock() {
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    log_message DEBUG "Lock uvolněn"
}

# ===== INICIALIZACE =====

# Inicializace prostředí – složky, soubory, trap signálů
initialize() {
    log_message INFO "Inicializace monitoring skriptu"
    
    # Vytvoření adresářů podle potřeby
    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"
    
    # Pokud není log, založ nový se záhlavím
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "timestamp,status,latency_ms,outage_duration,failed_targets,error_details" > "$LOG_FILE"
        log_message INFO "Vytvořen CSV log: $LOG_FILE"
    fi
    
    # Pokud není state file, vytvoř nový (výchozí stav UP)
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "UP" > "$STATE_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE"
        log_message INFO "Inicializován stavový soubor"
    fi
    
    # Trap na ukončení (SIGINT/SIGTERM) – nastaví SHUTDOWN_REQUESTED=true
    trap 'SHUTDOWN_REQUESTED=true; log_message INFO "Shutdown požadován"' SIGINT SIGTERM
}

# ===== PING TESTY =====

# Otestuje jeden konkrétní cíl (IP) – vrací string ve formátu "SUCCESS:latence" nebo "FAIL:typ_chyby"
test_single_target() {
    local target="$1"
    local output exit_code latency
    
    output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" 2>&1)
    exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        # Najde největší "time=xxx" v řetězci, extrahuje ms (případně celé číslo)
        latency=$(echo "$output" | grep -oE "time=[0-9]+(\.[0-9]+)?" | tail -1 | cut -d'=' -f2)
        latency=${latency%.*}  # Odstraň desetinnou část
        echo "SUCCESS:${latency:-0}"
    else
        # Typizace selhání podle hlášek ping
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

# Otestuje všechny cíle v PING_TARGETS, spočítá počet úspěšných, celkovou latenci, sebere errory
# Výsledek: pro UP "UP:latence::n/m", pro DOWN "DOWN:0:selhane_cile:detaily"
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
    
    # Odstraní případnou koncovou čárku (pro CSV)
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

# Načte předchozí stav z $STATE_FILE (status:čas)
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

# Aktualizuje stavový soubor (status, čas)
update_state() {
    local status="$1"
    local timestamp="$2"
    
    {
        echo "$status"
        echo "$timestamp"  
        echo "Updated by PID $$ at $(date)"
    } > "$STATE_FILE"
}

# Spočítá délku výpadku (od-do), vrací formát hh:mm:ss
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

# Zápis výsledku do CSV logu (úprava pro oddělení čárek ve stringu)
log_to_csv() {
    local timestamp="$1"
    local status="$2"
    local latency="$3"
    local duration="$4"
    local failed_targets="$5"
    local error_details="$6"
    
    # Nahrazení čárek středníky (CSV friendly)
    failed_targets="${failed_targets//,/;}"
    error_details="${error_details//,/;}"
    
    echo "$timestamp,$status,$latency,$duration,$failed_targets,$error_details" >> "$LOG_FILE"
}

# ===== CLOUD BACKUP =====

# Upload CSV do cloudu přes rclone, pokud je dostupný a nakonfigurovaný remote
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

# Vrací true/false: je čas na pravidelný upload do cloudu?
should_upload() {
    local current_time
    current_time=$(date +%s)
    local time_since_upload=$((current_time - LAST_UPLOAD_TIME))
    [[ $time_since_upload -ge $UPLOAD_INTERVAL ]]
}

# ===== LOG ROTACE =====

# Kontrola velikosti logu, pokud přesáhne limit, provede rotaci a založí nový log
check_log_rotation() {
    [[ ! -f "$LOG_FILE" ]] && return
    
    # Kompatibilita BSD vs GNU stat (BSD má -f%z, GNU -c%s)
    local log_size
    log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    
    if [[ $log_size -gt $MAX_LOG_SIZE ]]; then
        local backup_file="${LOG_FILE%.csv}-$(date '+%Y%m%d_%H%M%S').csv"
        mv "$LOG_FILE" "$backup_file"
        echo "timestamp,status,latency_ms,outage_duration,failed_targets,error_details" > "$LOG_FILE"
        log_message INFO "Log rotován: $backup_file (velikost: $((log_size/1024))KB)"
        # Asynchronní upload rotovaného souboru (neblokuje běh)
        (rclone copy "$backup_file" "$RCLONE_REMOTE:$RCLONE_PATH" --quiet &) 2>/dev/null
    fi
}

# ===== CLEANUP =====

# Úklid při ukončení (release lock, kill background joby)
cleanup_and_exit() {
    log_message INFO "Ukončuji monitoring..."
    release_lock
    # Kill background joby (např. async upload)
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
        check_log_rotation    # Každý cyklus kontrola velikosti logu
        
        # Čas testu
        local current_time
        current_time=$(date '+%Y-%m-%d %H:%M:%S')
        
        # Proveď ping testy všech cílů
        local test_result
        test_result=$(ping_test_all_targets)
        
        # Rozparsování výsledku na proměnné
        IFS=':' read -r current_status latency failed_targets error_details <<< "$test_result"
        
        # Zjisti předchozí stav (UP/DOWN a čas)
        local previous_state
        previous_state=$(read_previous_state)
        IFS=':' read -r previous_status previous_time <<< "$previous_state"
        
        # Pokud nastala změna stavu, loguj a update
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
            
            update_state "$current_status" "$current_time"
            upload_to_cloud &   # Okamžitý upload do cloudu na změnu stavu (async)
        fi
        
        # Pravidelný (časovaný) upload, i bez změny stavu
        if should_upload; then
            upload_to_cloud &
        fi
        
        # Čekání do dalšího cyklu
        sleep "$PING_INTERVAL"
    done
}

# ===== MAIN =====

main() {
    # Nepodporuje uživatelské parametry (vše natvrdo, jednoduše)
    acquire_lock
    initialize
    main_loop
    cleanup_and_exit
}

# Spouštění pouze pokud je skript spuštěn přímo (ne jako import)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
