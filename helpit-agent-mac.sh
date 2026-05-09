#!/bin/bash
# HelpIT Autonomous Agent — macOS Comprehensive Scan (v3.0)
# - Minimizes Terminal on launch (customer never sees the window)
# - Posts progress to /api/agent/scan/progress after each category
# - Submits final scan_data to /api/agent/scan
# - Closes Terminal automatically and self-deletes when done

set -u

AUTH_TOKEN="{{AUTH_TOKEN}}"
SESSION_TOKEN="{{SESSION_TOKEN}}"
API_BASE="https://www.helpitinc.com"
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"

# ─── Minimize Terminal so customer sees the portal, not this output ────
osascript -e 'tell application "System Events" to set visible of process "Terminal" to false' >/dev/null 2>&1 &

# ─── Helpers ───────────────────────────────────────────────────────────
post_progress() {
  local step="$1"
  local pct="${2:-null}"
  local body
  if [ "$pct" = "null" ]; then
    body="{\"session_token\":\"$SESSION_TOKEN\",\"step\":\"$step\"}"
  else
    body="{\"session_token\":\"$SESSION_TOKEN\",\"step\":\"$step\",\"percent\":$pct}"
  fi
  curl -sS -X POST "$API_BASE/api/agent/scan/progress" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    --max-time 5 \
    --data "$body" >/dev/null 2>&1 &
}

cleanup_and_exit() {
  local code="${1:-0}"
  # Self-delete the script (fire-and-forget)
  if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
    rm -f "$SCRIPT_PATH" >/dev/null 2>&1 || true
  fi
  # Close the Terminal window/tab that ran this script
  osascript -e 'tell application "Terminal" to close (every window whose name contains "bash" or name contains "scan")' >/dev/null 2>&1 || true
  osascript -e 'tell application "Terminal" to quit' >/dev/null 2>&1 &
  exit "$code"
}

trap 'cleanup_and_exit 1' INT TERM

to_gb()    { awk "BEGIN { printf \"%.2f\", $1/1024/1024/1024 }"; }
kb_to_gb() { awk "BEGIN { printf \"%.2f\", $1/1024/1024 }"; }
safe_du_gb() {
  if [ -e "$1" ]; then
    local kb
    kb=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
    [ -z "$kb" ] && kb=0
    kb_to_gb "$kb"
  else
    echo "0"
  fi
}

post_progress "starting" 5
echo "🔍 HelpIT Autonomous Agent — Comprehensive Mac Scan"

# ─── 1. STORAGE ────────────────────────────────────────────────────────
post_progress "scanning_storage" 15
echo "📦 Scanning storage..."
DISK_LINE=$(df -k / | tail -1)
DISK_TOTAL_KB=$(echo "$DISK_LINE" | awk '{print $2}')
DISK_USED_KB=$(echo "$DISK_LINE" | awk '{print $3}')
DISK_FREE_KB=$(echo "$DISK_LINE" | awk '{print $4}')
DISK_PERCENT=$(echo "$DISK_LINE" | awk '{print $5}' | tr -d '%')
DISK_TOTAL_GB=$(kb_to_gb "$DISK_TOTAL_KB")
DISK_USED_GB=$(kb_to_gb "$DISK_USED_KB")
DISK_FREE_GB=$(kb_to_gb "$DISK_FREE_KB")

