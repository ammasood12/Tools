#!/bin/bash
# =============================================================
# V2bX User IP & Device Analyzer (Journald-based)
# Version: v5.0.3
# Purpose: Detect how many IPs/devices a single UUID uses,
#          analyze sessions & overlaps, and score violations.
# =============================================================

VERSION="v5.0.4"
SERVICE_NAME="V2bX"
JOURNAL_UNIT="-u ${SERVICE_NAME}"

# ---------------------------
# Colors & Symbols
# ---------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

CHECK_MARK="${GREEN}✓${NC}"
CROSS_MARK="${RED}✗${NC}"

# ---------------------------
# Temp files
# ---------------------------
TMP_EVENTS="/tmp/v2bx_user_events.txt"       # ts|epoch|ip|raw
TMP_SESSIONS="/tmp/v2bx_user_sessions.txt"   # ip|first_ts|last_ts|first_epoch|last_epoch|count
TMP_OVERLAPS="/tmp/v2bx_user_overlaps.txt"   # start_epoch|end_epoch|ip_list
TMP_RAW="/tmp/v2bx_user_raw.txt"
IP_DETAILS_FILE="/root/v2bx_ip_details.json"  # Persistent IP details cache

declare -A IP_LOCATION_CACHE

# ============================================================
# Utility Functions
# ============================================================

print_header() {
  clear
  echo
  echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════╗${NC}"
  echo -e "${PURPLE}${BOLD}║     V2bX User IP & Device Analyzer ${VERSION}     ║${NC}"
  echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════╝${NC}"
  echo
}

check_and_install() {
  local package="$1"
  if ! command -v "$package" &>/dev/null; then
    echo -e "${YELLOW}Installing dependency: ${package}${NC}"
    apt update -y >/dev/null 2>&1
    apt install -y "$package" >/dev/null 2>&1
    if command -v "$package" &>/dev/null; then
      echo -e "  ${CHECK_MARK} ${package} installed"
    else
      echo -e "  ${CROSS_MARK} Failed to install ${package}, script may not work correctly."
    fi
  else
    echo -e "  ${CHECK_MARK} ${package} already installed"
  fi
}

ensure_dependencies() {
  echo -e "${CYAN}📦 Checking dependencies...${NC}"
  check_and_install curl
  check_and_install jq
  check_and_install gawk
  echo
}

