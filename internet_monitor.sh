#!/bin/bash

#################################################################
# Internet Connection Monitor for Void Linux (runit/tmux/screen)
# Sleduje připojení k internetu a loguje všechny výpadky
# Pro dlouhodobou evidenci při stížnostech na ISP/ČTÚ
# Verze: 2.0 (Enhanced) - Robustní monitoring s více cíli
#################################################################

# ===== KONFIGURACE - UPRAVTE PODLE POTŘEBY =====

# Ping parametry - více cílů pro zvýšenou spolehlivost
PING_TARGETS=("8.8.8.8" "1.1.1.1" "8.8.4.4")     # Google DNS, Cloudflare, Google DNS2
PING_INTERVAL=30                                 # Interval mezi pingy (sekundy)
PING_COUNT=2                                     # Počet ping paketů (-c)
PING_TIMEOUT=2                                   # Timeout pro ping (-W, sekundy)
PING_SUCCESS_THRESHOLD=1                         # Min. počet úspěšných cílů pro UP stav

# Cesty a soubory
LOG_FILE="$HOME/poruchy.csv"              # Cesta k CSV logu
TEMP_STATE="$HOME/.inet_monitor.state"    # Dočasný soubor pro stav
LOCK_FILE="$HOME/.inet_monitor.lock"      # Lock soubor proti duplicitním instancím

# Cloud upload (rclone)
RCLONE_REMOTE="protondrive"                      # Název rclone remote (gdrive, proton, apod.)
RCLONE_PATH="monitoring/"                        # Cesta v cloudu
UPLOAD_ON_CHANGE=true                            # Upload při každé změně stavu
UPLOAD_INTERVAL=3600                             # Pravidelný upload (sekundy, 0=vypnuto)

# E-mail notifikace (volitelné)
SEND_EMAIL=false                                 # Zapnout/vypnout e-mail notifikace
EMAIL_RECIPIENT="admin@example.com"                # E-mail příjemce
EMAIL_SUBJECT_PREFIX="[Internet Monitor]"        # Prefix předmětu e-mailu

# Rozšířené možnosti
MAX_LOG_SIZE=10485760                            # Max. velikost logu (10MB)
VERBOSE_LOGGING=true                             # Podrobné logování do systému
HEALTH_CHECK_INTERVAL=300                        # Zdravotní kontrola skriptu (5min)

# ===== INICIALIZACE A KONTROLA PROSTŘEDÍ =====

# Kontrola duplicitní instance
if [[ -f "$LOCK_FILE" ]]; then
    if kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
        echo "ERROR: Another instance is already running (PID: $(cat "$LOCK_FILE"))"
        exit 1
    else
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"

# Vytvoření adresářů pokud neexistují
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$TEMP_STATE")"

# Vytvoření CSV souboru s rozšířenou hlavičkou
if [[ ! -f "$LOG_FILE" ]]; then
    echo "timestamp,status,latency_ms,outage_duration,target_tested,error_details,script_version" > "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Created enhanced log file: $LOG_FILE"
fi

# Inicializace stavového souboru
if [[ ! -f "$TEMP_STATE" ]]; then
    echo "UP" > "$TEMP_STATE"
    echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$TEMP_STATE"
    echo "Script started" >> "$TEMP_STATE"
fi

# ===== FUNKCE =====

# Funkce pro logování zpráv (rozšířená)
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $message"
    
    # Zápis do syslogu pokud je dostupný
    if [[ "$VERBOSE_LOGGING" == "true" ]] && command -v logger >/dev/null 2>&1; then
        logger -t "inet_monitor" "$message"
    fi
}

