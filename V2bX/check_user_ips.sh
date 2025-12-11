#!/bin/bash
# =============================================================
# V2bX User IP & Device Analyzer (Journald-based)
# Version: v5.0.1
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

pause() {
  echo
  read -rp "Press Enter to continue..." _
}

get_ip_location_short() {
    local ip=$1
    local short_location=""

    if [[ -n "${IP_LOCATION_CACHE[$ip]:-}" ]]; then
        echo "${IP_LOCATION_CACHE[$ip]}"
        return
    fi

    if response=$(curl -s -m 5 "http://ip-api.com/json/$ip?fields=status,countryCode,regionName,city,isp,org" 2>/dev/null); then
        if echo "$response" | jq -e . >/dev/null 2>&1; then
            if echo "$response" | jq -e '.status == "success"' >/dev/null 2>&1; then
                city=$(echo "$response" | jq -r '.city // empty')
                country_code=$(echo "$response" | jq -r '.countryCode // empty')
                regionName=$(echo "$response" | jq -r '.regionName // empty')
                isp=$(echo "$response" | jq -r '.isp // empty')

                short_city=$(echo "$city" | cut -d' ' -f1 | cut -c1-9 | sed 's/[^a-zA-Z]//g')

                local carrier=""
                if [[ "$isp" =~ [Mm]obile ]]; then carrier="M"
                elif [[ "$isp" =~ [Tt]elecom ]]; then carrier="T"
                elif [[ "$isp" =~ [Uu]nicom ]]; then carrier="U"
                elif [[ -n "$isp" ]]; then carrier="I"
                fi

                if [[ -n "$country_code" && -n "$short_city" ]]; then
                    short_location="${country_code}-${regionName}-${short_city}"
                    [[ -n "$carrier" ]] && short_location="${short_location}(${carrier})"
                elif [[ -n "$country_code" ]]; then
                    short_location="${country_code}-${regionName}"
                    [[ -n "$carrier" ]] && short_location="${short_location}(${carrier})"
                fi
            fi
        fi
    fi

    if [[ "$short_location" == "" || "$short_location" == "Unknown" ]]; then
        short_location="Unknown"
    fi

    IP_LOCATION_CACHE["$ip"]="$short_location"
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

show_session_table() {
  echo
  echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}                           User IP Session Summary ${NC}"
  echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
  
  # printf "%-3s %-18s %-20s %-20s %-8s %-10s\n" "#" "IP" "First Seen" "Last Seen" "Count" "Duration"
  printf "%-3s %-16s %-25s %-20s %-20s %-8s %-10s\n" "#" "IP" "Location" "First Seen" "Last Seen" "Count" "Duration"
  echo -e "${BLUE}----------------------------------------------------------------------------------${NC}"
  # echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"

  local i=0
  sort -t"|" -k4,4n "$TMP_SESSIONS" | while IFS="|" read -r ip first_ts last_ts first_ep last_ep cnt; do
    i=$((i+1))
    local dur=$((last_ep - first_ep))
    # printf "%-3s %-18s %-20s %-20s %-8s %-10s\n" \
      # "$i" "$ip" "$first_ts" "$last_ts" "$cnt" "$(human_time "$dur")"
	loc=$(get_ip_location_short "$ip")
	printf "%-3s %-16s %-25s %-20s %-20s %-8s %-10s\n" \
      "$i" "$ip" "$loc" "$first_ts" "$last_ts" "$cnt" "$(human_time "$dur")"
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
  echo -e "${BLUE}----------------------------------------------------------------------------------${NC}"

  local i=0
  sort -t"|" -k1,1n "$TMP_OVERLAPS" | while IFS="|" read -r start_ep end_ep ip_list; do
    i=$((i+1))
    local dur=$((end_ep - start_ep))
    printf "%-3s %-20s %-20s %-10s %-s\n" \
      "$i" "$(human_date "$start_ep")" "$(human_date "$end_ep")" "$(human_time "$dur")" "$ip_list"
  done
}

# ============================================================
# Main
# ============================================================

main() {
  print_header
  ensure_dependencies
  select_period
  prompt_uuid
  echo

  load_raw_logs
  parse_events
  build_sessions
  detect_overlaps
  show_session_table
  show_overlap_table
  score_violation

  echo
  echo -e "${GREEN}Done.${NC}"
}

main "$@"