human_time() {
  # seconds -> HH:MM:SS
  local total="$1"
  local h=$((total / 3600))
  local m=$(((total % 3600) / 60))
  local s=$((total % 60))
  printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

human_date() {
  local epoch="$1"
  date -d "@${epoch}" +"%Y-%m-%d %H:%M:%S"
}

fmt_ts() {
    local iso="$1"
    date -d "$iso" +"%Y-%m-%d %H:%M:%S"
}

pause() {
  echo
  read -rp "Press Enter to continue..." _
}

# ============================================================
# IP Details Cache Management
# ============================================================


# ============================================================
# SIMPLE IP Details Management
# ============================================================

validate_and_repair_cache() {
    if [[ -f "$IP_DETAILS_FILE" ]]; then
        echo -e "${CYAN}🔧 Validating cache file...${NC}"
        if ! jq -e . "$IP_DETAILS_FILE" >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠️  Cache file is corrupted, creating new one${NC}"
            echo "{}" > "$IP_DETAILS_FILE"
        fi
    else
        echo "{}" > "$IP_DETAILS_FILE"
    fi
    chmod 600 "$IP_DETAILS_FILE"
}

get_ip_details_simple() {
    local ip="$1"
    
    # First check memory cache
    if [[ -n "${IP_LOCATION_CACHE[$ip]}" ]]; then
        echo "${IP_LOCATION_CACHE[$ip]}"
        return
    fi
    
    # Try to read from file cache
    if [[ -f "$IP_DETAILS_FILE" ]]; then
        local cached_data
        cached_data=$(jq -r ".[\"$ip\"] // empty" "$IP_DETAILS_FILE" 2>/dev/null || true)
        
        if [[ -n "$cached_data" ]] && [[ "$cached_data" != "null" ]]; then
            # Check if cache is stale (older than 7 days)
            local fetched_date
            fetched_date=$(echo "$cached_data" | jq -r '.fetched_date // empty' 2>/dev/null || true)
            
            if [[ -n "$fetched_date" ]]; then
                local fetched_epoch current_epoch diff_days
                fetched_epoch=$(date -d "$fetched_date" +%s 2>/dev/null || true)
                current_epoch=$(date +%s)
                
                if [[ -n "$fetched_epoch" ]]; then
                    diff_days=$(( (current_epoch - fetched_epoch) / 86400 ))
                    
                    if [[ "$diff_days" -le 7 ]]; then
                        # Cache is fresh
                        IP_LOCATION_CACHE["$ip"]="$cached_data"
                        echo "$cached_data"
                        return
                    fi
                fi
            fi
        fi
    fi
    
    # Fetch new data
    echo -e "  ${CYAN}Fetching IP details for: $ip${NC}"
    local fetched_date
    fetched_date=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Try ip-api.com
    local response result_json
    response=$(curl -s -m 5 "http://ip-api.com/json/$ip?fields=status,country,countryCode,region,regionName,city,zip,lat,lon,timezone,isp,org,as,asname,reverse,proxy,hosting,query" 2>/dev/null || true)
    
    if [[ -n "$response" ]] && echo "$response" | jq -e '.status == "success"' >/dev/null 2>&1; then
        result_json=$(echo "$response" | jq --arg fetched "$fetched_date" '{
            ip: .query,
            country: .country,
            country_code: .countryCode,
            region: .regionName,
            city: .city,
            zip: .zip,
            lat: .lat,
            lon: .lon,
            timezone: .timezone,
            isp: .isp,
            org: .org,
            as: .as,
            asname: .asname,
            reverse: .reverse,
            proxy: .proxy,
            hosting: .hosting,
            fetched_date: $fetched,
            source: "ip-api.com"
        }')
    else
        # Fallback to minimal data
        result_json=$(jq -n --arg ip "$ip" --arg fetched "$fetched_date" '{
            ip: $ip,
            country: "Unknown",
            country_code: "XX",
            region: "Unknown",
            city: "Unknown",
            isp: "Unknown",
            org: "Unknown",
            fetched_date: $fetched,
            source: "unknown"
        }')
    fi
    
    # Save to cache
    if [[ -n "$result_json" ]]; then
        # Update memory cache
        IP_LOCATION_CACHE["$ip"]="$result_json"
        
        # Update file cache
        if [[ -f "$IP_DETAILS_FILE" ]]; then
            local temp_file
            temp_file=$(mktemp)
            jq --arg ip "$ip" --argjson data "$result_json" '.[$ip] = $data' "$IP_DETAILS_FILE" > "$temp_file" 2>/dev/null && mv "$temp_file" "$IP_DETAILS_FILE"
            rm -f "$temp_file" 2>/dev/null || true
        fi
        
        echo "$result_json"
    fi
}

# ============================================================
# Display Functions (SIMPLE VERSION)
# ============================================================


show_ip_details_table() {
  echo
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}                                   Detailed IP Information                                          ${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
  
  printf "%-18s %-12s %-15s %-15s %-25s %-15s\n" "IP Address" "Country" "Region" "City" "ISP" "Last Updated"
  echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"

  # Get unique IPs from sessions
  local ips=()
  while IFS="|" read -r ip _ _ _ _ _; do
    ips+=("$ip")
  done < "$TMP_SESSIONS"

  # Remove duplicates
  ips=($(printf "%s\n" "${ips[@]}" | sort -u))

  for ip in "${ips[@]}"; do
    # echo -e "${YELLOW}DEBUG: Processing IP: $ip${NC}" >&2
    
    local details
    details=$(get_ip_details_simple "$ip" 2>/dev/null || true)
    
    # Initialize defaults
    local country="Unknown"
    local region="Unknown"
    local city="Unknown"
    local isp="Unknown"
    local fetched_date="Unknown"
    
    # Try to parse JSON
    if [[ -n "$details" ]]; then
        # echo -e "${YELLOW}DEBUG: Got details, length: ${#details}${NC}" >&2
        # echo -e "${YELLOW}DEBUG: Details: $details${NC}" >&2
        
        # Use jq to parse
        country=$(echo "$details" | jq -r '.country // "Unknown"' 2>/dev/null || echo "Unknown")
        region=$(echo "$details" | jq -r '.region // "Unknown"' 2>/dev/null || echo "Unknown")
        city=$(echo "$details" | jq -r '.city // "Unknown"' 2>/dev/null || echo "Unknown")
        isp=$(echo "$details" | jq -r '.isp // "Unknown"' 2>/dev/null || echo "Unknown")
        fetched_date=$(echo "$details" | jq -r '.fetched_date // "Unknown"' 2>/dev/null || echo "Unknown")
        
        # echo -e "${YELLOW}DEBUG: Parsed - Country: $country, Region: $region, City: $city${NC}" >&2
    else
        echo -e "${YELLOW}DEBUG: No details returned${NC}" >&2
    fi
    
    # Clean up values
    [[ "$country" == "null" ]] && country="Unknown"
    [[ "$region" == "null" ]] && region="Unknown"
    [[ "$city" == "null" ]] && city="Unknown"
    [[ "$isp" == "null" ]] && isp="Unknown"
    [[ "$fetched_date" == "null" ]] && fetched_date="Unknown"
    
    # Shorten for display
    country=$(echo "$country" | cut -c1-12)
    region=$(echo "$region" | cut -c1-15)
    city=$(echo "$city" | cut -c1-15)
    isp=$(echo "$isp" | cut -c1-25)
    fetched_date=$(echo "$fetched_date" | cut -c1-15)
    
    printf "%-18s %-12s %-15s %-15s %-25s %-15s\n" \
      "$ip" "$country" "$region" "$city" "$isp" "$fetched_date"
  done
  
  echo
  echo -e "${YELLOW}ℹ️  IP details cached in: ${IP_DETAILS_FILE}${NC}"
  echo -e "${YELLOW}ℹ️  Cache expires after 7 days, updates automatically when stale${NC}"
}

format_location_short_simple() {
    local details="$1"
    
    if [[ -z "$details" ]]; then
        echo "Unknown"
        return
    fi
    
    # Use jq to extract values
    local country_code city isp carrier short_city short_location
    
    country_code=$(echo "$details" | jq -r '.country_code // "XX"' 2>/dev/null || echo "XX")
    city=$(echo "$details" | jq -r '.city // ""' 2>/dev/null || echo "")
    isp=$(echo "$details" | jq -r '.isp // ""' 2>/dev/null || echo "")
    
    # Default if empty
    [[ -z "$country_code" ]] && country_code="XX"
    [[ -z "$city" ]] && city=""
    [[ -z "$isp" ]] && isp=""
    
    # Shorten city name
    if [[ -n "$city" ]] && [[ "$city" != "Unknown" ]] && [[ "$city" != "null" ]]; then
        short_city=$(echo "$city" | cut -d' ' -f1 | cut -c1-8 | sed 's/[^a-zA-Z]//g')
    else
        short_city=""
    fi
    
    # Determine carrier type
    carrier=""
    if [[ "$isp" =~ [Mm]obile ]]; then 
        carrier="M"
    elif [[ "$isp" =~ [Tt]elecom ]]; then 
        carrier="T"
    elif [[ "$isp" =~ [Uu]nicom ]]; then 
        carrier="U"
    elif [[ -n "$isp" ]]; then 
        carrier="I"
    fi
    
    # Build short location string
    if [[ -n "$short_city" ]]; then
        short_location="${country_code}-${short_city}"
        [[ -n "$carrier" ]] && short_location="${short_location}(${carrier})"
    elif [[ "$country_code" != "XX" ]]; then
        short_location="${country_code}"
        [[ -n "$carrier" ]] && short_location="${short_location}(${carrier})"
    else
        short_location="Unknown"
    fi
    
    echo "$short_location"
}






validate_and_repair_cache_1() {
    if [[ -f "$IP_DETAILS_FILE" ]]; then
        # Check if file is valid JSON
        if ! jq -e . "$IP_DETAILS_FILE" >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠️  Cache file is corrupted, repairing...${NC}"
            # Try to fix by extracting valid entries
            local temp_file
            temp_file=$(mktemp)
            echo "{}" > "$temp_file"
            
            # Try to salvage any valid entries
            if grep -o '"\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}":{[^}]*}' "$IP_DETAILS_FILE" 2>/dev/null | head -20 | while read -r entry; do
                ip=$(echo "$entry" | grep -o '"\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}"' | tr -d '"')
                json=$(echo "$entry" | sed 's/^[^{]*{/{/' | sed 's/}[^}]*$/}/')
                if echo "$json" | jq -e . >/dev/null 2>&1; then
                    jq --arg ip "$ip" --argjson data "$json" '.[$ip] = $data' "$temp_file" > "${temp_file}.tmp" && mv "${temp_file}.tmp" "$temp_file"
                fi
            done; then
                if jq -e . "$temp_file" >/dev/null 2>&1 && [[ $(jq 'length' "$temp_file") -gt 0 ]]; then
                    mv "$temp_file" "$IP_DETAILS_FILE"
                    echo -e "${GREEN}✅ Cache file repaired (salvaged some entries)${NC}"
                else
                    echo "{}" > "$IP_DETAILS_FILE"
                    echo -e "${GREEN}✅ Cache file reset to empty${NC}"
                    rm -f "$temp_file"
                fi
            else
                echo "{}" > "$IP_DETAILS_FILE"
                echo -e "${GREEN}✅ Cache file reset to empty${NC}"
            fi
        else
            echo -e "${GREEN}✅ Cache file is valid${NC}"
        fi
    else
        echo "{}" > "$IP_DETAILS_FILE"
        chmod 600 "$IP_DETAILS_FILE"
        echo -e "${GREEN}✅ Created new cache file${NC}"
    fi
}

init_ip_details_file() {
    if [[ ! -f "$IP_DETAILS_FILE" ]]; then
        echo "{}" > "$IP_DETAILS_FILE"
        chmod 600 "$IP_DETAILS_FILE"
    fi
}

safe_get_ip_details_from_cache() {
    local ip="$1"
    
    if [[ ! -f "$IP_DETAILS_FILE" ]]; then
        return 1
    fi
    
    # Get the IP data directly with error suppression
    local cache_content
    cache_content=$(jq -r ".[\"$ip\"] // empty" "$IP_DETAILS_FILE" 2>/dev/null || true)
    
    if [[ -n "$cache_content" ]] && [[ "$cache_content" != "null" ]] && [[ "$cache_content" != "{}" ]]; then
        # Quick validation
        if [[ "$cache_content" == {* ]] && [[ "$cache_content" == *} ]]; then
            echo "$cache_content"
            return 0
        fi
    fi
    
    return 1
}

update_ip_details_cache() {
    local ip="$1"
    local data="$2"
    
    if [[ ! -f "$IP_DETAILS_FILE" ]]; then
        echo "{}" > "$IP_DETAILS_FILE"
    fi
    
    # Simple approach: read entire file, update in memory, write back
    local temp_file
    temp_file=$(mktemp)
    
    # If file is empty or invalid, start with empty object
    if ! jq -e . "$IP_DETAILS_FILE" >/dev/null 2>&1; then
        echo "{}" > "$temp_file"
    else
        cp "$IP_DETAILS_FILE" "$temp_file"
    fi
    
    # Update the entry
    if jq --arg ip "$ip" --argjson data "$data" '.[$ip] = $data' "$temp_file" > "${temp_file}.new" 2>/dev/null; then
        if jq -e . "${temp_file}.new" >/dev/null 2>&1; then
            mv "${temp_file}.new" "$IP_DETAILS_FILE"
            chmod 600 "$IP_DETAILS_FILE"
        else
            echo "{}" > "$IP_DETAILS_FILE"
            jq -n --arg ip "$ip" --argjson data "$data" '.[$ip] = $data' > "$IP_DETAILS_FILE"
        fi
    else
        # Fallback: create new file with just this entry
        jq -n --arg ip "$ip" --argjson data "$data" '.[$ip] = $data' > "$IP_DETAILS_FILE"
    fi
    
    rm -f "$temp_file" "${temp_file}.new" 2>/dev/null || true
}

is_cache_stale() {
    local ip="$1"
    local cache_age_days=7
    local cache_entry
    
    # Get from cache
    if ! cache_entry=$(safe_get_ip_details_from_cache "$ip"); then
        return 0  # Stale (doesn't exist)
    fi
    
    # Extract fetched_date safely
    local fetched_date
    fetched_date=$(echo "$cache_entry" | grep -o '"fetched_date":"[^"]*"' | cut -d'"' -f4 2>/dev/null || true)
    
    if [[ -z "$fetched_date" ]]; then
        return 0  # Stale (no date)
    fi
    
    # Convert date to epoch
    local fetched_epoch
    fetched_epoch=$(date -d "$fetched_date" +%s 2>/dev/null || true)
    
    if [[ -z "$fetched_epoch" ]]; then
        return 0  # Stale (invalid date)
    fi
    
    local current_epoch
    current_epoch=$(date +%s)
    local diff_days=$(( (current_epoch - fetched_epoch) / 86400 ))
    
    if [[ "$diff_days" -gt "$cache_age_days" ]]; then
        return 0  # Stale
    else
        return 1  # Fresh
    fi
}

# ============================================================
# IP Information Fetching
# ============================================================

fetch_ip_details() {
    local ip="$1"
    local response
    local result_json
    local fetched_date
    
    echo -e "  ${CYAN}Fetching details for IP: $ip${NC}"
    
    fetched_date=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Try ip-api.com first
    response=$(curl -s -m 5 "http://ip-api.com/json/$ip?fields=status,country,countryCode,region,regionName,city,zip,lat,lon,timezone,isp,org,as,asname,reverse,proxy,hosting,query" 2>/dev/null || true)
    
    if [[ -n "$response" ]]; then
        if echo "$response" | jq -e '.status == "success"' >/dev/null 2>&1; then
            result_json=$(echo "$response" | jq --arg fetched "$fetched_date" '{
                ip: .query,
                country: .country,
                country_code: .countryCode,
                region: .regionName,
                city: .city,
                zip: .zip,
                lat: .lat,
                lon: .lon,
                timezone: .timezone,
                isp: .isp,
                org: .org,
                as: .as,
                asname: .asname,
                reverse: .reverse,
                proxy: .proxy,
                hosting: .hosting,
                fetched_date: $fetched,
                source: "ip-api.com"
            }' 2>/dev/null || true)
            
            if [[ -n "$result_json" ]]; then
                update_ip_details_cache "$ip" "$result_json"
                echo "$result_json"
                return 0
            fi
        fi
    fi
    
    # Fallback to ipapi.co
    response=$(curl -s -m 5 "https://ipapi.co/$ip/json/" 2>/dev/null || true)
    
    if [[ -n "$response" ]]; then
        if echo "$response" | jq -e '.error != true' >/dev/null 2>&1; then
            result_json=$(echo "$response" | jq --arg fetched "$fetched_date" '{
                ip: .ip,
                country: .country_name,
                country_code: .country_code,
                region: .region,
                city: .city,
                zip: .postal,
                lat: .latitude,
                lon: .longitude,
                timezone: .timezone,
                isp: .org,
                org: .org,
                as: .asn,
                asname: .asn,
                reverse: .reverse,
                proxy: .in_eu,
                hosting: false,
                fetched_date: $fetched,
                source: "ipapi.co"
            }' 2>/dev/null || true)
            
            if [[ -n "$result_json" ]]; then
                update_ip_details_cache "$ip" "$result_json"
                echo "$result_json"
                return 0
            fi
        fi
    fi
    
    # Minimal info if both fail
    result_json=$(jq -n --arg ip "$ip" --arg fetched "$fetched_date" '{
        ip: $ip,
        country: "Unknown",
        country_code: "XX",
        region: "Unknown",
        city: "Unknown",
        isp: "Unknown",
        org: "Unknown",
        fetched_date: $fetched,
        source: "unknown"
    }' 2>/dev/null || true)
    
    if [[ -n "$result_json" ]]; then
        update_ip_details_cache "$ip" "$result_json"
        echo "$result_json"
    fi
    
    return 1
}

get_ip_details() {
    local ip="$1"
    local cached_data
    
    # Check memory cache first
    if [[ -n "${IP_LOCATION_CACHE[$ip]:-}" ]]; then
        echo "${IP_LOCATION_CACHE[$ip]}"
        return
    fi
    
    # Check file cache if not stale
    if ! is_cache_stale "$ip"; then
        if cached_data=$(safe_get_ip_details_from_cache "$ip"); then
            IP_LOCATION_CACHE["$ip"]="$cached_data"
            echo "$cached_data"
            return
        fi
    fi
    
    # Fetch fresh data
    cached_data=$(fetch_ip_details "$ip")
    if [[ -n "$cached_data" ]]; then
        IP_LOCATION_CACHE["$ip"]="$cached_data"
        echo "$cached_data"
    else
        # Return minimal valid JSON
        jq -n --arg ip "$ip" --arg fetched "$(date +"%Y-%m-%d %H:%M:%S")" '{
            ip: $ip,
            country: "Unknown",
            country_code: "XX",
            region: "Unknown",
            city: "Unknown",
            isp: "Unknown",
            fetched_date: $fetched,
            source: "error"
        }' 2>/dev/null || echo '{"ip":"'$ip'","country":"Unknown","country_code":"XX","region":"Unknown","city":"Unknown","isp":"Unknown","fetched_date":"'$(date +"%Y-%m-%d %H:%M:%S")'","source":"error"}'
    fi
}

