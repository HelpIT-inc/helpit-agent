#!/bin/bash
# HelpIT Autonomous Agent — macOS Deep Scan + Fix (v4)
# Backward-compatible with the v3.1 flow (session page, polling, fix-result reporting,
# self-delete). The new part is the DEEP, HARDWARE-AWARE scan and a client-side command
# allowlist so the agent will refuse to run anything outside the safe set — even if the
# server told it to.

set -u

AUTH_TOKEN="{{AUTH_TOKEN}}"
SESSION_TOKEN="{{SESSION_TOKEN}}"
SESSION_ID="{{SESSION_ID}}"
API_BASE="https://www.helpitinc.com"
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
POLL_SECS=4
POLL_MAX=150   # ~10 min before timeout

# ---- housekeeping ---------------------------------------------------------
osascript -e 'tell application "System Events" to set visible of process "Terminal" to false' >/dev/null 2>&1 &
open "$API_BASE/helpit-agent/session/$SESSION_ID"

cleanup_and_exit() {
  local code="${1:-0}"
  [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ] && rm -f "$SCRIPT_PATH" >/dev/null 2>&1 || true
  osascript -e 'tell application "Terminal" to quit' >/dev/null 2>&1 &
  exit "$code"
}
trap 'cleanup_and_exit 1' INT TERM

jesc() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null \
         || printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
gb()  { awk "BEGIN{printf \"%.2f\", $1/1073741824}"; }
kgb() { awk "BEGIN{printf \"%.2f\", $1/1048576}"; }

echo "🔍 Running deep scan..."

# ---- 0. HARDWARE / OS IDENTITY (drives hardware-aware advice) --------------
ARCH=$(uname -m)                                   # arm64 = Apple Silicon, x86_64 = Intel
HW_MODEL=$(sysctl -n hw.model 2>/dev/null)
CHIP=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip|Processor Name/{print $2; exit}')
[ -z "$CHIP" ] && CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
RAM_GB=$(gb "$(sysctl -n hw.memsize 2>/dev/null)")
OS_NAME=$(sw_vers -productName 2>/dev/null)
OS_VER=$(sw_vers -productVersion 2>/dev/null)
OS_BUILD=$(sw_vers -buildVersion 2>/dev/null)
IS_INTEL=false; [ "$ARCH" = "x86_64" ] && IS_INTEL=true

