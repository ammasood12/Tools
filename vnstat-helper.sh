#!/bin/bash
# 🌐 VNSTAT HELPER — Multi-Interface & Oneline Edition
# Version: 2.6.0
# Description: Monitors billable traffic across all interfaces using vnStat --oneline.
#              Includes baseline management, auto summary, and system utilities.

set -euo pipefail

# ───────────────────────────────────────────────
# CONFIGURATION
# ───────────────────────────────────────────────
VERSION="2.6.0"
BASE_DIR="/root/vnstat-helper"
DATA_FILE="$BASE_DIR/baseline"
BASELINE_LOG="$BASE_DIR/baseline.log"
LOG_FILE="$BASE_DIR/log"
DAILY_LOG="$BASE_DIR/daily.log"
CRON_FILE="/etc/cron.d/vnstat-daily"
mkdir -p "$BASE_DIR"

# Colors
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"
CYAN="\033[1;36m"; MAGENTA="\033[1;35m"; BLUE="\033[1;34m"; NC="\033[0m"

# ───────────────────────────────────────────────
# DEPENDENCY CHECK
# ───────────────────────────────────────────────
check_dependencies() {
  local deps=("vnstat" "jq" "bc")
  local missing=()
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo -e "${YELLOW}Missing dependencies:${NC} ${RED}${missing[*]}${NC}"
    read -rp "Install them now? [Y/n]: " ans
    if [[ "${ans,,}" != "n" ]]; then
      apt update -qq && apt install -y vnstat jq bc
      systemctl enable vnstat >/dev/null 2>&1 || true
      systemctl start vnstat >/dev/null 2>&1 || true
    else
      echo -e "${RED}Dependencies required. Exiting.${NC}"
      exit 1
    fi
  fi
}

check_dependencies

# ───────────────────────────────────────────────
# HELPERS
# ───────────────────────────────────────────────
detect_ifaces() {
  ip -br link show | awk '{print $1}' | grep -E '^e|^en|^eth|^wlan' || true
}
fmt_uptime() { uptime -p | sed -E 's/^up //' | sed -E 's/days?/d/g; s/hours?/h/g; s/minutes?/m/g; s/seconds?/s/g; s/,//g'; }
round2() { printf "%.2f" "$1"; }
log_event() { echo "$(date '+%F %T') - $1" >> "$LOG_FILE"; }

# ───────────────────────────────────────────────
# UNIT CONVERSION (MB → GB → TB)
# ───────────────────────────────────────────────
format_size() {
  local val="$1"
  local unit="MB"
  [[ -z "$val" ]] && val=0
  if (( $(echo "$val >= 1000" | bc -l) )); then
    val=$(echo "scale=2; $val/1024" | bc)
    unit="GB"
  fi
  if (( $(echo "$val >= 1000" | bc -l) )); then
    val=$(echo "scale=2; $val/1024" | bc)
    unit="TB"
  fi
  echo "$(round2 "$val") $unit"
}

# ───────────────────────────────────────────────
# VNSTAT DATA (Multi-Interface Aggregation)
# ───────────────────────────────────────────────
get_vnstat_data() {
  local total_rx=0 total_tx=0 total_sum=0
  local ifaces=($(detect_ifaces))

  for iface in "${ifaces[@]}"; do
    line=$(vnstat --oneline -i "$iface" 2>/dev/null || true)
    [[ -z "$line" ]] && continue

    rx=$(echo "$line" | awk -F';' '{print $9}' | awk '{print $1}')
    tx=$(echo "$line" | awk -F';' '{print $10}' | awk '{print $1}')
    [[ -z "$rx" || -z "$tx" ]] && continue

    # Convert GiB → MB
    RX_MB=$(echo "scale=6; $rx * 1.07374 * 1024" | bc)
    TX_MB=$(echo "scale=6; $tx * 1.07374 * 1024" | bc)
    total_rx=$(echo "$total_rx + $RX_MB" | bc)
    total_tx=$(echo "$total_tx + $TX_MB" | bc)
  done

  total_sum=$(echo "$total_rx + $total_tx" | bc)
  echo "$(round2 "$total_rx") $(round2 "$total_tx") $(round2 "$total_sum")"
}

# ───────────────────────────────────────────────
# BASELINE MANAGEMENT
# ───────────────────────────────────────────────
record_baseline_auto() {
  local total=$(get_vnstat_data | awk '{print ($3/1024)}')
  local TIME=$(date '+%Y-%m-%d %H:%M')
  echo "BASE_TOTAL=$(round2 "$total")" > "$DATA_FILE"
  echo "RECORDED_TIME=\"$TIME\"" >> "$DATA_FILE"
  echo "$TIME | Auto | $total GB" >> "$BASELINE_LOG"
  echo -e "${GREEN}New baseline recorded: ${YELLOW}${total} GB${NC}"
}

record_baseline_manual() {
  read -rp "Enter manual baseline value (in GB): " input
  [[ -z "$input" ]] && echo -e "${RED}No value entered.${NC}" && return
  local TIME=$(date '+%Y-%m-%d %H:%M')
  echo "BASE_TOTAL=$(round2 "$input")" > "$DATA_FILE"
  echo "RECORDED_TIME=\"$TIME\"" >> "$DATA_FILE"
  echo "$TIME | Manual | $input GB" >> "$BASELINE_LOG"
  echo -e "${GREEN}Manual baseline set to ${YELLOW}${input} GB${NC}"
}