format_location_short() {
    local details="$1"
    local country_code city isp carrier short_city short_location
    
    # Extract values using jq if available
    if command -v jq >/dev/null 2>&1; then
        country_code=$(echo "$details" | jq -r '.country_code // "XX"' 2>/dev/null || echo "XX")
        city=$(echo "$details" | jq -r '.city // ""' 2>/dev/null || echo "")
        isp=$(echo "$details" | jq -r '.isp // ""' 2>/dev/null || echo "")
    else
        # Fallback to grep
        country_code=$(echo "$details" | grep -o '"country_code":[[:space:]]*"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "XX")
        city=$(echo "$details" | grep -o '"city":[[:space:]]*"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
        isp=$(echo "$details" | grep -o '"isp":[[:space:]]*"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
    fi
    
    # Default if empty
    [[ -z "$country_code" ]] && country_code="XX"
    [[ -z "$city" ]] && city=""
    [[ -z "$isp" ]] && isp=""
    
    # Shorten city name
    if [[ -n "$city" ]] && [[ "$city" != "Unknown" ]] && [[ "$city" != "null" ]]; then
        short_city=$(echo "$city" | cut -d' ' -f1 | cut -c1-8 | sed 's/[^a-zA-Z]//g')
    else
        short_city=""
    fi
    
    # Determine carrier type
    carrier=""
    if [[ "$isp" =~ [Mm]obile ]]; then 
        carrier="M"
    elif [[ "$isp" =~ [Tt]elecom ]]; then 
        carrier="T"
    elif [[ "$isp" =~ [Uu]nicom ]]; then 
        carrier="U"
    elif [[ -n "$isp" ]]; then 
        carrier="I"
    fi
    
    # Build short location string
    if [[ -n "$short_city" ]]; then
        short_location="${country_code}-${short_city}"
        [[ -n "$carrier" ]] && short_location="${short_location}(${carrier})"
    elif [[ "$country_code" != "XX" ]]; then
        short_location="${country_code}"
        [[ -n "$carrier" ]] && short_location="${short_location}(${carrier})"
    else
        short_location="Unknown"
    fi
    
    echo "$short_location"
}

# ============================================================
# Input & Period Selection
# ============================================================

select_period() {
  echo -e "${CYAN}Select log period to scan:${NC}"
  echo -e "  1) Last 1 hour"
  echo -e "  2) Last 1 day"
  echo -e "  3) Last 1 week"
  echo -e "  4) All logs"
  echo
  read -rp "Enter option [1-4]: " option

  case "$option" in
    1) PERIOD="1 hour ago" ;;
    2) PERIOD="1 day ago" ;;
    3) PERIOD="1 week ago" ;;
    4) PERIOD="" ;;
    *) echo -e "${RED}Invalid option, defaulting to last 1 day.${NC}"; PERIOD="1 day ago" ;;
  esac
}

