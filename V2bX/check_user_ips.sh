#!/bin/bash
# ==========================================
# V2bX User Activity Checker (Fixed Version)
# Fixed session grouping and overlap detection
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
# FIXED: Better Session Grouping - Group by IP and continuous usage
# ---------------------------
echo -e "${YELLOW}🔄 Analyzing connection patterns...${NC}"

# First, let's see what raw data we have
echo -e "${YELLOW}Raw connection sample:${NC}"
head -5 "$tmpfile"

# Create a proper session file with unique IP sessions
awk -F'|' '
{
    # Convert timestamp to sortable format
    cmd = "date -d \"" $1 "\" \"+%Y-%m-%d %H:%M:%S\" 2>/dev/null"
    cmd | getline formatted_ts
    close(cmd)
    if (formatted_ts == "") formatted_ts = $1
    
    print formatted_ts "|" $2
}' "$tmpfile" | sort > "/tmp/sorted_connections.txt"

# Now group into sessions (same IP within 10 minutes = same session)
awk -F'|' '
function to_epoch(timestamp) {
    cmd = "date -d \"" timestamp "\" +%s 2>/dev/null"
    cmd | getline epoch
    close(cmd)
    return epoch
}
BEGIN {
    OFS = "|"
}
{
    current_epoch = to_epoch($1)
    ip = $2
    
    if (ip == last_ip && (current_epoch - last_epoch) <= 600) {  # 10 minute window
        # Continue existing session
        session_end[ip] = $1
        connection_count[ip]++
    } else {
        # Save previous session if it exists
        if (last_ip != "") {
            # Only save if session has meaningful duration or multiple connections
            start_epoch = to_epoch(session_start[last_ip])
            end_epoch = to_epoch(session_end[last_ip])
            duration = end_epoch - start_epoch
            
            if (connection_count[last_ip] > 1 || duration >= 300) {  # Multiple connections or ≥5 min
                print connection_count[last_ip], last_ip, session_start[last_ip], session_end[last_ip]
            }
        }
        # Start new session
        session_start[ip] = $1
        session_end[ip] = $1
        connection_count[ip] = 1
        last_ip = ip
    }
    last_epoch = current_epoch
    last_formatted = $1
}
END {
    if (last_ip != "") {
        start_epoch = to_epoch(session_start[last_ip])
        end_epoch = to_epoch(session_end[last_ip])
        duration = end_epoch - start_epoch
        
        if (connection_count[last_ip] > 1 || duration >= 300) {
            print connection_count[last_ip], last_ip, session_start[last_ip], session_end[last_ip]
        }
    }
}' "/tmp/sorted_connections.txt" > "$logfile"

unique_sessions=$(wc -l < "$logfile")

if [ "$unique_sessions" -eq 0 ]; then
  echo -e "${YELLOW}⚠️ No meaningful sessions found for this user.${NC}"
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
# IP Location Function
# ---------------------------
get_ip_location() {
    local ip=$1
    local location=""
    local isp=""
    
    response=$(curl -s -m 3 "http://ip-api.com/json/$ip?fields=status,message,country,regionName,city,isp,org")
    status=$(echo "$response" | jq -r '.status' 2>/dev/null)
    
    if [ "$status" = "success" ]; then
        city=$(echo "$response" | jq -r '.city // empty')
        region=$(echo "$response" | jq -r '.regionName // empty')
        country=$(echo "$response" | jq -r '.country // empty')
        isp=$(echo "$response" | jq -r '.isp // empty')
        
        if [ -n "$city" ] && [ "$city" != "null" ]; then
            location="$city"
            [ -n "$region" ] && [ "$region" != "null" ] && [ "$region" != "$city" ] && location="$location, $region"
        else
            location="$region, $country"
        fi
        
        # Detect ISP
        if [[ "$isp" == *"Mobile"* ]]; then
            isp_type="Mobile"
        elif [[ "$isp" == *"Telecom"* ]]; then
            isp_type="Telecom" 
        elif [[ "$isp" == *"Unicom"* ]]; then
            isp_type="Unicom"
        else
            isp_type="Other"
        fi
        
        echo "$location|$isp_type"
    else
        echo "Unknown|Unknown"
    fi
}

# ---------------------------
# Calculate duration
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
# Pre-fetch IP locations
# ---------------------------
echo -e "${YELLOW}🌍 Fetching IP locations...${NC}"
> "$location_cache_file"

while IFS='|' read -r count ip start_time end_time; do
    if ! grep -q "^$ip|" "$location_cache_file" 2>/dev/null; then
        location_data=$(get_ip_location "$ip")
        echo "$ip|$location_data" >> "$location_cache_file"
        sleep 0.3
    fi
done < "$logfile"

# ---------------------------
# Display User Connection Summary
# ---------------------------
echo
echo -e "${CYAN}==================== User Connection Summary ====================${NC}"
echo
echo -e "${GREEN}✅ Found $unique_sessions sessions ($total_connections total connections)${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-18s | %-25s | %s\n" "#" "IP (Connections)" "Location (ISP)" "Session Time Range"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

sessions_file="/tmp/user_sessions_array.txt"
> "$sessions_file"

