# !/bin/bash
# 🌐 VNSTAT HELPER — Pro Panel
# Version: 2.3.1 (Admin Focused)
# Description: Enhanced admin-focused vnStat control panel with original dashboard layout.

set -euo pipefail

# ───────────────────────────────────────────────
# CONFIGURATION
# ───────────────────────────────────────────────
VERSION="2.3.1"
BASE_DIR="/root/vnstat-helper"
DATA_FILE="$BASE_DIR/baseline"
LOG_FILE="$BASE_DIR/log"
DAILY_LOG="$BASE_DIR/daily.log"
CRON_FILE="/etc/cron.d/vnstat-daily"
mkdir -p "$BASE_DIR"

# Colors
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; CYAN="\033[1;36m"; MAGENTA="\033[1;35m"; BLUE="\033[1;34m"; NC="\033[0m"

# ───────────────────────────────────────────────
# HELPERS
# ───────────────────────────────────────────────
log_event() { echo "$(date '+%F %T') - $1" >> "$LOG_FILE"; }
detect_iface() { ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}'; }
fmt_uptime() { uptime -p | sed -E 's/up //' | awk '{gsub("days?","d");gsub("hours?","h");gsub("minutes?","m");printf "%s ",$0}' | sed 's/ $//'; }

# ───────────────────────────────────────────────
# VNSTAT FUNCTIONS
# ───────────────────────────────────────────────
get_vnstat_oneline_totals() {
  vnstat --oneline | while IFS=';' read -r id iface day rx tx total _; do
    [[ -z "$iface" || "$iface" == "iface" ]] && continue
    rx_value=$(echo "$rx" | awk '{print $1 * 1.07374}')
    tx_value=$(echo "$tx" | awk '{print $1 * 1.07374}')
    total_value=$(echo "$total" | awk '{print $1 * 1.07374}')
    printf "%s  RX: %.2f GB  TX: %.2f GB  Total: %.2f GB\n" "$iface" "$rx_value" "$tx_value" "$total_value"
  done
}

show_combined_summary() {
  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
  echo -e "${YELLOW}vnStat Totals (All Interfaces)${NC}"
  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
  get_vnstat_oneline_totals
  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
  log_event "Displayed vnStat totals for all interfaces"
}

# ───────────────────────────────────────────────
# DASHBOARD
# ───────────────────────────────────────────────
show_dashboard() {
  clear
  source "$DATA_FILE" 2>/dev/null || BASE_TOTAL=0
  VNSTAT_TOTAL=$(vnstat --oneline | awk -F';' '{rx=$4;tx=$5;sub("GiB","",rx);sub("GiB","",tx);t=rx+tx;sum+=t} END{print sum*1.07374}')
  TOTAL_SUM=$(echo "$BASE_TOTAL + $VNSTAT_TOTAL" | bc)
  echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}       🌐 VNSTAT HELPER v${VERSION}   |   vnStat v$(vnstat --version | awk '{print $2}') ${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
  echo -e "${MAGENTA}   Boot Time:${NC} $(who -b | awk '{print $3, $4}')      ${MAGENTA} Interface:${NC} $(detect_iface)"
  echo -e "${MAGENTA} Server Time:${NC} $(date '+%Y-%m-%d %H:%M:%S')      ${MAGENTA} Uptime:${NC} $(fmt_uptime)"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"  
  echo -e "${YELLOW} Baseline:${NC} $BASE_TOTAL GB     ${YELLOW}Total:${NC} $TOTAL_SUM GB"
  echo -e "${YELLOW} vnStat:${NC} $VNSTAT_TOTAL GB"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

# ───────────────────────────────────────────────
# ADMIN FUNCTIONS
# ───────────────────────────────────────────────
reset_vnstat() {
  echo -e "${CYAN}Resetting vnStat database...${NC}"
  systemctl stop vnstat 2>/dev/null || true
  rm -rf /var/lib/vnstat && mkdir -p /var/lib/vnstat && chown vnstat:vnstat /var/lib/vnstat
  systemctl start vnstat 2>/dev/null || true
  log_event "vnStat database reset"
  echo -e "${GREEN}vnStat reset completed.${NC}"
}

record_baseline() {
  local iface=$(detect_iface)
  read RX TX <<<$(ip -s link show "$iface" | awk '/RX:/{getline;rx=$1} /TX:/{getline;tx=$1} END{print rx,tx}')
  RX_GB=$(echo "scale=2; $RX/1024/1024/1024" | bc)
  TX_GB=$(echo "scale=2; $TX/1024/1024/1024" | bc)
  TOTAL=$(echo "$RX_GB + $TX_GB" | bc)
  echo "BASE_TOTAL=$TOTAL" > "$DATA_FILE"
  echo -e "${GREEN}New baseline recorded: ${YELLOW}${TOTAL} GB${NC}"
  log_event "New baseline recorded ($TOTAL GB)"
}

install_vnstat() {
  if command -v vnstat >/dev/null 2>&1; then
    echo -e "${YELLOW}vnStat is already installed.${NC}"
  else
    apt update -qq && apt install -y vnstat jq bc
    systemctl enable vnstat && systemctl start vnstat
    echo -e "${GREEN}vnStat installed successfully.${NC}"
  fi
}

uninstall_vnstat() {
  echo -e "${RED}Uninstalling vnStat...${NC}"
  systemctl stop vnstat 2>/dev/null || true
  apt purge -y vnstat
  rm -rf /var/lib/vnstat /etc/vnstat.conf
  log_event "vnStat uninstalled"
  echo -e "${GREEN}vnStat removed successfully.${NC}"
}

# ───────────────────────────────────────────────
# MAIN MENU (Admin Focused)
# ───────────────────────────────────────────────
while true; do
  show_dashboard
  echo -e " ${GREEN}[1]${NC} Daily Stats           ${GREEN}[6]${NC} Combined Totals (All IFs)"
  echo -e " ${GREEN}[2]${NC} Weekly Stats          ${GREEN}[7]${NC} Reset vnStat Database"
  echo -e " ${GREEN}[3]${NC} Monthly Stats         ${GREEN}[8]${NC} Record New Baseline"
  echo -e " ${GREEN}[4]${NC} Hourly Stats          ${GREEN}[9]${NC} Auto Summary Scheduler"
  echo -e " ${GREEN}[5]${NC} Top 10 Traffic Days   ${GREEN}[S]${NC} System Info"
  echo -e " ${GREEN}[I]${NC} Install/Update        ${GREEN}[U]${NC} Uninstall"
  echo -e " ${GREEN}[L]${NC} View Logs             ${GREEN}[Q]${NC} Quit"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  read -rp "Select: " ch
  echo ""
  case "${ch^^}" in
    1) vnstat --days -i $(detect_iface) | less ;;
    2) vnstat --weeks -i $(detect_iface) | less ;;
    3) vnstat --months -i $(detect_iface) | less ;;
    4) vnstat --hours -i $(detect_iface) | less ;;
    5) vnstat --top | less ;;
    6) show_combined_summary ;;
    7) reset_vnstat ;;
    8) record_baseline ;;
    9) echo -e "${YELLOW}To be implemented...${NC}" ;;
    S) hostnamectl ; uptime ; free -h ; df -h | grep -E '^/dev' ;;
    I) install_vnstat ;;
    U) uninstall_vnstat ;;
    L) tail -n 20 "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}No logs yet.${NC}" ;;
    Q) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice.${NC}" ;;
  esac
  echo ""
  read -n 1 -s -r -p "Press any key to continue..."
done
