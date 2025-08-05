#!/bin/bash
#########################################################################
# Internet Hop Monitor for Void Linux
#
# Diagnostika výpadků a vysoké latence na klíčových síťových bodech (hopy)
# Určeno pro troubleshooting a argumentaci vůči poskytovateli internetu.
#
# Sleduje 4 konkrétní hopy:
#   192.168.1.1       # ROUTER      - Tvůj domácí router
#   10.4.40.1         # CPE/ANTENA  - První zařízení ISP (switch, anténa, bridge)
#   100.100.4.254     # CGNAT       - Carrier-Grade NAT router ISP
#   172.31.255.2      # ISP_CORE    - Páteřní bod poskytovatele
#
# Typy záznamů:
#   DOWN         - Výpadek konektivity (ani jeden ping neprojde)
#   UP           - Obnovení spojení, vypočítána délka výpadku
#   HIGH_LATENCY - Vysoká odezva (průměrný ping > LATENCY_THRESHOLD ms)
#
# Výstup CSV:
# timestamp;hop_ip;hop_name;status;latency_ms;down_since;up_since;duration_sec;error_details
#
# Logy se každou hodinu synchronizují na ProtonDrive (rclone).
#
# Autor: 0xF1X
#########################################################################

# ==== KONFIGURACE ====
declare -A HOPS=(
    ["192.168.1.1"]="ROUTER"
    ["10.4.40.1"]="CPE/ANTENA"
    ["100.100.4.254"]="CGNAT"
    ["172.31.255.2"]="ISP_CORE"
)

PING_INTERVAL=30
PING_COUNT=3
PING_TIMEOUT=2
LATENCY_THRESHOLD=100         # ms

LOG_FILE="/home/w3men0/poruchy.csv"
LOG_TEXT_FILE="/home/w3men0/inet_monitor.log"
STATE_FILE="/home/w3men0/.inet_monitor_state"
LOCK_FILE="/tmp/inet_monitor.lock"

RCLONE_REMOTE="protondrive"
RCLONE_PATH="monitoring/"
UPLOAD_INTERVAL=3600

MAX_LOG_SIZE=10485760

set -u
declare -g SHUTDOWN_REQUESTED=0

log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_TEXT_FILE"
}

cleanup() {
    log_msg "Skript ukončen."
    rm -f "$LOCK_FILE"
    exit 0
}
trap 'SHUTDOWN_REQUESTED=1' SIGINT SIGTERM
trap cleanup EXIT

if [[ -f "$LOCK_FILE" ]]; then
    if kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
        log_msg "Jiná instance běží (PID: $(cat "$LOCK_FILE"))"
        exit 1
    else
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"

mkdir -p "$(dirname "$LOG_FILE")"

if [[ ! -f "$LOG_FILE" ]]; then
    cat <<EOF > "$LOG_FILE"
# LEGEND: timestamp;hop_ip;hop_name;status;latency_ms;down_since;up_since;duration_sec;error_details
# HOPS: 192.168.1.1=ROUTER, 10.4.40.1=CPE/ANTENA, 100.100.4.254=CGNAT, 172.31.255.2=ISP_CORE
timestamp;hop_ip;hop_name;status;latency_ms;down_since;up_since;duration_sec;error_details
EOF
fi

# --- BEZPEČNÁ INICIALIZACE POLE S PŘEDVÝCHOZÍMI HODNOTAMI ---
declare -A LAST_STATUS LAST_DOWN_SINCE

for ip in "${!HOPS[@]}"; do
    LAST_STATUS["$ip"]="UP"
    LAST_DOWN_SINCE["$ip"]=""
done

# Pokud existuje STATE_FILE, přepiš hodnoty podle souboru (pouze sledované IP)
if [[ -f "$STATE_FILE" ]]; then
    while IFS=',' read -r ip status down_since; do
        [[ -n "$ip" && -n "${HOPS[$ip]+x}" ]] && LAST_STATUS["$ip"]=$status && LAST_DOWN_SINCE["$ip"]=$down_since
    done < "$STATE_FILE"
fi

save_state() {
    > "$STATE_FILE"
    for ip in "${!HOPS[@]}"; do
        echo "$ip,${LAST_STATUS[$ip]},${LAST_DOWN_SINCE[$ip]}" >> "$STATE_FILE"
    done
}

calculate_duration() {
    local start="$1" end="$2"
    local t1=$(date -d "$start" +%s 2>/dev/null)
    local t2=$(date -d "$end" +%s 2>/dev/null)
    [[ -z "$t1" || -z "$t2" || $t1 -gt $t2 ]] && echo "N/A" && return
    echo $((t2 - t1))
}

upload_to_cloud() {
    if ! command -v rclone >/dev/null 2>&1; then
        log_msg "rclone není nainstalován, upload přeskočen."
        return
    fi
    if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:$"; then
        log_msg "rclone remote '$RCLONE_REMOTE' není nakonfigurován."
        return
    fi
    rclone copy "$LOG_FILE" "$RCLONE_REMOTE:$RCLONE_PATH" --quiet
    log_msg "poruchy.csv synchronizován na ProtonDrive."
}

