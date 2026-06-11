#!/bin/bash
# HelpIT Autonomous Agent — macOS Scan + Fix (v5.2)
# v5 security rewrite: the agent NEVER executes a command string from the server.
#   - Auth: every fix-phase call uses ONLY the short-lived agt_ SESSION_TOKEN.
#   - Approval: polls /approved-actions, which returns nothing until the customer
#     approves in the portal (the human gate, enforced server-side).
#   - Execution: approved {action_id, params} are mapped to fixed native
#     functions via a dispatch table. No eval. No allowlist-on-strings.
# v5.1: Trash MEASUREMENT reads through Finder, fails LOUD (-1=blocked) not 0.
# v5.2: Trash EMPTY uses Finder and VERIFIES by re-count -- reports success
#       only if the Trash is actually empty, never on a silent no-op.

set -u

# AUTH_TOKEN is intentionally blanked by the server now (token hygiene). The
# agent authenticates every call with the agt_ SESSION_TOKEN only. The line is
# kept so the scan POST below still references a defined variable under `set -u`.
AUTH_TOKEN="{{AUTH_TOKEN}}"
SESSION_TOKEN="{{SESSION_TOKEN}}"
SESSION_ID="{{SESSION_ID}}"
API_BASE="https://www.helpitinc.com"

# Open portal session page in default browser so the customer can review & approve
open "$API_BASE/helpit-agent/session/$SESSION_ID"

cleanup_and_exit() {
  local code="${1:-0}"
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

# Trash size via Finder automation (reads THROUGH macOS privacy protection).
# `du ~/.Trash` returns "Operation not permitted" under macOS TCC, and that
# failure silently became 0 GB -- the agent reported a clean machine it never
# actually inspected. This reads the real size through Finder (which holds the
# entitlement) and returns -1 ("blocked / unknown") when it genuinely cannot
# read -- NEVER a fake 0. Finder returns per-item physical size in bytes,
# sometimes in scientific notation (e.g. 7.1077888E+8), so the sum is done in
# awk, which handles it; bash arithmetic cannot.
trash_size_gb() {
  local sizes
  sizes=$(osascript -e 'tell application "Finder" to get physical size of every item of trash' 2>/dev/null)
  if [ -z "$sizes" ]; then
    # Empty output is ambiguous: truly-empty Trash vs. blocked. Ask Finder for a
    # count to tell them apart. count "0" => real empty; otherwise => blocked.
    local count
    count=$(osascript -e 'tell application "Finder" to count items of trash' 2>/dev/null)
    if [ "$count" = "0" ]; then echo "0"; else echo "-1"; fi
    return
  fi
  echo "$sizes" | awk -F',' '
    { for (i=1; i<=NF; i++) { gsub(/[^0-9eE.+-]/,"",$i); if ($i!="") sum += $i } }
    END { printf "%.2f", sum/1024/1024/1024 }'
}

echo "🔍 Scanning..."

# ══════════════════════════════════════════
# 0. HARDWARE IDENTITY
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

TRASH_GB=$(trash_size_gb)
IOS_BACKUPS_GB=$(safe_du_gb "$HOME/Library/Application Support/MobileSync")
TMP_GB=$(safe_du_gb "/tmp")
VAR_FOLDERS_GB=$(safe_du_gb "/var/folders")
DOWNLOADS_GB=$(safe_du_gb "$HOME/Downloads")
DOWNLOADS_COUNT=$(find "$HOME/Downloads" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
DS_STORE_COUNT=$(find "$HOME" -name ".DS_Store" -type f 2>/dev/null | wc -l | tr -d ' ')

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
BATTERY_CONDITION=$(echo "$BATT_RAW" | awk -F': ' '/Condition/{gsub(/^ +/,"",$2); print $2; exit}'); [ -z "$BATTERY_CONDITION" ] && BATTERY_CONDITION="Unknown"
BATTERY_CYCLES=$(echo "$BATT_RAW" | awk -F': ' '/Cycle Count/{gsub(/^ +/,"",$2); print $2; exit}'); [ -z "$BATTERY_CYCLES" ] && BATTERY_CYCLES=0
CRASH_REPORTS_COUNT=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | wc -l | tr -d ' ')
CONSOLE_ERRORS_JSON=$(log show --last 1h --predicate 'messageType == error' --style compact 2>/dev/null \
  | head -10 | awk '{ gsub(/"/,"\\\""); if (length($0)>0) printf "%s\"%s\"", (NR>1?",":""), substr($0,1,200) }' \
  | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
[ -z "$CONSOLE_ERRORS_JSON" ] && CONSOLE_ERRORS_JSON="[]"

# ══════════════════════════════════════════
# POST SCAN DATA TO AI  (unchanged contract)
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
# POLL FOR APPROVAL + FETCH APPROVED ACTIONS
# The agent uses ONLY the agt_ SESSION_TOKEN. /approved-actions returns:
#   409 → not yet approved (keep waiting)
#   200 → approved; body has the action list
#   401 → session ended/expired (stop)
# ══════════════════════════════════════════
APPROVED_URL="$API_BASE/api/agent/session/$SESSION_TOKEN/approved-actions"
MAX_WAIT=600
POLL_INTERVAL=5
WAITED=0
ACTIONS_JSON=""

while [ "$WAITED" -lt "$MAX_WAIT" ]; do
  RESP=$(curl -sS -w $'\n%{http_code}' -X GET "$APPROVED_URL" --max-time 15 2>/dev/null)
  CODE=$(printf '%s' "$RESP" | tail -1)
  BODY=$(printf '%s' "$RESP" | sed '$d')

  case "$CODE" in
    200)
      echo "🔧 Fixes approved! Executing..."
      ACTIONS_JSON=$(printf '%s' "$BODY" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('actions',[])))" 2>/dev/null)
      break
      ;;
    409)
      : # still awaiting customer approval — keep polling
      ;;
    401)
      echo "ℹ️  Session is no longer active. Exiting."
      cleanup_and_exit 0
      ;;
    *)
      : # transient/network error — keep polling
      ;;
  esac

  sleep "$POLL_INTERVAL"
  WAITED=$((WAITED + POLL_INTERVAL))
