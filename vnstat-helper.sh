#!/bin/bash
# vnstat-helper.sh — Minimal vnStat Manager with Auto Setup + Options
# Author: ChatGPT
# Location for all data/logs: /root/vnstat-helper/

BASE_DIR="/root/vnstat-helper"
DATA_FILE="$BASE_DIR/baseline"
COMBINED_FILE="$BASE_DIR/total"
LOG_FILE="$BASE_DIR/log"
DAILY_LOG="$BASE_DIR/daily.log"
CRON_FILE="/etc/cron.d/vnstat-daily"
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
BOOT_TIME=$(who -b | awk '{print $3, $4}')
CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
INSTALL_TIME_FILE="/var/lib/vnstat/install_time"

mkdir -p "$BASE_DIR"

bytes_to_gb() { echo "scale=2; $1/1024/1024/1024" | bc; }

get_vnstat_total_gb() {
  vnstat -i "$IFACE" --json 2>/dev/null | jq -r '.interfaces[0].traffic.months[-1].rx, .interfaces[0].traffic.months[-1].tx' | awk '{sum += $1} END {print sum/1024}' 2>/dev/null
}

check_vnstat() {
  if ! command -v vnstat >/dev/null 2>&1; then
    echo "Installing vnStat..."
    sudo apt update -qq && sudo apt install vnstat jq -y
    sudo systemctl enable vnstat
    sudo systemctl start vnstat
    sleep 3
  fi
}

record_baseline() {
  read RX TX <<<$(ip -s link show "$IFACE" | awk '/RX:/{getline; rx=$1} /TX:/{getline; tx=$1} END{print rx, tx}')
  RX_GB=$(bytes_to_gb $RX); TX_GB=$(bytes_to_gb $TX)
  TOTAL_GB=$(echo "scale=2; $RX_GB + $TX_GB" | bc)
  {
    echo "BOOT_TIME=\"$BOOT_TIME\""
    echo "BASE_RX=$RX_GB"
    echo "BASE_TX=$TX_GB"
    echo "BASE_TOTAL=$TOTAL_GB"
    echo "RECORDED_TIME=\"$CURRENT_TIME\""
  } | sudo tee "$DATA_FILE" >/dev/null
  sudo chmod 600 "$DATA_FILE"
}

show_combined_summary() {
  source "$DATA_FILE"
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  COMBINED_TOTAL=$(echo "scale=2; $BASE_TOTAL + $VNSTAT_TOTAL" | bc)
  echo "Baseline: $BASE_TOTAL GB"
  echo "vnStat:   $VNSTAT_TOTAL GB"
  echo "Total:    $COMBINED_TOTAL GB"
  echo "$(date '+%F %T') Interface:$IFACE Baseline:$BASE_TOTAL GB vnStat:$VNSTAT_TOTAL GB Total:$COMBINED_TOTAL GB" | sudo tee -a "$LOG_FILE" >/dev/null
}

reset_vnstat() {
  sudo systemctl stop vnstat
  sudo rm -rf /var/lib/vnstat
  sudo mkdir /var/lib/vnstat
  sudo chown vnstat:vnstat /var/lib/vnstat
  sudo systemctl start vnstat
}

install_vnstat() {
  sudo apt update -qq && sudo apt install vnstat jq -y
  sudo systemctl enable vnstat
  sudo systemctl start vnstat
  sleep 2
  date +%s | sudo tee "$INSTALL_TIME_FILE" >/dev/null
}

uninstall_vnstat() {
  sudo systemctl stop vnstat
  sudo apt purge vnstat -y
  sudo rm -rf /var/lib/vnstat /etc/vnstat.conf "$INSTALL_TIME_FILE"
}

daily_summary_toggle() {
  if [ -f "$CRON_FILE" ]; then
    sudo rm -f "$CRON_FILE"
    echo "❎ Daily summary disabled."
  else
    echo "0 0 * * * root /usr/local/bin/vnstat-helper.sh --daily >> $DAILY_LOG 2>&1" | sudo tee "$CRON_FILE" >/dev/null
    echo "✅ Daily summary enabled. Logs → $DAILY_LOG"
  fi
}

# Run daily summary (for cron)
if [[ "$1" == "--daily" ]]; then
  [ ! -f "$DATA_FILE" ] && exit 0
  source "$DATA_FILE"
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  COMBINED_TOTAL=$(echo "scale=2; $BASE_TOTAL + $VNSTAT_TOTAL" | bc)
  echo "$(date '+%F %T') Interface:$IFACE Baseline:$BASE_TOTAL GB vnStat:$VNSTAT_TOTAL GB Total:$COMBINED_TOTAL GB" >> "$DAILY_LOG"
  exit 0
fi

# ───────────────────────────────────────────────
# Auto setup
# ───────────────────────────────────────────────
check_vnstat
[ ! -f "$INSTALL_TIME_FILE" ] && date +%s | sudo tee "$INSTALL_TIME_FILE" >/dev/null
VNSTAT_INSTALL_TIME=$(cat "$INSTALL_TIME_FILE")
BASELINE_TIME=0
[ -f "$DATA_FILE" ] && BASELINE_TIME=$(date -d "$(grep RECORDED_TIME "$DATA_FILE" | cut -d'"' -f2)" +%s 2>/dev/null || echo 0)
[ ! -f "$DATA_FILE" ] && record_baseline
if [ "$BASELINE_TIME" -lt "$VNSTAT_INSTALL_TIME" ]; then
  read -rp "Baseline older than vnStat install. Reinstall vnStat for better data? (y/n): " a
  [[ "$a" =~ ^[Yy]$ ]] && uninstall_vnstat && install_vnstat && record_baseline
fi

# ───────────────────────────────────────────────
# Menu
# ───────────────────────────────────────────────
while true; do
  clear
  echo "=============================="
  echo "      VNSTAT CONTROL PANEL"
  echo "=============================="
  echo "1) Daily usage"
  echo "2) Weekly usage"
  echo "3) Monthly usage"
  echo "4) Hourly usage"
  echo "5) Live monitor"
  echo "6) Combined total"
  echo "7) Export JSON"
  echo "8) Reset vnStat"
  echo "9) Install vnStat"
  echo "10) Uninstall vnStat"
  echo "11) Enable/Disable daily summary"
  echo "12) View logs"
  echo "13) Exit"
  echo "=============================="
  read -rp "Select option [1-13]: " ch
  echo ""
  case $ch in
    1) vnstat -i "$IFACE" -d ;;
    2) vnstat -i "$IFACE" -w ;;
    3) vnstat -i "$IFACE" -m ;;
    4) vnstat -i "$IFACE" -h ;;
    5) vnstat -i "$IFACE" -l ;;
    6) show_combined_summary ;;
    7) vnstat -i "$IFACE" --json > "$BASE_DIR/vnstat-export.json" && echo "Exported → $BASE_DIR/vnstat-export.json" ;;
    8) reset_vnstat ;;
    9) install_vnstat ;;
    10) uninstall_vnstat ;;
    11) daily_summary_toggle ;;
    12) sudo tail -n 20 "$LOG_FILE" 2>/dev/null || echo "No logs yet." ;;
    13) exit 0 ;;
    *) echo "Invalid option." ;;
  esac
  echo ""
  read -rp "Press Enter to continue..."
done
