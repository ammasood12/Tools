# !/bin/bash
# 🌐 VNSTAT HELPER — Pro Panel
# Version: 2.4.0
# Description: Advanced vnStat control and monitoring panel using oneline mode for clearer dashboard.

set -euo pipefail

# ───────────────────────────────────────────────
# CONFIGURATION
# ───────────────────────────────────────────────
VERSION="2.4.0"
BASE_DIR="/root/vnstat-helper"
DATA_FILE="$BASE_DIR/baseline"
LOG_FILE="$BASE_DIR/log"
mkdir -p "$BASE_DIR"

# Colors
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; CYAN="\033[1;36m"; MAGENTA="\033[1;35m"; BLUE="\033[1;34m"; NC="\033[0m"

# ───────────────────────────────────────────────
# UTILITIES
# ───────────────────────────────────────────────
log_event() { echo "$(date '+%F %T') - $1" >> "$LOG_FILE"; }
detect_iface() { ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}'; }
fmt_uptime() { uptime -p | sed -E 's/up //' | sed 's/ /, /g'; }

ensure_deps() {
  for pkg in vnstat jq bc; do
    if ! command -v "$pkg" &>/dev/null; then
      echo -e "${YELLOW}Installing missing dependency: $pkg${NC}"
      apt update -qq && apt install -y "$pkg"
    fi
  done
}

# ───────────────────────────────────────────────
# VNSTAT DATA HANDLING (using --oneline)
# ───────────────────────────────────────────────
get_vnstat_oneline_totals() {
  vnstat --oneline | while IFS=';' read -r id iface day rx tx total speed month_rx month_tx month_total month_speed year_rx year_tx year_total; do
    [[ -z "$iface" || "$iface" == "iface" ]] && continue

    # Extract numerical values and convert GiB → GB
    rx_value=$(echo "$rx" | awk '{print $1 * 1.07374}')
    tx_value=$(echo "$tx" | awk '{print $1 * 1.07374}')
    total_value=$(echo "$total" | awk '{print $1 * 1.07374}')

    printf "%-10s RX: %8.2f GB  TX: %8.2f GB  TOTAL: %8.2f GB\n" "$iface" "$rx_value" "$tx_value" "$total_value"
  done
}

# ───────────────────────────────────────────────
# DASHBOARD FUNCTIONS
# ───────────────────────────────────────────────
show_vnstat_dashboard() {
  clear
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}   🌐 VNSTAT HELPER v${VERSION}   |   vnStat v$(vnstat --version | awk '{print $2}')${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
  echo -e "${MAGENTA} Hostname:${NC} $(hostname)       ${MAGENTA}Interface:${NC} $(detect_iface)"
  echo -e "${MAGENTA} System Uptime:${NC} $(fmt_uptime)"
  echo -e "${MAGENTA} Date:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
  echo -e "${YELLOW}▶ vnStat Traffic Summary (All Interfaces)${NC}"
  echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
  get_vnstat_oneline_totals
  echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
  echo -e "${YELLOW}▶ Top Traffic Days:${NC}"
  vnstat --top | tail -n +3 | head -n 5
  echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
  echo -e "${YELLOW}▶ Monthly Traffic:${NC}"
  vnstat --months | tail -n +3 | head -n 5
  echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
  echo -e "${YELLOW}▶ Hourly Graph:${NC}"
  vnstat --hoursgraph | tail -n 12
  echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
  echo -e "${GREEN}Refreshes every 5 seconds (Ctrl+C to stop)${NC}"
}

live_dashboard() {
  while true; do
    show_vnstat_dashboard
    sleep 5
  done
}

# ───────────────────────────────────────────────
# MENU ACTIONS
# ───────────────────────────────────────────────
reset_vnstat() {
  echo -e "${CYAN}Resetting vnStat database...${NC}"
  systemctl stop vnstat 2>/dev/null || true
  rm -rf /var/lib/vnstat && mkdir -p /var/lib/vnstat && chown vnstat:vnstat /var/lib/vnstat
  systemctl start vnstat 2>/dev/null || true
  log_event "vnStat database reset"
  echo -e "${GREEN}vnStat reset completed.${NC}"
}

install_vnstat() {
  if command -v vnstat >/dev/null 2>&1; then
    echo -e "${YELLOW}vnStat is already installed.${NC}"
  else
    echo -e "${CYAN}Installing vnStat...${NC}"
    apt update -qq && apt install -y vnstat jq bc
    systemctl enable vnstat || true
    systemctl start vnstat || true
    log_event "vnStat installed"
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
# MAIN MENU
# ───────────────────────────────────────────────
ensure_deps

while true; do
  clear
  echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}   🌐 VNSTAT HELPER v${VERSION} MENU${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
  echo -e " ${GREEN}[1]${NC} Show Real-Time Dashboard"
  echo -e " ${GREEN}[2]${NC} Show One-Time Summary"
  echo -e " ${GREEN}[3]${NC} Show Daily Stats"
  echo -e " ${GREEN}[4]${NC} Show Weekly Stats"
  echo -e " ${GREEN}[5]${NC} Show Monthly Stats"
  echo -e " ${GREEN}[6]${NC} Show Top 10 Days"
  echo -e " ${GREEN}[7]${NC} Reset vnStat Database"
  echo -e " ${GREEN}[I]${NC} Install/Update vnStat"
  echo -e " ${GREEN}[U]${NC} Uninstall vnStat"
  echo -e " ${GREEN}[Q]${NC} Quit"
  echo -e "${CYAN}───────────────────────────────────────────${NC}"
  read -rp "Select: " ch
  echo ""
  case "${ch^^}" in
    1) live_dashboard ;;
    2) show_vnstat_dashboard ; read -n 1 -s -r -p "Press any key..." ;;
    3) vnstat --days | less ;;
    4) vnstat --weeks | less ;;
    5) vnstat --months | less ;;
    6) vnstat --top | less ;;
    7) reset_vnstat ;;
    I) install_vnstat ;;
    U) uninstall_vnstat ;;
    Q) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice.${NC}" ;;
  esac
  echo ""
  read -n 1 -s -r -p "Press any key to return to menu..."
done