prompt_uuid() {
  echo
  read -rp "Enter user UUID: " UUID
  if [[ -z "$UUID" ]]; then
    echo -e "${RED}UUID cannot be empty. Exiting.${NC}"
    exit 1
  fi
}

# ============================================================
# Log Loading & Parsing
# ============================================================

load_raw_logs() {
  echo -e "${CYAN}🔍 Extracting logs for UUID: ${UUID}${NC}"
  : > "$TMP_RAW"

  if [[ -n "$PERIOD" ]]; then
    journalctl ${JOURNAL_UNIT} --since "$PERIOD" -o cat | grep -F "$UUID" > "$TMP_RAW"
  else
    journalctl ${JOURNAL_UNIT} -o cat | grep -F "$UUID" > "$TMP_RAW"
  fi

  local lines
  lines=$(wc -l < "$TMP_RAW")
  if [[ "$lines" -eq 0 ]]; then
    echo -e "${YELLOW}⚠️ No log entries found for this UUID in the selected period.${NC}"
    exit 0
  fi

  echo -e "${GREEN}✅ Found ${lines} matching log lines for this UUID.${NC}"
}

parse_events() {
  echo -e "${CYAN}🧩 Parsing log lines into events (timestamp + IP)...${NC}"
  : > "$TMP_EVENTS"

  # Always use short-iso because it ALWAYS includes valid timestamps
  if [[ -n "$PERIOD" ]]; then
      journalctl ${JOURNAL_UNIT} --since "$PERIOD" -o short-iso | grep -F "$UUID" > "$TMP_RAW"
  else
      journalctl ${JOURNAL_UNIT} -o short-iso | grep -F "$UUID" > "$TMP_RAW"
  fi

  gawk -v uuid="$UUID" '
  {
      # Journald timestamp (ALWAYS exists)
      # Format: 2025-12-11T14:30:26+00:00
      ts = $1

      # Validate timestamp
      if (ts !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) {
          next
      }

      # Convert to epoch
      cmd = "date -d \"" ts "\" +%s"
      cmd | getline epoch
      close(cmd)

      if (epoch == "" || epoch == 0) next

      # Reconstruct the message (skip first 3 systemd metadata fields)
      msg=""
      for (i=4; i<=NF; i++) msg = msg $i " "

      # Extract IP from "from <IP>:port"
      match(msg, /from (tcp:)?(\[[0-9A-Fa-f:.]+\]|[0-9.]+):[0-9]+/, m)
      ip = m[2]
      gsub(/\[|\]/, "", ip)

      if (ip == "") next

      print ts "|" epoch "|" ip "|" msg
  }' "$TMP_RAW" > "$TMP_EVENTS"

  local count
  count=$(wc -l < "$TMP_EVENTS")

  if [[ "$count" -eq 0 ]]; then
      echo -e "${YELLOW}⚠️ Parsed 0 events. Timestamp extraction failed or logs malformed.${NC}"
      exit 0
  fi

  echo -e "${GREEN}✅ Parsed ${count} events for this UUID.${NC}"
}


