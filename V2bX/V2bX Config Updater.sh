#!/bin/bash
# ========================================
# 🚀 V2bX Config Updater
# ========================================
clear
# V2bX Config Updater version
version="7.07.3"
# --- Colors ---
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
RED='\033[1;31m'
BOLD='\033[1m'
NC='\033[0m'

# ========================================
# Editable values
# ========================================

# --- Select CertMode (http, dns, self, none) ---
Provider="cloudflare" # <-- ❌ Don't Edit
CertMode_hysteria2="dns"
CertMode_vmess="dns"
CertMode_trojan="dns"
CertMode_vless="none"

# --- Node list ---
# [NodeID]="domain.com"
declare -A nodes=(
  [1]="ln-sg.phicloud.shop"
  [2]="sg-1.phicloud.shop"
  [3]="jp2.phicloud.shop"
  [4]="jplinode.phicloud.shop"
  [5]="jp-1.phicloud.shop"
  [6]="bv-hk.phicloud.shop"
  [7]="ln-us1-la.phicloud.shop"
  [8]="ph-manila.phicloud.shop"
  [9]="us-2.phicloud.shop"
  [10]="hk-1.phicloud.shop"
  [11]="ni-tw2.phicloud.shop"
  [12]="test2.phicloud.shop"
  [13]="ac-hk.phicloud.shop"
  [14]="au-1.phicloud.shop"
  [15]="sg-3.phicloud.shop"
)

# --- Node type ID offsets ---
# these will append to nodeID e.g. for node 10, nodeTypeID=102
declare -A nodeTypeID=(
  ["vless"]=1
  ["hysteria2"]=2
  ["vmess"]=3
  ["trojan"]=5
)

# ========================================
# --- Universal Safe Input Function ---
# ========================================

ask_input() {
  local prompt="$1"
  read -rp "$(echo -e ${YELLOW}$prompt${NC})" reply
  if [[ -z "$reply" || "$reply" == "0" ]]; then
    echo -e "${RED}🚪 Exiting script...${NC}"
    # if the script is sourced, just return
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
      return 1
    else
      # if it's executed normally, exit only the script
      kill $$
    fi
  fi
  echo "$reply"
}


# ========================================
# V2bX CONFIG UPDATER - Main
# ========================================
echo -e "${BOLD}${BLUE}==============================================${NC}"
echo -e "${BOLD}${BLUE}        🛠️  V2bX CONFIG UPDATER $version"
echo -e "${BOLD}${BLUE}==============================================${NC}"

# ========================================
# Pre-checks for installation and config
# ========================================
echo ""
echo -e "${BOLD}${BLUE}──────────────────────────────────────────────${NC}"
echo -e "${BOLD}${BLUE}        🔍 Checking environment... "
echo -e "${BOLD}${BLUE}──────────────────────────────────────────────${NC}"

# --- Check if v2bx is installed ---
if ! command -v v2bx &>/dev/null; then
  echo -e "${RED}❌ V2bX is not installed on this system.${NC}"
  installAns=$(ask_input "Do you want to install it now? [Y/n]: ") || exit 0
  if [[ ! "$installAns" =~ ^[Nn]$ ]]; then
    echo -e "${CYAN}⬇️ Installing V2bX...${NC}"
    bash <(wget -qO- https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh)
    if command -v v2bx &>/dev/null; then
      echo -e "${GREEN}✅ V2bX installed successfully.${NC}\n"
    else
      echo -e "${RED}❌ Installation failed. Please install manually.${NC}"
      exit 1
    fi
  else
    echo -e "${YELLOW}⚠️ Skipping installation. Exiting.${NC}"
    exit 1
  fi
else
  echo -e "${GREEN}✅ V2bX detected.${NC}"
fi

