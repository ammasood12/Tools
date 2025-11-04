#!/bin/bash
# 🌐 VNSTAT HELPER — Pro Panel
# Version: 2.2.2
# Author: ChatGPT
# Description: Smart vnStat control and monitoring panel for Ubuntu/Debian systems.

# ───────────────────────────────────────────────
# CONFIGURATION
# ───────────────────────────────────────────────
VERSION="2.2.3"
BASE_DIR="/root/vnstat-helper"
STATE_FILE="$BASE_DIR/state"
DATA_FILE="$BASE_DIR/baseline"
LOG_FILE="$BASE_DIR/log"
DAILY_LOG="$BASE_DIR/daily.log"
CRON_FILE="/etc/cron.d/vnstat-daily"
INSTALL_TIME_FILE="/var/lib/vnstat/install_time"
mkdir -p "$BASE_DIR"

# Detect active network interface
IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
BOOT_TIME=$(who -b | awk '{print $3, $4}')
CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# Colors
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"
CYAN="\033[1;36m"; MAGENTA="\033[1;35m"; BLUE="\033[1;34m"; NC="\033[0m"

# ───────────────────────────────────────────────
# FUNCTION: bytes_to_gb
# ───────────────────────────────────────────────
bytes_to_gb() {
  echo "scale=2; $1/1024/1024/1024" | bc
}

# ───────────────────────────────────────────────
# FUNCTION: ensure_deps
# ───────────────────────────────────────────────
ensure_deps() {
  for pkg in vnstat jq bc; do
    if ! command -v "$pkg" &>/dev/null; then
      echo -e "${YELLOW}Installing missing dependency: $pkg${NC}"
      apt update -qq && apt install -y "$pkg"
    fi
  done
}

# ───────────────────────────────────────────────
# FUNCTION: record_baseline
# ───────────────────────────────────────────────
record_baseline() {
  echo -e "${CYAN}Collecting baseline traffic data...${NC}"
  read RX TX <<<$(ip -s link show "$IFACE" | awk '/RX:/{getline;rx=$1} /TX:/{getline;tx=$1} END{print rx,tx}')
  RX_GB=$(bytes_to_gb "$RX")
  TX_GB=$(bytes_to_gb "$TX")
  TOTAL=$(echo "$RX_GB + $TX_GB" | bc)
  {
    echo "BOOT_TIME=\"$BOOT_TIME\""
    echo "BASE_RX=$RX_GB"
    echo "BASE_TX=$TX_GB"
    echo "BASE_TOTAL=$TOTAL"
    echo "RECORDED_TIME=\"$CURRENT_TIME\""
  } >"$DATA_FILE"
  chmod 600 "$DATA_FILE"
  echo -e "${GREEN}Baseline recorded successfully: ${YELLOW}${TOTAL} GB${NC}"
}

# ───────────────────────────────────────────────
# FUNCTION: get_vnstat_total_gb
# ───────────────────────────────────────────────
get_vnstat_total_gb() {
  vnstat --json -i "$IFACE" 2>/dev/null | jq -r '.interfaces[0].traffic.months[-1].rx, .interfaces[0].traffic.months[-1].tx' |
  awk '{sum+=$1} END{print sum/1024}' 2>/dev/null
}

# ───────────────────────────────────────────────
# FUNCTION: show_combined_summary
# ───────────────────────────────────────────────
show_combined_summary() {
  source "$DATA_FILE"
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  COMBINED=$(echo "$BASE_TOTAL + $VNSTAT_TOTAL" | bc)
  echo -e "${CYAN}──────────────────────────────────────${NC}"
  echo -e "${YELLOW}Baseline(GB)   vnStat(GB)     Total(GB)${NC}"
  echo -e "${CYAN}──────────────────────────────────────${NC}"
  echo -e "$BASE_TOTAL          $VNSTAT_TOTAL          $COMBINED"
  echo -e "${CYAN}──────────────────────────────────────${NC}"
  echo "$(date '+%F %T') iface=$IFACE base=$BASE_TOTAL vnstat=$VNSTAT_TOTAL total=$COMBINED" >>"$LOG_FILE"
}