num=1
while IFS='|' read -r count ip start_time end_time; do
    cache_entry=$(grep "^$ip|" "$location_cache_file")
    location=$(echo "$cache_entry" | cut -d'|' -f2)
    isp=$(echo "$cache_entry" | cut -d'|' -f3)
    
    start_fmt=$(date -d "$start_time" +"%Y/%m/%d %H:%M" 2>/dev/null || echo "$start_time")
    end_fmt=$(date -d "$end_time" +"%Y/%m/%d %H:%M" 2>/dev/null || echo "$end_time")
    duration=$(calculate_duration "$start_time" "$end_time")
    
    location_isp="$location ($isp)"
    if [ ${#location_isp} -gt 23 ]; then
        location_isp="${location_isp:0:20}..."
    fi
    
    printf "%-3s %-18s | %-25s | %s → %s (%s)\n" \
        "$num" "$ip ($count)" "$location_isp" "$start_fmt" "$end_fmt" "$duration"
    
    echo "$ip|$start_time|$end_time" >> "$sessions_file"
    ((num++))
done < "$logfile"

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# FIXED: Proper Overlap Detection
# ---------------------------
echo
echo -e "${CYAN}==================== Overlapping Sessions ======================${NC}"
echo
echo -e "${YELLOW}📅 Overlapping sessions (IPs active at the same time):${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
printf "%-3s %-25s | %s\n" "#" "Start → End" "IP(s)"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Convert to epoch for accurate comparison
epoch_events_file="/tmp/epoch_events.txt"
> "$epoch_events_file"

while IFS='|' read -r ip start end; do
    start_epoch=$(date -d "$start" +%s 2>/dev/null)
    end_epoch=$(date -d "$end" +%s 2>/dev/null)
    
    if [ -n "$start_epoch" ] && [ -n "$end_epoch" ]; then
        echo "$start_epoch|start|$ip" >> "$epoch_events_file"
        echo "$end_epoch|end|$ip" >> "$epoch_events_file"
    fi
done < "$sessions_file"

# Sort by epoch
sort -n "$epoch_events_file" > "$epoch_events_file.sorted"

# Track overlaps
active_ips=()
overlap_start=""
overlap_num=1
overlap_found=0
max_simultaneous_ips=0

while IFS='|' read -r epoch type ip; do
    if [ "$type" == "start" ]; then
        # Add IP to active list
        active_ips+=("$ip")
        current_count=${#active_ips[@]}
        
        # Track maximum
        [ $current_count -gt $max_simultaneous_ips ] && max_simultaneous_ips=$current_count
        
        # Start overlap if we have multiple IPs
        if [ $current_count -ge 2 ] && [ -z "$overlap_start" ]; then
            overlap_start=$epoch
            overlap_ips=("${active_ips[@]}")
        fi
        
    else
        # End overlap if we were tracking one
        if [ -n "$overlap_start" ] && [ ${#active_ips[@]} -ge 2 ]; then
            overlap_end=$epoch
            
            # Convert back to readable format
            start_readable=$(date -d "@$overlap_start" "+%Y/%m/%d %H:%M" 2>/dev/null)
            end_readable=$(date -d "@$overlap_end" "+%Y/%m/%d %H:%M" 2>/dev/null)
            
            # Get unique IPs
            unique_ips=$(printf '%s\n' "${active_ips[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
            
            printf "%-3s %-25s | %s\n" "$overlap_num" "$start_readable → $end_readable" "$unique_ips"
            ((overlap_num++))
            overlap_found=1
        fi
        
        # Remove IP from active list
        for i in "${!active_ips[@]}"; do
            if [ "${active_ips[i]}" == "$ip" ]; then
                unset 'active_ips[i]'
                break
            fi
        done
        active_ips=("${active_ips[@]}")
        
        # Reset overlap if less than 2 IPs
        if [ ${#active_ips[@]} -lt 2 ]; then
            overlap_start=""
        fi
    fi
done < "$epoch_events_file.sorted"

if [ $overlap_found -eq 0 ]; then
    echo -e "${GREEN}No overlapping sessions found${NC}"
fi

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Enhanced Analysis (Using Correct Data)
# ---------------------------
echo
echo -e "${PURPLE}==================== Enhanced Analysis =====================${NC}"

# Get unique IPs for additional context
unique_ips_count=$(cut -d'|' -f2 "$logfile" | sort -u | wc -l)

echo -e "${YELLOW}📊 Connection Analysis:${NC}"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"
echo -e "Total Connections: $total_connections"
echo -e "Unique IPs: $unique_ips_count" 
echo -e "Sessions: $unique_sessions"
echo -e "Max Simultaneous IPs: $max_simultaneous_ips"
echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# Simple assessment based on actual data
echo
echo -e "${YELLOW}🔍 Assessment:${NC}"

if [ $max_simultaneous_ips -ge 3 ]; then
    echo -e "  ${RED}🚨 POTENTIAL VIOLATION - $max_simultaneous_ips IPs simultaneous${NC}"
elif [ $max_simultaneous_ips -eq 2 ]; then
    echo -e "  ${YELLOW}⚠️  SUSPICIOUS - 2 IPs simultaneous${NC}"
else
    echo -e "  ${GREEN}✅ NORMAL USAGE - Single device patterns${NC}"
fi

echo
echo -e "${YELLOW}💡 Analysis Notes:${NC}"
if [ $overlap_found -eq 0 ]; then
    echo -e "  • No IP overlaps detected"
    echo -e "  • Usage appears to be from single device"
else
    echo -e "  • Found $((overlap_num-1)) overlapping session(s)"
    echo -e "  • Maximum of $max_simultaneous_ips IPs simultaneous"
fi

echo -e "${BLUE}-----------------------------------------------------------------${NC}"

# ---------------------------
# Save files and cleanup
# ---------------------------
echo
echo -e "${GREEN}📄 Session summary saved to: $logfile${NC}"
echo -e "${GREEN}📄 Raw timestamp+IP data saved to: $tmpfile${NC}"

# Cleanup
rm -f "$location_cache_file" "$sessions_file" "$epoch_events_file" "$epoch_events_file.sorted" "/tmp/sorted_connections.txt" 2>/dev/null
