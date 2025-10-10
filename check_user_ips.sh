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
echo -e " 1) Last 1 hour"
echo -e " 2) Last 1 day" 
echo -e " 3) Last 1 week"
echo -e " 4) All logs"
read -p "Enter option [1-4]: " option

case "$option" in
  1) period="1 hour ago" ;;
  2) period="1 day ago" ;;
  3) period="1 week ago" ;;
  4) period="" ;;
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
      hours = int(total_seconds / 3600);
      minutes = int((total_seconds % 3600) / 60);
      seconds = int(total_seconds % 60);
      duration = sprintf("%02d:%02d:%02d", hours, minutes, seconds);
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
# Calculate duration between two timestamps
# ---------------------------
calculate_duration() {
    local start="$1"
    local end="$2"
    
    start_epoch=$(date -d "$start" +%s 2>/dev/null)
    end_epoch=$(date -d "$end" +%s 2>/dev/null)
    
    if [ -n "$start_epoch" ] && [ -n "$end_epoch" ] && [ "$end_epoch" -gt "$start_epoch" ]; then
        total_seconds=$((end_epoch - start_epoch))
        hours=$((total_seconds / 3600))
        minutes=$(( (total_seconds % 3600) / 60 ))
        seconds=$((total_seconds % 60))
        printf "%02d:%02d:%02d" $hours $minutes $seconds
    else
        echo "00:00:00"
    fi
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
printf "%-3s %-18s | %-25s | %s\n" "#" "IP (Connections)" "Location" "Time Range (Usage)"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Create sessions array file
sessions_file="/tmp/user_sessions_array.txt"
> "$sessions_file"

num=1
while IFS='|' read -r count ip start_time end_time duration; do
    # Get location and subnet from cache
    cache_entry=$(grep "^$ip|" "$location_cache_file")
    location=$(echo "$cache_entry" | cut -d'|' -f2)
    
    # Format timestamps
    start_fmt=$(date -d "$start_time" +"%m/%d %H:%M" 2>/dev/null || echo "$start_time")
    end_fmt=$(date -d "$end_time" +"%m/%d %H:%M" 2>/dev/null || echo "$end_time")
    
    # Truncate long location strings
    if [ ${#location} -gt 22 ]; then
        location="${location:0:19}..."
    fi
    
    printf "%-3s %-18s | %-25s | %s → %s (%s)\n" \
        "$num" "$ip ($count)" "$location" "$start_fmt" "$end_fmt" "$duration"
    
    # Store session data with subnet
    echo "$ip|$start_time|$end_time|$duration" >> "$sessions_file"
    ((num++))
done < "$logfile"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Overlapping Sessions Analysis
# ---------------------------
echo
echo -e "${CYAN}==================== Overlapping Sessions ======================${NC}"
echo
echo -e "${YELLOW}📅 Sessions with overlapping time periods:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-35s | %s\n" "#" "Time Range (Usage)" "IPs"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Convert sessions to events
events_file="/tmp/events.txt"
> "$events_file"

while IFS='|' read -r ip start end duration; do
    echo "$start|start|$ip" >> "$events_file"
    echo "$end|end|$ip" >> "$events_file"
done < "$sessions_file"

# Sort events by timestamp
sort "$events_file" > "$events_file.sorted" 2>/dev/null

active_ips_file="/tmp/active_ips.txt"
> "$active_ips_file"

overlap_start=""
overlap_ips=()
overlap_num=1
overlap_found=0

if [ -s "$events_file.sorted" ]; then
    while IFS='|' read -r timestamp type ip; do
        if [ "$type" == "start" ]; then
            # Add IP to active list
            echo "$ip" >> "$active_ips_file"
            active_ips=($(sort -u "$active_ips_file"))
            
            # Start overlap if 2+ IPs active
            if [ ${#active_ips[@]} -ge 2 ] && [ -z "$overlap_start" ]; then
                overlap_start="$timestamp"
                overlap_ips=("${active_ips[@]}")
            fi
        else
            # Get active IPs before removal
            active_ips=($(sort -u "$active_ips_file"))
            
            # End overlap if currently 2+ IPs active
            if [ ${#active_ips[@]} -ge 2 ] && [ -n "$overlap_start" ]; then
                overlap_end="$timestamp"
                
                # Calculate overlap duration
                overlap_duration=$(calculate_duration "$overlap_start" "$overlap_end")
                
                # Format timestamps
                start_fmt=$(date -d "$overlap_start" +"%m/%d %H:%M" 2>/dev/null)
                end_fmt=$(date -d "$overlap_end" +"%m/%d %H:%M" 2>/dev/null)
                
                # Get IP list
                ips_list=$(printf "%s," "${active_ips[@]}" | sed 's/,$//')
                
                printf "%-3s %-35s | %s\n" "$overlap_num" "$start_fmt → $end_fmt ($overlap_duration)" "$ips_list"
                ((overlap_num++))
                overlap_found=1
            fi
            
            # Remove IP from active list
            grep -v "^$ip$" "$active_ips_file" > "$active_ips_file.tmp" && mv "$active_ips_file.tmp" "$active_ips_file"
            
            # Reset overlap if less than 2 IPs
            active_ips=($(sort -u "$active_ips_file"))
            if [ ${#active_ips[@]} -lt 2 ]; then
                overlap_start=""
                overlap_ips=()
            fi
        fi
    done < "$events_file.sorted"
fi

if [ $overlap_found -eq 0 ]; then
    echo -e "${YELLOW}No overlapping sessions found.${NC}"
    echo -e "${BLUE}-----------------------------------------------------------------${NC}"
fi

# ---------------------------
# Violation Analysis Conclusion
# ---------------------------
echo
echo -e "${PURPLE}==================== Violation Analysis ======================${NC}"
echo

# Analyze based on selected period
echo -e "${YELLOW}📊 Analysis for selected period: ${NC}$([ -n "$period" ] && echo "$period" || echo "All logs")"

# Count unique subnets for context
unique_subnets=$(cut -d'|' -f3 "$location_cache_file" | sort -u | wc -l | tr -d ' ')
total_overlaps=$((overlap_num - 1))

echo -e "${BLUE}-----------------------------------------------------------------${NC}"
echo -e "Unique IPs: $unique_ips"
echo -e "Unique IP Subnets: $unique_subnets"
echo -e "Overlapping Sessions: $total_overlaps"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Violation assessment based on period
echo
echo -e "${YELLOW}🔍 Violation Assessment:${NC}"

if [ $overlap_found -eq 0 ]; then
    echo -e "  ${GREEN}✅ NO EVIDENCE of multi-device usage${NC}"
    echo -e "  - No overlapping sessions detected in selected period"
else
    # Different assessment based on period
    case "$option" in
        1) # Last 1 hour
            if [ $total_overlaps -ge 2 ]; then
                echo -e "  ${RED}🚨 HIGH PROBABILITY OF VIOLATION${NC}"
                echo -e "  - Multiple overlaps in 1 hour suggests active multi-device usage"
            else
                echo -e "  ${YELLOW}⚠️  SUSPICIOUS ACTIVITY DETECTED${NC}"
                echo -e "  - Overlapping sessions found in 1 hour period"
            fi
            ;;
        2) # Last 1 day
            if [ $total_overlaps -ge 3 ]; then
                echo -e "  ${RED}🚨 HIGH PROBABILITY OF VIOLATION${NC}"
                echo -e "  - Multiple overlaps throughout the day"
            elif [ $total_overlaps -ge 1 ]; then
                echo -e "  ${YELLOW}⚠️  POTENTIAL VIOLATION${NC}"
                echo -e "  - Some overlapping sessions detected"
            else
                echo -e "  ${GREEN}✅ NO EVIDENCE of multi-device usage${NC}"
            fi
            ;;
        3) # Last 1 week
            if [ $total_overlaps -ge 5 ]; then
                echo -e "  ${RED}🚨 CLEAR VIOLATION PATTERN${NC}"
                echo -e "  - Consistent overlapping sessions throughout week"
            elif [ $total_overlaps -ge 2 ]; then
                echo -e "  ${YELLOW}⚠️  SUSPICIOUS PATTERN${NC}"
                echo -e "  - Multiple overlapping sessions detected"
            else
                echo -e "  ${GREEN}✅ MINOR OVERLAPS - likely normal usage${NC}"
            fi
            ;;
        4) # All logs
            if [ $total_overlaps -ge 10 ]; then
                echo -e "  ${RED}🚨 CLEAR AND REPEATED VIOLATIONS${NC}"
                echo -e "  - Extensive overlapping session history"
            elif [ $total_overlaps -ge 5 ]; then
                echo -e "  ${YELLOW}⚠️  FREQUENT VIOLATIONS DETECTED${NC}"
                echo -e "  - Regular pattern of overlapping sessions"
            elif [ $total_overlaps -ge 1 ]; then
                echo -e "  ${YELLOW}⚠️  OCCASIONAL OVERLAPS DETECTED${NC}"
                echo -e "  - Some overlapping sessions in history"
            else
                echo -e "  ${GREEN}✅ CLEAN USAGE HISTORY${NC}"
            fi
            ;;
    esac
    
    echo
    echo -e "${YELLOW}📋 Evidence Summary:${NC}"
    echo -e "  - Found $total_overlaps overlapping session(s)"
    echo -e "  - Check 'Overlapping Sessions' section above for details"
    echo -e "  - Each overlap shows simultaneous connections from different IPs"
fi

echo
echo -e "${YELLOW}💡 Interpretation Guide:${NC}"
echo -e "  - Overlapping sessions = Multiple IPs active at same time"
echo -e "  - Different IPs active simultaneously = Likely different devices"
echo -e "  - 3+ different IPs overlapping = Clear violation of 3-device limit"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Save files and cleanup
# ---------------------------
echo
echo -e "${GREEN}📄 Session summary saved to: $logfile${NC}"
echo -e "${GREEN}📄 Raw timestamp+IP data saved to: $tmpfile${NC}"

# Cleanup temporary files
rm -f "$location_cache_file" "$sessions_file" "$events_file" "$events_file.sorted" "$active_ips_file" 2>/dev/null