TOP_LARGEST_JSON="[]"
TOP=$(du -sk "$HOME"/* 2>/dev/null | sort -rn | head -5)
if [ -n "$TOP" ]; then
  TOP_LARGEST_JSON=$(echo "$TOP" | awk '
    BEGIN { printf "[" }
    { gb = $1/1024/1024;
      path = ""; for (i=2;i<=NF;i++) path = path (i==2?"":" ") $i;
      gsub(/"/, "\\\"", path);
      if (NR>1) printf ",";
      printf "{\"path\":\"%s\",\"size_gb\":%.2f}", path, gb
    }
    END { printf "]" }
  ')
fi

TRASH_GB=$(safe_du_gb "$HOME/.Trash")
IOS_BACKUPS_GB=$(safe_du_gb "$HOME/Library/Application Support/MobileSync")
TMP_GB=$(safe_du_gb "/tmp")
VAR_FOLDERS_GB=$(safe_du_gb "/var/folders")
DOWNLOADS_GB=$(safe_du_gb "$HOME/Downloads")
DOWNLOADS_COUNT=$(find "$HOME/Downloads" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
DS_STORE_COUNT=$(find "$HOME" -name ".DS_Store" -type f 2>/dev/null | wc -l | tr -d ' ')

# ─── 2. MEMORY ─────────────────────────────────────────────────────────
post_progress "scanning_memory" 30
echo "🧠 Scanning memory..."
RAM_TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
RAM_TOTAL_GB=$(to_gb "$RAM_TOTAL_BYTES")
VM_STAT=$(vm_stat 2>/dev/null)
PAGE_SIZE=$(echo "$VM_STAT" | awk '/page size of/ {print $8}')
[ -z "$PAGE_SIZE" ] && PAGE_SIZE=4096
PAGES_FREE=$(echo "$VM_STAT" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}'); [ -z "$PAGES_FREE" ] && PAGES_FREE=0
PAGES_INACTIVE=$(echo "$VM_STAT" | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}'); [ -z "$PAGES_INACTIVE" ] && PAGES_INACTIVE=0
PAGES_PURGEABLE=$(echo "$VM_STAT" | awk '/Pages purgeable/ {gsub(/\./,"",$3); print $3}'); [ -z "$PAGES_PURGEABLE" ] && PAGES_PURGEABLE=0
PAGES_ACTIVE=$(echo "$VM_STAT" | awk '/Pages active/ {gsub(/\./,"",$3); print $3}'); [ -z "$PAGES_ACTIVE" ] && PAGES_ACTIVE=0
PAGES_WIRED=$(echo "$VM_STAT" | awk '/Pages wired down/ {gsub(/\./,"",$4); print $4}'); [ -z "$PAGES_WIRED" ] && PAGES_WIRED=0
AVAIL_BYTES=$(( (PAGES_FREE + PAGES_INACTIVE + PAGES_PURGEABLE) * PAGE_SIZE ))
USED_BYTES=$(( (PAGES_ACTIVE + PAGES_WIRED) * PAGE_SIZE ))
RAM_AVAILABLE_GB=$(to_gb "$AVAIL_BYTES")
RAM_USED_GB=$(to_gb "$USED_BYTES")

MEM_PRESSURE_RAW=$(memory_pressure 2>/dev/null | tail -1 || echo "")
if echo "$MEM_PRESSURE_RAW" | grep -qi "critical"; then MEM_PRESSURE="critical"
elif echo "$MEM_PRESSURE_RAW" | grep -qi "warn"; then MEM_PRESSURE="warning"
else MEM_PRESSURE="normal"; fi

TOP_MEM_JSON=$(ps -axo pid,comm,rss -m 2>/dev/null | head -6 | tail -5 | awk '
  BEGIN { printf "[" }
  { mb = $3/1024; pid = $1;
    name = ""; for (i=2;i<NF;i++) name = name (i==2?"":" ") $i;
    gsub(/"/, "\\\"", name);
    if (NR>1) printf ",";
    printf "{\"pid\":%s,\"name\":\"%s\",\"memory_mb\":%.0f}", pid, name, mb
  }
  END { printf "]" }
')

SWAP_RAW=$(sysctl vm.swapusage 2>/dev/null || echo "")
SWAP_TOTAL_GB=$(echo "$SWAP_RAW" | awk -F'total = ' '{print $2}' | awk '{print $1}' | sed 's/M//' | awk '{printf "%.2f", $1/1024}')
SWAP_USED_GB=$(echo "$SWAP_RAW"  | awk -F'used = '  '{print $2}' | awk '{print $1}' | sed 's/M//' | awk '{printf "%.2f", $1/1024}')
[ -z "$SWAP_TOTAL_GB" ] && SWAP_TOTAL_GB=0
[ -z "$SWAP_USED_GB" ]  && SWAP_USED_GB=0

# ─── 3. CPU ────────────────────────────────────────────────────────────
post_progress "scanning_cpu" 40
echo "⚡ Scanning CPU..."
CPU_PERCENT=$(ps -A -o %cpu 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s}')
PROCESS_COUNT=$(ps -A 2>/dev/null | wc -l | tr -d ' ')
TOP_CPU_JSON=$(ps -axo pid,comm,%cpu -r 2>/dev/null | head -6 | tail -5 | awk '
  BEGIN { printf "[" }
  { pid = $1; cpu = $NF;
    name = ""; for (i=2;i<NF;i++) name = name (i==2?"":" ") $i;
    gsub(/"/, "\\\"", name);
    if (NR>1) printf ",";
    printf "{\"pid\":%s,\"name\":\"%s\",\"cpu_percent\":%.1f}", pid, name, cpu
  }
  END { printf "]" }
')

UPTIME_SEC=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[ ,]' '{print $4}')
NOW_SEC=$(date +%s)
if [ -n "$UPTIME_SEC" ] && [ "$UPTIME_SEC" -gt 0 ]; then
  UPTIME_DAYS=$(awk "BEGIN { printf \"%.1f\", ($NOW_SEC - $UPTIME_SEC)/86400 }")
  LAST_BOOT=$(date -r "$UPTIME_SEC" -u +"%Y-%m-%dT%H:%M:%SZ")
else
  UPTIME_DAYS=0
  LAST_BOOT="unknown"
fi

# ─── 4. STARTUP ────────────────────────────────────────────────────────
post_progress "scanning_startup" 55
echo "🚀 Scanning startup items..."
LOGIN_ITEMS_JSON=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
  | tr ',' '\n' | sed 's/^ *//;s/ *$//' \
  | awk 'NF>0 {gsub(/"/,"\\\""); printf "%s\"%s\"", (NR>1?",":""), $0}' \
  | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
[ -z "$LOGIN_ITEMS_JSON" ] && LOGIN_ITEMS_JSON="[]"

list_dir_to_json() {
  local dir="$1"
  if [ -d "$dir" ]; then
    ls -1 "$dir" 2>/dev/null | awk 'BEGIN{printf "["} NF>0{gsub(/"/,"\\\""); printf "%s\"%s\"", (NR>1?",":""), $0} END{printf "]"}'
  else
    echo "[]"
  fi
}
LAUNCH_AGENTS_USER_JSON=$(list_dir_to_json "$HOME/Library/LaunchAgents")
LAUNCH_AGENTS_SYSTEM_JSON=$(list_dir_to_json "/Library/LaunchAgents")
LAUNCH_DAEMONS_JSON=$(list_dir_to_json "/Library/LaunchDaemons")
USER_AGENTS_COUNT=$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | wc -l | tr -d ' ')
SYS_AGENTS_COUNT=$(ls "/Library/LaunchAgents" 2>/dev/null | wc -l | tr -d ' ')
DAEMONS_COUNT=$(ls "/Library/LaunchDaemons" 2>/dev/null | wc -l | tr -d ' ')
LOGIN_ITEMS_COUNT=$(echo "$LOGIN_ITEMS_JSON" | tr ',' '\n' | wc -l | tr -d ' ')
STARTUP_COUNT=$((USER_AGENTS_COUNT + SYS_AGENTS_COUNT + DAEMONS_COUNT + LOGIN_ITEMS_COUNT))