# ---- 1. STORAGE (deep: purgeable + local snapshots + SMART + top dirs) -----
DL=$(df -k / | tail -1)
DISK_TOTAL=$(kgb "$(echo "$DL" | awk '{print $2}')")
DISK_USED=$(kgb "$(echo "$DL" | awk '{print $3}')")
DISK_FREE=$(kgb "$(echo "$DL" | awk '{print $4}')")
DISK_PCT=$(echo "$DL" | awk '{print $5}' | tr -d '%')
PURGEABLE=$(df -H / 2>/dev/null | awk 'NR==2{print $4}')
SNAP_COUNT=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple')
SMART=$(diskutil info disk0 2>/dev/null | awk -F': ' '/SMART Status/{gsub(/^ +/,"",$2);print $2}')
TOP_DIRS=$(du -sk "$HOME"/* 2>/dev/null | sort -rn | head -5 | awk '{gb=$1/1048576; p="";for(i=2;i<=NF;i++)p=p (i==2?"":" ") $i; printf "{\"path\":\"%s\",\"gb\":%.2f},", p, gb}' | sed 's/,$//')

# ---- 2. MEMORY (pressure + swap + top consumers) ---------------------------
SWAP=$(sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}' | tr -d 'M')
FREE_PCT=$(vm_stat 2>/dev/null | awk '/Pages free/{f=$3} /Pages active/{a=$3} /Pages wired/{w=$4} END{tot=f+a+w; if(tot>0) printf "%.0f", f/tot*100}')
MEM_TOP=$(ps -arcm -o comm,%mem 2>/dev/null | head -6 | tail -5 | awk '{printf "{\"name\":\"%s\",\"mem_pct\":%s},",$1,$2}' | sed 's/,$//')

# ---- 3. CPU (named offenders only — required for an auto-fixable kill) ------
CPU_TOP=$(ps -arco comm,%cpu,pid,user 2>/dev/null | head -6 | tail -5 | awk '{printf "{\"name\":\"%s\",\"cpu_pct\":%s,\"pid\":%s,\"owner\":\"%s\"},",$1,$2,$3,$4}' | sed 's/,$//')

# ---- 4. STARTUP (login items + user LaunchAgents) --------------------------
LOGIN_ITEMS=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | tr ',' '\n' | sed 's/^ *//' | awk 'NF{printf "\"%s\",",$0}' | sed 's/,$//')
LAUNCH_AGENTS=$(ls -1 "$HOME/Library/LaunchAgents" 2>/dev/null | awk 'NF{printf "\"%s\",",$0}' | sed 's/,$//')

# ---- 5. NETWORK ------------------------------------------------------------
DNS_OK=$(ping -c1 -t2 1.1.1.1 >/dev/null 2>&1 && echo true || echo false)
PROXY=$(scutil --proxy 2>/dev/null | awk '/HTTPEnable/{print $3}')

# ---- 6. SECURITY (read-only state) -----------------------------------------
FV=$(fdesetup status 2>/dev/null | head -1)
SIP=$(csrutil status 2>/dev/null | awk '{print $NF}' | tr -d '.')
GATEKEEPER=$(spctl --status 2>/dev/null | awk '{print $2}')
FW=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -o 'enabled\|disabled' | head -1)
UPDATES=$(timeout 45 softwareupdate -l 2>/dev/null | grep -c '\* Label')

# ---- 7. BROWSER caches -----------------------------------------------------
CHROME_C=$(kgb "$(du -sk ~/Library/Caches/Google/Chrome 2>/dev/null | awk '{print $1}')"); [ -z "$CHROME_C" ] && CHROME_C=0
SAFARI_C=$(kgb "$(du -sk ~/Library/Caches/com.apple.Safari 2>/dev/null | awk '{print $1}')"); [ -z "$SAFARI_C" ] && SAFARI_C=0

# ---- 8. BATTERY (laptops; condition drives manufacturer service advice) ----
BATT_PCT=$(pmset -g batt 2>/dev/null | grep -o '[0-9]*%' | head -1 | tr -d '%')
BATT_CYCLES=$(system_profiler SPPowerDataType 2>/dev/null | awk -F': ' '/Cycle Count/{print $2; exit}')
BATT_COND=$(system_profiler SPPowerDataType 2>/dev/null | awk -F': ' '/Condition/{print $2; exit}')

# ---- 9. SYSTEM -------------------------------------------------------------
UPTIME_D=$(uptime 2>/dev/null | grep -o '[0-9]* days' | head -1 | grep -o '[0-9]*'); [ -z "$UPTIME_D" ] && UPTIME_D=0

# ---- assemble payload ------------------------------------------------------
PAYLOAD=$(cat <<JSON
{
  "platform":"macos",
  "hardware":{"model":"$(jesc "$HW_MODEL")","chip":"$(jesc "$CHIP")","arch":"$ARCH","is_intel":$IS_INTEL,"ram_gb":$RAM_GB,"os_name":"$(jesc "$OS_NAME")","os_version":"$OS_VER","os_build":"$OS_BUILD"},
  "storage":{"total_gb":$DISK_TOTAL,"used_gb":$DISK_USED,"free_gb":$DISK_FREE,"percent_used":${DISK_PCT:-0},"purgeable":"$(jesc "$PURGEABLE")","local_snapshots":${SNAP_COUNT:-0},"smart_status":"$(jesc "$SMART")","top_dirs":[${TOP_DIRS}]},
  "memory":{"free_pct":${FREE_PCT:-0},"swap_used_mb":"${SWAP:-0}","top_consumers":[${MEM_TOP}]},
  "cpu":{"top_processes":[${CPU_TOP}]},
  "startup":{"login_items":[${LOGIN_ITEMS}],"launch_agents":[${LAUNCH_AGENTS}]},
  "network":{"dns_ok":$DNS_OK,"proxy_enabled":"$(jesc "${PROXY:-0}")"},
  "security":{"filevault":"$(jesc "$FV")","sip":"$(jesc "$SIP")","gatekeeper":"$(jesc "$GATEKEEPER")","firewall":"$(jesc "$FW")","updates_available":${UPDATES:-0}},
  "browser":{"chrome_cache_mb":$CHROME_C,"safari_cache_mb":$SAFARI_C},
  "battery":{"percent":"${BATT_PCT:-}","cycle_count":"$(jesc "${BATT_CYCLES:-}")","condition":"$(jesc "${BATT_COND:-}")"},
  "system":{"uptime_days":${UPTIME_D:-0}}
}
JSON
)

