#!/bin/bash
# 🌐 VNSTAT HELPER — Pro Panel
# Version: 2.3.1
# Description: Smart vnStat control and monitoring panel for Ubuntu/Debian systems.

set -euo pipefail

# ───────────────────────────────────────────────
# CONFIGURATION
# ───────────────────────────────────────────────
VERSION="2.3.1"
BASE_DIR="/root/vnstat-helper"
STATE_FILE="$BASE_DIR/state"
DATA_FILE="$BASE_DIR/baseline"
LOG_FILE="$BASE_DIR/log"
DAILY_LOG="$BASE_DIR/daily.log"
CRON_FILE="/etc/cron.d/vnstat-daily"
INSTALL_TIME_FILE="/var/lib/vnstat/install_time"
mkdir -p "$BASE_DIR"

# Colors
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"
CYAN="\033[1;36m"; MAGENTA="\033[1;35m"; BLUE="\033[1;34m"; NC="\033[0m"

# ───────────────────────────────────────────────
# HELPERS
# ───────────────────────────────────────────────
bytes_to_gb() { echo "scale=2; $1/1024/1024/1024" | bc; }

log_event() { echo "$(date '+%F %T') - $1" >> "$LOG_FILE"; }

detect_iface() { ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}'; }

ensure_deps() {
  for pkg in vnstat jq bc; do
    if ! command -v "$pkg" &>/dev/null; then
      echo -e "${YELLOW}Installing missing dependency: $pkg${NC}"
      apt update -qq && apt install -y "$pkg"
    fi
  done
}

# ───────────────────────────────────────────────
# BASELINE FUNCTIONS
# ───────────────────────────────────────────────
record_baseline() {
  local iface=$(detect_iface)
  echo -e "${CYAN}Collecting baseline traffic data...${NC}"
  read RX TX <<<$(ip -s link show "$iface" | awk '/RX:/{getline;rx=$1} /TX:/{getline;tx=$1} END{print rx,tx}')
  RX_GB=$(bytes_to_gb "$RX")
  TX_GB=$(bytes_to_gb "$TX")
  TOTAL=$(echo "$RX_GB + $TX_GB" | bc)
  {
    echo "BOOT_TIME=\"$(who -b | awk '{print $3, $4}')\""
    echo "BASE_RX=$RX_GB"
    echo "BASE_TX=$TX_GB"
    echo "BASE_TOTAL=$TOTAL"
    echo "RECORDED_TIME=\"$(date '+%Y-%m-%d %H:%M:%S')\""
  } >"$DATA_FILE"
  chmod 600 "$DATA_FILE"
  log_event "Baseline recorded ($TOTAL GB)"
  echo -e "${GREEN}Baseline recorded successfully: ${YELLOW}${TOTAL} GB${NC}"
}

