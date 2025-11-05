# !/bin/bash
# 🌐 VNSTAT HELPER — Billable Traffic Edition
# Version: 2.5.0
# Author: ChatGPT
# Description: Uses `vnstat --oneline` for faster, accurate billable traffic monitoring
#              with auto-unit conversion, baseline management, and vnStat utilities.

set -euo pipefail

# ───────────────────────────────────────────────
# CONFIGURATION
# ───────────────────────────────────────────────
VERSION="2.5.0"
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
# HELPERS
# ───────────────────────────────────────────────
detect_iface() { ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}'; }
fmt_uptime() { uptime -p | sed -E 's/^up //' | sed -E 's/days?/d/g; s/hours?/h/g; s/minutes?/m/g; s/seconds?/s/g; s/,//g'; }
round2() { printf "%.2f" "$1"; }
log_event() { echo "$(date '+%F %T') - $1" >> "$LOG_FILE"; }

# ───────────────────────────────────────────────
# UNIVERSAL UNIT CONVERTER (MB → GB → TB)
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
# VNSTAT DATA RETRIEVAL (via --oneline)
# ───────────────────────────────────────────────
get_vnstat_data() {
  local iface=$(detect_iface)
  local rx tx total ready_flag=1

  # Format: id;iface;day;rx_day;tx_day;total_day;rate;month;rx_month;tx_month;total_month;...
  line=$(vnstat --oneline -i "$iface" 2>/dev/null || echo "")
  if [[ -z "$line" ]]; then
    echo "0 0 0 0"; return
  fi

  rx=$(echo "$line" | awk -F';' '{print $9}' | awk '{print $1}')
  tx=$(echo "$line" | awk -F';' '{print $10}' | awk '{print $1}')
  total=$(echo "$line" | awk -F';' '{print $11}' | awk '{print $1}')

  # Convert GiB → GB (decimal)
  RX_GB=$(echo "scale=6; $rx * 1.07374" | bc)
  TX_GB=$(echo "scale=6; $tx * 1.07374" | bc)
  TOTAL_GB=$(echo "scale=6; $total * 1.07374" | bc)

  # Convert to MB for unified formatter
  RX_MB=$(echo "scale=6; $RX_GB * 1024" | bc)
  TX_MB=$(echo "scale=6; $TX_GB * 1024" | bc)
  TOTAL_MB=$(echo "scale=6; $TOTAL_GB * 1024" | bc)

  [[ "$RX_MB" == "0.00" && "$TX_MB" == "0.00" ]] && ready_flag=0

  RX_MB=$(round2 "$RX_MB")
  TX_MB=$(round2 "$TX_MB")
  TOTAL_MB=$(round2 "$TOTAL_MB")

  echo "$RX_MB $TX_MB $TOTAL_MB $ready_flag"
}

# ───────────────────────────────────────────────
# BASELINE MANAGEMENT
# ───────────────────────────────────────────────
record_baseline_auto() {
  local iface=$(detect_iface)
  read RX TX <<<$(ip -s link show "$iface" | awk '/RX:/{getline;rx=$1} /TX:/{getline;tx=$1} END{print rx,tx}')
  RX_GB=$(echo "scale=6; $RX/1024/1024/1024" | bc)
  TX_GB=$(echo "scale=6; $TX/1024/1024/1024" | bc)
  TOTAL=$(echo "$RX_GB + $TX_GB" | bc)
  TOTAL=$(round2 "$TOTAL")
  TIME=$(date '+%Y-%m-%d %H:%M')
  {
    echo "BASE_TOTAL=$TOTAL"
    echo "RECORDED_TIME=\"$TIME\""
  } > "$DATA_FILE"
  echo "$TIME | Auto | $TOTAL GB" >> "$BASELINE_LOG"
  echo -e "${GREEN}New baseline recorded: ${YELLOW}${TOTAL} GB${NC}"
}

record_baseline_manual() {
  read -rp "Enter manual baseline value (in GB): " input
  [[ -z "$input" ]] && echo -e "${RED}No value entered.${NC}" && return
  TOTAL=$(round2 "$input")
  TIME=$(date '+%Y-%m-%d %H:%M')
  {
    echo "BASE_TOTAL=$TOTAL"
    echo "RECORDED_TIME=\"$TIME\""
  } > "$DATA_FILE"
  echo "$TIME | Manual | $TOTAL GB" >> "$BASELINE_LOG"
  echo -e "${GREEN}Manual baseline set to ${YELLOW}${TOTAL} GB${NC}"
}

