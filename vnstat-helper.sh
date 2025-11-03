#!/bin/bash
# VNSTAT HELPER PANEL

VERSION="2.1.0"                          # <── update here when you change script
BASE_DIR="/root/vnstat-helper"
STATE_FILE="$BASE_DIR/state"
DATA_FILE="$BASE_DIR/baseline"
LOG_FILE="$BASE_DIR/log"
DAILY_LOG="$BASE_DIR/daily.log"
CRON_FILE="/etc/cron.d/vnstat-daily"
INSTALL_TIME_FILE="/var/lib/vnstat/install_time"
mkdir -p "$BASE_DIR"

# detect primary interface
IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
BOOT_TIME=$(who -b | awk '{print $3, $4}')
CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# ───────────────────────────────────────────────
# COLORS
# ───────────────────────────────────────────────
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"
CYAN="\033[1;36m"; MAGENTA="\033[1;35m"; BLUE="\033[1;34m"; NC="\033[0m"

# ───────────────────────────────────────────────
# BASIC UTILITIES
# ───────────────────────────────────────────────
bytes_to_gb(){ echo "scale=2; $1/1024/1024/1024" | bc; }

ensure_deps(){
  for p in vnstat jq bc; do
    command -v "$p" >/dev/null 2>&1 || { echo -e "${YELLOW}Installing missing: $p${NC}"; apt update -qq && apt install -y "$p"; }
  done
}

record_baseline(){
  echo -e "${CYAN}Collecting current traffic counters...${NC}"
  read RX TX <<<$(ip -s link show "$IFACE" | awk '/RX:/{getline;rx=$1} /TX:/{getline;tx=$1} END{print rx,tx}')
  RX_GB=$(bytes_to_gb "$RX"); TX_GB=$(bytes_to_gb "$TX")
  TOTAL=$(echo "$RX_GB + $TX_GB" | bc)
  {
    echo "BOOT_TIME=\"$BOOT_TIME\""
    echo "BASE_RX=$RX_GB"; echo "BASE_TX=$TX_GB"
    echo "BASE_TOTAL=$TOTAL"; echo "RECORDED_TIME=\"$CURRENT_TIME\""
  } >"$DATA_FILE"
  chmod 600 "$DATA_FILE"
  echo -e "${GREEN}Baseline saved:${NC} $TOTAL GB total"
}

get_vnstat_total_gb(){
  vnstat -i "$IFACE" --json 2>/dev/null | jq -r '.interfaces[0].traffic.months[-1].rx, .interfaces[0].traffic.months[-1].tx' |
  awk '{s+=$1} END{print s/1024}' 2>/dev/null
}

show_combined_summary(){
  source "$DATA_FILE"
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  COMBINED=$(echo "$BASE_TOTAL + $VNSTAT_TOTAL" | bc)
  echo -e "${YELLOW}Baseline:${NC} $BASE_TOTAL GB"
  echo -e "${YELLOW}vnStat:${NC}   $VNSTAT_TOTAL GB"
  echo -e "${GREEN}Total:${NC}    $COMBINED GB"
  echo "$(date '+%F %T') iface=$IFACE baseline=$BASE_TOTAL vnstat=$VNSTAT_TOTAL total=$COMBINED" >>"$LOG_FILE"
}

reset_vnstat(){
  systemctl stop vnstat 2>/dev/null
  rm -rf /var/lib/vnstat; mkdir -p /var/lib/vnstat; chown vnstat:vnstat /var/lib/vnstat
  systemctl start vnstat 2>/dev/null
  echo -e "${GREEN}vnStat database reset.${NC}"
}

manual_reset_and_new_baseline(){
  read -rp "Reset vnStat and record new baseline? (y/n): " y
  [[ "$y" =~ ^[Yy]$ ]] || return
  reset_vnstat; record_baseline
}

install_vnstat(){
  apt update -qq && apt install -y vnstat jq
  systemctl enable vnstat; systemctl start vnstat
  date +%s >"$INSTALL_TIME_FILE"
  echo -e "${GREEN}vnStat installed.${NC}"
}

uninstall_vnstat(){
  systemctl stop vnstat 2>/dev/null
  apt purge -y vnstat; rm -rf /var/lib/vnstat /etc/vnstat.conf "$INSTALL_TIME_FILE"
  echo -e "${RED}vnStat removed.${NC}"
}