# ─── 5. NETWORK ────────────────────────────────────────────────────────
post_progress "scanning_network" 65
echo "🌐 Scanning network..."
DNS_SERVERS_JSON=$(scutil --dns 2>/dev/null | grep 'nameserver\[' | awk '{print $3}' | sort -u \
  | awk 'BEGIN{printf "["} NF>0 {gsub(/"/,"\\\""); printf "%s\"%s\"", (NR>1?",":""), $0} END{printf "]"}')
[ -z "$DNS_SERVERS_JSON" ] && DNS_SERVERS_JSON="[]"

DNS_RESPONSE_MS=$(dig +stats google.com 2>/dev/null | awk '/Query time:/ {print $4; exit}')
[ -z "$DNS_RESPONSE_MS" ] && DNS_RESPONSE_MS=0

PING_MS=$(ping -c 2 -t 4 8.8.8.8 2>/dev/null | awk -F'/' '/round-trip/ {printf "%.0f", $5}')
[ -z "$PING_MS" ] && PING_MS=999

ACTIVE_INTERFACE=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}'); [ -z "$ACTIVE_INTERFACE" ] && ACTIVE_INTERFACE="unknown"
ACTIVE_IP=$(ipconfig getifaddr "$ACTIVE_INTERFACE" 2>/dev/null); [ -z "$ACTIVE_IP" ] && ACTIVE_IP="unknown"
DNS_CACHE_ENTRIES=$(dscacheutil -statistics 2>/dev/null | awk '/Entries/ {sum+=$2} END {print sum+0}'); [ -z "$DNS_CACHE_ENTRIES" ] && DNS_CACHE_ENTRIES=0

