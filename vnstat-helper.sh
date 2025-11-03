#!/bin/bash
# vnstat-helper.sh — Smart vnStat Manager with Auto Setup + Explanations
# All data stored in /root/vnstat-helper/

version="v1.02"

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
    echo "Installing vnStat (network usage tracker)..."
    sudo apt update -qq && sudo apt install vnstat jq -y
    sudo systemctl enable vnstat
    sudo systemctl start vnstat
    sleep 3
  fi
}

record_baseline() {
  echo "→ Collecting system traffic counters from ip -s link..."
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
  echo "✅ Baseline recorded at $DATA_FILE"
}

show_combined_summary() {
  echo "→ Calculating total traffic since boot and vnStat installation..."
  source "$DATA_FILE"
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  COMBINED_TOTAL=$(echo "scale=2; $BASE_TOTAL + $VNSTAT_TOTAL" | bc)
  echo ""
  echo "Baseline: $BASE_TOTAL GB"
  echo "vnStat:   $VNSTAT_TOTAL GB"
  echo "Total:    $COMBINED_TOTAL GB"
  echo "$(date '+%F %T') Interface:$IFACE Baseline:$BASE_TOTAL GB vnStat:$VNSTAT_TOTAL GB Total:$COMBINED_TOTAL GB" | sudo tee -a "$LOG_FILE" >/dev/null
}

reset_vnstat() {
  echo "→ Resetting vnStat database (keeps installation, clears usage data)..."
  sudo systemctl stop vnstat
  sudo rm -rf /var/lib/vnstat
  sudo mkdir /var/lib/vnstat
  sudo chown vnstat:vnstat /var/lib/vnstat
  sudo systemctl start vnstat
  echo "✅ vnStat database reset and restarted."
}

install_vnstat() {
  echo "→ Installing vnStat and dependencies..."
  sudo apt update -qq && sudo apt install vnstat jq -y
  sudo systemctl enable vnstat
  sudo systemctl start vnstat
  sleep 2
  date +%s | sudo tee "$INSTALL_TIME_FILE" >/dev/null
  echo "✅ vnStat installed successfully."
}

uninstall_vnstat() {
  echo "→ Removing vnStat and all its data..."
  sudo systemctl stop vnstat
  sudo apt purge vnstat -y
  sudo rm -rf /var/lib/vnstat /etc/vnstat.conf "$INSTALL_TIME_FILE"
  echo "✅ vnStat fully uninstalled."
}

daily_summary_toggle() {
  if [ -f "$CRON_FILE" ]; then
    sudo rm -f "$CRON_FILE"
    echo "❎ Disabled automatic daily summary logging."
  else
    echo "0 0 * * * root /usr/local/bin/vnstat-helper.sh --daily >> $DAILY_LOG 2>&1" | sudo tee "$CRON_FILE" >/dev/null
    echo "✅ Enabled automatic daily summary logging (logs → $DAILY_LOG)"
  fi
}

# Daily run (for cron)
if [[ "$1" == "--daily" ]]; then
  [ ! -f "$DATA_FILE" ] && exit 0
  source "$DATA_FILE"
  VNSTAT_TOTAL=$(get_vnstat_total_gb)
  COMBINED_TOTAL=$(echo "scale=2; $BASE_TOTAL + $VNSTAT_TOTAL" | bc)
  echo "$(date '+%F %T') Interface:$IFACE Baseline:$BASE_TOTAL GB vnStat:$VNSTAT_TOTAL GB Total:$COMBINED_TOTAL GB" >> "$DAILY_LOG"
  exit 0
fi

# ───────────────────────────────────────────────
# Auto setup logic
# ───────────────────────────────────────────────
check_vnstat
[ ! -f "$INSTALL_TIME_FILE" ] && date +%s | sudo tee "$INSTALL_TIME_FILE" >/dev/null
VNSTAT_INSTALL_TIME=$(cat "$INSTALL_TIME_FILE")
BASELINE_TIME=0
[ -f "$DATA_FILE" ] && BASELINE_TIME=$(date -d "$(grep RECORDED_TIME "$DATA_FILE" | cut -d'"' -f2)" +%s 2>/dev/null || echo 0)
[ ! -f "$DATA_FILE" ] && record_baseline

if [ "$BASELINE_TIME" -lt "$VNSTAT_INSTALL_TIME" ] && [ "$BASELINE_TIME" != "0" ]; then
  echo "⚠️ Baseline is older than vnStat installation."
  echo "→ To ensure accuracy, vnStat database will be reset for a fresh start."
  reset_vnstat
fi

# ───────────────────────────────────────────────
# Menu
# ───────────────────────────────────────────────
while true; do
  clear
  echo "=============================="
  echo "   VNSTAT CONTROL PANEL $version"
  echo "=============================="
  echo "1) Daily usage"
  echo "2) Weekly usage"
  echo "3) Monthly usage"
  echo "4) Hourly usage"
  echo "5) Live monitor"
  echo "6) Combined total"
  echo "7) Export JSON"
  echo "8) Reset vnStat database"
  echo "9) Install vnStat"
  echo "10) Uninstall vnStat"
  echo "11) Enable/Disable daily summary"
  echo "12) View logs"
  echo "13) Exit"
  echo "=============================="
  read -rp "Select option [1-13]: " ch
  echo ""
  case $ch in
    1) echo "→ Showing daily traffic usage (received/sent per day):"; vnstat -i "$IFACE" -d ;;
    2) echo "→ Showing weekly usage summary (7-day totals):"; vnstat -i "$IFACE" -w ;;
    3) echo "→ Showing monthly usage overview:"; vnstat -i "$IFACE" -m ;;
    4) echo "→ Showing hourly usage (last 24 hours):"; vnstat -i "$IFACE" -h ;;
    5) echo "→ Live real-time bandwidth monitor (press Ctrl+C to stop):"; vnstat -i "$IFACE" -l ;;
    6) echo "→ Calculating and displaying total traffic:"; show_combined_summary ;;
    7) echo "→ Exporting vnStat data to JSON:"; vnstat -i "$IFACE" --json > "$BASE_DIR/vnstat-export.json" && echo "✅ Exported → $BASE_DIR/vnstat-export.json" ;;
    8) echo "→ This clears vnStat data (not uninstall)."; reset_vnstat ;;
    9) echo "→ Installing vnStat manually..."; install_vnstat ;;
    10) echo "→ Uninstalling vnStat completely..."; uninstall_vnstat ;;
    11) echo "→ Toggle daily auto summary:"; daily_summary_toggle ;;
    12) echo "→ Showing last 20 log entries:"; sudo tail -n 20 "$LOG_FILE" 2>/dev/null || echo "No logs yet." ;;
    13) echo "👋 Exiting vnStat helper."; exit 0 ;;
    *) echo "Invalid option. Try again." ;;
  esac
  echo ""
  read -rp "Press Enter to return to menu..."
done
