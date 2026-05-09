#!/bin/bash
# HelpIT Autonomous Agent — macOS Comprehensive Scan (v3.0)
# - Minimizes Terminal on launch
# - Submits scan_data to /api/agent/scan
# - Closes Terminal automatically and self-deletes when done

set -u

AUTH_TOKEN="{{AUTH_TOKEN}}"
SESSION_TOKEN="{{SESSION_TOKEN}}"
API_BASE="https://www.helpitinc.com"
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"

# Minimize Terminal
osascript -e 'tell application "System Events" to set visible of process "Terminal" to false' >/dev/null 2>&1 &

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

echo "🔍 Scanning..."

# 1. STORAGE
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

# 2. MEMORY
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

# 3. CPU
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

# 4. STARTUP
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
LA
