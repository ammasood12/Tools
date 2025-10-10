#!/bin/bash
# ==========================================
# V2bX User Activity Checker (Fixed Version)
# Fixed timestamp parsing issues
# ==========================================

# ---------------------------
# Color codes for output
# ---------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
# Extract IPs and timestamps from V2bX logs (FIXED)
# ---------------------------
if [ -n "$period" ]; then
    # With time period
    journalctl -u V2bX --since "$period" -o cat | grep "$uuid" \
    | awk '{match($0,/from ([0-9.:]+):[0-9]+/,a); ip=a[1]; match($0,/^[0-9\/]+ [0-9:.]+/,b); ts=b[0]; if(ip!="") print ts "|" ip}' \
    > "$tmpfile"
else
    # All logs
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
# Unique IP counts + first/last timestamps
# ---------------------------
sort "$tmpfile" | awk -F'|' '{
  count[$2]++;
  if(!start[$2]) start[$2]=$1;
  end[$2]=$1
} END {
  for(ip in count)
    printf "%d|%s|%s|%s\n", count[ip], ip, start[ip], end[ip]
}' | sort -nr > "$logfile"

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
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ $package installed${NC}"
        else
            echo -e "${RED}✗ Failed to install $package${NC}"
        fi
    else
        echo -e "${GREEN}✓ $package already installed${NC}"
    fi
}

check_and_install curl
check_and_install jq

# ---------------------------
# High Accuracy IP Location Function
# ---------------------------
get_ip_location() {
    local ip=$1
    local location=""
    
    # Method 1: ip-api.com (most accurate for Chinese IPs)
    response=$(curl -s -m 2 "http://ip-api.com/json/$ip?fields=status,message,country,regionName,city,isp,org,as,query")
    status=$(echo "$response" | jq -r '.status' 2>/dev/null)
    
    if [ "$status" = "success" ]; then
        city=$(echo "$response" | jq -r '.city // empty')
        region=$(echo "$response" | jq -r '.regionName // empty')
        country=$(echo "$response" | jq -r '.country // empty')
        isp=$(echo "$response" | jq -r '.isp // empty')
        
        # For Chinese IPs, include ISP information for better accuracy
        if [ "$country" = "China" ]; then
            if [ -n "$city" ] && [ "$city" != "null" ]; then
                location="$city"
                [ -n "$region" ] && [ "$region" != "null" ] && [ "$region" != "$city" ] && location="$location, $region"
                # Add ISP info for mobile networks
                if [[ "$isp" == *"Mobile"* ]] || [[ "$isp" == *"China Mobile"* ]]; then
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
            # For non-Chinese IPs
            if [ -n "$city" ] && [ "$city" != "null" ]; then
                location="$city, $region, $country"
            else
                location="$region, $country"
            fi
        fi
    fi
    
    # Method 2: ipapi.co (fallback with different database)
    if [ -z "$location" ] || [ "$location" = "null" ]; then
        response=$(curl -s -m 2 "https://ipapi.co/$ip/json/")
        city=$(echo "$response" | jq -r '.city // empty')
        region=$(echo "$response" | jq -r '.region // empty')
        country=$(echo "$response" | jq -r '.country_name // empty')
        
        if [ -n "$city" ] && [ "$city" != "null" ]; then
            location="$city, $region, $country"
        elif [ -n "$region" ] && [ "$region" != "null" ]; then
            location="$region, $country"
        elif [ -n "$country" ] && [ "$country" != "null" ]; then
            location="$country"
        fi
    fi
    
    # Final fallback
    if [ -z "$location" ] || [ "$location" = "null" ]; then
        location="Unknown location"
    fi
    
    # Clean up
    location=$(echo "$location" | sed 's/^[, ]*//; s/[, ]*$//; s/,,*/,/g; s/null//g')
    echo "$location"
}

# ---------------------------
# Pre-fetch all IP locations (silent)
# ---------------------------
echo -e "${YELLOW}🌍 Fetching IP locations...${NC}"
> "$location_cache_file"

while IFS='|' read -r count ip start_time end_time; do
    if ! grep -q "^$ip|" "$location_cache_file" 2>/dev/null; then
        location=$(get_ip_location "$ip")
        echo "$ip|$location" >> "$location_cache_file"
        # Reduced delay for better performance
        sleep 0.3
    fi
done < "$logfile"