# ───────────────────────────────────────────────
# VNSTAT DATA FUNCTIONS
# ───────────────────────────────────────────────
get_vnstat_total_gb() {
  local iface rx tx total
  iface=$(detect_iface)

  # Try months data first, fallback to total
  rx=$(vnstat --json -i "$iface" 2>/dev/null | jq -r '
    if .interfaces[0].traffic.months[-1].rx then
      .interfaces[0].traffic.months[-1].rx
    elif .interfaces[0].traffic.total.rx then
      .interfaces[0].traffic.total.rx
    else
      0
    end
  ')

  tx=$(vnstat --json -i "$iface" 2>/dev/null | jq -r '
    if .interfaces[0].traffic.months[-1].tx then
      .interfaces[0].traffic.months[-1].tx
    elif .interfaces[0].traffic.total.tx then
      .interfaces[0].traffic.total.tx
    else
      0
    end
  ')

  total=$(echo "scale=2; ($rx + $tx) / 1024" | bc)
  echo "$total"
}


show_combined_summary() {
  source "$DATA_FILE"
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  COMBINED=$(echo "$BASE_TOTAL + $VNSTAT_TOTAL" | bc)
  echo -e "${CYAN}──────────────────────────────────────${NC}"
  echo -e "${YELLOW}Baseline(GB)   vnStat(GB)     Total(GB)${NC}"
  echo -e "${CYAN}──────────────────────────────────────${NC}"
  echo -e "$BASE_TOTAL          $VNSTAT_TOTAL          $COMBINED"
  echo -e "${CYAN}──────────────────────────────────────${NC}"
  log_event "iface=$(detect_iface) base=$BASE_TOTAL vnstat=$VNSTAT_TOTAL total=$COMBINED"
}

show_used_since_baseline() {
  source "$DATA_FILE"
  USED=$(get_vnstat_total_gb)
  echo -e "${YELLOW}Used since baseline:${NC} ${USED} GB"
}

# ───────────────────────────────────────────────
# SYSTEM CONTROL
# ───────────────────────────────────────────────
reset_vnstat() {
  echo -e "${CYAN}Resetting vnStat database...${NC}"
  systemctl stop vnstat 2>/dev/null || true
  [ -d /var/lib/vnstat ] && tar czf "$BASE_DIR/vnstat-backup-$(date +%F).tar.gz" /var/lib/vnstat
  rm -rf /var/lib/vnstat
  mkdir -p /var/lib/vnstat
  chown vnstat:vnstat /var/lib/vnstat
  systemctl start vnstat 2>/dev/null || true
  log_event "vnStat database reset"
  echo -e "${GREEN}vnStat reset completed.${NC}"
}

manual_reset_and_new_baseline() {
  read -rp "Reset vnStat and record new baseline? (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || return
  reset_vnstat
  record_baseline
}

# ───────────────────────────────────────────────
# INSTALL/UPDATE/UNINSTALL
# ───────────────────────────────────────────────
install_vnstat() {
  if command -v vnstat >/dev/null 2>&1; then
    CURRENT_VER=$(vnstat --version 2>/dev/null | awk '{print $2}')
    echo -e "${YELLOW}vnStat is already installed (version ${CURRENT_VER}).${NC}"
    read -rp "Update to the latest version? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      apt update -qq && apt install --only-upgrade -y vnstat jq
      systemctl restart vnstat || true
      date +%s >"$INSTALL_TIME_FILE"
      log_event "vnStat updated to $CURRENT_VER"
      echo -e "${GREEN}vnStat updated successfully.${NC}"
    else
      echo -e "${YELLOW}Skipped vnStat update.${NC}"
    fi
  else
    echo -e "${CYAN}Installing vnStat...${NC}"
    apt update -qq && apt install -y vnstat jq
    systemctl enable vnstat || true
    systemctl start vnstat || true
    date +%s >"$INSTALL_TIME_FILE"
    log_event "vnStat installed"
    echo -e "${GREEN}vnStat installed successfully.${NC}"
  fi
}

uninstall_vnstat() {
  echo -e "${RED}Uninstalling vnStat...${NC}"
  systemctl stop vnstat 2>/dev/null || true
  apt purge -y vnstat
  rm -rf /var/lib/vnstat /etc/vnstat.conf "$INSTALL_TIME_FILE"
  log_event "vnStat uninstalled"
  echo -e "${GREEN}vnStat removed successfully.${NC}"
}

# ───────────────────────────────────────────────
# UTILITIES
# ───────────────────────────────────────────────
fmt_uptime() { uptime -p | sed -E 's/up //' | awk '{gsub("days?","d");gsub("hours?","h");gsub("minutes?","m");printf "%s ",$0}' | sed 's/ $//'; }

live_speed() {
  echo -e "${CYAN}Press Ctrl+C to stop live speed monitor${NC}"
  OLD_RX=$(< /sys/class/net/$(detect_iface)/statistics/rx_bytes)
  OLD_TX=$(< /sys/class/net/$(detect_iface)/statistics/tx_bytes)
  while sleep 1; do
    NEW_RX=$(< /sys/class/net/$(detect_iface)/statistics/rx_bytes)
    NEW_TX=$(< /sys/class/net/$(detect_iface)/statistics/tx_bytes)
    RX=$(echo "scale=2; ($NEW_RX-$OLD_RX)*8/1024/1024" | bc)
    TX=$(echo "scale=2; ($NEW_TX-$OLD_TX)*8/1024/1024" | bc)
    printf "\r${GREEN}RX↓ %6.2f Mbps${NC}   ${YELLOW}TX↑ %6.2f Mbps${NC}" "$RX" "$TX"
    OLD_RX=$NEW_RX; OLD_TX=$NEW_TX
  done
}

auto_summary_menu() {
  echo -e "${CYAN}Auto Summary Scheduler${NC}"
  echo "1) Hourly  2) Daily  3) Weekly  4) Monthly  5) Disable"
  read -rp "Choose: " x
  case $x in
    1) echo "0 * * * * root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" >"$CRON_FILE";;
    2) echo "0 0 * * * root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" >"$CRON_FILE";;
    3) echo "0 0 * * 0 root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" >"$CRON_FILE";;
    4) echo "0 0 1 * * root /usr/local/bin/vnstat-helper.sh --daily >>$DAILY_LOG 2>&1" >"$CRON_FILE";;
    5) rm -f "$CRON_FILE";;
  esac
  log_event "Cron schedule updated (option $x)"
  echo -e "${GREEN}Schedule updated.${NC}"
}

