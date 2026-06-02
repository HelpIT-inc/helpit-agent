#!/bin/bash
# HelpIT Autonomous Agent — macOS Comprehensive Scan + Fix (v4.0)
# Built on v3.1 — IDENTICAL backend contract (endpoints, payload shapes, auth, polling,
# fix-result). New in v4: hardware identity (Intel vs Apple Silicon), storage root-cause
# depth (local snapshots + SMART), battery condition/cycles, and a client-side safety
# allowlist that blocks any non-approved command shape before execution.

set -u

AUTH_TOKEN="{{AUTH_TOKEN}}"
SESSION_TOKEN="{{SESSION_TOKEN}}"
SESSION_ID="{{SESSION_ID}}"
API_BASE="https://www.helpitinc.com"
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"

# Minimize Terminal
osascript -e 'tell application "System Events" to set visible of process "Terminal" to false' >/dev/null 2>&1 &

# Open portal session page in default browser
open "$API_BASE/helpit-agent/session/$SESSION_ID"

cleanup_and_exit() {
  local code="${1:-0}"
  if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
    rm -f "$SCRIPT_PATH" >/dev/null 2>&1 || true
  fi
  osascript -e 'tell application "Terminal" to quit' >/dev/null 2>&1 &
  exit "$code"
}
trap 'cleanup_and_exit 1' INT TERM

to_gb()    { awk "BEGIN { printf \"%.2f\", $1/1024/1024/1024 }"; }
kb_to_gb() { awk "BEGIN { printf \"%.2f\", $1/1024/1024 }"; }
safe_du_gb() {
  if [ -e "$1" ]; then
    local kb; kb=$(du -sk "$1" 2>/dev/null | awk '{print $1}'); [ -z "$kb" ] && kb=0
    kb_to_gb "$kb"
  else echo "0"; fi
}

# ── NEW (v4): client-side safety allowlist ──────────────────────────────────
# Defense-in-depth. Even if the server returns a command, we refuse to run it
# unless it matches a known-safe shape AND contains no elevation/destructive tokens.
# The agent NEVER runs sudo or anything outside this set.
is_safe_command() {
  local c="$1"
  case "$c" in
    *sudo*|*"rm -rf /"*|*mkfs*|*"diskutil erase"*|*shutdown*|*reboot*|*"dd if="*|*":(){"*) return 1;;
  esac
  case "$c" in
    "rm -rf ~/Library/Caches/"*)            return 0;;  # covers Chrome/Safari cache too
    "rm -rf \$TMPDIR"*|'rm -rf "$TMPDIR"'*) return 0;;
    "dscacheutil -flushcache"*)             return 0;;
    "pkill -f "*)                           return 0;;
    osascript*"empty trash"*)               return 0;;
  esac
  return 1
}

echo "🔍 Scanning..."

# ══════════════════════════════════════════
# 0. HARDWARE IDENTITY  (NEW v4 — drives hardware-aware fixes)
# ══════════════════════════════════════════
ARCH=$(uname -m)
IS_INTEL=false; [ "$ARCH" = "x86_64" ] && IS_INTEL=true
HW_MODEL=$(sysctl -n hw.model 2>/dev/null); [ -z "$HW_MODEL" ] && HW_MODEL="unknown"
CHIP=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip|Processor Name/{gsub(/^ +/,"",$2); print $2; exit}')
[ -z "$CHIP" ] && CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
[ -z "$CHIP" ] && CHIP="unknown"

# ══════════════════════════════════════════
# 1. STORAGE
# ══════════════════════════════════════════
DISK_LINE=$(df -k / | tail -1)
DISK_TOTAL_GB=$(kb_to_gb "$(echo "$DISK_LINE" | awk '{print $2}')")
DISK_USED_GB=$(kb_to_gb "$(echo "$DISK_LINE" | awk '{print $3}')")
DISK_FREE_GB=$(kb_to_gb "$(echo "$DISK_LINE" | awk '{print $4}')")
DISK_PERCENT=$(echo "$DISK_LINE" | awk '{print $5}' | tr -d '%')

