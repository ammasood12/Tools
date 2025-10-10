#!/bin/bash
# ==========================================
# V2bX User Activity Checker (Violation Detection)
# Enhanced with usage time calculation and violation analysis
# ==========================================

# ---------------------------
# Color codes for output
# ---------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# ---------------------------
# Select log period
# ---------------------------
echo -e "${CYAN}Select log period to scan:${NC}"
echo -e " 1) Last 1 day"
echo -e " 2) Last 1 week"
echo -e " 3) All logs"
read -p "Enter option [1-3]: " option

case "$option" in
  1) period="1 day ago" ;;
  2) period="1 week ago" ;;
  3) period="" ;;
  *) echo -e "${RED}Invalid option${NC}"; exit 1 ;;
esac

# ---------------------------
# Get user UUID or email
# ---------------------------
read -p "Enter user UUID or email: " uuid
if [ -z "$uuid" ]; then
  echo -e "${RED}❌ UUID or email cannot be empty.${NC}"
  exit 1
fi

echo -e "${CYAN}🔍 Extracting session data for user: $uuid ...${NC}"

tmpfile="/tmp/user_ips_raw.txt"
logfile="/root/user_sessions.txt"
location_cache_file="/tmp/ip_locations.txt"

# ---------------------------
# Extract IPs and timestamps from V2bX logs
# ---------------------------
if [ -n "$period" ]; then
    journalctl -u V2bX --since "$period" -o cat | grep "$uuid" \
    | awk '{match($0,/from ([0-9.:]+):[0-9]+/,a); ip=a[1]; match($0,/^[0-9\/]+ [0-9:.]+/,b); ts=b[0]; if(ip!="") print ts "|" ip}' \
    > "$tmpfile"
else
    journalctl -u V2bX -o cat | grep "$uuid" \
    | awk '{match($0,/from ([0-9.:]+):[0-9]+/,a); ip=a[1]; match($0,/^[0-9\/]+ [0-9:.]+/,b); ts=b[0]; if(ip!="") print ts "|" ip}' \
    > "$tmpfile"
fi

total_connections=$(wc -l < "$tmpfile")
if [ "$total_connections" -eq 0 ]; then
  echo -e "${YELLOW}⚠️ No activity found for this user.${NC}"
  exit 0
fi

# ---------------------------
# Unique IP counts + first/last timestamps + calculate duration
# ---------------------------
sort "$tmpfile" | awk -F'|' '{
  count[$2]++;
  if(!start[$2]) start[$2]=$1;
  end[$2]=$1;
  # Store all timestamps for duration calculation
  if(first_ts[$2]=="") first_ts[$2]=$1;
  last_ts[$2]=$1;
} END {
  for(ip in count) {
    # Calculate approximate duration (first to last connection)
    cmd = "date -d \"" last_ts[ip] "\" +%s 2>/dev/null";
    cmd | getline end_epoch;
    close(cmd);
    cmd = "date -d \"" first_ts[ip] "\" +%s 2>/dev/null";
    cmd | getline start_epoch;
    close(cmd);
    
    if(end_epoch > start_epoch) {
      total_seconds = end_epoch - start_epoch;
      days = int(total_seconds / 86400);
      hours = int((total_seconds % 86400) / 3600);
      minutes = int((total_seconds % 3600) / 60);
      duration = sprintf("%02d:%02d:%02d", days, hours, minutes);
    } else {
      duration = "00:00:00";
    }
    printf "%d|%s|%s|%s|%s\n", count[ip], ip, start[ip], end[ip], duration;
  }
}' | sort -t'|' -k3,3 > "$logfile"  # Sort by start time

unique_ips=$(wc -l < "$logfile")

# ---------------------------
# Check and install dependencies only if needed
# ---------------------------
echo -e "${CYAN}📦 Checking dependencies...${NC}"

check_and_install() {
    local package=$1
    if ! command -v "$package" &> /dev/null; then
        echo -e "${YELLOW}Installing $package...${NC}"
        apt install -y "$package" > /dev/null 2>&1
    else
        echo -e "${GREEN}✓ $package already installed${NC}"
    fi
}

check_and_install curl
check_and_install jq

