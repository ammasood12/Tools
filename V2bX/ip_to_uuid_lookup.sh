#!/bin/bash

# IP to UUID Lookup Tool
# ----------------------
# This script searches system logs for a given IP address
# and extracts all associated UUIDs. It shows how many times
# each UUID appears and displays results in a clean table.
#
# Usage: Just run the script and enter an IP when prompted.
# Features: Color output, hit counts, export option, summary stats.

# ---------- Configuration ----------
VERSION="v2.0.0"
SCRIPT_NAME="IP to UUID Lookup"
LOG_SOURCE="journalctl"  # Can be changed to a file path if needed

# ---------- Colors & Styles ----------
BOLD="\e[1m"
GREEN="\e[32m"
CYAN="\e[36m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[34m"
MAGENTA="\e[35m"
RESET="\e[0m"
DIM="\e[2m"
ITALIC="\e[3m"

# Icons
CHECK="✓"
CROSS="✗"
INFO="ℹ"
SEARCH="🔍"
LIST="📋"
CLOCK="⏱"
WARNING="⚠"

# ---------- Functions ----------
print_header() {
    clear
    echo -e "${BLUE}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "               $SCRIPT_NAME $VERSION"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_separator() {
    echo -e "${DIM}─────────────────────────────────────────────────────────${RESET}"
}

print_success() {
    echo -e "${GREEN}${CHECK} $1${RESET}"
}

print_error() {
    echo -e "${RED}${CROSS} $1${RESET}"
}

print_info() {
    echo -e "${CYAN}${INFO} $1${RESET}"
}

print_warning() {
    echo -e "${YELLOW}${WARNING} $1${RESET}"
}

print_result_header() {
    echo
    echo -e "${MAGENTA}${BOLD}${SEARCH} Search Results for IP: ${CYAN}$IP${RESET}"
    print_separator
    printf "${BOLD}%-8s %-40s %-10s${RESET}\n" "Hits" "UUID" "Status"
    print_separator
}

validate_ip() {
    local ip="$1"
    # Basic IP validation (IPv4)
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [[ "$octet" -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# ---------- Main Script ----------
print_header

# ---------- Input ----------
echo -e "${CYAN}${BOLD}${SEARCH} IP Address Lookup${RESET}"
print_separator
echo -e "${ITALIC}Enter an IP address to find associated UUIDs in system logs${RESET}"
echo

while true; do
    echo -ne "${BOLD}${CYAN}Enter IP address: ${RESET}"
    read -r IP
    
    if [[ -z "$IP" ]]; then
        print_error "No IP address entered. Please try again."
        echo
        continue
    fi
    
    if ! validate_ip "$IP"; then
        print_warning "'$IP' doesn't appear to be a valid IPv4 address."
        echo -ne "${YELLOW}Continue anyway? (y/n): ${RESET}"
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi
        echo
        continue
    fi
    break
done

# ---------- Search ----------
echo
print_info "Searching logs for IP: $IP"
echo -e "${DIM}${CLOCK} This may take a moment...${RESET}"
echo

# Start timer
START_TIME=$(date +%s)

# Search for UUIDs associated with the IP
if [[ "$LOG_SOURCE" == "journalctl" ]]; then
    RESULT=$(journalctl --no-pager 2>/dev/null \
        | grep -F "$IP" \
        | grep -oE '[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}' \
        | sort | uniq -c | sort -nr)
else
    RESULT=$(grep -F "$IP" "$LOG_SOURCE" 2>/dev/null \
        | grep -oE '[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}' \
        | sort | uniq -c | sort -nr)
fi

# Calculate elapsed time
END_TIME=$(date +%s)
ELAPSED_TIME=$((END_TIME - START_TIME))

# ---------- Results ----------
if [[ -z "$RESULT" ]]; then
    echo
    print_warning "No UUIDs found associated with IP: $IP"
    echo
    print_info "Possible reasons:"
    echo -e "  ${DIM}• No logs contain this IP address"
    echo -e "  • The IP hasn't made any requests"
    echo -e "  • UUIDs in logs use a different format"
    echo -e "  • Log source may be different${RESET}"
    echo
    exit 0
fi

# Count total results
TOTAL_UUIDS=$(echo "$RESULT" | wc -l)
TOTAL_HITS=$(echo "$RESULT" | awk '{sum+=$1} END {print sum}')

print_result_header

# Display results with color coding
echo "$RESULT" | while read -r count uuid; do
    # Color code based on hit count
    if [[ $count -gt 100 ]]; then
        count_color="${RED}${BOLD}"
    elif [[ $count -gt 10 ]]; then
        count_color="${YELLOW}"
    else
        count_color="${GREEN}"
    fi
    
    # Determine status based on hit count
    if [[ $count -gt 100 ]]; then
        status="High"
        status_color="${RED}"
    elif [[ $count -gt 10 ]]; then
        status="Medium"
        status_color="${YELLOW}"
    else
        status="Low"
        status_color="${GREEN}"
    fi
    
    printf "${count_color}%-8s${RESET} %-40s ${status_color}%-10s${RESET}\n" \
        "$count" "$uuid" "$status"
done

print_separator

# ---------- Summary ----------
echo
echo -e "${GREEN}${BOLD}${CHECK} Search Complete${RESET}"
echo -e "${DIM}─────────────────────────────────────────────────────────${RESET}"
echo -e "${CYAN}${BOLD}Summary:${RESET}"
echo -e "  ${BOLD}IP Address:${RESET}        $IP"
echo -e "  ${BOLD}Total UUIDs Found:${RESET} $TOTAL_UUIDS"
echo -e "  ${BOLD}Total Log Entries:${RESET} $TOTAL_HITS"
echo -e "  ${BOLD}Search Time:${RESET}       ${ELAPSED_TIME}s"
echo -e "  ${BOLD}Log Source:${RESET}        $LOG_SOURCE"
echo

# ---------- Export Option ----------
if [[ $TOTAL_UUIDS -gt 0 ]]; then
    echo -ne "${CYAN}Export results to file? (y/n): ${RESET}"
    read -r export_choice
    
    if [[ "$export_choice" =~ ^[Yy]$ ]]; then
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        EXPORT_FILE="ip_uuid_results_${IP//./_}_${TIMESTAMP}.txt"
        
        {
            echo "# IP to UUID Lookup Results"
            echo "# Generated: $(date)"
            echo "# IP Address: $IP"
            echo "# Total UUIDs: $TOTAL_UUIDS"
            echo "# Total Hits: $TOTAL_HITS"
            echo ""
            echo "Hits, UUID, Status"
            echo "$RESULT" | while read -r count uuid; do
                if [[ $count -gt 100 ]]; then status="High"
                elif [[ $count -gt 10 ]]; then status="Medium"
                else status="Low"
                fi
                echo "$count, $uuid, $status"
            done
        } > "$EXPORT_FILE"
        
        print_success "Results exported to: $EXPORT_FILE"
    fi
fi

echo
print_info "Press Enter to exit..."
read -r