auto_summary_menu(){
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

live_speed(){
  echo -e "${CYAN}Ctrl+C to stop live speed (Mbps)${NC}"
  OLD_RX=$(< /sys/class/net/$IFACE/statistics/rx_bytes)
  OLD_TX=$(< /sys/class/net/$IFACE/statistics/tx_bytes)
  while true; do
    sleep 1
    NEW_RX=$(< /sys/class/net/$IFACE/statistics/rx_bytes)
    NEW_TX=$(< /sys/class/net/$IFACE/statistics/tx_bytes)
    RX=$(echo "scale=2; ($NEW_RX-$OLD_RX)*8/1024/1024" | bc)
    TX=$(echo "scale=2; ($NEW_TX-$OLD_TX)*8/1024/1024" | bc)
    printf "${GREEN}RX↓ %8.2f Mbps${NC}   ${YELLOW}TX↑ %8.2f Mbps${NC}\r" "$RX" "$TX"
    OLD_RX=$NEW_RX; OLD_TX=$NEW_TX
  done
}

# ───────────────────────────────────────────────
# DASHBOARD DATA
# ───────────────────────────────────────────────
load_combined_info(){
  [ ! -f "$DATA_FILE" ] && BASE_TOTAL=0 && BASE_TIME="N/A" && VNSTAT_TOTAL=0 && TOTAL_SUM=0 && return
  source "$DATA_FILE"
  BASE_TIME=$(grep RECORDED_TIME "$DATA_FILE" | cut -d'"' -f2)
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  TOTAL_SUM=$(echo "$BASE_TOTAL + $VNSTAT_TOTAL" | bc)
}

# ───────────────────────────────────────────────
# DASHBOARD DISPLAY
# ───────────────────────────────────────────────
COMPACT_MODE=$(grep -E '^COMPACT=' "$STATE_FILE" 2>/dev/null | cut -d'=' -f2)
[ -z "$COMPACT_MODE" ] && COMPACT_MODE=false

show_dashboard(){
  clear
  load_combined_info
  UPTIME=$(uptime -p | sed 's/up //')
  echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║        🌐 VNSTAT HELPER  v${VERSION}                         ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
  if [ "$COMPACT_MODE" = false ]; then
    printf "${MAGENTA} Interface:${NC} %-10s ${MAGENTA}Uptime:${NC} %-20s\n" "$IFACE" "$UPTIME"
    printf "${MAGENTA} Boot Time:${NC} %-20s ${MAGENTA}Now:${NC} %-20s\n" "$BOOT_TIME" "$CURRENT_TIME"
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
    printf "${YELLOW} Baseline Date:${NC} %-20s\n" "$BASE_TIME"
    printf "${YELLOW} Baseline Used:${NC} %-10s GB  ${YELLOW}vnStat:${NC} %-10s GB\n" "$BASE_TOTAL" "$VNSTAT_TOTAL"
    printf "${YELLOW} Total Combined:${NC} %-10s GB\n" "$TOTAL_SUM"
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  else
    printf "${YELLOW}Iface:${NC} %-6s | ${YELLOW}Up:${NC} %-15s | ${YELLOW}Total:${NC} %-10s GB\n" "$IFACE" "$UPTIME" "$TOTAL_SUM"
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  fi
}

# ───────────────────────────────────────────────
# MAIN MENU
# ───────────────────────────────────────────────
ensure_deps
[ ! -f "$DATA_FILE" ] && record_baseline

while true; do
  show_dashboard
  echo -e "${GREEN}[1]${NC} Daily Usage       ${GREEN}[8]${NC} Reset vnStat DB"
  echo -e "${GREEN}[2]${NC} Weekly Usage      ${GREEN}[9]${NC} New Baseline"
  echo -e "${GREEN}[3]${NC} Monthly Usage     ${GREEN}[10]${NC} Install vnStat"
  echo -e "${GREEN}[4]${NC} Hourly Usage      ${GREEN}[11]${NC} Auto Summary"
  echo -e "${GREEN}[5]${NC} Live Monitor      ${GREEN}[12]${NC} Uninstall vnStat"
  echo -e "${GREEN}[6]${NC} Combined Total    ${GREEN}[13]${NC} View Logs"
  echo -e "${GREEN}[7]${NC} Export JSON       ${GREEN}[14]${NC} Exit"
  echo -e "${GREEN}[15]${NC} Live Speed (Mbps) ${GREEN}[C]${NC} Toggle Compact"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
  read -rp "Select [1–15/C]: " ch
  echo ""
  case "${ch^^}" in
    1) vnstat -i "$IFACE" -d ;;
    2) vnstat -i "$IFACE" -w ;;
    3) vnstat -i "$IFACE" -m ;;
    4) vnstat -i "$IFACE" -h ;;
    5) vnstat -i "$IFACE" -l ;;
    6) show_combined_summary ;;
    7) vnstat -i "$IFACE" --json >"$BASE_DIR/vnstat-export.json" && echo -e "${GREEN}Exported → $BASE_DIR/vnstat-export.json${NC}" ;;
    8) reset_vnstat ;;
    9) manual_reset_and_new_baseline ;;
    10) install_vnstat ;;
    11) auto_summary_menu ;;
    12) uninstall_vnstat ;;
    13) tail -n 20 "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}No logs yet.${NC}" ;;
    14) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
    15) live_speed ;;
    C)
      COMPACT_MODE=$([ "$COMPACT_MODE" = false ] && echo true || echo false)
      echo "COMPACT=$COMPACT_MODE" >"$STATE_FILE"
      ;;
    *) echo -e "${RED}Invalid option.${NC}" ;;
  esac
  echo ""
  read -rp "Press Enter..."
done
