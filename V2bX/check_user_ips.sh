#!/bin/bash
# ==========================================
# V2bX User Activity Checker (Enhanced Violation Detection)
# Improved detection and violation scoring with detailed overlap analysis
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
# Unique IP counts + first/last timestamps with duration filtering
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

# Filter out sessions with less than 5 minutes duration
filtered_logfile="/tmp/user_sessions_filtered.txt"
> "$filtered_logfile"

sort "$tmpfile" | awk -F'|' '{
  count[$2]++;
  if(!start[$2]) start[$2]=$1;
  end[$2]=$1;
} END {
  for(ip in count) {
    printf "%d|%s|%s|%s\n", count[ip], ip, start[ip], end[ip]
  }
}' | while IFS='|' read -r count ip start_time end_time; do
    duration=$(calculate_duration "$start_time" "$end_time")
    duration_seconds=$(echo "$duration" | awk -F: '{print ($1 * 3600) + ($2 * 60) + $3}')
    # Only include sessions with duration >= 5 minutes (300 seconds)
    if [ "$duration_seconds" -ge 300 ]; then
        echo "$count|$ip|$start_time|$end_time" >> "$filtered_logfile"
    fi
done

# Use filtered data for display
cp "$filtered_logfile" "$logfile"
unique_ips=$(wc -l < "$logfile")

if [ "$unique_ips" -eq 0 ]; then
  echo -e "${YELLOW}⚠️ No significant activity found (all sessions < 5 minutes).${NC}"
  exit 0
fi

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
# Enhanced IP Location Function with ISP Detection
# ---------------------------
get_ip_location() {
    local ip=$1
    local location=""
    local isp=""
    
    response=$(curl -s -m 2 "http://ip-api.com/json/$ip?fields=status,message,country,regionName,city,isp,org,as")
    status=$(echo "$response" | jq -r '.status' 2>/dev/null)
    
    if [ "$status" = "success" ]; then
        city=$(echo "$response" | jq -r '.city // empty')
        region=$(echo "$response" | jq -r '.regionName // empty')
        country=$(echo "$response" | jq -r '.country // empty')
        isp=$(echo "$response" | jq -r '.isp // empty')
        org=$(echo "$response" | jq -r '.org // empty')
        
        # Build location string
        if [ -n "$city" ] && [ "$city" != "null" ]; then
            location="$city"
            [ -n "$region" ] && [ "$region" != "null" ] && [ "$region" != "$city" ] && location="$location, $region"
        else
            location="$region, $country"
        fi
        
        # Detect ISP type
        if [[ "$isp" == *"Mobile"* ]] || [[ "$org" == *"Mobile"* ]]; then
            isp_type="Mobile"
        elif [[ "$isp" == *"Telecom"* ]] || [[ "$org" == *"Telecom"* ]]; then
            isp_type="Telecom"
        elif [[ "$isp" == *"Unicom"* ]] || [[ "$org" == *"Unicom"* ]]; then
            isp_type="Unicom"
        else
            isp_type="Other"
        fi
        
        echo "$location|$isp_type|$city|$region"
    else
        echo "Unknown|Unknown||"
    fi
}

# ---------------------------
# Get IP subnet (first 3 octets)
# ---------------------------
get_ip_subnet() {
    local ip=$1
    echo "$ip" | cut -d. -f1-3
}

# ---------------------------
# Pre-fetch all IP locations with enhanced data
# ---------------------------
echo -e "${YELLOW}🌍 Fetching IP locations and network data...${NC}"
> "$location_cache_file"

while IFS='|' read -r count ip start_time end_time; do
    if ! grep -q "^$ip|" "$location_cache_file" 2>/dev/null; then
        location_data=$(get_ip_location "$ip")
        subnet=$(get_ip_subnet "$ip")
        echo "$ip|$location_data|$subnet" >> "$location_cache_file"
        sleep 0.2
    fi
done < "$logfile"

# ---------------------------
# Display Main IP Table (No Duration Column)
# ---------------------------
echo
echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}==================== User Connection Summary ====================${NC}"
echo -e "${CYAN}=================================================================${NC}"
echo
echo -e "${GREEN}✅ Found $unique_ips unique IPs ($total_connections total connections)${NC}"
echo -e "${YELLOW}📝 Note: Showing only sessions ≥ 5 minutes duration${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-25s | %-30s | %s\n" "#" "IP (Connections)" "Location (ISP)" "Time Range"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Create sessions array file
sessions_file="/tmp/user_sessions_array.txt"
> "$sessions_file"