# ───────────────────────────────────────────────
# FUNCTION: reset_vnstat
# ───────────────────────────────────────────────
reset_vnstat() {
  echo -e "${CYAN}Resetting vnStat database...${NC}"
  systemctl stop vnstat 2>/dev/null
  rm -rf /var/lib/vnstat
  mkdir -p /var/lib/vnstat
  chown vnstat:vnstat /var/lib/vnstat
  systemctl start vnstat 2>/dev/null
  echo -e "${GREEN}vnStat reset completed.${NC}"
}

# ───────────────────────────────────────────────
# FUNCTION: manual_reset_and_new_baseline
# ───────────────────────────────────────────────
manual_reset_and_new_baseline() {
  read -rp "Reset vnStat and record new baseline? (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || return
  reset_vnstat
  record_baseline
}

# ───────────────────────────────────────────────
# FUNCTION: install_vnstat (Install/Update)
# ───────────────────────────────────────────────
install_vnstat() {
  if command -v vnstat >/dev/null 2>&1; then
    CURRENT_VER=$(vnstat --version 2>/dev/null | awk '{print $2}')
    echo -e "${YELLOW}vnStat is already installed (version ${CURRENT_VER}).${NC}"
    read -rp "Do you want to update it to the latest version? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      echo -e "${CYAN}Updating vnStat...${NC}"
      apt update -qq && apt install --only-upgrade -y vnstat jq
      systemctl restart vnstat
      date +%s >"$INSTALL_TIME_FILE"
      echo -e "${GREEN}vnStat updated successfully.${NC}"
    else
      echo -e "${YELLOW}Skipped vnStat update.${NC}"
    fi
  else
    echo -e "${CYAN}Installing vnStat...${NC}"
    apt update -qq && apt install -y vnstat jq
    systemctl enable vnstat
    systemctl start vnstat
    date +%s >"$INSTALL_TIME_FILE"
    echo -e "${GREEN}vnStat installed successfully.${NC}"
  fi
}

# ───────────────────────────────────────────────
# FUNCTION: uninstall_vnstat
# ───────────────────────────────────────────────
uninstall_vnstat() {
  echo -e "${RED}Uninstalling vnStat...${NC}"
  systemctl stop vnstat 2>/dev/null
  apt purge -y vnstat
  rm -rf /var/lib/vnstat /etc/vnstat.conf "$INSTALL_TIME_FILE"
  echo -e "${GREEN}vnStat removed successfully.${NC}"
}

# ───────────────────────────────────────────────
# FUNCTION: auto_summary_menu
# ───────────────────────────────────────────────
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
  echo -e "${GREEN}Schedule updated.${NC}"
}

# ───────────────────────────────────────────────
# FUNCTION: live_speed
# ───────────────────────────────────────────────
live_speed() {
  echo -e "${CYAN}Press Ctrl+C to stop live speed monitor${NC}"
  OLD_RX=$(< /sys/class/net/$IFACE/statistics/rx_bytes)
  OLD_TX=$(< /sys/class/net/$IFACE/statistics/tx_bytes)
  while true; do
    sleep 1
    NEW_RX=$(< /sys/class/net/$IFACE/statistics/rx_bytes)
    NEW_TX=$(< /sys/class/net/$IFACE/statistics/tx_bytes)
    RX=$(echo "scale=2; ($NEW_RX-$OLD_RX)*8/1024/1024" | bc)
    TX=$(echo "scale=2; ($NEW_TX-$OLD_TX)*8/1024/1024" | bc)
    echo -ne "${GREEN}RX↓ ${RX} Mbps${NC}   ${YELLOW}TX↑ ${TX} Mbps${NC}\r"
    OLD_RX=$NEW_RX; OLD_TX=$NEW_TX
  done
}

