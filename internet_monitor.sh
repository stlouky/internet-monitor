#!/bin/bash

#################################################################
# Internet Connection Hop Monitor - FIXED
# Sleduje hopy k ISP a loguje výpadky s ochranou proti pádu
# Opraveno: dělení nulou, správa locku, správné trapování, robustní chování
#################################################################

# --- KONFIGURACE ---
readonly PING_TARGETS=("192.168.1.1" "10.4.40.1" "100.100.4.254" "172.31.255.2")
readonly PING_INTERVAL=30
readonly PING_COUNT=2
readonly PING_TIMEOUT=2

readonly LOG_FILE="/home/w3men0/poruchy.csv"
readonly STATE_FILE="/home/w3men0/.inet_monitor_state"
readonly LOCK_FILE="/tmp/inet_monitor.lock"
readonly VERBOSE=true

# --- GLOBÁLNÍ PROMĚNNÉ ---
declare -g SHUTDOWN_REQUESTED=0

# --- FUNKCE ---
log_message() {
    local level="$1"
    local message="$2"
    if [[ "$level" == "DEBUG" && "$VERBOSE" != "true" ]]; then
        return
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $level: $message" >&2
}

cleanup() {
    log_message INFO "Ukončuji skript a uvolňuji zámek..."
    if [[ -f "$LOCK_FILE" ]] && [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
        rm -f "$LOCK_FILE"
    fi
}

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_message ERROR "Již běží jiná instance (PID: $pid). Ukončuji."
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo "$$" > "$LOCK_FILE"
}

# --- TRAPY ---
trap 'SHUTDOWN_REQUESTED=1' SIGINT SIGTERM
trap cleanup EXIT

# --- START ---
acquire_lock
log_message INFO "Internet Hop Monitor spuštěn (PID: $$)."

mkdir -p "$(dirname "$LOG_FILE")"
if [[ ! -f "$LOG_FILE" ]]; then
    echo "timestamp,status,avg_latency_ms,outage_duration_hms,failed_hops" > "$LOG_FILE"
fi

# Načtení posledního stavu
last_status="UP"
last_status_time=$(date +%s)
if [[ -f "$STATE_FILE" ]]; then
    read -r last_status last_status_time < "$STATE_FILE" || true
fi

while [[ "$SHUTDOWN_REQUESTED" -eq 0 ]]; do
    success_count=0
    total_latency=0
    failed_hops=""
    current_status="UP"

    for i in "${!PING_TARGETS[@]}"; do
        target="${PING_TARGETS[i]}"
        hop_num=$((i + 1))
        output=$(ping -c $PING_COUNT -W $PING_TIMEOUT "$target" 2>&1)
        exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            ((success_count++))
            # Robustní extrakce latence:
            latency=$(echo "$output" | awk -F'/' '/rtt/ {print int($5)}')
            if [[ -z "$latency" ]]; then
                latency=0
            fi
            ((total_latency += latency))
        else
            current_status="DOWN"
            failed_hops+="${target} (hop${hop_num});"
        fi
    done

    # Ošetření dělení nulou
    if [[ $success_count -gt 0 ]]; then
        avg_latency=$((total_latency / success_count))
    else
        avg_latency=0
    fi

    # Změna stavu?
    if [[ "$current_status" != "$last_status" ]]; then
        log_message INFO "Změna stavu: ${last_status} -> ${current_status}"
        current_time_s=$(date +%s)
        if [[ "$current_status" == "UP" ]]; then
            duration=$((current_time_s - last_status_time))
            duration_hms=$(date -u -d "@$duration" '+%H:%M:%S')
            echo "$(date '+%Y-%m-%d %H:%M:%S'),UP,${avg_latency},${duration_hms}," >> "$LOG_FILE"
            log_message INFO "PŘIPOJENÍ OBNOVENO. Výpadek trval ${duration_hms}."
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S'),DOWN,N/A,N/A,${failed_hops}" >> "$LOG_FILE"
            log_message WARN "VÝPADEK ZJIŠTĚN. Nedostupné hopy: ${failed_hops}"
        fi
        last_status="$current_status"
        last_status_time="$current_time_s"
        echo "$last_status $last_status_time" > "$STATE_FILE"
    fi

    log_message DEBUG "Cyklus dokončen. Stav: ${current_status}. Dosažitelné hopy: ${success_count}/${#PING_TARGETS[@]}."

    # Čekání s možností přerušení
    for ((i=0; i<PING_INTERVAL; i++)); do
        if [[ "$SHUTDOWN_REQUESTED" -eq 1 ]]; then
            log_message INFO "Detekován požadavek na ukončení, opouštím smyčku."
            break 2
        fi
        sleep 1
    done
done

exit 0