WIFI_SIGNAL_DBM=0
AIRPORT="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
if [ -x "$AIRPORT" ]; then
  WIFI_SIGNAL_DBM=$("$AIRPORT" -I 2>/dev/null | awk '/agrCtlRSSI/ {print $2}'); [ -z "$WIFI_SIGNAL_DBM" ] && WIFI_SIGNAL_DBM=0
fi

# ─── 6. SECURITY ───────────────────────────────────────────────────────
post_progress "scanning_security" 75
echo "🔒 Scanning security settings..."
FILEVAULT_ENABLED=false
fdesetup status 2>/dev/null | grep -qi "On" && FILEVAULT_ENABLED=true
FIREWALL_STATE=$(defaults read /Library/Preferences/com.apple.alf globalstate 2>/dev/null || echo 0)
FIREWALL_ENABLED=false; [ "$FIREWALL_STATE" != "0" ] && FIREWALL_ENABLED=true
GATEKEEPER_ENABLED=false
spctl --status 2>/dev/null | grep -qi "assessments enabled" && GATEKEEPER_ENABLED=true

PENDING_UPDATES=0
UPDATE_OUT=$(softwareupdate -l 2>&1 | head -50)
if echo "$UPDATE_OUT" | grep -qi "No new software"; then PENDING_UPDATES=0
else PENDING_UPDATES=$(echo "$UPDATE_OUT" | grep -c '^\* '); fi

SIP_ENABLED=true
csrutil status 2>/dev/null | grep -qi "disabled" && SIP_ENABLED=false
REMOTE_LOGIN_ENABLED=false
systemsetup -getremotelogin 2>/dev/null | grep -qi "On" && REMOTE_LOGIN_ENABLED=true

# ─── 7. BROWSER ────────────────────────────────────────────────────────
post_progress "scanning_browser" 85
echo "🌎 Scanning browsers..."
CHROME_EXT_DIR="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
CHROME_EXT_COUNT=$(ls "$CHROME_EXT_DIR" 2>/dev/null | wc -l | tr -d ' ')
CHROME_CACHE_GB=$(safe_du_gb "$HOME/Library/Caches/Google/Chrome")
SAFARI_CACHE_GB=$(safe_du_gb "$HOME/Library/Caches/com.apple.Safari")
BROWSER_HELPERS_JSON=$(ps -A -o comm 2>/dev/null \
  | grep -Ei 'helper|extension' | sort -u | head -10 \
  | awk 'BEGIN{printf "["} NF>0 {gsub(/"/,"\\\""); printf "%s\"%s\"", (NR>1?",":""), $0} END{printf "]"}')
[ -z "$BROWSER_HELPERS_JSON" ] && BROWSER_HELPERS_JSON="[]"

# ─── 8. SYSTEM ─────────────────────────────────────────────────────────
post_progress "scanning_system" 92
echo "💻 Scanning system info..."
OS_VERSION=$(sw_vers -productVersion 2>/dev/null)
OS_BUILD=$(sw_vers -buildVersion 2>/dev/null)

BATTERY_HEALTH=0
BATT_RAW=$(system_profiler SPPowerDataType 2>/dev/null)
if echo "$BATT_RAW" | grep -q "Battery Information"; then
  MAX_CAP=$(echo "$BATT_RAW" | awk '/Maximum Capacity/ {gsub(/%/,"",$3); print $3; exit}')
  [ -n "$MAX_CAP" ] && BATTERY_HEALTH="$MAX_CAP"
fi

CRASH_REPORTS_COUNT=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | wc -l | tr -d ' ')