# ───────────────────────────────────────────────
# FUNCTION: load_combined_info
# ───────────────────────────────────────────────
load_combined_info() {
  [ ! -f "$DATA_FILE" ] && BASE_TOTAL=0 BASE_TIME="N/A" VNSTAT_TOTAL=0 TOTAL_SUM=0 && return
  source "$DATA_FILE"
  BASE_TIME=$(grep RECORDED_TIME "$DATA_FILE" | cut -d'"' -f2)
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  TOTAL_SUM=$(echo "$BASE_TOTAL + $VNSTAT_TOTAL" | bc)
}

# ───────────────────────────────────────────────
# FUNCTION: fmt_uptime
# ───────────────────────────────────────────────
fmt_uptime() {
  uptime -p | sed -E 's/up //' | awk '{gsub("days?","d");gsub("hours?","h");gsub("minutes?","m");printf "%s ",$0}' | sed 's/ $//'
}

# ───────────────────────────────────────────────
# FUNCTION: show_dashboard
# ───────────────────────────────────────────────
show_dashboard() {
  clear
  load_combined_info
  UPTIME=$(fmt_uptime)
  VNSTAT_VER=$(vnstat --version 2>/dev/null | awk '{print $2}')
  echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}       🌐 VNSTAT HELPER v${VERSION}   |   vnStat v${VNSTAT_VER:-N/A} ${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
  echo -e "${MAGENTA} Interface:${NC} $IFACE             ${MAGENTA} Boot Time:${NC} $BOOT_TIME"
  echo -e "${MAGENTA} Uptime:${NC} $UPTIME      ${MAGENTA} Now:${NC} $CURRENT_TIME"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"  
  echo -e "${YELLOW} Baseline: ${NC}$BASE_TOTAL GB     ${YELLOW}Total: ${NC}$TOTAL_SUM GB"
  echo -e "${YELLOW} vnStat: ${NC}$VNSTAT_TOTAL GB"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
}

# ───────────────────────────────────────────────
# FUNCTION: show_stats (vnStat version-aware)
# ───────────────────────────────────────────────
VNVER=$(vnstat --version 2>/dev/null | awk '{print $2}' | cut -d. -f1)
show_stats() {
  local mode="$1"
  if [ "$VNVER" -ge 2 ]; then
    case $mode in
      days) vnstat --days -i "$IFACE" ;;
      weeks) vnstat --weeks -i "$IFACE" ;;
      months) vnstat --months -i "$IFACE" ;;
      hours) vnstat --hours -i "$IFACE" ;;
    esac
  else
    case $mode in
      days) vnstat -d -i "$IFACE" ;;
      weeks) vnstat -w -i "$IFACE" ;;
      months) vnstat -m -i "$IFACE" ;;
      hours) vnstat -h -i "$IFACE" ;;
    esac
  fi
}

# ───────────────────────────────────────────────
# MAIN MENU
# ───────────────────────────────────────────────
ensure_deps
[ ! -f "$DATA_FILE" ] && record_baseline

while true; do
  show_dashboard
  echo ""
  echo -e " ${GREEN}[1]${NC} Daily         ${GREEN}[5]${NC} Combined Total"
  echo -e " ${GREEN}[2]${NC} Weekly        ${GREEN}[6]${NC} Live Speed"
  echo -e " ${GREEN}[3]${NC} Monthly       ${GREEN}[7]${NC} Reset vnStat"
  echo -e " ${GREEN}[4]${NC} Hourly        ${GREEN}[8]${NC} New Baseline"
  echo -e " ${GREEN}[9]${NC} Auto Summary  ${GREEN}[I]${NC} Install/Update"
  echo -e " ${GREEN}[U]${NC} Uninstall     ${GREEN}[L]${NC} Logs"
  echo -e " ${GREEN}[Q]${NC} Quit"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  read -rp "Select: " ch
  echo ""
  case "${ch^^}" in
    1) show_stats days ;;
    2) show_stats weeks ;;
    3) show_stats months ;;
    4) show_stats hours ;;
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