build_sessions() {
  echo -e "${CYAN}🧮 Building per-IP sessions (first seen / last seen / count)...${NC}"
  : > "$TMP_SESSIONS"

  sort -t"|" -k3,3 -k2,2n "$TMP_EVENTS" | gawk -F"|" '
  {
    ts      = $1
    epoch   = $2 + 0
    ip      = $3

    if (!(ip in first_ts)) {
      first_ts[ip]    = ts
      first_epoch[ip] = epoch
    }
    last_ts[ip]    = ts
    last_epoch[ip] = epoch
    count[ip]++
  }
  END {
    for (ip in count) {
      printf "%s|%s|%s|%d|%d|%d\n",
             ip, first_ts[ip], last_ts[ip],
             first_epoch[ip], last_epoch[ip], count[ip]
    }
  }' > "$TMP_SESSIONS"

  local ips
  ips=$(wc -l < "$TMP_SESSIONS")
  echo -e "${GREEN}✅ Aggregated sessions for ${ips} unique IP(s).${NC}"
}

# ============================================================
# Overlap Detection & Scoring
# ============================================================

detect_overlaps() {
  echo -e "${CYAN}🔁 Detecting overlapping IP sessions (multi-device usage)...${NC}"
  : > "$TMP_OVERLAPS"

  # Sort by start time (first_epoch)
  sort -t"|" -k4,4n "$TMP_SESSIONS" | gawk -F"|" '
  {
    ip        = $1
    first_ts  = $2
    last_ts   = $3
    start_ep  = $4 + 0
    end_ep    = $5 + 0
    cnt       = $6 + 0

    idx = NR
    ip_arr[idx]       = ip
    start[idx]        = start_ep
    stop[idx]         = end_ep
    first_ts_arr[idx] = first_ts
    last_ts_arr[idx]  = last_ts
    count_arr[idx]    = cnt
    n = idx
  }
  END {
    # Compare each pair; record overlapping time windows
    for (i = 1; i <= n; i++) {
      for (j = i + 1; j <= n; j++) {
        # Overlap if intervals intersect
        if (start[i] <= stop[j] && start[j] <= stop[i]) {
          overlap_start = (start[i] > start[j] ? start[i] : start[j])
          overlap_end   = (stop[i]  < stop[j]  ? stop[i]  : stop[j])
          if (overlap_end > overlap_start) {
            printf "%d|%d|%s,%s\n", overlap_start, overlap_end, ip_arr[i], ip_arr[j]
          }
        }
      }
    }
  }' > "$TMP_OVERLAPS"

  local overlaps
  overlaps=$(wc -l < "$TMP_OVERLAPS")
  if [[ "$overlaps" -eq 0 ]]; then
    echo -e "${YELLOW}ℹ️  No overlapping IP sessions detected for this UUID.${NC}"
  else
    echo -e "${GREEN}✅ Detected ${overlaps} overlapping session window(s).${NC}"
  fi
}