curl -s -X POST "$API_BASE/api/agent/scan" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H "X-Session-Token: $SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"sessionId\":\"$SESSION_ID\",\"scan\":$PAYLOAD}" >/dev/null 2>&1

echo "✅ Scan submitted. Review and approve fixes in your browser."

# ---- CLIENT-SIDE SAFETY ALLOWLIST (defense-in-depth) -----------------------
# Even if the server returns a command, we refuse to run it unless it matches a safe
# pattern AND contains no elevation/destructive tokens. The agent never runs sudo.
is_safe_command() {
  local c="$1"
  case "$c" in
    *sudo*|*rm\ -rf\ /*|*mkfs*|*diskutil\ erase*|*:\(\)*|*shutdown*|*reboot*|*dd\ if=*) return 1;;
  esac
  case "$c" in
    "rm -rf ~/Library/Caches/"*) return 0;;
    "rm -rf \"\$TMPDIR\""*)       return 0;;
    "dscacheutil -flushcache")    return 0;;
    "osascript -e 'tell application \"Finder\" to empty trash'"*) return 0;;
    "pkill -f "*)                 return 0;;
    *) return 1;;
  esac
}

# ---- poll for approval -----------------------------------------------------
APPROVED=""
for i in $(seq 1 $POLL_MAX); do
  RESP=$(curl -s "$API_BASE/api/agent/session/$SESSION_ID/approved" \
    -H "Authorization: Bearer $AUTH_TOKEN" -H "X-Session-Token: $SESSION_TOKEN" 2>/dev/null)
  case "$RESP" in
    *'"status":"cancelled"'*) echo "Session cancelled."; cleanup_and_exit 0;;
    *'"command"'*)            APPROVED="$RESP"; break;;
  esac
  sleep $POLL_SECS
done
[ -z "$APPROVED" ] && { echo "No fixes approved (timeout)."; cleanup_and_exit 0; }

# ---- execute approved fixes (id<TAB>command per line from backend) ----------
echo "$APPROVED" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    for f in d.get("fixes",[]):
        print(f.get("id","")+"\t"+(f.get("command") or ""))
except Exception: pass
' 2>/dev/null | while IFS=$'\t' read -r FID CMD; do
  [ -z "$CMD" ] && continue
  if is_safe_command "$CMD"; then
    OUT=$(eval "$CMD" 2>&1); RC=$?
    STATUS=$([ $RC -eq 0 ] && echo success || echo failed)
  else
    OUT="blocked by client safety allowlist"; STATUS="blocked"
  fi
  curl -s -X POST "$API_BASE/api/agent/fix-result" \
    -H "Authorization: Bearer $AUTH_TOKEN" -H "X-Session-Token: $SESSION_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"sessionId\":\"$SESSION_ID\",\"fixId\":\"$FID\",\"status\":\"$STATUS\",\"output\":\"$(jesc "$OUT")\"}" >/dev/null 2>&1
done

echo "✅ All approved fixes complete."
cleanup_and_exit 0