# Funkce pro výpočet délky výpadku (vylepšená)
calculate_outage_duration() {
    local start_time="$1"
    local end_time="$2"
    
    local start_epoch=$(date -d "$start_time" +%s 2>/dev/null)
    local end_epoch=$(date -d "$end_time" +%s 2>/dev/null)
    
    if [[ -z "$start_epoch" || -z "$end_epoch" || $start_epoch -gt $end_epoch ]]; then
        echo "N/A"
        return
    fi
    
    local duration=$((end_epoch - start_epoch))
    local days=$((duration / 86400))
    local hours=$(((duration % 86400) / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    if [[ $days -gt 0 ]]; then
        printf "%dd %02d:%02d:%02d" "$days" "$hours" "$minutes" "$seconds"
    else
        printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
    fi
}

# Funkce pro odesílání e-mailových notifikací
send_email_notification() {
    local subject="$1"
    local body="$2"
    
    if [[ "$SEND_EMAIL" != "true" ]]; then
        return
    fi
    
    if command -v mail >/dev/null 2>&1; then
        echo -e "$body" | mail -s "$EMAIL_SUBJECT_PREFIX $subject" "$EMAIL_RECIPIENT" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            log_message "Email notification sent successfully"
        else
            log_message "WARNING: Failed to send email notification"
        fi
    elif command -v sendmail >/dev/null 2>&1; then
        {
            echo "To: $EMAIL_RECIPIENT"
            echo "Subject: $EMAIL_SUBJECT_PREFIX $subject"
            echo ""
            echo -e "$body"
        } | sendmail "$EMAIL_RECIPIENT" 2>/dev/null
        log_message "Email notification sent via sendmail"
    else
        log_message "WARNING: No mail command found, email notification skipped"
    fi
}

# Funkce pro upload do cloudu (vylepšená)
upload_to_cloud() {
    if ! command -v rclone >/dev/null 2>&1; then
        log_message "WARNING: rclone not found, skipping cloud upload"
        return 1
    fi
    
    # Kontrola konfigurace rclone
    if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:$"; then
        log_message "WARNING: rclone remote '$RCLONE_REMOTE' not configured"
        return 1
    fi
    
    local upload_start=$(date +%s)
    if rclone copy "$LOG_FILE" "$RCLONE_REMOTE:$RCLONE_PATH" --quiet; then
        local upload_time=$(($(date +%s) - upload_start))
        log_message "Successfully uploaded log to cloud ($RCLONE_REMOTE) in ${upload_time}s"
        return 0
    else
        log_message "ERROR: Failed to upload log to cloud"
        return 1
    fi
}

# Robustní ping test s více cíli
ping_test() {
    local successful_pings=0
    local total_latency=0
    local tested_targets=""
    local error_details=""
    
    for target in "${PING_TARGETS[@]}"; do
        tested_targets="${tested_targets}${target};"
        
        local output
        output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            # Extrakce latence - robustnější parsing
            local latency=$(echo "$output" | grep -oE "time=[0-9]+(\.[0-9]+)?" | tail -1 | cut -d'=' -f2 | cut -d'.' -f1)
            if [[ -n "$latency" && "$latency" =~ ^[0-9]+$ ]]; then
                total_latency=$((total_latency + latency))
                successful_pings=$((successful_pings + 1))
            fi
        else
            # Zachycení chybových zpráv
            if echo "$output" | grep -q "Name or service not known"; then
                error_details="${error_details}DNS_FAIL;"
            elif echo "$output" | grep -q "Network is unreachable"; then
                error_details="${error_details}NET_UNREACHABLE;"
            elif echo "$output" | grep -q "Destination Host Unreachable"; then
                error_details="${error_details}HOST_UNREACHABLE;"
            else
                error_details="${error_details}TIMEOUT;"
            fi
        fi
    done
    
    if [[ $successful_pings -ge $PING_SUCCESS_THRESHOLD ]]; then
        local avg_latency=$((total_latency / successful_pings))
        echo "UP:$avg_latency:$tested_targets:$successful_pings/${#PING_TARGETS[@]}"
    else
        echo "DOWN:0:$tested_targets:$error_details"
    fi
}

# Kontrola velikosti logu a rotace
check_log_rotation() {
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        
        if [[ $log_size -gt $MAX_LOG_SIZE ]]; then
            local backup_file="${LOG_FILE%.csv}-$(date '+%Y%m%d_%H%M%S').csv"
            mv "$LOG_FILE" "$backup_file"
            echo "timestamp,status,latency_ms,outage_duration,target_tested,error_details,script_version" > "$LOG_FILE"
            log_message "Log rotated: $backup_file (size: ${log_size} bytes)"
            
            # Upload rotovaného souboru
            if [[ "$UPLOAD_ON_CHANGE" == "true" ]]; then
                rclone copy "$backup_file" "$RCLONE_REMOTE:$RCLONE_PATH" --quiet &
            fi
        fi
    fi
}

# Zdravotní kontrola skriptu
health_check() {
    local current_time=$(date +%s)
    local last_check_file="/tmp/inet_monitor_health"
    
    if [[ -f "$last_check_file" ]]; then
        local last_check=$(cat "$last_check_file")
        if [[ $((current_time - last_check)) -lt $HEALTH_CHECK_INTERVAL ]]; then
            return
        fi
    fi
    
    echo "$current_time" > "$last_check_file"
    
    # Kontrola dostupnosti cílových serverů
    local reachable_targets=0
    for target in "${PING_TARGETS[@]}"; do
        if ping -c 1 -W 1 "$target" >/dev/null 2>&1; then
            reachable_targets=$((reachable_targets + 1))
        fi
    done
    
    if [[ $reachable_targets -eq 0 ]]; then
        log_message "WARNING: No ping targets are reachable - possible network issue"
    fi
    
    # Kontrola místa na disku
    local available_space=$(df "$(dirname "$LOG_FILE")" | tail -1 | awk '{print $4}')
    if [[ $available_space -lt 100000 ]]; then  # Méně než 100MB
        log_message "WARNING: Low disk space available: ${available_space}KB"
    fi
}

# Funkce pro cleanup při ukončení
cleanup() {
    log_message "Monitoring stopped by user (graceful shutdown)"
    rm -f "$LOCK_FILE"
    exit 0
}

# ===== HLAVNÍ SMYČKA =====

log_message "Starting enhanced internet connection monitoring v2.0"
log_message "Targets: ${PING_TARGETS[*]}, Interval: ${PING_INTERVAL}s, Ping: -c $PING_COUNT -W $PING_TIMEOUT"
log_message "Success threshold: $PING_SUCCESS_THRESHOLD/${#PING_TARGETS[@]} targets"
log_message "Log file: $LOG_FILE (max size: $((MAX_LOG_SIZE/1024/1024))MB)"
log_message "Cloud: $RCLONE_REMOTE:$RCLONE_PATH (upload on change: $UPLOAD_ON_CHANGE)"
log_message "Email notifications: $SEND_EMAIL"

# Nastavení trap pro graceful shutdown
trap cleanup SIGINT SIGTERM

# Čítače pro různé intervaly
upload_counter=0
health_counter=0

while true; do
    # Zdravotní kontrola
    health_counter=$((health_counter + PING_INTERVAL))
    if [[ $health_counter -ge $HEALTH_CHECK_INTERVAL ]]; then
        health_check
        health_counter=0
    fi
    
    # Kontrola rotace logu
    check_log_rotation
    
    # Provedení ping testu
    result=$(ping_test)
    IFS=':' read -r current_status latency tested_targets extra_info <<< "$result"
    current_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Čtení aktuálního stavu
    if [[ -f "$TEMP_STATE" ]]; then
        previous_status=$(head -n1 "$TEMP_STATE")
        previous_time=$(sed -n '2p' "$TEMP_STATE")
    else
        previous_status="UNKNOWN"
        previous_time="$current_time"
    fi
    
    # Detekce změny stavu
    if [[ "$current_status" != "$previous_status" ]]; then
        log_message "Status change: $previous_status -> $current_status"
        
        if [[ "$current_status" == "DOWN" ]]; then
            # Přechod do DOWN stavu
            echo "$current_time,DOWN,N/A,N/A,$tested_targets,$extra_info,v2.0" >> "$LOG_FILE"
            log_message "Connection DOWN - all targets failed: $extra_info"
            
            # E-mail notifikace o výpadku
            send_email_notification "Connection DOWN" \
                "Internet connection lost at $current_time\nTested targets: $tested_targets\nError details: $extra_info"
            
        elif [[ "$current_status" == "UP" && "$previous_status" == "DOWN" ]]; then
            # Návrat do UP stavu - výpočet délky výpadku
            outage_duration=$(calculate_outage_duration "$previous_time" "$current_time")
            
            echo "$current_time,UP,$latency,$outage_duration,$tested_targets,$extra_info,v2.0" >> "$LOG_FILE"
            log_message "Connection restored (${latency}ms avg) - outage duration: $outage_duration ($extra_info)"
            
            # E-mail notifikace o obnovení
            send_email_notification "Connection restored" \
                "Internet connection restored at $current_time\nAverage latency: ${latency}ms\nOutage duration: $outage_duration\nSuccessful targets: $extra_info"
        fi
        
        # Aktualizace stavového souboru
        {
            echo "$current_status"
            echo "$current_time"
            echo "Status changed from $previous_status"
        } > "$TEMP_STATE"
        
        # Upload do cloudu při změně stavu
        if [[ "$UPLOAD_ON_CHANGE" == "true" ]]; then
            upload_to_cloud &  # Asynchronní upload
        fi
    fi
    
    # Pravidelný upload do cloudu
    if [[ "$UPLOAD_INTERVAL" -gt 0 ]]; then
        upload_counter=$((upload_counter + PING_INTERVAL))
        if [[ $upload_counter -ge $UPLOAD_INTERVAL ]]; then
            upload_to_cloud &  # Asynchronní upload
            upload_counter=0
        fi
    fi
    
    # Čekání do dalšího cyklu
    sleep "$PING_INTERVAL"
done