score_violation() {
  echo
  echo -e "${CYAN}📊 Calculating violation score...${NC}"

  local ip_count overlap_count max_parallel_score overlap_score total_score
  local max_ips total_overlap_seconds

  ip_count=$(wc -l < "$TMP_SESSIONS")
  overlap_count=$(wc -l < "$TMP_OVERLAPS")

  # Max concurrent IPs (approx = unique IPs if overlaps exist)
  if [[ "$ip_count" -ge 4 ]]; then
    max_ips=4
  else
    max_ips="$ip_count"
  fi

  # Score for number of IPs
  if   [[ "$max_ips" -ge 4 ]]; then max_parallel_score=35
  elif [[ "$max_ips" -eq 3 ]]; then max_parallel_score=20
  elif [[ "$max_ips" -eq 2 ]]; then max_parallel_score=10
  else                             max_parallel_score=0
  fi

  # Total overlap time in seconds
  total_overlap_seconds=0
  if [[ -s "$TMP_OVERLAPS" ]]; then
    total_overlap_seconds=$(gawk -F"|" '{ total += ($2 - $1); } END { print total+0 }' "$TMP_OVERLAPS")
  fi

  local overlap_hours
  overlap_hours=$(printf "%.2f" "$(echo "$total_overlap_seconds / 3600" | bc -l 2>/dev/null)")

  # Score based on overlap duration
  if (( $(echo "$overlap_hours > 2.0" | bc -l 2>/dev/null) )); then
    overlap_score=25
  elif (( $(echo "$overlap_hours > 1.0" | bc -l 2>/dev/null) )); then
    overlap_score=15
  elif (( $(echo "$overlap_hours > 0.3" | bc -l 2>/dev/null) )); then
    overlap_score=5
  else
    overlap_score=0
  fi

  total_score=$((max_parallel_score + overlap_score))

  echo -e "  • Unique IPs: ${BLUE}${ip_count}${NC}"
  echo -e "  • Overlap windows: ${BLUE}${overlap_count}${NC}"
  echo -e "  • Total overlap time: ${BLUE}${overlap_hours}h (${total_overlap_seconds}s)${NC}"
  echo -e "  • IP-count score: ${YELLOW}${max_parallel_score}/35${NC}"
  echo -e "  • Overlap-time score: ${YELLOW}${overlap_score}/25${NC}"
  echo -e "  • ${BOLD}Total Violation Score: ${PURPLE}${total_score}/60${NC}"
  echo

  echo -e "${CYAN}Final Assessment:${NC}"
  if   [[ "$total_score" -ge 45 ]]; then
    echo -e "${RED}  🔴 HIGH CONFIDENCE: Strong multi-device sharing${NC}"
  elif [[ "$total_score" -ge 25 ]]; then
    echo -e "${YELLOW}  🟡 SUSPICIOUS: Possible sharing / family usage${NC}"
  elif [[ "$total_score" -ge 10 ]]; then
    echo -e "${GREEN}  🟢 LOW RISK: Some IP change, likely normal (mobile / CGNAT)${NC}"
  else
    echo -e "${GREEN}  🟢 NORMAL: Single-device or mild roaming${NC}"
  fi
}