# ---------------------------
# IP Location Function
# ---------------------------
get_ip_location() {
    local ip=$1
    local location=""
    
    response=$(curl -s -m 2 "http://ip-api.com/json/$ip?fields=status,message,country,regionName,city,isp")
    status=$(echo "$response" | jq -r '.status' 2>/dev/null)
    
    if [ "$status" = "success" ]; then
        city=$(echo "$response" | jq -r '.city // empty')
        region=$(echo "$response" | jq -r '.regionName // empty')
        country=$(echo "$response" | jq -r '.country // empty')
        isp=$(echo "$response" | jq -r '.isp // empty')
        
        if [ -n "$city" ] && [ "$city" != "null" ]; then
            location="$city"
            [ -n "$region" ] && [ "$region" != "null" ] && [ "$region" != "$city" ] && location="$location, $region"
            if [[ "$isp" == *"Mobile"* ]]; then
                location="$location (Mobile)"
            elif [[ "$isp" == *"Telecom"* ]]; then
                location="$location (Telecom)"
            elif [[ "$isp" == *"Unicom"* ]]; then
                location="$location (Unicom)"
            fi
        else
            location="$region, $country"
        fi
    else
        location="Unknown"
    fi
    
    echo "$location"
}

# ---------------------------
# Get IP subnet (first 3 octets)
# ---------------------------
get_ip_subnet() {
    local ip=$1
    echo "$ip" | cut -d. -f1-3
}

# ---------------------------
# Pre-fetch all IP locations
# ---------------------------
echo -e "${YELLOW}🌍 Fetching IP locations...${NC}"
> "$location_cache_file"

while IFS='|' read -r count ip start_time end_time duration; do
    if ! grep -q "^$ip|" "$location_cache_file" 2>/dev/null; then
        location=$(get_ip_location "$ip")
        subnet=$(get_ip_subnet "$ip")
        echo "$ip|$location|$subnet" >> "$location_cache_file"
        sleep 0.2
    fi
done < "$logfile"

# ---------------------------
# Display Main IP Table (Sorted by Start Time)
# ---------------------------
echo
echo -e "${CYAN}==================== User Connection Summary ====================${NC}"
echo
echo -e "${GREEN}✅ Found $unique_ips unique IPs ($total_connections total connections)${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-18s | %-8s | %-25s | %s\n" "#" "IP (Connections)" "Usage" "Location" "Start → End"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Create sessions array file
sessions_file="/tmp/user_sessions_array.txt"
> "$sessions_file"