check_log_rotation() {
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $log_size -gt $MAX_LOG_SIZE ]]; then
            local backup="${LOG_FILE%.csv}-$(date '+%Y%m%d_%H%M%S').csv"
            mv "$LOG_FILE" "$backup"
            cat <<EOF > "$LOG_FILE"
# LEGEND: timestamp;hop_ip;hop_name;status;latency_ms;down_since;up_since;duration_sec;error_details
# HOPS: 192.168.1.1=ROUTER, 10.4.40.1=CPE/ANTENA, 100.100.4.254=CGNAT, 172.31.255.2=ISP_CORE
timestamp;hop_ip;hop_name;status;latency_ms;down_since;up_since;duration_sec;error_details
EOF
            log_msg "Log rotován: $backup"
        fi
    fi
}

# Test jednoho hopu, výstup: status:latency:err
test_hop() {
    local ip="$1"
    local name="$2"
    local output latency status err
    output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" 2>&1)
    if [[ $? -eq 0 ]]; then
        # RTT průměr (ms)
        latency=$(echo "$output" | awk -F'/' '/rtt|round-trip/ {print int($5)}')
        [[ -z "$latency" || ! "$latency" =~ ^[0-9]+$ ]] && latency=0
        if (( latency > LATENCY_THRESHOLD )); then
            status="HIGH_LATENCY"
            err="RTT=${latency}ms"
        else
            status="UP"
            err=""
        fi
    else
        status="DOWN"
        latency="N/A"
        if echo "$output" | grep -q "Name or service not known"; then
            err="DNS_FAIL"
        elif echo "$output" | grep -q "Network is unreachable"; then
            err="NET_UNREACHABLE"
        elif echo "$output" | grep -q "Destination Host Unreachable"; then
            err="HOST_UNREACHABLE"
        else
            err="TIMEOUT"
        fi
    fi
    echo "$status:$latency:$err"
}

log_event() {
    local timestamp="$1" ip="$2" name="$3" status="$4" latency="$5" down_since="$6" up_since="$7" duration="$8" err="$9"
    echo "$timestamp;$ip;$name;$status;$latency;$down_since;$up_since;$duration;$err" >> "$LOG_FILE"
}

log_msg "Internet Hop Monitor spuštěn."

last_upload_time=$(date +%s)

while [[ "$SHUTDOWN_REQUESTED" -eq 0 ]]; do
    check_log_rotation

    now=$(date '+%Y-%m-%d %H:%M:%S')

    for ip in "${!HOPS[@]}"; do
        name="${HOPS[$ip]}"
        IFS=':' read -r status latency err < <(test_hop "$ip" "$name")
        prev_status="${LAST_STATUS[$ip]}"
        prev_down_since="${LAST_DOWN_SINCE[$ip]}"

        # DOWN event
        if [[ "$status" == "DOWN" && "$prev_status" != "DOWN" ]]; then
            log_event "$now" "$ip" "$name" "DOWN" "N/A" "$now" "" "" "$err"
            LAST_STATUS["$ip"]="DOWN"
            LAST_DOWN_SINCE["$ip"]="$now"
            log_msg "[$name/$ip] Výpadek: $err"
        # UP event (obnova)
        elif [[ "$status" == "UP" && "$prev_status" == "DOWN" ]]; then
            duration=$(calculate_duration "$prev_down_since" "$now")
            log_event "$now" "$ip" "$name" "UP" "$latency" "$prev_down_since" "$now" "$duration" "$err"
            LAST_STATUS["$ip"]="UP"
            LAST_DOWN_SINCE["$ip"]=""
            log_msg "[$name/$ip] Obnoveno po $duration s"
        # HIGH_LATENCY (pouze pokud nebylo již v předchozím cyklu high latency)
        elif [[ "$status" == "HIGH_LATENCY" && "$prev_status" != "HIGH_LATENCY" ]]; then
            log_event "$now" "$ip" "$name" "HIGH_LATENCY" "$latency" "" "" "" "$err"
            LAST_STATUS["$ip"]="HIGH_LATENCY"
            log_msg "[$name/$ip] Vysoká latence: $latency ms"
        # Pokud je vše OK (UP a předtím bylo HIGH_LATENCY), poznamenat obnovení normálu
        elif [[ "$status" == "UP" && "$prev_status" == "HIGH_LATENCY" ]]; then
            log_event "$now" "$ip" "$name" "UP" "$latency" "" "" "" ""
            LAST_STATUS["$ip"]="UP"
            log_msg "[$name/$ip] Latence OK: $latency ms"
        fi
    done

    save_state

    now_epoch=$(date +%s)
    if (( now_epoch - last_upload_time >= UPLOAD_INTERVAL )); then
        upload_to_cloud
        last_upload_time=$now_epoch
    fi

    for ((i=0; i<PING_INTERVAL; i++)); do
        [[ "$SHUTDOWN_REQUESTED" -eq 1 ]] && break
        sleep 1
    done
done