# ============================================================
# Display Functions
# ============================================================

show_ip_details_table_1() {
  echo
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}                                   Detailed IP Information                                          ${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
  
  printf "%-18s %-12s %-15s %-15s %-25s %-15s\n" "IP Address" "Country" "Region" "City" "ISP" "Last Updated"
  echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"

  # Get unique IPs from sessions
  local ips=()
  while IFS="|" read -r ip _ _ _ _ _; do
    ips+=("$ip")
  done < "$TMP_SESSIONS"

  # Remove duplicates
  ips=($(printf "%s\n" "${ips[@]}" | sort -u))

  for ip in "${ips[@]}"; do
    local details
    details=$(get_ip_details "$ip" 2>/dev/null || true)
    
    # Initialize defaults
    local country="Unknown"
    local region="Unknown"
    local city="Unknown"
    local isp="Unknown"
    local fetched_date="Unknown"
    
    # Try to parse JSON using jq if available
    if [[ -n "$details" ]]; then
        # First try jq (more reliable for JSON)
        if command -v jq >/dev/null 2>&1; then
            country=$(echo "$details" | jq -r '.country // "Unknown"' 2>/dev/null || echo "Unknown")
            region=$(echo "$details" | jq -r '.region // "Unknown"' 2>/dev/null || echo "Unknown")
            city=$(echo "$details" | jq -r '.city // "Unknown"' 2>/dev/null || echo "Unknown")
            isp=$(echo "$details" | jq -r '.isp // "Unknown"' 2>/dev/null || echo "Unknown")
            fetched_date=$(echo "$details" | jq -r '.fetched_date // "Unknown"' 2>/dev/null || echo "Unknown")
        else
            # Fallback to grep patterns (updated to match actual JSON)
            country=$(echo "$details" | grep -o '"country":[[:space:]]*"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "Unknown")
            region=$(echo "$details" | grep -o '"region":[[:space:]]*"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "Unknown")
            city=$(echo "$details" | grep -o '"city":[[:space:]]*"[^"]*"' | cut-d'"' -f4 2>/dev/null || echo "Unknown")
            isp=$(echo "$details" | grep -o '"isp":[[:space:]]*"[^"]*"' | cut-d'"' -f4 2>/dev/null || echo "Unknown")
            fetched_date=$(echo "$details" | grep -o '"fetched_date":[[:space:]]*"[^"]*"' | cut-d'"' -f4 2>/dev/null || echo "Unknown")
        fi
    fi
    
    # Clean up values
    [[ "$country" == "null" ]] && country="Unknown"
    [[ "$region" == "null" ]] && region="Unknown"
    [[ "$city" == "null" ]] && city="Unknown"
    [[ "$isp" == "null" ]] && isp="Unknown"
    [[ "$fetched_date" == "null" ]] && fetched_date="Unknown"
    
    # Shorten for display
    country=$(echo "$country" | cut -c1-12)
    region=$(echo "$region" | cut -c1-15)
    city=$(echo "$city" | cut -c1-15)
    isp=$(echo "$isp" | cut -c1-25)
    fetched_date=$(echo "$fetched_date" | cut -c1-15)
    
    printf "%-18s %-12s %-15s %-15s %-25s %-15s\n" \
      "$ip" "$country" "$region" "$city" "$isp" "$fetched_date"
  done
  
  echo
  echo -e "${YELLOW}ℹ️  IP details cached in: ${IP_DETAILS_FILE}${NC}"
  echo -e "${YELLOW}ℹ️  Cache expires after 7 days, updates automatically when stale${NC}"
}

show_session_table_1() {
  echo
  echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}                     User IP Session Summary (${PERIOD})${NC}"
  echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
  
  printf "%-3s %-18s %-25s %-20s %-20s %-8s %-10s\n" "#" "IP" "Location" "First Seen" "Last Seen" "Count" "Duration"
  echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────────────${NC}"

  local i=0
  sort -t"|" -k4,4n "$TMP_SESSIONS" | while IFS="|" read -r ip first_ts last_ts first_ep last_ep cnt; do
    i=$((i+1))
    local dur=$((last_ep - first_ep))
    
    # Get location from cache or fetch
    local details
    details=$(get_ip_details "$ip" 2>/dev/null || true)
    loc=$(format_location_short "$details")
    
    printf "%-3s %-18s %-25s %-20s %-20s %-8s %-10s\n" \
      "$i" "$ip" "$loc" "$(fmt_ts "$first_ts")" "$(fmt_ts "$last_ts")" "$cnt" "$(human_time "$dur")"
  done
}

show_session_table() {
  echo
  echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}                     User IP Session Summary (${PERIOD})${NC}"
  echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
  
  printf "%-3s %-18s %-25s %-20s %-20s %-8s %-10s\n" "#" "IP" "Location" "First Seen" "Last Seen" "Count" "Duration"
  echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────────────${NC}"

  local i=0
  sort -t"|" -k4,4n "$TMP_SESSIONS" | while IFS="|" read -r ip first_ts last_ts first_ep last_ep cnt; do
    i=$((i+1))
    local dur=$((last_ep - first_ep))
    
    # Get location from cache or fetch
    local details
    details=$(get_ip_details_simple "$ip" 2>/dev/null || true)
    loc=$(format_location_short_simple "$details")
    
    printf "%-3s %-18s %-25s %-20s %-20s %-8s %-10s\n" \
      "$i" "$ip" "$loc" "$(fmt_ts "$first_ts")" "$(fmt_ts "$last_ts")" "$cnt" "$(human_time "$dur")"
  done
}