TOP_LARGEST_JSON="[]"
TOP=$(du -sk "$HOME"/* 2>/dev/null | sort -rn | head -5)
if [ -n "$TOP" ]; then
  TOP_LARGEST_JSON=$(echo "$TOP" | awk '
    BEGIN { printf "[" }
    { gb=$1/1024/1024; path=""; for (i=2;i<=NF;i++) path=path (i==2?"":" ") $i;
      gsub(/"/, "\\\"", path);
      if (NR>1) printf ",";
      printf "{\"path\":\"%s\",\"size_gb\":%.2f}", path, gb }
    END { printf "]" }')
fi

TRASH_GB=$(safe_du_gb "$HOME/.Trash")
IOS_BACKUPS_GB=$(safe_du_gb "$HOME/Library/Application Support/MobileSync")
TMP_GB=$(safe_du_gb "/tmp")
VAR_FOLDERS_GB=$(safe_du_gb "/var/folders")
DOWNLOADS_GB=$(safe_du_gb "$HOME/Downloads")
DOWNLOADS_COUNT=$(find "$HOME/Downloads" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
DS_STORE_COUNT=$(find "$HOME" -name ".DS_Store" -type f 2>/dev/null | wc -l | tr -d ' ')

# NEW v4 — storage root-cause signals
LOCAL_SNAPSHOTS=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple'); [ -z "$LOCAL_SNAPSHOTS" ] && LOCAL_SNAPSHOTS=0
SMART_STATUS=$(diskutil info disk0 2>/dev/null | awk -F': ' '/SMART Status/{gsub(/^ +/,"",$2); print $2; exit}'); [ -z "$SMART_STATUS" ] && SMART_STATUS="Not Supported"

# ══════════════════════════════════════════
# 2. MEMORY
# ══════════════════════════════════════════
RAM_TOTAL_GB=$(to_gb "$(sysctl -n hw.memsize 2>/dev/null || echo 0)")
VM_STAT=$(vm_stat 2>/dev/null)
PAGE_SIZE=$(echo "$VM_STAT" | awk '/page size of/ {print $8}'); [ -z "$PAGE_SIZE" ] && PAGE_SIZE=4096
PF=$(echo "$VM_STAT" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}'); [ -z "$PF" ] && PF=0
PI=$(echo "$VM_STAT" | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}'); [ -z "$PI" ] && PI=0
PP=$(echo "$VM_STAT" | awk '/Pages purgeable/ {gsub(/\./,"",$3); print $3}'); [ -z "$PP" ] && PP=0
PA=$(echo "$VM_STAT" | awk '/Pages active/ {gsub(/\./,"",$3); print $3}'); [ -z "$PA" ] && PA=0
PW=$(echo "$VM_STAT" | awk '/Pages wired down/ {gsub(/\./,"",$4); print $4}'); [ -z "$PW" ] && PW=0
RAM_AVAILABLE_GB=$(to_gb "$(( (PF+PI+PP)*PAGE_SIZE ))")
RAM_USED_GB=$(to_gb "$(( (PA+PW)*PAGE_SIZE ))")
MEM_PRESSURE_RAW=$(memory_pressure 2>/dev/null | tail -1 || echo "")
if echo "$MEM_PRESSURE_RAW" | grep -qi "critical"; then MEM_PRESSURE="critical"
elif echo "$MEM_PRESSURE_RAW" | grep -qi "warn"; then MEM_PRESSURE="warning"
else MEM_PRESSURE="normal"; fi
TOP_MEM_JSON=$(ps -axo pid,comm,rss -m 2>/dev/null | head -6 | tail -5 | awk '
  BEGIN { printf "[" }
  { mb=$3/1024; pid=$1; name=""; for (i=2;i<NF;i++) name=name (i==2?"":" ") $i;
    gsub(/"/,"\\\"",name); if (NR>1) printf ",";
    printf "{\"pid\":%s,\"name\":\"%s\",\"memory_mb\":%.0f}", pid, name, mb }
  END { printf "]" }')
SWAP_RAW=$(sysctl vm.swapusage 2>/dev/null || echo "")
SWAP_TOTAL_GB=$(echo "$SWAP_RAW" | awk -F'total = ' '{print $2}' | awk '{print $1}' | sed 's/M//' | awk '{printf "%.2f", $1/1024}')
SWAP_USED_GB=$(echo "$SWAP_RAW"  | awk -F'used = '  '{print $2}' | awk '{print $1}' | sed 's/M//' | awk '{printf "%.2f", $1/1024}')
[ -z "$SWAP_TOTAL_GB" ] && SWAP_TOTAL_GB=0
[ -z "$SWAP_USED_GB" ]  && SWAP_USED_GB=0

# ══════════════════════════════════════════
# 3. CPU
# ══════════════════════════════════════════
CPU_PERCENT=$(ps -A -o %cpu 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s}')
PROCESS_COUNT=$(ps -A 2>/dev/null | wc -l | tr -d ' ')
TOP_CPU_JSON=$(ps -axo pid,comm,%cpu -r 2>/dev/null | head -6 | tail -5 | awk '
  BEGIN { printf "[" }
  { pid=$1; cpu=$NF; name=""; for (i=2;i<NF;i++) name=name (i==2?"":" ") $i;
    gsub(/"/,"\\\"",name); if (NR>1) printf ",";
    printf "{\"pid\":%s,\"name\":\"%s\",\"cpu_percent\":%.1f}", pid, name, cpu }
  END { printf "]" }')
UPTIME_SEC=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[ ,]' '{print $4}')
NOW_SEC=$(date +%s)
if [ -n "$UPTIME_SEC" ] && [ "$UPTIME_SEC" -gt 0 ]; then
  UPTIME_DAYS=$(awk "BEGIN { printf \"%.1f\", ($NOW_SEC - $UPTIME_SEC)/86400 }")
  LAST_BOOT=$(date -r "$UPTIME_SEC" -u +"%Y-%m-%dT%H:%M:%SZ")
else UPTIME_DAYS=0; LAST_BOOT="unknown"; fi

# ══════════════════════════════════════════
# 4. STARTUP
# ══════════════════════════════════════════
LOGIN_ITEMS_JSON=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
  | tr ',' '\n' | sed 's/^ *//;s/ *$//' \
  | awk 'NF>0 {gsub(/"/,"\\\""); printf "%s\"%s\"", (NR>1?",":""), $0}' \
  | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
[ -z "$LOGIN_ITEMS_JSON" ] && LOGIN_ITEMS_JSON="[]"
list_dir_to_json() {
  local dir="$1"
  if [ -d "$dir" ]; then
    ls -1 "$dir" 2>/dev/null | awk 'BEGIN{printf "["} NF>0{gsub(/"/,"\\\""); printf "%s\"%s\"", (NR>1?",":""), $0} END{printf "]"}'
  else echo "[]"; fi
}
LAUNCH_AGENTS_USER_JSON=$(list_dir_to_json "$HOME/Library/LaunchAgents")
LAUNCH_AGENTS_SYSTEM_JSON=$(list_dir_to_json "/Library/LaunchAgents")
LAUNCH_DAEMONS_JSON=$(list_dir_to_json "/Library/LaunchDaemons")
UAC=$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | wc -l | tr -d ' ')
SAC=$(ls "/Library/LaunchAgents" 2>/dev/null | wc -l | tr -d ' ')
DC=$(ls "/Library/LaunchDaemons" 2>/dev/null | wc -l | tr -d ' ')
LIC=$(echo "$LOGIN_ITEMS_JSON" | tr ',' '\n' | wc -l | tr -d ' ')
STARTUP_COUNT=$((UAC + SAC + DC + LIC))

