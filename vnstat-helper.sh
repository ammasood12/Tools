# !/bin/bash
# 🌐 VNSTAT HELPER — Pro Panel
# Version: 2.3.2 (Enhanced Baseline Manager)
# Description: Smart vnStat control and monitoring panel with advanced baseline handling.

set -euo pipefail

# ───────────────────────────────────────────────
# CONFIGURATION
# ───────────────────────────────────────────────
VERSION="2.3.2"
BASE_DIR="/root/vnstat-helper"
DATA_FILE="$BASE_DIR/baseline"
LOG_FILE="$BASE_DIR/log"
BASELINE_LOG="$BASE_DIR/baseline.log"
mkdir -p "$BASE_DIR"

# Colors
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"
CYAN="\033[1;36m"; MAGENTA="\033[1;35m"; BLUE="\033[1;34m"; NC="\033[0m"

# ───────────────────────────────────────────────
# HELPERS
# ───────────────────────────────────────────────
detect_iface() { ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}'; }
fmt_uptime() { uptime -p | sed -E 's/up //' | awk '{gsub("days?","d");gsub("hours?","h");gsub("minutes?","m");printf "%s ",$0}' | sed 's/ $//'; }
log_event() { echo "$(date '+%F %T') - $1" >> "$LOG_FILE"; }

# ───────────────────────────────────────────────
# VNSTAT HANDLERS
# ───────────────────────────────────────────────
get_monthly_total() {
  local iface=$(detect_iface)
  vnstat --oneline | while IFS=';' read -r id dev _ _ _ _ _ month_rx month_tx month_total _; do
    [[ "$dev" == "$iface" ]] && {
      total_gib=$(echo "$month_total" | awk '{print $1}')
      total_gb=$(echo "scale=2; $total_gib*1.07374" | bc)
      echo "$total_gb"
      return
    }
  done
}

# ───────────────────────────────────────────────
# BASELINE MANAGEMENT (Rounded Precision)
# ───────────────────────────────────────────────
BASELINE_LOG="$BASE_DIR/baseline.log"

round2() { printf "%.2f" "$1"; }

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
  if [ ! -s "$BASELINE_LOG" ]; then
    echo -e "${RED}No saved baselines yet.${NC}"
    return
  fi
  echo -e "${CYAN}──────────────────────────────${NC}"
  nl -w2 -s". " <(tac "$BASELINE_LOG")
  echo -e "${CYAN}──────────────────────────────${NC}"
  read -rp "Select a baseline number: " choice
  line=$(tac "$BASELINE_LOG" | sed -n "${choice}p")
  [[ -z "$line" ]] && echo -e "${RED}Invalid selection.${NC}" && return
  value=$(echo "$line" | awk '{print $(NF-1)}')
  time=$(echo "$line" | awk '{print $1" "$2}')
  {
    echo "BASE_TOTAL=$(round2 "$value")"
    echo "RECORDED_TIME=\"$time\""
  } > "$DATA_FILE"
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
# VNSTAT MONTHLY TOTAL (Rounded)
# ───────────────────────────────────────────────
get_monthly_total() {
  local iface=$(detect_iface)
  vnstat --oneline | while IFS=';' read -r id dev _ _ _ _ _ month_rx month_tx month_total _; do
    [[ "$dev" == "$iface" ]] && {
      total_gib=$(echo "$month_total" | awk '{print $1}')
      total_gb=$(echo "scale=6; $total_gib*1.07374" | bc)
      echo "$(round2 "$total_gb")"
      return
    }
  done
}

# ───────────────────────────────────────────────
# DASHBOARD (Rounded Values)
# ───────────────────────────────────────────────
show_dashboard() {
  clear
  BASE_TOTAL=0
  RECORDED_TIME="N/A"

  if [ -f "$DATA_FILE" ] && [ -s "$DATA_FILE" ]; then
    source "$DATA_FILE"
  fi

  VNSTAT_TOTAL=$(get_monthly_total)
  VNSTAT_TOTAL=$(round2 "${VNSTAT_TOTAL:-0}")
  BASE_TOTAL=$(round2 "${BASE_TOTAL:-0}")
  TOTAL_SUM=$(echo "scale=6; $BASE_TOTAL + $VNSTAT_TOTAL" | bc)
  TOTAL_SUM=$(round2 "$TOTAL_SUM")

  echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}       🌐 VNSTAT HELPER v${VERSION}   |   vnStat v$(vnstat --version | awk '{print $2}') ${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
  echo -e "${MAGENTA}   Boot Time:${NC} $(who -b | awk '{print $3, $4}')      ${MAGENTA} Interface:${NC} $(detect_iface)"
  echo -e "${MAGENTA} Server Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')      ${MAGENTA} Uptime:${NC} $(fmt_uptime)"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"  
  echo -e "${YELLOW} Baseline:${NC} ${BASE_TOTAL} GB       (${RECORDED_TIME})"
  echo -e "${YELLOW} vnStat:${NC}   ${VNSTAT_TOTAL} GB       ($(date '+%Y-%m-%d %H:%M'))"
  echo -e "${RED} Total:${NC}     ${RED}${TOTAL_SUM} GB${NC}"
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
  echo -e " ${GREEN}[5]${NC} Top 10 Traffic Days   ${GREEN}[L]${NC} View Logs"
  echo -e " ${GREEN}[I]${NC} Install/Update vnStat ${GREEN}[U]${NC} Uninstall"
  echo -e " ${GREEN}[Q]${NC} Quit"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  read -rp "Select: " ch
  echo ""
  case "${ch^^}" in
    1) vnstat --days -i $(detect_iface) ;;
    2) vnstat --weeks -i $(detect_iface) ;;
    3) vnstat --months -i $(detect_iface) ;;
    4) vnstat --hours -i $(detect_iface) ;;
    5) vnstat --top ;;
    6) show_dashboard ;;
    7) systemctl stop vnstat; rm -rf /var/lib/vnstat; systemctl start vnstat; echo -e "${GREEN}vnStat reset completed.${NC}" ;;
    8) modify_baseline_menu ;;
    9) echo -e "${YELLOW}Auto summary not yet implemented.${NC}" ;;
    I) apt update -qq && apt install -y vnstat jq bc; systemctl enable vnstat; systemctl start vnstat ;;
    U) apt purge -y vnstat; rm -rf /var/lib/vnstat /etc/vnstat.conf; echo -e "${GREEN}vnStat uninstalled.${NC}" ;;
    L) tail -n 20 "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}No logs yet.${NC}" ;;
    Q) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice.${NC}" ;;
  esac
  echo ""
  read -n 1 -s -r -p "Press any key to continue..."
done
