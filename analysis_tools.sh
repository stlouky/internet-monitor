#!/bin/bash

#################################################################
# Utility skripty pro analýzu dat z Internet Connection Monitor
# Použití: source analysis_tools.sh
#################################################################

# Cesta k CSV souboru
readonly CSV_FILE="${HOME}/poruchy.csv"

# Barevné výstupy
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ===== ZÁKLADNÍ FUNKCE =====

# Kontrola existence CSV souboru
check_csv_file() {
    if [[ ! -f "$CSV_FILE" ]]; then
        echo -e "${RED}ERROR: CSV soubor nenalezen: $CSV_FILE${NC}" >&2
        return 1
    fi
    return 0
}

# Převod času na sekundy
time_to_seconds() {
    local time_str="$1"
    
    if [[ "$time_str" == "N/A" || -z "$time_str" ]]; then
        echo "0"
        return
    fi
    
    # Formát: HH:MM:SS nebo DD:HH:MM:SS
    if [[ "$time_str" =~ ^([0-9]+d )?([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        local days=0
        local hours="${BASH_REMATCH[2]}"
        local minutes="${BASH_REMATCH[3]}"
        local seconds="${BASH_REMATCH[4]}"
        
        if [[ -n "${BASH_REMATCH[1]}" ]]; then
            days="${BASH_REMATCH[1]%d *}"
        fi
        
        echo $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
    else
        echo "0"
    fi
}

# Formátování času ze sekund
seconds_to_time() {
    local total_seconds="$1"
    local days hours minutes seconds
    
    days=$((total_seconds / 86400))
    hours=$(((total_seconds % 86400) / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))
    
    if ((days > 0)); then
        printf "%dd %02d:%02d:%02d" "$days" "$hours" "$minutes" "$seconds"
    else
        printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
    fi
}

# ===== ANALÝZA FUNKCÍ =====

# Základní statistiky
show_basic_stats() {
    check_csv_file || return 1
    
    echo -e "${BLUE}=== ZÁKLADNÍ STATISTIKY ===${NC}"
    
    local total_records=$(grep -c "^[0-9]" "$CSV_FILE")
    local down_events=$(grep -c ",DOWN," "$CSV_FILE")
    local up_events=$(grep -c ",UP," "$CSV_FILE")
    
    echo "Celkový počet záznamů: $total_records"
    echo "Události DOWN: $down_events"
    echo "Události UP: $up_events"
    
    if [[ -f "$CSV_FILE" ]]; then
        local first_record=$(grep "^[0-9]" "$CSV_FILE" | head -1 | cut -d',' -f1)
        local last_record=$(grep "^[0-9]" "$CSV_FILE" | tail -1 | cut -d',' -f1)
        echo "První záznam: $first_record"
        echo "Poslední záznam: $last_record"
    fi
    
    echo
}

# Analýza výpadků za období
analyze_outages() {
    local period="${1:-30}"  # Výchozí 30 dní
    
    check_csv_file || return 1
    
    echo -e "${BLUE}=== ANALÝZA VÝPADKŮ (posledních $period dní) ===${NC}"
    
    local cutoff_date
    cutoff_date=$(date -d "$period days ago" '+%Y-%m-%d')
    
    # Filtrování záznamů za období
    local temp_file
    temp_file=$(mktemp)
    grep "^[0-9]" "$CSV_FILE" | awk -F',' -v cutoff="$cutoff_date" '$1 >= cutoff' > "$temp_file"
    
    local down_count up_count total_downtime_seconds avg_downtime
    down_count=$(grep -c ",DOWN," "$temp_file")
    up_count=$(grep -c ",UP," "$temp_file")
    
    echo "Počet výpadků: $down_count"
    echo "Počet obnovení: $up_count"
    
    if ((up_count > 0)); then
        # Výpočet celkového downtime
        total_downtime_seconds=0
        while IFS=',' read -r timestamp status latency duration targets errors; do
            if [[ "$status" == "UP" && "$duration" != "N/A" ]]; then
                local seconds
                seconds=$(time_to_seconds "$duration")
                ((total_downtime_seconds += seconds))
            fi
        done < <(grep ",UP," "$temp_file")
        
        echo "Celkový downtime: $(seconds_to_time $total_downtime_seconds)"
        
        if ((up_count > 0)); then
            avg_downtime=$((total_downtime_seconds / up_count))
            echo "Průměrný downtime: $(seconds_to_time $avg_downtime)"
        fi
        
        # Výpočet SLA
        local period_seconds=$((period * 24 * 3600))
        local uptime_percent
        uptime_percent=$(echo "scale=4; (($period_seconds - $total_downtime_seconds) / $period_seconds) * 100" | bc 2>/dev/null || echo "N/A")
        
        if [[ "$uptime_percent" != "N/A" ]]; then
            echo -e "SLA (uptime): ${GREEN}${uptime_percent}%${NC}"
        fi
    fi
    
    rm -f "$temp_file"
    echo
}

# Top nejčastější chyby
show_top_errors() {
    local limit="${1:-10}"
    
    check_csv_file || return 1
    
    echo -e "${BLUE}=== TOP $limit NEJČASTĚJŠÍCH CHYB ===${NC}"
    
    grep ",DOWN," "$CSV_FILE" | cut -d',' -f6 | \
    sed 's/;/\n/g' | grep -v '^$' | \
    sort | uniq -c | sort -nr | head -"$limit" | \
    while read count error; do
        printf "%-20s: %d\n" "$error" "$count"
    done
    
    echo
}

# Analýza latence
analyze_latency() {
    check_csv_file || return 1
    
    echo -e "${BLUE}=== ANALÝZA LATENCE ===${NC}"
    
    # Získání hodnot latence (pouze UP stavy s platnou latencí)
    local temp_file
    temp_file=$(mktemp)
    
    grep ",UP," "$CSV_FILE" | cut -d',' -f3 | \
    grep -E '^[0-9]+$' | sort -n > "$temp_file"
    
    local count min_lat max_lat avg_lat median_lat
    count=$(wc -l < "$temp_file")
    
    if ((count > 0)); then
        min_lat=$(head -1 "$temp_file")
        max_lat=$(tail -1 "$temp_file")
        avg_lat=$(awk '{sum+=$1} END {print int(sum/NR)}' "$temp_file")
        
        # Medián
        local middle=$((count / 2))
        if ((count % 2 == 0)); then
            local val1 val2
            val1=$(sed -n "${middle}p" "$temp_file")
            val2=$(sed -n "$((middle + 1))p" "$temp_file")
            median_lat=$(((val1 + val2) / 2))
        else
            median_lat=$(sed -n "$((middle + 1))p" "$temp_file")
        fi
        
        echo "Počet měření: $count"
        echo "Minimální latence: ${min_lat}ms"
        echo "Maximální latence: ${max_lat}ms"  
        echo "Průměrná latence: ${avg_lat}ms"
        echo "Medián latence: ${median_lat}ms"
        
        # Distribuční analýza
        echo
        echo "Distribuce latence:"
        awk '{
            if ($1 < 10) bucket="<10ms"
            else if ($1 < 50) bucket="10-49ms"
            else if ($1 < 100) bucket="50-99ms"
            else if ($1 < 200) bucket="100-199ms"
            else bucket="≥200ms"
            count[bucket]++
        } END {
            for (b in count) print b ": " count[b]
        }' "$temp_file" | sort
    else
        echo "Žádná platná data latence nenalezena"
    fi
    
    rm -f "$temp_file"
    echo
}

# Timeline výpadků
show_outage_timeline() {
    local days="${1:-7}"
    
    check_csv_file || return 1
    
    echo -e "${BLUE}=== TIMELINE VÝPADKŮ (posledních $days dní) ===${NC}"
    
    local cutoff_date
    cutoff_date=$(date -d "$days days ago" '+%Y-%m-%d')
    
    grep "^[0-9]" "$CSV_FILE" | \
    awk -F',' -v cutoff="$cutoff_date" '$1 >= cutoff' | \
    while IFS=',' read -r timestamp status latency duration targets errors; do
        local date_part="${timestamp%% *}"
        local time_part="${timestamp##* }"
        
        case "$status" in
            "DOWN")
                echo -e "${RED}[$date_part $time_part] DOWN${NC} - Selhaly: $targets"
                [[ -n "$errors" ]] && echo "  └─ Chyby: $errors"
                ;;
            "UP")
                local duration_info=""
                [[ "$duration" != "N/A" ]] && duration_info=" (výpadek: $duration)"
                echo -e "${GREEN}[$date_part $time_part] UP${NC} - Latence: ${latency}ms$duration_info"
                ;;
        esac
    done
    
    echo
}

# Export pro Excel/další analýzu
export_for_analysis() {
    local output_file="${1:-outage_analysis_$(date +%Y%m%d).csv}"
    
    check_csv_file || return 1
    
    echo -e "${BLUE}=== EXPORT DAT PRO ANALÝZU ===${NC}"
    
    # Vytvoření rozšířeného CSV s vypočítanými poli
    {
        echo "timestamp,date,time,status,latency_ms,outage_duration_seconds,targets_tested,error_details,day_of_week,hour"
        
        grep "^[0-9]" "$CSV_FILE" | while IFS=',' read -r timestamp status latency duration targets errors script_version; do
            local date_part="${timestamp%% *}"
            local time_part="${timestamp##* }"
            local hour="${time_part%%:*}"
            local day_of_week
            day_of_week=$(date -d "$date_part" '+%A')
            local duration_seconds
            duration_seconds=$(time_to_seconds "$duration")
            
            echo "$timestamp,$date_part,$time_part,$status,$latency,$duration_seconds,$targets,$errors,$day_of_week,$hour"
        done
    } > "$output_file"
    
    echo "Data exportována do: $output_file"
    echo "Počet záznamů: $(grep -c "^[0-9]" "$output_file")"
    echo
}

# Hlavní menu
show_menu() {
    echo -e "${YELLOW}=== INET MONITOR - ANALÝZA DAT ===${NC}"
    echo "1. Základní statistiky"
    echo "2. Analýza výpadků za období (dny)"
    echo "3. Top nejčastější chyby"
    echo "4. Analýza latence"
    echo "5. Timeline výpadků"
    echo "6. Export dat pro analýzu"
    echo "7. Zobrazit posledních 10 záznamů"
    echo "q. Ukončit"
    echo
}

# Zobrazení posledních záznamů
show_recent_records() {
    local count="${1:-10}"
    
    check_csv_file || return 1
    
    echo -e "${BLUE}=== POSLEDNÍCH $count ZÁZNAMŮ ===${NC}"
    
    {
        head -1 "$CSV_FILE"  # Hlavička
        tail -"$count" "$CSV_FILE"
    } | column -t -s','
    
    echo
}

# Interaktivní menu
interactive_menu() {
    while true; do
        show_menu
        read -p "Vyberte možnost: " choice
        
        case "$choice" in
            1) show_basic_stats ;;
            2) 
                read -p "Zadejte počet dní (výchozí 30): " days
                analyze_outages "${days:-30}"
                ;;
            3)
                read -p "Zadejte počet top chyb (výchozí 10): " limit
                show_top_errors "${limit:-10}"
                ;;
            4) analyze_latency ;;
            5)
                read -p "Zadejte počet dní (výchozí 7): " days
                show_outage_timeline "${days:-7}"
                ;;
            6)
                read -p "Zadejte název souboru (výchozí: auto): " filename
                export_for_analysis "$filename"
                ;;
            7)
                read -p "Zadejte počet záznamů (výchozí 10): " count
                show_recent_records "${count:-10}"
                ;;
            q|Q) break ;;
            *) echo -e "${RED}Neplatná volba!${NC}" ;;
        esac
        
        read -p "Stiskněte Enter pro pokračování..."
        clear
    done
}

# Pokud je skript spuštěn přímo, zobrazí menu
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    interactive_menu
fi