# ───────────────────────────────────────────────
# DASHBOARD
# ───────────────────────────────────────────────
load_combined_info() {
  [ ! -f "$DATA_FILE" ] && BASE_TOTAL=0 VNSTAT_TOTAL=0 TOTAL_SUM=0 && return
  source "$DATA_FILE"
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  TOTAL_SUM=$(echo "$BASE_TOTAL + $VNSTAT_TOTAL" | bc)
}

show_dashboard() {
  clear
  load_combined_info
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
# MAIN MENU
# ───────────────────────────────────────────────
ensure_deps
[ ! -f "$DATA_FILE" ] && record_baseline

while true; do
  show_dashboard
  echo -e " ${GREEN}[0]${NC} Used Since Baseline   ${GREEN}[5]${NC} Combined Total"
  echo -e " ${GREEN}[1]${NC} Daily Stats           ${GREEN}[6]${NC} Live Speed"
  echo -e " ${GREEN}[2]${NC} Weekly Stats          ${GREEN}[7]${NC} Reset vnStat"
  echo -e " ${GREEN}[3]${NC} Monthly Stats         ${GREEN}[8]${NC} New Baseline"
  echo -e " ${GREEN}[4]${NC} Hourly Stats          ${GREEN}[9]${NC} Auto Summary"
  echo -e " ${GREEN}[I]${NC} Install/Update        ${GREEN}[U]${NC} Uninstall"
  echo -e " ${GREEN}[L]${NC} Logs                  ${GREEN}[Q]${NC} Quit"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  read -rp "Select: " ch
  echo ""
  case "${ch^^}" in
    0) show_used_since_baseline ;;
    1) vnstat --days -i $(detect_iface) ;;
    2) vnstat --weeks -i $(detect_iface) ;;
    3) vnstat --months -i $(detect_iface) ;;
    4) vnstat --hours -i $(detect_iface) ;;
    5) show_combined_summary ;;
    6) live_speed ;;
    7) reset_vnstat ;;
    8) manual_reset_and_new_baseline ;;
    9) auto_summary_menu ;;
    I) install_vnstat ;;
    U) uninstall_vnstat ;;
    L) tail -n 20 "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}No logs yet.${NC}" ;;
    Q) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice.${NC}" ;;
  esac
  echo ""
  read -n 1 -s -r -p "Press any key to continue..."
done