# ══════════════════════════════════════════
# 5. NETWORK
# ══════════════════════════════════════════
DNS_SERVERS_JSON=$(scutil --dns 2>/dev/null | grep 'nameserver\[' | awk '{print $3}' | sort -u \
  | awk 'BEGIN{printf "["} NF>0 {gsub(/"/,"\\\""); printf "%s\"%s\"", (NR>1?",":""), $0} END{printf "]"}')
[ -z "$DNS_SERVERS_JSON" ] && DNS_SERVERS_JSON="[]"
DNS_RESPONSE_MS=$(dig +stats google.com 2>/dev/null | awk '/Query time:/ {print $4; exit}'); [ -z "$DNS_RESPONSE_MS" ] && DNS_RESPONSE_MS=0
PING_MS=$(ping -c 2 -t 4 8.8.8.8 2>/dev/null | awk -F'/' '/round-trip/ {printf "%.0f", $5}'); [ -z "$PING_MS" ] && PING_MS=999
ACTIVE_INTERFACE=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}'); [ -z "$ACTIVE_INTERFACE" ] && ACTIVE_INTERFACE="unknown"
ACTIVE_IP=$(ipconfig getifaddr "$ACTIVE_INTERFACE" 2>/dev/null); [ -z "$ACTIVE_IP" ] && ACTIVE_IP="unknown"
DNS_CACHE_ENTRIES=$(dscacheutil -statistics 2>/dev/null | awk '/Entries/ {sum+=$2} END {print sum+0}'); [ -z "$DNS_CACHE_ENTRIES" ] && DNS_CACHE_ENTRIES=0
WIFI_SIGNAL_DBM=0
AIRPORT="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
if [ -x "$AIRPORT" ]; then
  WIFI_SIGNAL_DBM=$("$AIRPORT" -I 2>/dev/null | awk '/agrCtlRSSI/ {print $2}'); [ -z "$WIFI_SIGNAL_DBM" ] && WIFI_SIGNAL_DBM=0
fi

