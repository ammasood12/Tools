#!/bin/bash
# ============================================================
# 🧠  Network Diagnostic & Optimization Tool for Ubuntu/Debian
# ============================================================
# Features:
#   • Auto system info display
#   • BBR/BBR2 + fq_codel + UDP/QUIC optimization
#   • Network tests (ping / speed / traceroute)
#   • Restore backups
#   • Logging + color output
# ============================================================

# ---------- Colors ----------
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
NC="\033[0m"

LOG_FILE="/root/network-diagnostics-$(date +%Y%m%d-%H%M%S).log"

# ---------- Functions ----------
system_info() {
  clear
  echo -e "${CYAN}============================================================"
  echo -e "        🧠 System & Network Information"
  echo -e "============================================================${NC}"

  lsb_release -a 2>/dev/null
  echo -e "${CYAN}Kernel Version:${NC} $(uname -r)"
  echo -e "${CYAN}CPU:${NC} $(lscpu | grep 'Model name' | sed 's/Model name:\s*//')"
  echo -e "${CYAN}Cores:${NC} $(nproc)"
  echo -e "${CYAN}Memory:${NC} $(free -h | awk '/Mem:/{print $2}')"
  echo -e "${CYAN}Swap:${NC} $(free -h | awk '/Swap:/{print $2}')"
  echo

  echo -e "${YELLOW}>>> Active Network Interfaces${NC}"
  for i in $(ls /sys/class/net | grep -v lo); do
    IP=$(ip -4 addr show $i | grep inet | awk '{print $2}' | head -n1)
    echo -e "${CYAN}Interface:${NC} $i  ${CYAN}IP:${NC} ${IP:-N/A}"
    ethtool $i 2>/dev/null | grep -E "Speed|Duplex" | sed "s/^/   /"
    ip -s link show $i | awk '/RX:/{getline;print "   RX bytes: "$1", packets: "$2} /TX:/{getline;print "   TX bytes: "$1", packets: "$2}'
    echo -e "${GREEN}------------------------------------------------------------${NC}"
  done

  echo -e "${YELLOW}>>> Default Route${NC}"
  ip route get 8.8.8.8 | head -n1

  echo -e "${YELLOW}>>> BBR Status${NC}"
  sysctl net.ipv4.tcp_available_congestion_control | sed -E "s/(bbr2?)/\x1b[1;32m\1\x1b[0m/g"
  sysctl net.ipv4.tcp_congestion_control | sed -E "s/(bbr2?)/\x1b[1;32m\1\x1b[0m/g"

  echo -e "${CYAN}============================================================${NC}"
}

network_tests() {
  echo -e "\n${YELLOW}>>> Installing tools (if missing)...${NC}"
  apt update -y >/dev/null 2>&1
  apt install -y speedtest-cli traceroute ethtool >/dev/null 2>&1
  echo -e "${GREEN}✓ Tools ready.${NC}\n"

  echo -e "${CYAN}============================================================"
  echo -e "          🌐 Network Connectivity Tests"
  echo -e "============================================================${NC}"

  echo -e "${YELLOW}>>> Ping Tests${NC}"
  for host in 8.8.8.8 1.1.1.1 223.5.5.5; do
    echo -e "${CYAN}Pinging ${host}...${NC}"
    ping -c 4 $host | tail -n2 | tee -a "$LOG_FILE"
  done

  echo -e "\n${YELLOW}>>> Speed Test${NC}"
  speedtest-cli --secure | tee -a "$LOG_FILE"

  echo -e "\n${YELLOW}>>> Traceroute to 8.8.8.8${NC}"
  traceroute 8.8.8.8 | head -n 15 | tee -a "$LOG_FILE"

  echo -e "${CYAN}============================================================${NC}"
  echo -e "${GREEN}✅ Network test completed. Results logged to:${NC} $LOG_FILE"
}

apply_optimization() {
  echo -e "\n${YELLOW}>>> Checking BBR2 availability...${NC}"
  if modprobe tcp_bbr2 2>/dev/null; then
    read -p "BBR2 is available. Use BBR2 instead of BBR? [Y/n]: " USEBBR2
    if [[ "$USEBBR2" =~ ^[Yy]$ ]]; then
      BBR_MODE="bbr2"
    else
      BBR_MODE="bbr"
    fi
  else
    BBR_MODE="bbr"
    echo -e "${RED}BBR2 not found. Using BBR.${NC}"
  fi

  BACKUP_FILE="/etc/sysctl.conf.bak-$(date +%Y%m%d-%H%M%S)"
  echo -e "${YELLOW}>>> Creating backup: $BACKUP_FILE${NC}"
  cp /etc/sysctl.conf "$BACKUP_FILE" && echo -e "${GREEN}✓ Backup created.${NC}"

  echo -e "\n${YELLOW}>>> Applying optimization settings...${NC}"
  cat <<EOF > /etc/sysctl.conf
# ============================================================
# V2bX / Sing-box / Xray Network Optimization
# BBR + fq_codel + UDP/QUIC Enhanced
# Updated: $(date +%Y%m%d-%H%M%S)
# ============================================================

net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = ${BBR_MODE}
net.ipv4.ip_forward = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_mem = 3145728 4194304 8388608
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_syncookies = 1
fs.file-max = 1000000
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
# ============================================================
EOF

  sysctl -p | tee -a "$LOG_FILE"
  echo -e "${GREEN}✅ Optimization applied using ${BBR_MODE}.${NC}\n"
  echo -e "${YELLOW}>>> Verifying current settings...${NC}"
  echo -e "  Congestion Control : $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo -e "  Default qdisc      : $(sysctl -n net.core.default_qdisc)"
  echo -e "  IPv4 Forwarding    : $(sysctl -n net.ipv4.ip_forward)"
  echo -e "  Kernel Version     : $(uname -r)"
  echo -e "${GREEN}------------------------------------------------------------${NC}"
  echo -e "${GREEN}✅ System optimized for BBR/BBR2 + UDP/QUIC.${NC}\n"
}

restore_settings() {
  LAST_BAK=$(ls -t /etc/sysctl.conf.bak-* 2>/dev/null | head -n1)
  if [[ -z "$LAST_BAK" ]]; then
    echo -e "${RED}No backup found to restore.${NC}"
    return
  fi
  echo -e "${YELLOW}>>> Restoring from backup: ${LAST_BAK}${NC}"
  cp "$LAST_BAK" /etc/sysctl.conf && sysctl -p | tee -a "$LOG_FILE"
  echo -e "${GREEN}✅ Settings restored successfully.${NC}"
}

# ---------- Main ----------
system_info
while true; do
  echo -e "\n${CYAN}=============================="
  echo -e "   🧠 Network Management Menu"
  echo -e "==============================${NC}"
  echo -e "1️⃣  Run Network Tests"
  echo -e "2️⃣  Apply Optimization (BBR/BBR2 + UDP/QUIC)"
  echo -e "3️⃣  Restore Original Settings"
  echo -e "4️⃣  Exit"
  echo -ne "${YELLOW}Select an option [1-4]: ${NC}"
  read -r opt
  case $opt in
    1) network_tests ;;
    2) apply_optimization ;;
    3) restore_settings ;;
    4) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid option!${NC}" ;;
  esac
done
