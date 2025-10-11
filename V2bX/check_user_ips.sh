#!/bin/bash
# ==========================================
# V2bX User Activity Checker (Enhanced Violation Detection)
# Removed misleading duration, added smart violation detection
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
# Unique IP counts + first/last timestamps (NO DURATION CALCULATION)
# ---------------------------
sort "$tmpfile" | awk -F'|' '{
  count[$2]++;
  if(!start[$2]) start[$2]=$1;
  end[$2]=$1;
} END {
  for(ip in count)
    printf "%d|%s|%s|%s\n", count[ip], ip, start[ip], end[ip]
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
# Calculate duration between two timestamps for overlaps only
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
echo -e "${CYAN}==================== User Connection Summary ====================${NC}"
echo
echo -e "${GREEN}✅ Found $unique_ips unique IPs ($total_connections total connections)${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-18s | %-30s | %s\n" "#" "IP (Connections)" "Location (ISP)" "Time Range"
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
    
    printf "%-3s %-18s | %-30s | %s → %s\n" \
        "$num" "$ip ($count)" "$location_isp" "$start_fmt" "$end_fmt"
    
    # Store enhanced session data
    echo "$ip|$subnet|$city|$region|$isp|$start_time|$end_time" >> "$sessions_file"
    ((num++))
done < "$logfile"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Enhanced Overlap Detection with Violation Scoring
# ---------------------------
echo
echo -e "${CYAN}==================== Enhanced Overlap Analysis ====================${NC}"
echo

# Initialize violation scoring
violation_score=0
max_simultaneous_ips=0
different_cities=0
different_regions=0
different_isps=0
long_overlaps=0
overlap_details=()

# Convert sessions to events
events_file="/tmp/events.txt"
> "$events_file"

while IFS='|' read -r ip subnet city region isp start end; do
    echo "$start|start|$ip|$subnet|$city|$region|$isp" >> "$events_file"
    echo "$end|end|$ip|$subnet|$city|$region|$isp" >> "$events_file"
done < "$sessions_file"

# Sort events by timestamp
sort "$events_file" > "$events_file.sorted" 2>/dev/null

# Process events for enhanced analysis
active_ips_file="/tmp/active_ips.txt"
active_subnets_file="/tmp/active_subnets.txt"
active_cities_file="/tmp/active_cities.txt"
active_regions_file="/tmp/active_regions.txt"
active_isps_file="/tmp/active_isps.txt"
> "$active_ips_file"
> "$active_subnets_file"
> "$active_cities_file"
> "$active_regions_file"
> "$active_isps_file"

overlap_start=""
overlap_num=1

if [ -s "$events_file.sorted" ]; then
    while IFS='|' read -r timestamp type ip subnet city region isp; do
        if [ "$type" == "start" ]; then
            # Add to all active lists
            echo "$ip" >> "$active_ips_file"
            echo "$subnet" >> "$active_subnets_file"
            [ -n "$city" ] && echo "$city" >> "$active_cities_file"
            [ -n "$region" ] && echo "$region" >> "$active_regions_file"
            [ -n "$isp" ] && echo "$isp" >> "$active_isps_file"
            
            # Calculate current diversity
            current_ips=$(sort -u "$active_ips_file" | wc -l | tr -d ' ')
            current_subnets=$(sort -u "$active_subnets_file" | wc -l | tr -d ' ')
            current_cities=$(sort -u "$active_cities_file" | wc -l | tr -d ' ')
            current_regions=$(sort -u "$active_regions_file" | wc -l | tr -d ' ')
            current_isps=$(sort -u "$active_isps_file" | wc -l | tr -d ' ')
            
            # Track maximum simultaneous IPs
            [ $current_ips -gt $max_simultaneous_ips ] && max_simultaneous_ips=$current_ips
            
            # Start overlap tracking when we have multiple IPs
            if [ $current_ips -ge 2 ] && [ -z "$overlap_start" ]; then
                overlap_start="$timestamp"
                overlap_data="$current_ips|$current_subnets|$current_cities|$current_regions|$current_isps"
            fi
            
        else
            # End overlap if we were tracking one
            if [ -n "$overlap_start" ]; then
                overlap_end="$timestamp"
                overlap_duration=$(calculate_duration "$overlap_start" "$overlap_end")
                
                # Parse overlap data
                current_ips=$(echo "$overlap_data" | cut -d'|' -f1)
                current_subnets=$(echo "$overlap_data" | cut -d'|' -f2)
                current_cities=$(echo "$overlap_data" | cut -d'|' -f3)
                current_regions=$(echo "$overlap_data" | cut -d'|' -f4)
                current_isps=$(echo "$overlap_data" | cut -d'|' -f5)
                
                # Store overlap details for scoring
                overlap_details+=("$current_ips|$current_subnets|$current_cities|$current_regions|$current_isps|$overlap_duration")
                
                # Update maximum diversity counts
                [ $current_cities -gt $different_cities ] && different_cities=$current_cities
                [ $current_regions -gt $different_regions ] && different_regions=$current_regions
                [ $current_isps -gt $different_isps ] && different_isps=$current_isps
                
                # Check for long overlaps (>30 minutes)
                overlap_seconds=$(echo "$overlap_duration" | awk -F: '{print ($1 * 3600) + ($2 * 60) + $3}')
                [ $overlap_seconds -gt 1800 ] && long_overlaps=$((long_overlaps + 1))
                
                overlap_start=""
            fi
            
            # Remove from active lists
            grep -v "^$ip$" "$active_ips_file" > "$active_ips_file.tmp" && mv "$active_ips_file.tmp" "$active_ips_file"
            grep -v "^$subnet$" "$active_subnets_file" > "$active_subnets_file.tmp" && mv "$active_subnets_file.tmp" "$active_subnets_file"
            [ -n "$city" ] && grep -v "^$city$" "$active_cities_file" > "$active_cities_file.tmp" && mv "$active_cities_file.tmp" "$active_cities_file"
            [ -n "$region" ] && grep -v "^$region$" "$active_regions_file" > "$active_regions_file.tmp" && mv "$active_regions_file.tmp" "$active_regions_file"
            [ -n "$isp" ] && grep -v "^$isp$" "$active_isps_file" > "$active_isps_file.tmp" && mv "$active_isps_file.tmp" "$active_isps_file"
        fi
    done < "$events_file.sorted"
fi

# ---------------------------
# Calculate Violation Score
# ---------------------------
echo -e "${YELLOW}📊 Violation Scoring Analysis:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# 1. Concurrent IP Count (40 points max)
if [ $max_simultaneous_ips -ge 4 ]; then
    ip_score=40
    echo -e "🔴 Max Simultaneous IPs: $max_simultaneous_ips (+40 points)"
elif [ $max_simultaneous_ips -eq 3 ]; then
    ip_score=20
    echo -e "🟡 Max Simultaneous IPs: $max_simultaneous_ips (+20 points)"
else
    ip_score=0
    echo -e "🟢 Max Simultaneous IPs: $max_simultaneous_ips (+0 points)"
fi
violation_score=$((violation_score + ip_score))

# 2. Geographic Diversity (30 points max)
if [ $different_cities -ge 3 ]; then
    geo_score=30
    echo -e "🔴 Different Cities: $different_cities (+30 points)"
elif [ $different_cities -eq 2 ]; then
    geo_score=15
    echo -e "🟡 Different Cities: $different_cities (+15 points)"
else
    geo_score=0
    echo -e "🟢 Different Cities: $different_cities (+0 points)"
fi
violation_score=$((violation_score + geo_score))

# 3. Network Diversity (20 points max)
if [ $different_isps -ge 2 ]; then
    net_score=20
    echo -e "🔴 Different ISPs: $different_isps (+20 points)"
else
    net_score=0
    echo -e "🟢 Different ISPs: $different_isps (+0 points)"
fi
violation_score=$((violation_score + net_score))

# 4. Overlap Duration (10 points max)
if [ $long_overlaps -ge 2 ]; then
    time_score=10
    echo -e "🔴 Long Overlaps (>30min): $long_overlaps (+10 points)"
elif [ $long_overlaps -eq 1 ]; then
    time_score=5
    echo -e "🟡 Long Overlaps (>30min): $long_overlaps (+5 points)"
else
    time_score=0
    echo -e "🟢 Long Overlaps (>30min): $long_overlaps (+0 points)"
fi
violation_score=$((violation_score + time_score))

echo -e "${BLUE}-----------------------------------------------------------------${NC}"
echo -e "${PURPLE}Total Violation Score: $violation_score/100${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Display Critical Overlaps
# ---------------------------
echo
echo -e "${YELLOW}🚨 Critical Overlap Sessions:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-20s | %-10s | %s\n" "#" "Time Range" "Duration" "IPs & Networks"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

critical_count=0
for overlap in "${overlap_details[@]}"; do
    ips=$(echo "$overlap" | cut -d'|' -f1)
    subnets=$(echo "$overlap" | cut -d'|' -f2)
    cities=$(echo "$overlap" | cut -d'|' -f3)
    isps=$(echo "$overlap" | cut -d'|' -f5)
    duration=$(echo "$overlap" | cut -d'|' -f6)
    
    # Only show overlaps with high violation potential
    if [ $ips -ge 3 ] || [ $cities -ge 2 ] || [ $isps -ge 2 ]; then
        ((critical_count++))
        printf "%-3s %-20s | %-10s | %d IPs, %d cities, %d ISPs\n" \
            "$critical_count" "Overlap" "$duration" "$ips" "$cities" "$isps"
    fi
done

if [ $critical_count -eq 0 ]; then
    echo -e "${YELLOW}No critical overlaps detected${NC}"
fi

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Final Violation Assessment
# ---------------------------
echo
echo -e "${PURPLE}==================== FINAL ASSESSMENT =====================${NC}"
echo

if [ $violation_score -ge 70 ]; then
    echo -e "🔴 ${RED}🚨 HIGH CONFIDENCE VIOLATION DETECTED${NC}"
    echo -e "   - Multiple strong indicators of multi-device usage"
    echo -e "   - Very likely exceeding 3-device limit"
elif [ $violation_score -ge 40 ]; then
    echo -e "🟡 ${YELLOW}⚠️  SUSPICIOUS ACTIVITY DETECTED${NC}"
    echo -e "   - Several indicators suggest potential violation"
    echo -e "   - Monitor user for further evidence"
elif [ $violation_score -ge 20 ]; then
    echo -e "🟡 ${YELLOW}📋 INCONCLUSIVE - NEEDS MONITORING${NC}"
    echo -e "   - Some minor indicators detected"
    echo -e "   - Could be normal carrier IP rotation"
else
    echo -e "🟢 ${GREEN}✅ LIKELY NORMAL USAGE${NC}"
    echo -e "   - No strong evidence of multi-device usage"
    echo -e "   - Patterns consistent with single device + carrier rotation"
fi

echo
echo -e "${YELLOW}📋 Key Evidence:${NC}"
echo -e "   • Max simultaneous IPs: $max_simultaneous_ips"
echo -e "   • Different cities active: $different_cities"
echo -e "   • Different ISPs used: $different_isps"
echo -e "   • Long overlaps: $long_overlaps"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Save files and cleanup
# ---------------------------
echo
echo -e "${GREEN}📄 Session summary saved to: $logfile${NC}"
echo -e "${GREEN}📄 Raw timestamp+IP data saved to: $tmpfile${NC}"

# Cleanup temporary files
rm -f "$location_cache_file" "$sessions_file" "$events_file" "$events_file.sorted" \
      "$active_ips_file" "$active_subnets_file" "$active_cities_file" \
      "$active_regions_file" "$active_isps_file" 2>/dev/null
