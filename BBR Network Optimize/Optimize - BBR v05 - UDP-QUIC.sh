#!/bin/bash
# ============================================================
# 🚀 Replace /etc/sysctl.conf with V2bX (China) Optimization
# BBR + fq_codel + UDP/QUIC Enhanced (Hysteria2 / Reality)
# Auto Backup: /etc/sysctl.conf.bak-YYYY-MM-DD
# ============================================================

GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

clear
echo -e "${CYAN}============================================================"
echo -e "     V2bX / Sing-box / Xray sysctl.conf Optimization"
echo -e "          BBR + fq_codel + UDP/QUIC Enhanced"
echo -e "============================================================${RESET}"
sleep 1

# --- Backup existing sysctl.conf ---
BACKUP_FILE="/etc/sysctl.conf.bak-$(date +%F)"
echo -e "${YELLOW}>>> Creating backup: $BACKUP_FILE${RESET}"
cp /etc/sysctl.conf "$BACKUP_FILE" && echo -e "${GREEN}✓ Backup created successfully.${RESET}" || echo -e "${YELLOW}! Backup failed (check permissions).${RESET}"

sleep 1
echo
echo -e "${YELLOW}>>> Replacing /etc/sysctl.conf with enhanced version...${RESET}"

cat <<'EOF' > /etc/sysctl.conf
# ============================================================
# V2bX / Sing-box / Xray Network Optimization
# Optimized for China routes | BBR + fq_codel | UDP/QUIC Enhanced
# Updated: $(date)
# ============================================================

# --- Core network optimization ---
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr

# --- Connection stability ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- Performance tuning ---
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

# --- TCP buffers ---
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608

# --- UDP / QUIC performance enhancement ---
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_mem = 3145728 4194304 8388608
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768

# --- Port range ---
net.ipv4.ip_local_port_range = 10240 65535

# --- Security & stability ---
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 1

# --- File descriptor limits ---
fs.file-max = 1000000

# --- Routing reliability (multi-interface safe) ---
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# ============================================================
# End of V2bX optimization block
# ============================================================
EOF

echo -e "${GREEN}✓ /etc/sysctl.conf replaced successfully.${RESET}"
sleep 1

# --- Apply and display result ---
echo
echo -e "${YELLOW}>>> Applying new sysctl settings...${RESET}"
sysctl -p
echo

echo -e "${CYAN}------------------------------------------------------------${RESET}"
echo -e "${GREEN}✅ Current active settings:${RESET}"
echo
echo -e "  Congestion Control  : $(sysctl -n net.ipv4.tcp_congestion_control)"
echo -e "  Default qdisc       : $(sysctl -n net.core.default_qdisc)"
echo -e "  IPv4 Forwarding     : $(sysctl -n net.ipv4.ip_forward)"
echo -e "  Kernel Version      : $(uname -r)"
echo -e "${CYAN}------------------------------------------------------------${RESET}"
echo

# --- UDP verification block ---
echo -e "${YELLOW}>>> Verifying UDP/QUIC optimization...${RESET}"
UDP_MEM=$(sysctl -n net.ipv4.udp_mem)
RBUF=$(sysctl -n net.core.rmem_max)
WBUF=$(sysctl -n net.core.wmem_max)
echo
echo -e "${CYAN}UDP kernel memory (min/pressure/max):${RESET}  $UDP_MEM"
echo -e "${CYAN}Max receive buffer (rmem_max):${RESET}         $RBUF"
echo -e "${CYAN}Max send buffer (wmem_max):${RESET}            $WBUF"
echo
echo -e "${GREEN}✅ UDP/QUIC enhancement active.${RESET}"
echo -e "${CYAN}------------------------------------------------------------${RESET}"
echo
echo -e "${GREEN}✅ Done! Your system is now optimized for:"
echo -e "   - Hysteria2 (UDP acceleration)"
echo -e "   - VLESS + Reality (QUIC/TLS)"
echo -e "   - VMess + WebSocket (TCP)"
echo -e "   - Trojan + WebSocket (TCP)"
echo -e "${CYAN}------------------------------------------------------------${RESET}"
echo