# ───────────────────────────────────────────────
# AUTO SUMMARY (renamed & status)
# ───────────────────────────────────────────────
auto_summary_menu() {
  local status="Disabled"
  if [ -f "$CRON_FILE" ]; then
    status=$(awk '{print $6}' "$CRON_FILE" | sed 's/--daily//' | sed 's/root//g' | xargs)
    [[ -z "$status" ]] && status="Enabled"
  fi

  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
  echo -e "${YELLOW}Auto Traffic Summary (Current: $status)${NC}"
  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
  echo "1) Hourly Summary"
  echo "2) Daily Summary"
  echo "3) Weekly Summary"
  echo "4) Monthly Summary"
  echo "5) Disable Auto Summary"
  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
  read -rp "Choose: " x
  case $x in
    1) echo "0 * * * * root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
    2) echo "0 0 * * * root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
    3) echo "0 0 * * 0 root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
    4) echo "0 0 1 * * root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
    5) rm -f "$CRON_FILE";;
    *) echo -e "${RED}Invalid option.${NC}"; return;;
  esac
  echo -e "${GREEN}Auto summary schedule updated.${NC}"
}

# ───────────────────────────────────────────────
# VIEW TRAFFIC SUMMARY LOG
# ───────────────────────────────────────────────
view_traffic_log() {
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  echo -e "${YELLOW} Traffic Summary Log — $DAILY_LOG ${NC}"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  if [ -s "$DAILY_LOG" ]; then
    tail -n 30 "$DAILY_LOG" | awk '{print NR")", $0}'
  else
    echo -e "${RED}No traffic summaries yet.${NC}"
  fi
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

# ───────────────────────────────────────────────
# VNSTAT FUNCTIONS MENU
# ───────────────────────────────────────────────
vnstat_functions_menu() {
  local iface=$(detect_ifaces | head -n1)
  while true; do
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}             ⚙️ vnStat Utilities Menu${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e " ${GREEN}[1]${NC} Daily Stats"
    echo -e " ${GREEN}[2]${NC} Monthly Stats"
    echo -e " ${GREEN}[3]${NC} Yearly Stats"
    echo -e " ${GREEN}[4]${NC} Top Days"
    echo -e " ${GREEN}[5]${NC} Reset vnStat Database"
    echo -e " ${GREEN}[6]${NC} Install / Update vnStat"
    echo -e " ${GREEN}[7]${NC} Uninstall vnStat"
    echo -e " ${GREEN}[Q]${NC} Return"
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
    read -rp "Select: " f
    case "${f^^}" in
      1) vnstat --days -i "$iface";;
      2) vnstat --months -i "$iface";;
      3) vnstat --years -i "$iface";;
      4) vnstat --top -i "$iface";;
      5) systemctl stop vnstat; rm -rf /var/lib/vnstat; systemctl start vnstat; echo -e "${GREEN}Database reset.${NC}";;
      6) apt update -qq && apt install -y vnstat jq bc; systemctl enable vnstat; systemctl start vnstat; echo -e "${GREEN}vnStat installed/updated.${NC}";;
      7) apt purge -y vnstat; rm -rf /var/lib/vnstat /etc/vnstat.conf; echo -e "${GREEN}vnStat removed.${NC}";;
      Q) return;;
      *) echo -e "${RED}Invalid option.${NC}";;
    esac
    read -n 1 -s -r -p "Press any key to continue..."
  done
}

# ───────────────────────────────────────────────
# DASHBOARD
# ───────────────────────────────────────────────
show_dashboard() {
  clear
  BASE_TOTAL=0; RECORDED_TIME="N/A"
  [ -f "$DATA_FILE" ] && source "$DATA_FILE"

  read RX_MB TX_MB TOTAL_MB < <(get_vnstat_data)
  BASE_TOTAL=$(round2 "${BASE_TOTAL:-0}")
  TOTAL_SUM=$(echo "scale=6; $BASE_TOTAL + ($TOTAL_MB/1024)" | bc)
  TOTAL_SUM=$(round2 "$TOTAL_SUM")

  echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}       🌐 VNSTAT HELPER v${VERSION}   |   vnStat v$(vnstat --version | awk '{print $2}') ${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
  echo -e "${MAGENTA}   Interfaces:${NC} $(detect_ifaces)"
  echo -e "${MAGENTA}   Server Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')   ${MAGENTA} Uptime:${NC} $(fmt_uptime)"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  echo -e "${YELLOW} Baseline (of total):${NC} $(format_size "$(echo "$BASE_TOTAL*1024" | bc)") (${RECORDED_TIME})"
  echo -e "${YELLOW} vnStat (download):${NC}  $(format_size "$RX_MB")"
  echo -e "${YELLOW} vnStat (upload):${NC}    $(format_size "$TX_MB")"
  echo -e "${RED} Total (of total):${NC}   ${RED}$(format_size "$TOTAL_MB")${NC}"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

# ───────────────────────────────────────────────
# MAIN MENU
# ───────────────────────────────────────────────
while true; do
  show_dashboard
  echo -e " ${GREEN}[1]${NC} View Traffic Summary Log"
  echo -e " ${GREEN}[2]${NC} Auto Traffic Summary"
  echo -e " ${GREEN}[3]${NC} Modify Baseline"
  echo -e " ${GREEN}[4]${NC} vnStat Functions"
  echo -e " ${GREEN}[5]${NC} View Logs"
  echo -e " ${GREEN}[Q]${NC} Quit"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  read -rp "Select: " ch
  echo ""
  case "${ch^^}" in
    1) view_traffic_log ;;
    2) auto_summary_menu ;;
    3) modify_baseline_menu ;;
    4) vnstat_functions_menu ;;
    5) tail -n 20 "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}No logs yet.${NC}" ;;
    Q) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice.${NC}" ;;
  esac
  echo ""
  read -n 1 -s -r -p "Press any key to continue..."
done