# --- Check existing config.json ---
config_file="/etc/V2bX/config.json"
if [[ -f "$config_file" ]]; then
	echo -e "\n${CYAN}📄 Checking existing config.json...${NC}"

	# --- Extract node info (Core + NodeType + NodeID + CertDomain) ---
	echo -e "${YELLOW}Detected Nodes and Cores:${NC}"

	awk '
	  /"Core":/ {core=$2; gsub(/"|,/, "", core)}
	  /"NodeType":/ {node=$2; gsub(/"|,/, "", node)}
	  /"NodeID":/ {id=$2; gsub(/,/, "", id)}
	  /"CertDomain":/ {
		domain=$2; gsub(/"|,/, "", domain);
		if (core != "" && node != "") {
		  printf "  • %-5s → %-10s | NodeID: %-4s | Domain: %s\n", core, node, id, domain;
		  core=node=id=domain="";
		}
	  }
	' "$config_file"

	# --- Summary ---
	total_nodes=$(grep -c '"NodeType"' "$config_file" || true)
	total_cores=$(grep -c '"Type"' "$config_file" || true)
	if (( total_nodes > 0 )); then
	  echo -e "\n${CYAN}Summary:${NC} $total_nodes node(s), $total_cores core(s)\n"
	else
	  echo -e "${RED}No valid nodes found in current config.${NC}\n"
	fi
else
  echo -e "${RED}⚠️ No existing /etc/V2bX/config.json found.${NC}\n"
fi


# ========================================
# Configuration values
# ========================================

# --- Load API keys from /etc/V2bX/keys.conf ---
if [[ -f /etc/V2bX/keys.conf ]]; then
  source /etc/V2bX/keys.conf
else
  echo ""
  echo -e "${RED}❌ Missing /etc/V2bX/keys.conf${NC}"
  echo "==================================================="
  echo -e "${YELLOW}Run the following to set up your keys first:${NC}"
  echo "==================================================="
  echo "cat <<EOF > /etc/V2bX/keys.conf"
  echo "ApiHost=\"your_api_host_here\""
  echo "APIKEY=\"your_api_key_here\""
  echo "Email=\"your_email_here\""  
  echo "CLOUDFLARE_EMAIL=\"your_cloudflare_email_here\""
  echo "CLOUDFLARE_API_KEY=\"your_cloudflare_api_key_here\""
  echo "EOF"
  echo "chmod 600 /etc/V2bX/keys.conf"
  echo "========================="
  echo "Or use one line command"
  echo "========================="
  echo "echo 'ApiHost="your_api_host_here"\nAPIKEY="your_api_key_here"\nEmail="your_email_here"\nCLOUDFLARE_EMAIL="your_cloudflare_email_here"\nCLOUDFLARE_API_KEY="your_cloudflare_api_key_here"' | sed 's/\\n/\n/g' > /etc/V2bX/keys.conf && chmod 600 /etc/V2bX/keys.conf"
  exit 1
fi

# ========================================
# Select which node types to include
# ========================================
echo -e "${BOLD}${BLUE}──────────────────────────────────────────────${NC}"
echo -e "${BOLD}${BLUE}        ✅  Add Nodes "
echo -e "${BOLD}${BLUE}──────────────────────────────────────────────${NC}"
echo ""
echo -e "${CYAN}Select which node types you want to include:${NC}\n"
echo -e "This will append to original nodeID (e.g. for node 10, nodeTypeID=102)\n"
echo -e "  1) ${GREEN}VLESS       → xRay${NC}"
echo -e "  2) ${GREEN}Hysteria2   → Singbox${NC}"
echo -e "  3) ${GREEN}VMESS       → xRay${NC}"
echo -e "  4) ${GREEN}ShadowSocks → xRay${NC}  ${RED}[Not Available]${NC}"
echo -e "  5) ${GREEN}TROJAN      → xRay${NC}"
echo ""
# read -rp "$(echo -e ${YELLOW}"Enter selection (e.g. 1,3,4): "${NC})" node_selection
node_selection=$(ask_input "Enter selection (e.g. 1,3,4 or 0 to exit): ") || exit 0
echo ""

# Reset all options
USE_VLESS=false
USE_HYSTERIA2=false
USE_VMESS=false
USE_SHADOWSOCKS=false
USE_TROJAN=false

# Convert input into array and enable chosen ones
invalid_found=false
IFS=',' read -ra selected <<< "$node_selection"
for num in "${selected[@]}"; do
  case "${num// /}" in
    1) USE_VLESS=true ;;
    2) USE_HYSTERIA2=true ;;
    3) USE_VMESS=true ;;
    5) USE_TROJAN=true ;;
    *)
      echo -e "${RED}⚠️  Option ${num// /} is not available and will be ignored.${NC}"
      invalid_found=true
      ;;
  esac
done

if $invalid_found; then
  echo -e "${YELLOW}ℹ️  Some selections were invalid and skipped.${NC}\n"
fi


# Show confirmation
echo -e "${GREEN}✅ Node type selection complete:${NC}"