num=1
while IFS='|' read -r count ip start_time end_time; do
    # Get enhanced location data from cache
    cache_entry=$(grep "^$ip|" "$location_cache_file")
    location=$(echo "$cache_entry" | cut -d'|' -f2)
    isp=$(echo "$cache_entry" | cut -d'|' -f3)
    city=$(echo "$cache_entry" | cut -d'|' -f4)
    region=$(echo "$cache_entry" | cut -d'|' -f5)
    subnet=$(echo "$cache_entry" | cut -d'|' -f6)
    
    # Format timestamps
    start_fmt=$(date -d "$start_time" +"%m/%d %H:%M" 2>/dev/null || echo "$start_time")
    end_fmt=$(date -d "$end_time" +"%m/%d %H:%M" 2>/dev/null || echo "$end_time")
    
    # Build location string with ISP
    location_isp="$location ($isp)"
    if [ ${#location_isp} -gt 28 ]; then
        location_isp="${location_isp:0:25}..."
    fi
    
    printf "%-3s %-25s | %-30s | %s → %s\n" \
        "$num" "$ip ($count)" "$location_isp" "$start_fmt" "$end_fmt"
    
    # Store enhanced session data
    echo "$ip|$subnet|$city|$region|$isp|$start_time|$end_time" >> "$sessions_file"
    ((num++))
done < "$logfile"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Enhanced Overlap Detection with Improved Algorithm
# ---------------------------
echo
echo -e "${CYAN}===================================================================${NC}"
echo -e "${CYAN}==================== Enhanced Overlap Analysis ====================${NC}"
echo -e "${CYAN}===================================================================${NC}"
echo

# Convert sessions to events for timeline analysis
events_file="/tmp/events.txt"
> "$events_file"

while IFS='|' read -r ip subnet city region isp start end; do
    start_epoch=$(date -d "$start" +%s 2>/dev/null)
    end_epoch=$(date -d "$end" +%s 2>/dev/null)
    if [ -n "$start_epoch" ] && [ -n "$end_epoch" ]; then
        echo "$start_epoch|start|$ip|$subnet|$city|$region|$isp" >> "$events_file"
        echo "$end_epoch|end|$ip|$subnet|$city|$region|$isp" >> "$events_file"
    fi
done < "$sessions_file"

# Sort events by timestamp
sort -n "$events_file" > "$events_file.sorted" 2>/dev/null

# ---------------------------
# Improved Overlap Detection Algorithm
# ---------------------------
active_ips=()
overlap_segments=()
current_overlap_start=""
current_active_ips=()

while IFS='|' read -r timestamp type ip subnet city region isp; do
    if [ "$type" == "start" ]; then
        # Add IP to active list
        active_ips+=("$ip")
        
        # If we have 2 or more IPs active and no overlap tracking, start new overlap
        if [ ${#active_ips[@]} -ge 2 ] && [ -z "$current_overlap_start" ]; then
            current_overlap_start=$timestamp
            current_active_ips=("${active_ips[@]}")
        fi
        
        # Update current active IPs if we're already tracking an overlap
        if [ -n "$current_overlap_start" ]; then
            current_active_ips=("${active_ips[@]}")
        fi
        
    else # type == "end"
        # Remove IP from active list
        for i in "${!active_ips[@]}"; do
            if [ "${active_ips[i]}" == "$ip" ]; then
                unset 'active_ips[i]'
                break
            fi
        done
        active_ips=("${active_ips[@]}") # Reindex array
        
        # End current overlap if we drop below 2 IPs
        if [ -n "$current_overlap_start" ] && [ ${#active_ips[@]} -lt 2 ]; then
            overlap_segments+=("$current_overlap_start|$timestamp|${current_active_ips[*]}")
            current_overlap_start=""
            current_active_ips=()
        fi
    fi
done < "$events_file.sorted"

# ---------------------------
# Detailed Overlap Sessions Display
# ---------------------------
echo
echo -e "${YELLOW}📊 Detailed Overlap Sessions:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-25s | %s\n" "#" "Start → End" "IP(s)"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

overlap_count=0
declare -a overlap_details_array=()

for segment in "${overlap_segments[@]}"; do
    start_epoch=$(echo "$segment" | cut -d'|' -f1)
    end_epoch=$(echo "$segment" | cut -d'|' -f2)
    ips_string=$(echo "$segment" | cut -d'|' -f3)
    
    # Convert timestamps back to readable format
    start_readable=$(date -d "@$start_epoch" +"%Y/%m/%d %H:%M" 2>/dev/null)
    end_readable=$(date -d "@$end_epoch" +"%Y/%m/%d %H:%M" 2>/dev/null)
    
    # Calculate duration
    duration_seconds=$((end_epoch - start_epoch))
    duration=$(printf "%02d:%02d:%02d" $((duration_seconds/3600)) $(((duration_seconds%3600)/60)) $((duration_seconds%60)))
    
    # Only show overlaps with duration >= 1 minute
    if [ $duration_seconds -ge 60 ]; then
        ((overlap_count++))
        
        # Convert IP string to array and get unique count
        IFS=' ' read -ra ips_array <<< "$ips_string"
        unique_ips_count=$(printf "%s\n" "${ips_array[@]}" | sort -u | wc -l)
        
        # Format IPs for display (comma separated)
        ips_display=$(echo "$ips_string" | tr ' ' ',')
        
        printf "%-3s %-25s | %s\n" \
            "$overlap_count" "$start_readable → $end_readable" "$ips_display"
        
        # Store for violation scoring
        overlap_details_array+=("$unique_ips_count|$duration_seconds|$ips_string")
    fi
done

if [ $overlap_count -eq 0 ]; then
    echo -e "${YELLOW}No significant overlap sessions detected${NC}"
fi

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Enhanced Violation Scoring System
# ---------------------------
echo
echo -e "${YELLOW}🚨 Enhanced Violation Scoring Analysis:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Initialize scoring variables
violation_score=0
max_concurrent_ips=0
total_overlap_time=0
high_risk_overlaps=0
moderate_risk_overlaps=0

# Analyze each overlap segment
for overlap in "${overlap_details_array[@]}"; do
    ip_count=$(echo "$overlap" | cut -d'|' -f1)
    duration_seconds=$(echo "$overlap" | cut -d'|' -f2)
    ips_string=$(echo "$overlap" | cut -d'|' -f3)
    
    # Track maximum concurrent IPs
    [ $ip_count -gt $max_concurrent_ips ] && max_concurrent_ips=$ip_count
    
    # Track total overlap time
    total_overlap_time=$((total_overlap_time + duration_seconds))
    
    # Categorize risk level
    if [ $ip_count -ge 3 ] && [ $duration_seconds -ge 1800 ]; then
        ((high_risk_overlaps++))
    elif [ $ip_count -ge 2 ] && [ $duration_seconds -ge 600 ]; then
        ((moderate_risk_overlaps++))
    fi
done

# ---------------------------
# Improved Scoring Algorithm
# ---------------------------

# 1. Concurrent IP Count Score (35 points max)
if [ $max_concurrent_ips -ge 4 ]; then
    ip_score=35
    echo -e "${RED}🔴 Max Concurrent IPs: $max_concurrent_ips (+35 points)"
elif [ $max_concurrent_ips -eq 3 ]; then
    ip_score=20
    echo -e "${YELLOW}🟡 Max Concurrent IPs: $max_concurrent_ips (+20 points)"
elif [ $max_concurrent_ips -eq 2 ]; then
    ip_score=10
    echo -e "${GREEN}🟢 Max Concurrent IPs: $max_concurrent_ips (+10 points)"
else
    ip_score=0
    echo -e "${GREEN}🟢 Max Concurrent IPs: $max_concurrent_ips (+0 points)"
fi
violation_score=$((violation_score + ip_score))

# 2. High Risk Overlap Score (30 points max)
if [ $high_risk_overlaps -ge 3 ]; then
    high_risk_score=30
    echo -e "${RED}🔴 High Risk Overlaps: $high_risk_overlaps (+30 points)"
elif [ $high_risk_overlaps -eq 2 ]; then
    high_risk_score=20
    echo -e "${YELLOW}🟡 High Risk Overlaps: $high_risk_overlaps (+20 points)"
elif [ $high_risk_overlaps -eq 1 ]; then
    high_risk_score=10
    echo -e "${YELLOW}🟡 High Risk Overlaps: $high_risk_overlaps (+10 points)"
else
    high_risk_score=0
    echo -e "${GREEN}🟢 High Risk Overlaps: $high_risk_overlaps (+0 points)"
fi
violation_score=$((violation_score + high_risk_score))

# 3. Moderate Risk Overlap Score (20 points max)
if [ $moderate_risk_overlaps -ge 3 ]; then
    moderate_risk_score=20
    echo -e "${RED}🔴 Moderate Risk Overlaps: $moderate_risk_overlaps (+20 points)"
elif [ $moderate_risk_overlaps -ge 2 ]; then
    moderate_risk_score=15
    echo -e "${YELLOW}🟡 Moderate Risk Overlaps: $moderate_risk_overlaps (+15 points)"
elif [ $moderate_risk_overlaps -eq 1 ]; then
    moderate_risk_score=5
    echo -e "${GREEN}🟢 Moderate Risk Overlaps: $moderate_risk_overlaps (+5 points)"
else
    moderate_risk_score=0
    echo -e "${GREEN}🟢 Moderate Risk Overlaps: $moderate_risk_overlaps (+0 points)"
fi
violation_score=$((violation_score + moderate_risk_score))

# 4. Total Overlap Time Score (15 points max)
overlap_hours=$(echo "scale=2; $total_overlap_time / 3600" | bc)
if (( $(echo "$overlap_hours > 2.0" | bc -l) )); then
    time_score=15
    echo -e "${RED}🔴 Total Overlap Time: ${overlap_hours}h (+15 points)"
elif (( $(echo "$overlap_hours > 1.0" | bc -l) )); then
    time_score=10
    echo -e "${YELLOW}🟡 Total Overlap Time: ${overlap_hours}h (+10 points)"
elif (( $(echo "$overlap_hours > 0.5" | bc -l) )); then
    time_score=5
    echo -e "${GREEN}🟢 Total Overlap Time: ${overlap_hours}h (+5 points)"
else
    time_score=0
    echo -e "${GREEN}🟢 Total Overlap Time: ${overlap_hours}h (+0 points)"
fi
violation_score=$((violation_score + time_score))

echo -e "${BLUE}-----------------------------------------------------------------${NC}"
echo -e "${PURPLE}Total Violation Score: $violation_score/100${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Final Assessment with Improved Criteria
# ---------------------------
echo
echo -e "${CYAN}===========================================================${NC}"
echo -e "${CYAN}==================== FINAL ASSESSMENT =====================${NC}"
echo -e "${CYAN}===========================================================${NC}"
echo

if [ $violation_score -ge 75 ]; then
    echo -e "${RED}🔴 🚨 HIGH CONFIDENCE VIOLATION DETECTED${NC}"
    echo -e "   - Strong evidence of multi-device usage exceeding limits"
    echo -e "   - Multiple high-risk overlap patterns detected"
    echo -e "   - Immediate investigation recommended"
elif [ $violation_score -ge 50 ]; then
    echo -e "${YELLOW}🟡 ⚠️  SUSPICIOUS ACTIVITY DETECTED${NC}"
    echo -e "   - Moderate evidence of potential policy violation"
    echo -e "   - Several concerning overlap patterns observed"
    echo -e "   - Close monitoring advised"
elif [ $violation_score -ge 25 ]; then
    echo -e "${YELLOW}🟡 📋 INCONCLUSIVE - NEEDS MONITORING${NC}"
    echo -e "   - Some minor overlap patterns detected"
    echo -e "   - Could be normal network behavior"
    echo -e "   - Continue monitoring for patterns"
else
    echo -e "${GREEN}🟢 ✅ LIKELY NORMAL USAGE${NC}"
    echo -e "   - No significant evidence of policy violation"
    echo -e "   - Patterns consistent with single device usage"
    echo -e "   - Normal carrier IP rotation detected"
fi

echo
echo -e "${YELLOW}📋 Key Evidence Summary:${NC}"
echo -e "   • Max concurrent IPs: $max_concurrent_ips"
echo -e "   • High risk overlaps: $high_risk_overlaps"
echo -e "   • Moderate risk overlaps: $moderate_risk_overlaps"
echo -e "   • Total overlap time: ${overlap_hours}h"
echo -e "   • Detailed overlap sessions: $overlap_count"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Save files and cleanup
# ---------------------------
echo
echo -e "${GREEN}📄 Session summary saved to: $logfile${NC}"
echo -e "${GREEN}📄 Raw timestamp+IP data saved to: $tmpfile${NC}"

# Cleanup temporary files
rm -f "$location_cache_file" "$sessions_file" "$events_file" "$events_file.sorted" \
      "$filtered_logfile" 2>/dev/null