CONSOLE_ERRORS_JSON=$(log show --last 1h --predicate 'messageType == error' --style compact 2>/dev/null \
  | head -10 | awk '{ gsub(/"/,"\\\""); if (length($0)>0) printf "%s\"%s\"", (NR>1?",":""), substr($0,1,200) }' \
  | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
[ -z "$CONSOLE_ERRORS_JSON" ] && CONSOLE_ERRORS_JSON="[]"

# ─── BUILD JSON PAYLOAD ────────────────────────────────────────────────
post_progress "submitting" 97
echo "📤 Submitting to AI..."
PAYLOAD=$(cat <<JSON
{
  "session_token": "$SESSION_TOKEN",
  "scan_data": {
    "os_type": "mac",
    "storage": {
      "disk_total_gb": $DISK_TOTAL_GB, "disk_used_gb": $DISK_USED_GB, "disk_free_gb": $DISK_FREE_GB,
      "disk_percent_used": $DISK_PERCENT, "top_largest": $TOP_LARGEST_JSON,
      "trash_size_gb": $TRASH_GB, "ios_backups_size_gb": $IOS_BACKUPS_GB,
      "tmp_size_gb": $TMP_GB, "var_folders_size_gb": $VAR_FOLDERS_GB,
      "ds_store_count": $DS_STORE_COUNT,
      "downloads_size_gb": $DOWNLOADS_GB, "downloads_file_count": $DOWNLOADS_COUNT
    },
    "memory": {
      "ram_total_gb": $RAM_TOTAL_GB, "ram_used_gb": $RAM_USED_GB, "ram_available_gb": $RAM_AVAILABLE_GB,
      "memory_pressure": "$MEM_PRESSURE", "top_processes_memory": $TOP_MEM_JSON,
      "swap_used_gb": $SWAP_USED_GB, "swap_total_gb": $SWAP_TOTAL_GB
    },
    "cpu": {
      "cpu_percent": $CPU_PERCENT, "top_processes_cpu": $TOP_CPU_JSON,
      "process_count": $PROCESS_COUNT, "uptime_days": $UPTIME_DAYS
    },
    "startup": {
      "login_items": $LOGIN_ITEMS_JSON, "launch_agents_user": $LAUNCH_AGENTS_USER_JSON,
      "launch_agents_system": $LAUNCH_AGENTS_SYSTEM_JSON, "launch_daemons": $LAUNCH_DAEMONS_JSON,
      "startup_count": $STARTUP_COUNT
    },
    "network": {
      "dns_servers": $DNS_SERVERS_JSON, "dns_response_ms": $DNS_RESPONSE_MS,
      "ping_8888_ms": $PING_MS, "active_interface": "$ACTIVE_INTERFACE", "active_ip": "$ACTIVE_IP",
      "dns_cache_entries": $DNS_CACHE_ENTRIES, "wifi_signal_dbm": $WIFI_SIGNAL_DBM
    },
    "security": {
      "filevault_enabled": $FILEVAULT_ENABLED, "firewall_enabled": $FIREWALL_ENABLED,
      "gatekeeper_enabled": $GATEKEEPER_ENABLED, "pending_updates": $PENDING_UPDATES,
      "sip_enabled": $SIP_ENABLED, "remote_login_enabled": $REMOTE_LOGIN_ENABLED
    },
    "browser": {
      "chrome_extension_count": $CHROME_EXT_COUNT, "chrome_cache_size_gb": $CHROME_CACHE_GB,
      "safari_cache_size_gb": $SAFARI_CACHE_GB, "browser_helpers": $BROWSER_HELPERS_JSON
    },
    "system": {
      "os_version": "$OS_VERSION", "os_build": "$OS_BUILD",
      "last_boot_at": "$LAST_BOOT", "battery_health_percent": $BATTERY_HEALTH,
      "crash_reports_count": $CRASH_REPORTS_COUNT, "recent_console_errors": $CONSOLE_ERRORS_JSON
    }
  }
}
JSON
)

RESPONSE=$(curl -sS -X POST "$API_BASE/api/agent/scan" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  --data "$PAYLOAD")

if echo "$RESPONSE" | grep -q '"ok":true'; then
  echo "✅ Scan complete!"
  cleanup_and_exit 0
else
  echo "⚠️  Server returned: $(echo "$RESPONSE" | head -c 300)"
  cleanup_and_exit 1
fi