# ========================================
# Selection Summary 
# ========================================
echo ""
echo -e "${BOLD}${BLUE}──────────────────────────────────────────────${NC}"
echo -e "${BOLD}${BLUE}        ✅  Selection Summary "
echo -e "${BOLD}${BLUE}──────────────────────────────────────────────${NC}"
echo ""
echo -e "${YELLOW}This script will:${NC}"
echo -e "  • Backup ${CYAN}/etc/V2bX/config.json${NC}"
echo -e "  • Replace ${CYAN}/etc/V2bX/config.json${NC}"
echo -e "  • Use API Key: ${CYAN}${APIKEY}${NC}"
echo -e "  • Configure active sections:${NC}"
echo -e "      ▷ ${CYAN}VLESS       → xRay:${NC}     $USE_VLESS"
echo -e "      ▷ ${CYAN}Hysteria2   → Singbox:${NC}  $USE_HYSTERIA2"
echo -e "      ▷ ${CYAN}VMESS       → xRay:${NC}     $USE_VMESS"
echo -e "      ▷ ${CYAN}ShadowSocks → xRay:${NC}     $USE_SHADOWSOCKS"
echo -e "      ▷ ${CYAN}TROJAN      → xRay:${NC}     $USE_TROJAN"
echo -e "  • Automatically restart V2bX\n"

# --- Display nodes ---
echo -e "${BOLD}${BLUE}──────────────────────────────────────────────${NC}"
echo -e "${BOLD} No │ Domain${NC}"
echo -e "${BLUE}──────────────────────────────────────────────${NC}"
for i in $(seq 1 15); do
  printf "${CYAN} %2s ${NC}│ %s\n" "$i" "${nodes[$i]}"
done
echo -e "${BLUE}──────────────────────────────────────────────${NC}\n"

# --- Select node ---
# read -rp "$(echo -e ${YELLOW}"Enter Node number (1–15): "${NC})" nodeNum
nodeNum=$(ask_input "Enter Node number (1–15 or 0 to exit): ") || exit 0
echo ""
if [[ -z "${nodes[$nodeNum]}" ]]; then
  echo -e "${RED}❌ Invalid node number.${NC}"
  echo -e "${YELLOW}Please try again.${NC}"
  exec "$0"  # restart the script instead of exiting shell
fi

domain="${nodes[$nodeNum]}"
echo -e "${GREEN}✅ Selected Node:${NC} $domain\n"

# --- Calculate NodeIDs ---
for type in "${!nodeTypeID[@]}"; do
  declare NodeID_${type}=$((nodeNum * 10 + nodeTypeID[$type]))
done

echo -e "${CYAN}Generated Node IDs:${NC}"
$USE_VLESS && echo -e "  VLESS:     $NodeID_vless"
$USE_VMESS && echo -e "  VMESS:     $NodeID_vmess"
$USE_TROJAN && echo -e "  TROJAN:    $NodeID_trojan"
$USE_HYSTERIA2 && echo -e "  Hysteria2: $NodeID_hysteria2"
echo ""

# --- Ensure directory exists ---
mkdir -p /etc/V2bX
backup_file="/etc/V2bX/config.json.bak-$(date +%Y%m%d-%H%M%S)"
cp /etc/V2bX/config.json "$backup_file" 2>/dev/null && \
echo -e "${GREEN}💾 Backup created:${NC} $backup_file\n"

# --- Begin writing config ---
echo -e "${YELLOW}🧩 Generating configuration...${NC}"