show_overlap_table() {
  if [[ ! -s "$TMP_OVERLAPS" ]]; then
    echo
    echo -e "${YELLOW}No overlap windows to display.${NC}"
    return
  fi

  echo
  echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}               Overlapping Session Windows (Parallel IP Usage) ${NC}"
  echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
  printf "%-3s %-20s %-20s %-10s %-s\n" "#" "Start" "End" "Duration" "IPs"
  echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────────────${NC}"

  local i=0
  sort -t"|" -k1,1n "$TMP_OVERLAPS" | while IFS="|" read -r start_ep end_ep ip_list; do
    i=$((i+1))
    local dur=$((end_ep - start_ep))
    printf "%-3s %-20s %-20s %-10s %-s\n" \
      "$i" "$(human_date "$start_ep")" "$(human_date "$end_ep")" "$(human_time "$dur")" "$ip_list"
  done
}

# ============================================================
# Cache Cleanup (Simple)
# ============================================================

cleanup_old_cache() {
  echo -e "${CYAN}🧹 Cache cleanup skipped (stability focus)${NC}"
  return 0
}

# ============================================================
# Main
# ============================================================

main_1() {
  print_header
  ensure_dependencies
  validate_and_repair_cache
  init_ip_details_file
  cleanup_old_cache
  select_period
  prompt_uuid
  echo

  load_raw_logs
  parse_events
  build_sessions
  detect_overlaps
  
  # Show detailed IP table first
  show_ip_details_table
  pause
  
  # Then show session table
  show_session_table
  show_overlap_table
  score_violation

  echo
  echo -e "${GREEN}✅ Analysis complete.${NC}"
  
  # Cleanup temp files
  rm -f "$TMP_EVENTS" "$TMP_SESSIONS" "$TMP_OVERLAPS" "$TMP_RAW" 2>/dev/null || true
}

main() {
  print_header
  ensure_dependencies
  validate_and_repair_cache  # Use simple validation
  select_period
  prompt_uuid
  echo

  load_raw_logs
  parse_events
  build_sessions
  detect_overlaps
  
  # Show detailed IP table first
  show_ip_details_table
  pause
  
  # Then show session table
  show_session_table
  show_overlap_table
  score_violation

  echo
  echo -e "${GREEN}✅ Analysis complete.${NC}"
  
  # Cleanup temp files
  rm -f "$TMP_EVENTS" "$TMP_SESSIONS" "$TMP_OVERLAPS" "$TMP_RAW" 2>/dev/null || true
}

# Run main function
main "$@"