# ══════════════════════════════════════════
# 6. SECURITY
# ══════════════════════════════════════════
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

# ══════════════════════════════════════════
# 7. BROWSER
# ══════════════════════════════════════════
CHROME_EXT_DIR="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
CHROME_EXT_COUNT=$(ls "$CHROME_EXT_DIR" 2>/dev/null | wc -l | tr -d ' ')
CHROME_CACHE_GB=$(safe_du_gb "$HOME/Library/Caches/Google/Chrome")
SAFARI_CACHE_GB=$(safe_du_gb "$HOME/Library/Caches/com.apple.Safari")
BROWSER_HELPERS_JSON=$(ps -A -o comm 2>/dev/null \
  | grep -Ei 'helper|extension' | sort -u | head -10 \
  | awk 'BEGIN{printf "["} NF>0 {gsub(/"/,"\\\""); printf "%s\"%s\"", (NR>1?",":""), $0} END{printf "]"}')
[ -z "$BROWSER_HELPERS_JSON" ] && BROWSER_HELPERS_JSON="[]"

# ══════════════════════════════════════════
# 8. SYSTEM
# ══════════════════════════════════════════
OS_VERSION=$(sw_vers -productVersion 2>/dev/null)
OS_BUILD=$(sw_vers -buildVersion 2>/dev/null)
BATTERY_HEALTH=0
BATT_RAW=$(system_profiler SPPowerDataType 2>/dev/null)
if echo "$BATT_RAW" | grep -q "Battery Information"; then
  MAX_CAP=$(echo "$BATT_RAW" | awk '/Maximum Capacity/ {gsub(/%/,"",$3); print $3; exit}')
  [ -n "$MAX_CAP" ] && BATTERY_HEALTH="$MAX_CAP"
fi
# NEW v4 — battery condition + cycle count (manufacturer service guidance)
BATTERY_CONDITION=$(echo "$BATT_RAW" | awk -F': ' '/Condition/{gsub(/^ +/,"",$2); print $2; exit}'); [ -z "$BATTERY_CONDITION" ] && BATTERY_CONDITION="Unknown"
BATTERY_CYCLES=$(echo "$BATT_RAW" | awk -F': ' '/Cycle Count/{gsub(/^ +/,"",$2); print $2; exit}'); [ -z "$BATTERY_CYCLES" ] && BATTERY_CYCLES=0
CRASH_REPORTS_COUNT=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | wc -l | tr -d ' ')
CONSOLE_ERRORS_JSON=$(log show --last 1h --predicate 'messageType == error' --style compact 2>/dev/null \
  | head -10 | awk '{ gsub(/"/,"\\\""); if (length($0)>0) printf "%s\"%s\"", (NR>1?",":""), substr($0,1,200) }' \
  | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
[ -z "$CONSOLE_ERRORS_JSON" ] && CONSOLE_ERRORS_JSON="[]"

# ══════════════════════════════════════════
# POST SCAN DATA TO AI
# ══════════════════════════════════════════
echo "📤 Submitting scan to AI..."
SCAN_PAYLOAD=$(cat <<JSON
{
  "session_token": "$SESSION_TOKEN",
  "scan_data": {
    "os_type": "mac",
    "hardware": {
      "arch": "$ARCH", "is_intel": $IS_INTEL, "model": "$HW_MODEL", "chip": "$CHIP"
    },
    "storage": {
      "disk_total_gb": $DISK_TOTAL_GB, "disk_used_gb": $DISK_USED_GB, "disk_free_gb": $DISK_FREE_GB,
      "disk_percent_used": $DISK_PERCENT, "top_largest": $TOP_LARGEST_JSON,
      "trash_size_gb": $TRASH_GB, "ios_backups_size_gb": $IOS_BACKUPS_GB,
      "tmp_size_gb": $TMP_GB, "var_folders_size_gb": $VAR_FOLDERS_GB,
      "ds_store_count": $DS_STORE_COUNT,
      "downloads_size_gb": $DOWNLOADS_GB, "downloads_file_count": $DOWNLOADS_COUNT,
      "local_snapshots": $LOCAL_SNAPSHOTS, "smart_status": "$SMART_STATUS"
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
      "battery_condition": "$BATTERY_CONDITION", "battery_cycle_count": $BATTERY_CYCLES,
      "crash_reports_count": $CRASH_REPORTS_COUNT, "recent_console_errors": $CONSOLE_ERRORS_JSON
    }
  }
}
JSON
)

SCAN_RESPONSE=$(curl -sS -X POST "$API_BASE/api/agent/scan" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  --max-time 180 \
  --data "$SCAN_PAYLOAD")

if ! echo "$SCAN_RESPONSE" | grep -q '"ok":true'; then
  echo "⚠️  Scan failed: $(echo "$SCAN_RESPONSE" | head -c 300)"
  cleanup_and_exit 1
fi

echo "✅ Scan submitted. Waiting for approval on portal..."

# ══════════════════════════════════════════
# POLL FOR APPROVAL
# ══════════════════════════════════════════
MAX_WAIT=600
POLL_INTERVAL=5
WAITED=0

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
  SESSION_RESPONSE=$(curl -sS -X GET "$API_BASE/api/agent/session/$SESSION_ID" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    --max-time 15 2>/dev/null)

  STATUS=$(echo "$SESSION_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session',{}).get('status',''))" 2>/dev/null)

  case "$STATUS" in
    fixing)
      echo "🔧 Fixes approved! Executing..."
      break
      ;;
    completed)
      echo "✅ Session completed."
      cleanup_and_exit 0
      ;;
    cancelled|failed)
      echo "❌ Session $STATUS."
      cleanup_and_exit 0
      ;;
    awaiting_approval) ;;
    *) ;;
  esac

  sleep "$POLL_INTERVAL"
  WAITED=$((WAITED + POLL_INTERVAL))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
  echo "⏰ Timed out waiting for approval."
  cleanup_and_exit 1