select_existing_baseline() {
  if [ ! -s "$BASELINE_LOG" ]; then echo -e "${RED}No saved baselines yet.${NC}"; return; fi
  echo -e "${CYAN}──────────────────────────────${NC}"
  nl -w2 -s". " <(tac "$BASELINE_LOG")
  echo -e "${CYAN}──────────────────────────────${NC}"
  read -rp "Select a baseline number: " choice
  line=$(tac "$BASELINE_LOG" | sed -n "${choice}p")
  [[ -z "$line" ]] && echo -e "${RED}Invalid selection.${NC}" && return
  value=$(echo "$line" | awk '{print $(NF-1)}'); time=$(echo "$line" | awk '{print $1" "$2}')
  { echo "BASE_TOTAL=$(round2 "$value")"; echo "RECORDED_TIME=\"$time\""; } > "$DATA_FILE"
  echo -e "${GREEN}Active baseline switched to ${YELLOW}$(round2 "$value") GB${NC} (Recorded: $time)"
}

modify_baseline_menu() {
  while true; do
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}         ⚙️  Modify Baseline Options${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
    echo -e " ${GREEN}[1]${NC} Reset & Record New Baseline (Auto)"
    echo -e " ${GREEN}[2]${NC} Input Manual Baseline"
    echo -e " ${GREEN}[3]${NC} Select Existing Baseline"
    echo -e " ${GREEN}[Q]${NC} Return to Main Menu"
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
    read -rp "Select: " opt
    case "${opt^^}" in
      1) record_baseline_auto ;;
      2) record_baseline_manual ;;
      3) select_existing_baseline ;;
      Q) return ;;
      *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
    read -n 1 -s -r -p "Press any key to continue..."
  done
}

# ───────────────────────────────────────────────
# AUTO SUMMARY + VIEW LOG
# ───────────────────────────────────────────────
auto_summary_menu() {
  echo -e "${CYAN}Auto Summary Scheduler${NC}"
  echo "1) Hourly  2) Daily  3) Weekly  4) Monthly  5) Disable"
  read -rp "Choose: " x
  case $x in
    1) echo "0 * * * * root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
    2) echo "0 0 * * * root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
    3) echo "0 0 * * 0 root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
    4) echo "0 0 1 * * root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" > "$CRON_FILE";;
    5) rm -f "$CRON_FILE";;
    *) echo -e "${RED}Invalid option.${NC}"; return;;
  esac
  echo -e "${GREEN}Schedule updated.${NC}"
}