# ---------------------------
# Display Main IP Table
# ---------------------------
echo
echo -e "${CYAN}==================== User Connection Summary ====================${NC}"
echo
echo -e "${GREEN}✅ Found $unique_ips unique IPs ($total_connections total connections)${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-20s | %-35s | %s\n" "#" "IP (Connections)" "Location" "Start → End"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Create sessions array file
sessions_file="/tmp/user_sessions_array.txt"
> "$sessions_file"

num=1
while IFS='|' read -r count ip start_time end_time; do
    # Get location from cache
    location=$(grep "^$ip|" "$location_cache_file" | cut -d'|' -f2-)
    if [ -z "$location" ]; then
        location="Unknown location"
    fi
    
    # Format timestamps (with better error handling)
    start_fmt=$(date -d "$start_time" +"%Y/%m/%d %H:%M" 2>/dev/null || echo "$start_time")
    end_fmt=$(date -d "$end_time" +"%Y/%m/%d %H:%M" 2>/dev/null || echo "$end_time")
    
    # Truncate long location strings
    if [ ${#location} -gt 34 ]; then
        location="${location:0:31}..."
    fi
    
    printf "%-3s %-20s | %-35s | %s → %s\n" \
        "$num" "$ip ($count)" "$location" "$start_fmt" "$end_fmt"
    
    # Store session data in file
    echo "$ip|$start_fmt|$end_fmt" >> "$sessions_file"
    ((num++))
done < "$logfile"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Overlapping sessions (2+ IPs)
# ---------------------------
echo
echo -e "${CYAN}==================== Overlapping Sessions ======================${NC}"
echo
echo -e "${YELLOW}📅 Overlapping sessions per day (IPs active at the same time):${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-25s | %s\n" "#" "Start → End" "IP(s)"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Convert sessions to events using files
events_file="/tmp/events.txt"
> "$events_file"

while IFS='|' read -r ip start end; do
    echo "$start|start|$ip" >> "$events_file"
    echo "$end|end|$ip" >> "$events_file"
done < "$sessions_file"

# Sort events by timestamp
sort "$events_file" > "$events_file.sorted" 2>/dev/null

active_ips_file="/tmp/active_ips.txt"
> "$active_ips_file"

overlap_start=""
overlap_num=1
overlap_found=0

if [ -s "$events_file.sorted" ]; then
    while IFS='|' read -r timestamp type ip; do
        if [ "$type" == "start" ]; then
            # Add IP to active list
            echo "$ip" >> "$active_ips_file"
            active_count=$(wc -l < "$active_ips_file" | tr -d ' ')
            
            # Start overlap if 2+ IPs active
            if [ "$active_count" -eq 2 ] && [ -z "$overlap_start" ]; then
                overlap_start="$timestamp"
            fi
        else
            # Get active count before removal
            active_count=$(wc -l < "$active_ips_file" | tr -d ' ')
            
            # End overlap if currently 2+ IPs active
            if [ "$active_count" -ge 2 ] && [ -n "$overlap_start" ]; then
                overlap_end="$timestamp"
                # Get active IPs list
                ips_list=$(tr '\n' ',' < "$active_ips_file" | sed 's/,$//')
                printf "%-3s %-25s | %s\n" "$overlap_num" "$overlap_start → $overlap_end" "$ips_list"
                ((overlap_num++))
                overlap_found=1
            fi
            
            # Remove IP from active list
            grep -v "^$ip$" "$active_ips_file" > "$active_ips_file.tmp" 2>/dev/null && mv "$active_ips_file.tmp" "$active_ips_file"
            
            # Reset overlap_start if less than 2 IPs
            active_count=$(wc -l < "$active_ips_file" | tr -d ' ')
            if [ "$active_count" -lt 2 ]; then
                overlap_start=""
            fi
        fi
    done < "$events_file.sorted"
fi

if [ $overlap_found -eq 0 ]; then
    echo -e "${YELLOW}No overlapping sessions found.${NC}"
fi

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Save files and cleanup
# ---------------------------
echo
echo -e "${GREEN}📄 Session summary saved to: $logfile${NC}"
echo -e "${GREEN}📄 Raw timestamp+IP data saved to: $tmpfile${NC}"

# Cleanup temporary files
rm -f "$location_cache_file" "$sessions_file" "$events_file" "$events_file.sorted" "$active_ips_file" 2>/dev/null