num=1
while IFS='|' read -r count ip start_time end_time duration; do
    # Get location and subnet from cache
    cache_entry=$(grep "^$ip|" "$location_cache_file")
    location=$(echo "$cache_entry" | cut -d'|' -f2)
    subnet=$(echo "$cache_entry" | cut -d'|' -f3)
    
    # Format timestamps
    start_fmt=$(date -d "$start_time" +"%m/%d %H:%M" 2>/dev/null || echo "$start_time")
    end_fmt=$(date -d "$end_time" +"%m/%d %H:%M" 2>/dev/null || echo "$end_time")
    
    # Truncate long location strings
    if [ ${#location} -gt 22 ]; then
        location="${location:0:19}..."
    fi
    
    printf "%-3s %-18s | %-8s | %-25s | %s → %s\n" \
        "$num" "$ip ($count)" "$duration" "$location" "$start_fmt" "$end_fmt"
    
    # Store session data with subnet
    echo "$ip|$subnet|$start_time|$end_time" >> "$sessions_file"
    ((num++))
done < "$logfile"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Overlapping Sessions Analysis (Enhanced)
# ---------------------------
echo
echo -e "${CYAN}==================== Overlapping Sessions ======================${NC}"
echo
echo -e "${YELLOW}📅 Sessions with overlapping time periods:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-20s | %s\n" "#" "Start → End" "IPs (Subnet)"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Convert sessions to events
events_file="/tmp/events.txt"
> "$events_file"

while IFS='|' read -r ip subnet start end; do
    start_fmt=$(date -d "$start" +"%m/%d %H:%M" 2>/dev/null || echo "$start")
    end_fmt=$(date -d "$end" +"%m/%d %H:%M" 2>/dev/null || echo "$end")
    echo "$start|start|$ip|$subnet" >> "$events_file"
    echo "$end|end|$ip|$subnet" >> "$events_file"
done < "$sessions_file"

# Sort events by timestamp
sort "$events_file" > "$events_file.sorted" 2>/dev/null

active_ips_file="/tmp/active_ips.txt"
active_subnets_file="/tmp/active_subnets.txt"
> "$active_ips_file"
> "$active_subnets_file"

overlap_start=""
overlap_num=1
overlap_found=0

if [ -s "$events_file.sorted" ]; then
    while IFS='|' read -r timestamp type ip subnet; do
        if [ "$type" == "start" ]; then
            # Add IP and subnet to active lists
            echo "$ip" >> "$active_ips_file"
            echo "$subnet" >> "$active_subnets_file"
            
            active_count=$(sort -u "$active_ips_file" | wc -l | tr -d ' ')
            active_subnets=$(sort -u "$active_subnets_file" | wc -l | tr -d ' ')
            
            # Start overlap if 2+ IPs from different subnets active
            if [ "$active_subnets" -ge 2 ] && [ -z "$overlap_start" ]; then
                overlap_start="$timestamp"
                overlap_subnets=$(sort -u "$active_subnets_file" | tr '\n' ',' | sed 's/,$//')
            fi
        else
            # Get counts before removal
            active_count=$(sort -u "$active_ips_file" | wc -l | tr -d ' ')
            active_subnets=$(sort -u "$active_subnets_file" | wc -l | tr -d ' ')
            
            # End overlap if currently 2+ subnets active
            if [ "$active_subnets" -ge 2 ] && [ -n "$overlap_start" ]; then
                overlap_end="$timestamp"
                # Get active IPs and subnets
                active_ips_list=$(sort -u "$active_ips_file" | tr '\n' ',' | sed 's/,$//')
                active_subnets_list=$(sort -u "$active_subnets_file" | tr '\n' ',' | sed 's/,$//')
                
                start_fmt=$(date -d "$overlap_start" +"%m/%d %H:%M" 2>/dev/null)
                end_fmt=$(date -d "$overlap_end" +"%m/%d %H:%M" 2>/dev/null)
                
                printf "%-3s %-20s | %s\n" "$overlap_num" "$start_fmt → $end_fmt" "$active_ips_list"
                printf "%-3s %-20s | %s\n" "" "" "Subnets: $active_subnets_list"
                echo -e "${BLUE}-----------------------------------------------------------------${NC}"
                ((overlap_num++))
                overlap_found=1
            fi
            
            # Remove IP and subnet from active lists
            grep -v "^$ip$" "$active_ips_file" > "$active_ips_file.tmp" && mv "$active_ips_file.tmp" "$active_ips_file"
            grep -v "^$subnet$" "$active_subnets_file" > "$active_subnets_file.tmp" && mv "$active_subnets_file.tmp" "$active_subnets_file"
            
            # Reset overlap if less than 2 subnets
            active_subnets=$(sort -u "$active_subnets_file" | wc -l | tr -d ' ')
            if [ "$active_subnets" -lt 2 ]; then
                overlap_start=""
            fi
        fi
    done < "$events_file.sorted"
fi

if [ $overlap_found -eq 0 ]; then
    echo -e "${YELLOW}No overlapping sessions from different networks found.${NC}"
    echo -e "${BLUE}-----------------------------------------------------------------${NC}"
fi

# ---------------------------
# Violation Analysis Conclusion
# ---------------------------
echo
echo -e "${PURPLE}==================== Violation Analysis ======================${NC}"
echo

# Analyze subnet patterns
echo -e "${YELLOW}📊 Network Analysis:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Count unique subnets
unique_subnets=$(cut -d'|' -f2 "$location_cache_file" | sort -u | wc -l | tr -d ' ')
echo -e "Unique IP Subnets: $unique_subnets"

# Show subnet distribution
echo
echo -e "${YELLOW}🌐 IP Subnet Distribution:${NC}"
awk -F'|' '{subnet_count[$3]++} END {
    for(subnet in subnet_count) {
        printf "  %-15s: %2d IPs\n", subnet, subnet_count[subnet]
    }
}' "$location_cache_file"

# Violation assessment
echo
echo -e "${YELLOW}🔍 Violation Assessment:${NC}"

if [ $overlap_found -eq 0 ]; then
    echo -e "  ${GREEN}✅ NO EVIDENCE of multi-device usage${NC}"
    echo -e "  - All connections appear to be from same network segments"
    echo -e "  - IP changes are likely due to carrier rotation"
else
    echo -e "  ${RED}🚨 POTENTIAL VIOLATION DETECTED${NC}"
    echo -e "  - Multiple different network segments active simultaneously"
    echo -e "  - This suggests different devices/locations"
    echo -e "  - Check overlapping sessions above for evidence"
fi

echo
echo -e "${YELLOW}💡 Interpretation Guide:${NC}"
echo -e "  - Same subnet (e.g., 39.144.154.*) = Same carrier, likely same device"
echo -e "  - Different subnets overlapping = Different networks, likely different devices"
echo -e "  - 3+ different subnets overlapping = Clear violation of 3-device limit"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Save files and cleanup
# ---------------------------
echo
echo -e "${GREEN}📄 Session summary saved to: $logfile${NC}"
echo -e "${GREEN}📄 Raw timestamp+IP data saved to: $tmpfile${NC}"

# Cleanup temporary files
rm -f "$location_cache_file" "$sessions_file" "$events_file" "$events_file.sorted" "$active_ips_file" "$active_subnets_file" 2>/dev/null