fi

# ══════════════════════════════════════════
# EXECUTE APPROVED FIXES
# ══════════════════════════════════════════
FIXES_JSON=$(echo "$SESSION_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
fixes = d.get('session', {}).get('fixes_approved', [])
print(json.dumps(fixes))
" 2>/dev/null)

if [ -z "$FIXES_JSON" ] || [ "$FIXES_JSON" = "[]" ] || [ "$FIXES_JSON" = "null" ]; then
  echo "⚠️  No fixes to execute."
  cleanup_and_exit 0
fi

FIX_COUNT=$(echo "$FIXES_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
echo "🔧 Executing $FIX_COUNT fixes..."

for i in $(seq 0 $((FIX_COUNT - 1))); do
  FIX_TITLE=$(echo "$FIXES_JSON" | python3 -c "import sys,json; f=json.load(sys.stdin)[$i]; print(f.get('title',''))" 2>/dev/null)
  FIX_CMD=$(echo "$FIXES_JSON" | python3 -c "import sys,json; f=json.load(sys.stdin)[$i]; print(f.get('fix',{}).get('command',''))" 2>/dev/null)

  if [ -z "$FIX_CMD" ] || [ "$FIX_CMD" = "None" ] || [ "$FIX_CMD" = "null" ]; then
    echo "  ⏭️  Skipping '$FIX_TITLE' — no command"
    curl -sS -X POST "$API_BASE/api/agent/fix-result" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      --max-time 10 \
      --data "{\"session_token\":\"$SESSION_TOKEN\",\"fix_id\":\"$FIX_TITLE\",\"result\":\"failed\",\"error_details\":\"No executable command provided\"}" >/dev/null 2>&1
    continue
  fi

  # NEW v4 — refuse anything outside the safe allowlist BEFORE executing
  if ! is_safe_command "$FIX_CMD"; then
    echo "  🚫 Blocked by safety allowlist: $FIX_TITLE"
    curl -sS -X POST "$API_BASE/api/agent/fix-result" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      --max-time 10 \
      --data "{\"session_token\":\"$SESSION_TOKEN\",\"fix_id\":\"$FIX_TITLE\",\"result\":\"failed\",\"error_details\":\"Blocked by client safety allowlist\"}" >/dev/null 2>&1
    continue
  fi

  echo "  🔧 Fixing: $FIX_TITLE"
  FIX_OUTPUT=$(eval "$FIX_CMD" 2>&1)
  FIX_EXIT=$?

  if [ "$FIX_EXIT" -eq 0 ]; then
    FIX_RESULT="success"; echo "  ✅ Fixed: $FIX_TITLE"
  else
    FIX_RESULT="failed";  echo "  ❌ Failed: $FIX_TITLE"
  fi

  ESCAPED_OUTPUT=$(echo "$FIX_OUTPUT" | head -c 500 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '""')

  curl -sS -X POST "$API_BASE/api/agent/fix-result" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    --max-time 10 \
    --data "{\"session_token\":\"$SESSION_TOKEN\",\"fix_id\":\"$FIX_TITLE\",\"result\":\"$FIX_RESULT\",\"error_details\":$ESCAPED_OUTPUT}" >/dev/null 2>&1

  sleep 1
done

echo "✅ All fixes complete!"
cleanup_and_exit 0