view_auto_summary_log() {
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  echo -e "${YELLOW} Auto Summary Log — $DAILY_LOG ${NC}"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  if [ -s "$DAILY_LOG" ]; then
    tail -n 30 "$DAILY_LOG" | awk '{print NR")", $0}'
  else
    echo -e "${RED}No auto summary logs found yet.${NC}"
  fi
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

# ───────────────────────────────────────────────
# VNSTAT FUNCTIONS MENU
# ───────────────────────────────────────────────
vnstat_functions_menu() {
  local iface=$(detect_iface)
  while true; do
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}             📊 vnStat Functions Menu${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e " ${GREEN}[1]${NC} Daily   ${GREEN}[5]${NC} Top Days"
    echo -e " ${GREEN}[2]${NC} Weekly  ${GREEN}[6]${NC} Hours"
    echo -e " ${GREEN}[3]${NC} Monthly ${GREEN}[7]${NC} Hours Graph"
    echo -e " ${GREEN}[4]${NC} Yearly  ${GREEN}[8]${NC} 5-Minute Graph"
    echo -e " ${GREEN}[Q]${NC} Return"
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
    read -rp "Select: " f
    case "${f^^}" in
      1) vnstat --days -i "$iface";;
      2) vnstat --weeks -i "$iface";;
      3) vnstat --months -i "$iface";;
      4) vnstat --years -i "$iface";;
      5) vnstat --top -i "$iface";;
      6) vnstat --hours -i "$iface";;
      7) vnstat --hoursgraph -i "$iface";;
      8) vnstat --fiveminutes -i "$iface";;
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

  read RX_MB TX_MB TOTAL_MB READY < <(get_vnstat_data)
  BASE_TOTAL=$(round2 "${BASE_TOTAL:-0}")
  TOTAL_SUM=$(echo "scale=6; $BASE_TOTAL + ($TOTAL_MB/1024)" | bc 2>/dev/null || echo "0")
  TOTAL_SUM=$(round2 "$TOTAL_SUM")

  echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}       🌐 VNSTAT HELPER v${VERSION}   |   vnStat v$(vnstat --version | awk '{print $2}') ${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
  echo -e "${MAGENTA}   Boot Time:${NC} $(who -b | awk '{print $3, $4}')      ${MAGENTA} Interface:${NC} $(detect_iface)"
  echo -e "${MAGENTA} Server Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')      ${MAGENTA} Uptime:${NC} $(fmt_uptime)"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"

  echo -e "${YELLOW} Baseline (of total):${NC} $(format_size "$(echo "$BASE_TOTAL*1024" | bc)")       (${RECORDED_TIME})"
  if [[ "$READY" -eq 1 ]]; then
    echo -e "${YELLOW} vnStat (download):${NC}  $(format_size "$RX_MB")       ($(date '+%Y-%m-%d %H:%M'))"
    echo -e "${YELLOW} vnStat (upload):${NC}    $(format_size "$TX_MB")       ($(date '+%Y-%m-%d %H:%M'))"
  else
    echo -e "${YELLOW} vnStat (download):${NC}  ${YELLOW}Collecting data... (vnStat updating)${NC}"
    echo -e "${YELLOW} vnStat (upload):${NC}    ${YELLOW}Collecting data... (vnStat updating)${NC}"
  fi
  echo -e "${RED} Total (of total):${NC}   ${RED}$(format_size "$TOTAL_MB")${NC}"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  echo -e " ${GREEN}[0]${NC} View Auto Summary Log"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

# ───────────────────────────────────────────────
# MAIN MENU
# ───────────────────────────────────────────────
while true; do
  show_dashboard
  echo -e " ${GREEN}[1]${NC} Daily Stats           ${GREEN}[6]${NC} Combined Totals"
  echo -e " ${GREEN}[2]${NC} Weekly Stats          ${GREEN}[7]${NC} Reset vnStat DB"
  echo -e " ${GREEN}[3]${NC} Monthly Stats         ${GREEN}[8]${NC} Modify Baseline"
  echo -e " ${GREEN}[4]${NC} Hourly Stats          ${GREEN}[9]${NC} Auto Summary Scheduler"
  echo -e " ${GREEN}[5]${NC} vnStat Functions      ${GREEN}[L]${NC} View Logs"
  echo -e " ${GREEN}[I]${NC} Install/Update vnStat ${GREEN}[U]${NC} Uninstall"
  echo -e " ${GREEN}[Q]${NC} Quit"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  read -rp "Select: " ch
  echo ""
  case "${ch^^}" in
    0) view_auto_summary_log ;;
    1) vnstat --days -i $(detect_iface) ;;
    2) vnstat --weeks -i $(detect_iface) ;;
    3) vnstat --months -i $(detect_iface) ;;
    4) vnstat --hours -i $(detect_iface) ;;
    5) vnstat_functions_menu ;;
    6) show_dashboard ;;
    7) systemctl stop vnstat; rm -rf /var/lib/vnstat; systemctl start vnstat; echo -e "${GREEN}vnStat reset completed.${NC}" ;;
    8) modify_baseline_menu ;;
    9) auto_summary_menu ;;
    I) apt update -qq && apt install -y vnstat jq bc; systemctl enable vnstat; systemctl start vnstat ;;
    U) apt purge -y vnstat; rm -rf /var/lib/vnstat /etc/vnstat.conf; echo -e "${GREEN}vnStat uninstalled.${NC}" ;;
    L) tail -n 20 "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}No logs yet.${NC}" ;;
    Q) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice.${NC}" ;;
  esac
  echo ""
  read -n 1 -s -r -p "Press any key to continue..."
done