done

if [ -z "$ACTIONS_JSON" ]; then
  echo "⏰ Timed out waiting for approval."
  cleanup_and_exit 1
fi
if [ "$ACTIONS_JSON" = "[]" ] || [ "$ACTIONS_JSON" = "null" ]; then
  echo "⚠️  No actions to execute."
  cleanup_and_exit 0
fi

# ══════════════════════════════════════════
# EXECUTE APPROVED ACTIONS
# Structured {action_id, params} → fixed native functions. NO eval. NO server
# command strings. An action_id the dispatch table does not know is refused.
# ══════════════════════════════════════════
report_result() {   # $1 action_id, $2 result, $3 error text
  local err_json
  err_json=$(printf '%s' "$3" | head -c 400 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '""')
  curl -sS -X POST "$API_BASE/api/agent/fix-result" \
    -H "Content-Type: application/json" \
    --max-time 10 \
    --data "{\"session_token\":\"$SESSION_TOKEN\",\"fix_id\":\"$1\",\"result\":\"$2\",\"error_details\":$err_json}" >/dev/null 2>&1
}

do_flush_dns()   { dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null; return 0; }
do_clear_temp()  { [ -n "${TMPDIR:-}" ] && rm -rf "${TMPDIR:?}/"* 2>/dev/null; return 0; }
do_empty_trash() {
  # rm on ~/.Trash is blocked by macOS App Management and silently exits 0 --
  # it reported "success" while deleting nothing. Use Finder (which holds the
  # entitlement) and VERIFY by re-counting. Never trust the exit code here.
  local before after
  before=$(osascript -e 'tell application "Finder" to count items of trash' 2>/dev/null)
  osascript -e 'tell application "Finder" to empty trash' 2>/dev/null
  after=$(osascript -e 'tell application "Finder" to count items of trash' 2>/dev/null)
  [ -z "$after" ] && return 1          # couldn't verify -> honest failure
  [ "$after" = "0" ] && return 0       # Trash actually empty now -> success
  return 1                              # items remain -> honest failure
}
do_clear_cache() {   # $1 = target (fixed branches only; never interpolated into a command)
  case "$1" in
    chrome) rm -rf "$HOME/Library/Caches/Google/Chrome/"* 2>/dev/null;;
    safari) rm -rf "$HOME/Library/Caches/com.apple.Safari/"* 2>/dev/null;;
    edge)   rm -rf "$HOME/Library/Caches/Microsoft Edge/"* 2>/dev/null;;
    *)      return 2;;
  esac
  return 0
}

dispatch_action() {   # $1 = action_id, $2 = target param
  case "$1" in
    flush_dns)   do_flush_dns;;
    clear_temp)  do_clear_temp;;
    empty_trash) do_empty_trash;;
    clear_cache) do_clear_cache "$2";;
    *)           return 3;;   # unknown / disabled / wrong-OS action -> refuse
  esac
}

COUNT=$(printf '%s' "$ACTIONS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
echo "🔧 Executing $COUNT approved action(s)..."

for i in $(seq 0 $((COUNT - 1))); do
  ACTION_ID=$(printf '%s' "$ACTIONS_JSON" | python3 -c "import sys,json; a=json.load(sys.stdin)[$i]; print(a.get('action_id',''))" 2>/dev/null)
  TITLE=$(printf '%s' "$ACTIONS_JSON"     | python3 -c "import sys,json; a=json.load(sys.stdin)[$i]; print(a.get('title') or a.get('action_id',''))" 2>/dev/null)
  TARGET=$(printf '%s' "$ACTIONS_JSON"    | python3 -c "import sys,json; a=json.load(sys.stdin)[$i]; p=a.get('params') or {}; print(p.get('target',''))" 2>/dev/null)

  [ -z "$ACTION_ID" ] && continue

  echo "  🔧 $TITLE"
  if dispatch_action "$ACTION_ID" "$TARGET"; then
    echo "  ✅ Done: $TITLE"
    report_result "$ACTION_ID" "success" ""
  else
    echo "  🚫 Refused: $TITLE (not a permitted action on this machine)"
    report_result "$ACTION_ID" "failed" "Action not permitted by agent dispatch"
  fi
  sleep 1
done

echo "✅ All actions complete!"
cleanup_and_exit 0