{
cat <<CONFIG_HEADER
{
  "Log": {
    "Level": "error",
    "Output": ""
  },
CONFIG_HEADER

# --- Add Cores ---

cat <<CORE_HEADER
  "Cores": [
CORE_HEADER

if $USE_VLESS || $USE_VMESS || $USE_TROJAN; then
  cat <<XRAYCORE
    {
      "Type": "xray",
      "Log": {
        "Level": "error",
        "ErrorPath": "/etc/V2bX/error.log"
      },
      "OutboundConfigPath": "/etc/V2bX/custom_outbound.json",
      "RouteConfigPath": "/etc/V2bX/route.json"
    }$( $USE_HYSTERIA2 && echo "," )
XRAYCORE
fi

if $USE_HYSTERIA2; then
  cat <<SINGCORE
    {
      "Type": "sing",
      "Log": {
        "Level": "error",
        "Timestamp": true
      },
      "NTP": {
        "Enable": false,
        "Server": "time.apple.com",
        "ServerPort": 0
      },
      "OriginalPath": "/etc/V2bX/sing_origin.json"
    }
SINGCORE
fi

cat <<CORE_FOOTER
  ],
CORE_FOOTER

cat <<NODE_HEADER
  "Nodes": [
NODE_HEADER

# --- Add Nodes ---

if $USE_HYSTERIA2; then
  cat <<SINGNODE
    {
      "Core": "sing",
      "ApiHost": "$ApiHost",
      "ApiKey": "$APIKEY",
      "NodeID": $NodeID_hysteria2,
      "NodeType": "hysteria2",
      "Timeout": 30,
      "ListenIP": "::",
      "SendIP": "0.0.0.0",
      "DeviceOnlineMinTraffic": 200,
      "MinReportTraffic": 0,
      "TCPFastOpen": false,
      "SniffEnabled": true,
      "CertConfig": {
        "CertMode": "$CertMode_hysteria2",
		"RejectUnknownSni": false,
        "CertDomain": "$domain",
        "CertFile": "/etc/V2bX/fullchain.cer",
        "KeyFile": "/etc/V2bX/cert.key",
        "Email": "$Email",
        "Provider": "$Provider",
        "DNSEnv": {
          "CLOUDFLARE_EMAIL": "$CLOUDFLARE_EMAIL",
          "CLOUDFLARE_API_KEY": "$CLOUDFLARE_API_KEY"
        }
      }
    }$( $USE_VMESS || $USE_TROJAN || $USE_VLESS && echo "," )
SINGNODE
fi

if $USE_VMESS; then
  cat <<VMESSNODE
    {
      "Core": "xray",
      "ApiHost": "$ApiHost",
      "ApiKey": "$APIKEY",
      "NodeID": $NodeID_vmess,
      "NodeType": "vmess",
      "Timeout": 30,
      "ListenIP": "0.0.0.0",
      "SendIP": "0.0.0.0",
      "DeviceOnlineMinTraffic": 200,
      "MinReportTraffic": 0,
      "EnableProxyProtocol": false,
      "EnableUot": true,
      "EnableTFO": true,
      "DNSType": "UseIPv4",
      "CertConfig": {
        "CertMode": "$CertMode_vmess",
		"RejectUnknownSni": false,
        "CertDomain": "$domain",
        "CertFile": "/etc/V2bX/fullchain.cer",
        "KeyFile": "/etc/V2bX/cert.key",
        "Email": "$Email",
        "Provider": "$Provider",
        "DNSEnv": {
          "CLOUDFLARE_EMAIL": "$CLOUDFLARE_EMAIL",
          "CLOUDFLARE_API_KEY": "$CLOUDFLARE_API_KEY"
        }
      }
    }$( $USE_TROJAN || $USE_VLESS && echo "," )
VMESSNODE
fi

if $USE_TROJAN; then
  cat <<TROJANNODE
    {
      "Core": "xray",
      "ApiHost": "$ApiHost",
      "ApiKey": "$APIKEY",
      "NodeID": $NodeID_trojan,
      "NodeType": "trojan",
      "Timeout": 30,
      "ListenIP": "0.0.0.0",
      "SendIP": "0.0.0.0",
      "DeviceOnlineMinTraffic": 200,
      "MinReportTraffic": 0,
      "EnableProxyProtocol": false,
      "EnableUot": true,
      "EnableTFO": true,
      "DNSType": "UseIPv4",
      "CertConfig": {
        "CertMode": "$CertMode_trojan",
        "RejectUnknownSni": false,
        "CertDomain": "$domain",
        "CertFile": "/etc/V2bX/fullchain.cer",
        "KeyFile": "/etc/V2bX/cert.key",
        "Email": "$Email",
        "Provider": "$Provider",
        "DNSEnv": {
          "CLOUDFLARE_EMAIL": "$CLOUDFLARE_EMAIL",
          "CLOUDFLARE_API_KEY": "$CLOUDFLARE_API_KEY"
        }
      }
    }$( $USE_VLESS && echo "," )
TROJANNODE
fi

if $USE_VLESS; then
  cat <<VLESSNODE
    {
      "Core": "xray",
      "ApiHost": "$ApiHost",
      "ApiKey": "$APIKEY",
      "NodeID": $NodeID_vless,
      "NodeType": "vless",
      "Timeout": 30,
      "ListenIP": "0.0.0.0",
      "SendIP": "0.0.0.0",
      "DeviceOnlineMinTraffic": 200,
      "MinReportTraffic": 0,
      "EnableProxyProtocol": false,
      "EnableUot": true,
      "EnableTFO": true,
      "DNSType": "UseIPv4",
      "CertConfig": {
        "CertMode": "$CertMode_vless",
		"RejectUnknownSni": false,
        "CertDomain": "$domain",
        "CertFile": "/etc/V2bX/fullchain.cer",
        "KeyFile": "/etc/V2bX/cert.key",
        "Email": "$Email",
        "Provider": "$Provider",
        "DNSEnv": {
          "CLOUDFLARE_EMAIL": "$CLOUDFLARE_EMAIL",
          "CLOUDFLARE_API_KEY": "$CLOUDFLARE_API_KEY"
        }
      }
    }
VLESSNODE
fi

cat <<NODE_FOOTER
  ]
NODE_FOOTER

cat <<CONFIG_FOOTER
}
CONFIG_FOOTER

} > /etc/V2bX/config.json

echo -e "${GREEN}✅ Config successfully generated and saved.${NC}\n"
echo -e "${YELLOW}🔄 Restarting V2bX...${NC}"
v2bx restart
