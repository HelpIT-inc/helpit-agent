#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HELPIT AUTONOMOUS AGENT — macOS
# Version 2.2.0 — Fixed JSON parsing in apply_fixes
# ══════════════════════════════════════════════════════════════════════

HELPIT_API_BASE="https://agent.helpitinc.com"
AGENT_VERSION="2.2.0"
POLL_INTERVAL=8

AUTH_TOKEN="{{AUTH_TOKEN}}"
SESSION_ID="{{SESSION_ID}}"
SESSION_TOKEN="{{SESSION_TOKEN}}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;37m'; NC='\033[0m'

show_banner() {
    clear
    echo ""
    echo -e "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║                                              ║${NC}"
    echo -e "  ${CYAN}║         HELPIT AUTONOMOUS TECHNICIAN         ║${NC}"
    echo -e "  ${CYAN}║                                              ║${NC}"
    echo -e "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

show_ok() { echo -e "  ${GREEN}[OK]${NC} $1"; }
show_fail() { echo -e "  ${RED}[!!]${NC} $1"; }
show_status() { echo -e "  ${YELLOW}$1${NC}"; }

call_api() {
    local method="$1" path="$2" body="$3"
    local url="${HELPIT_API_BASE}${path}"
    local args=(-s -S -H "Content-Type: application/json" -H "Authorization: Bearer $AUTH_TOKEN")
    if [ "$method" = "GET" ]; then
        args+=(-X GET)
    elif [ "$method" = "POST" ]; then
        args+=(-X POST)
        [ -n "$body" ] && args+=(-d "$body")
    elif [ "$method" = "PATCH" ]; then
        args+=(-X PATCH)
        [ -n "$body" ] && args+=(-d "$body")
    fi
    curl "${args[@]}" "$url" 2>/dev/null
}

# Save API response to temp file for safe parsing
call_api_to_file() {
    local method="$1" path="$2" body="$3" outfile="$4"
    local url="${HELPIT_API_BASE}${path}"
    local args=(-s -S -o "$outfile" -H "Content-Type: application/json" -H "Authorization: Bearer $AUTH_TOKEN")
    if [ "$method" = "GET" ]; then
        args+=(-X GET)
    elif [ "$method" = "POST" ]; then
        args+=(-X POST)
        [ -n "$body" ] && args+=(-d "$body")
    elif [ "$method" = "PATCH" ]; then
        args+=(-X PATCH)
        [ -n "$body" ] && args+=(-d "$body")
    fi
    curl "${args[@]}" "$url" 2>/dev/null
}

json_get_safe() {
    local json="$1" key="$2" default="$3"
    echo "$json" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin); val=d$key
    print(val if val is not None else '$default')
except: print('$default')
" 2>/dev/null || echo "$default"
}

json_get_from_file() {
    local file="$1" key="$2" default="$3"
    python3 -c "
import json
try:
    with open('$file') as f:
        d=json.load(f)
    val=d$key
    print(val if val is not None else '$default')
except: print('$default')
" 2>/dev/null || echo "$default"
}

check_auth() {
    if [ ${#AUTH_TOKEN} -gt 10 ] && [[ "$AUTH_TOKEN" == sess_* ]]; then
        show_ok "Authenticated (pre-configured session)"
        return 0
    else
        show_fail "This script was not configured properly."
        echo -e "  ${GRAY}Please download a new copy from the HelpIT portal.${NC}"
        echo -e "  ${GRAY}https://agent.helpitinc.com/helpit-agent/dashboard${NC}"
        read -rp "  Press Enter to exit"
        exit 1
    fi
}

open_portal() {
    local portal_url="${HELPIT_API_BASE}/helpit-agent/session/${SESSION_ID}"
    echo -e "  ${CYAN}Opening your HelpIT dashboard...${NC}"
    echo -e "  ${GRAY}View live results at:${NC}"
    echo -e "  ${YELLOW}$portal_url${NC}"
    echo ""
    open "$portal_url" 2>/dev/null || true
}

run_scan() {
    show_status "Scanning your Mac..."
    call_api "PATCH" "/api/agent/session/$SESSION_ID" '{"status":"scanning"}' > /dev/null

    SCAN_DATA=$(python3 << 'PYEOF'
import json, subprocess, os, platform, time, socket, sys

scan = {}

print("  Scanning: OS info...", file=sys.stderr)
try:
    scan["os"] = {
        "name": subprocess.check_output(["sw_vers", "-productName"], text=True).strip(),
        "version": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
        "build": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
        "architecture": platform.machine(),
    }
    boot = subprocess.check_output(["sysctl", "-n", "kern.boottime"], text=True)
    boot_sec = int(boot.split("sec = ")[1].split(",")[0])
    scan["os"]["uptime_hours"] = round((time.time() - boot_sec) / 3600, 1)
except Exception as e:
    scan["os"] = {"name": "macOS", "error": str(e)}

print("  Scanning: Hardware...", file=sys.stderr)
mem_total_gb = 8
try:
    cpu = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
    mem_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip())
    mem_total_gb = round(mem_bytes / (1024**3), 1)
    vm = subprocess.check_output(["vm_stat"], text=True)
    pages_free = int([l for l in vm.split("\n") if "Pages free" in l][0].split(":")[1].strip().rstrip("."))
    pages_inactive = int([l for l in vm.split("\n") if "Pages inactive" in l][0].split(":")[1].strip().rstrip("."))
    available_gb = round((pages_free + pages_inactive) * 4096 / (1024**3), 1)
    df = subprocess.check_output(["df", "-g", "/"], text=True).split("\n")[1].split()
    scan["hardware"] = {
        "cpu": cpu, "ram_total_gb": mem_total_gb, "ram_available_gb": available_gb,
        "disk_total_gb": int(df[1]), "disk_free_gb": int(df[3]),
    }
except Exception as e:
    scan["hardware"] = {"error": str(e)}

print("  Scanning: Security...", file=sys.stderr)
try:
    fw = subprocess.check_output(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"], text=True)
    try:
        updates = subprocess.check_output(["softwareupdate", "-l", "--no-scan"], text=True, timeout=10)
        pending = updates.count("* Label:")
    except:
        pending = -1
    scan["security"] = {"antivirus": "macOS XProtect", "firewall_enabled": "enabled" in fw.lower(), "pending_updates": pending}
except Exception as e:
    scan["security"] = {"error": str(e)}

print("  Scanning: Startup programs...", file=sys.stderr)
try:
    agents = []
    for d in [os.path.expanduser("~/Library/LaunchAgents"), "/Library/LaunchAgents"]:
        if os.path.isdir(d):
            for f in os.listdir(d):
                if f.endswith(".plist"):
                    agents.append({"name": f.replace(".plist",""), "enabled": True, "impact": "medium"})
    scan["startup_programs"] = agents
except:
    scan["startup_programs"] = []

print("  Scanning: Processes...", file=sys.stderr)
try:
    ps = subprocess.check_output(["ps", "aux"], text=True)
    lines = ps.strip().split("\n")[1:]
    scan["running_processes"] = len(lines)
    top_procs = []
    for line in sorted(lines, key=lambda l: float(l.split()[3]) if len(l.split()) > 3 else 0, reverse=True)[:10]:
        parts = line.split()
        if len(parts) > 10:
            try:
                top_procs.append({"name": parts[10].split("/")[-1], "memory_mb": round(float(parts[3]) * mem_total_gb * 1024 / 100, 0)})
            except:
                pass
    scan["top_processes"] = top_procs
except:
    scan["running_processes"] = 0

print("  Scanning: Network...", file=sys.stderr)
try:
    dns_working = True
    try:
        socket.getaddrinfo("www.google.com", 80)
    except:
        dns_working = False
    dns_out = subprocess.check_output(["scutil", "--dns"], text=True)
    dns_list = list(set([l.split(":")[1].strip() for l in dns_out.split("\n") if "nameserver" in l][:4]))
    scan["network"] = {"dns_working": dns_working, "dns": dns_list}
except:
    scan["network"] = {"dns_working": True}

print("  Scanning: Cache files...", file=sys.stderr)
try:
    cache_size = 0
    for d in [os.path.expanduser("~/Library/Caches"), "/tmp"]:
        if os.path.isdir(d):
            for root, dirs, files in os.walk(d):
                for f in files:
                    try:
                        cache_size += os.path.getsize(os.path.join(root, f))
                    except:
                        pass
    scan["temp_files_gb"] = round(cache_size / (1024**3), 2)
except:
    scan["temp_files_gb"] = 0

print("  Scanning: Apps & extensions...", file=sys.stderr)
try:
    ext = 0
    for d in [os.path.expanduser("~/Library/Application Support/Google/Chrome/Default/Extensions"),
              os.path.expanduser("~/Library/Safari/Extensions")]:
        if os.path.isdir(d):
            ext += len(os.listdir(d))
    scan["browser_extensions"] = ext
except:
    scan["browser_extensions"] = 0

try:
    scan["installed_programs_count"] = len([a for a in os.listdir("/Applications") if a.endswith(".app")])
except:
    scan["installed_programs_count"] = 0

print(json.dumps(scan))
PYEOF
)

    echo ""
    show_ok "Scan complete!"
}

submit_scan() {
    show_status "Sending to AI for analysis... (15-30 seconds)"

    # Save scan data to temp file to avoid quoting issues
    local scan_file="/tmp/helpit_scan_$$.json"
    echo "$SCAN_DATA" > "$scan_file"

    local body
    body=$(python3 -c "
import json
with open('$scan_file') as f:
    scan = json.load(f)
print(json.dumps({'session_token': '$SESSION_TOKEN', 'scan_data': scan}))
")
    rm -f "$scan_file"

    ANALYSIS_RESULT=$(call_api "POST" "/api/agent/scan" "$body")

    local ok
    ok=$(json_get_safe "$ANALYSIS_RESULT" "['ok']" "false")
    if [ "$ok" != "True" ] && [ "$ok" != "true" ]; then
        show_fail "AI analysis failed."
        return 1
    fi

    show_ok "Analysis complete! Check your browser for results."
    echo ""

    local health summary issue_count
    health=$(json_get_safe "$ANALYSIS_RESULT" "['analysis']['overallHealth']" "unknown")
    summary=$(json_get_safe "$ANALYSIS_RESULT" "['analysis']['summary']" "")
    issue_count=$(json_get_safe "$ANALYSIS_RESULT" "['analysis']['issueCount']" "0")

    local health_color="$WHITE"
    case "$health" in
        good) health_color="$GREEN" ;;
        fair) health_color="$YELLOW" ;;
        poor|critical) health_color="$RED" ;;
    esac

    echo -e "  Health: ${health_color}$(echo "$health" | tr '[:lower:]' '[:upper:]')${NC}"
    echo -e "  ${GRAY}$summary${NC}"
    echo -e "  Found ${WHITE}$issue_count issue(s)${NC}"
    echo ""
    return 0
}

wait_for_approval() {
    show_status "Waiting for you to approve fixes in the browser..."
    echo -e "  ${GRAY}(You can minimize this window)${NC}"

    APPROVAL_FILE="/tmp/helpit_approval_$$.json"

    local elapsed=0 max_wait=600
    while [ $elapsed -lt $max_wait ]; do
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))

        # Save response to file instead of variable (avoids quoting issues)
        call_api_to_file "GET" "/api/agent/session/$SESSION_ID" "" "$APPROVAL_FILE"

        local status
        status=$(json_get_from_file "$APPROVAL_FILE" "['session']['status']" "")

        if [ "$status" = "fixing" ]; then
            echo ""
            show_ok "Fixes approved! Applying now..."
            return 0
        elif [ "$status" = "cancelled" ]; then
            echo ""
            show_status "Session cancelled. No changes made."
            rm -f "$APPROVAL_FILE"
            return 1
        fi
    done

    echo ""
    show_fail "Timed out (10 minutes)."
    rm -f "$APPROVAL_FILE"
    return 1
}

# ══════════════════════════════════════════════════════════════════════
# APPLY FIXES — Fixed: reads JSON from temp file, not inline heredoc
# ══════════════════════════════════════════════════════════════════════

apply_fixes() {
    show_status "Applying fixes..."

    tmutil localsnapshot / 2>/dev/null && show_ok "Safety snapshot created." || true
    echo ""

    # Use the temp file saved during approval polling
    python3 << PYEOF
import json, subprocess, sys, urllib.request

try:
    with open("$APPROVAL_FILE") as f:
        data = json.load(f)

    fixes = data.get("session", {}).get("fixes_approved", [])
    if not fixes:
        print("  No fixes to apply.")
        sys.exit(0)

    total = len(fixes)
    for i, fix in enumerate(fixes, 1):
        title = fix.get("title", "Unknown")
        fix_info = fix.get("fix", {})
        command = fix_info.get("command", "")
        description = fix_info.get("description", "")

        print(f"  [{i}/{total}] \033[1;37m{title}\033[0m")
        print(f"    Running: {description}")

        result = "success"
        error_details = None

        if command:
            try:
                output = subprocess.run(
                    command, shell=True, capture_output=True, text=True, timeout=120
                )
                if output.returncode == 0:
                    print(f"  \033[0;32m[OK]\033[0m {description}")
                else:
                    result = "failed"
                    error_details = output.stderr[:200] if output.stderr else f"Exit code {output.returncode}"
                    print(f"  \033[0;31m[!!]\033[0m {error_details}")
            except subprocess.TimeoutExpired:
                result = "failed"
                error_details = "Command timed out after 120 seconds"
                print(f"  \033[0;31m[!!]\033[0m Timed out")
            except Exception as e:
                result = "failed"
                error_details = str(e)
                print(f"  \033[0;31m[!!]\033[0m {e}")
        else:
            result = "success"
            print(f"  \033[0;32m[OK]\033[0m Manual recommendation noted")

        # Report result to server
        try:
            body = json.dumps({
                "session_token": "$SESSION_TOKEN",
                "fix_id": title,
                "result": result,
                "error_details": error_details
            }).encode()
            req = urllib.request.Request(
                "$HELPIT_API_BASE/api/agent/fix-result",
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": "Bearer $AUTH_TOKEN"
                },
                method="POST"
            )
            resp = urllib.request.urlopen(req, timeout=10)
            resp_data = json.loads(resp.read())
            if resp_data.get("allComplete"):
                print(f"\n  \033[0;32m[OK] All fixes complete!\033[0m")
        except Exception as e:
            print(f"    Warning: Could not report result: {e}", file=sys.stderr)

        print()

except Exception as e:
    print(f"  \033[0;31mError applying fixes: {e}\033[0m", file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
PYEOF
}

cleanup() {
    # Clean up temp files
    rm -f "$APPROVAL_FILE" 2>/dev/null
    rm -f /tmp/helpit_scan_$$.json 2>/dev/null

    echo ""
    echo -e "  ${GREEN}All done! Check your browser for the full report.${NC}"
    echo -e "  ${GRAY}This window will close in 10 seconds.${NC}"
    sleep 10

    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    (sleep 3 && rm -f "$script_path") &
}

main() {
    show_banner
    check_auth
    open_portal
    run_scan

    if ! submit_scan; then
        call_api "PATCH" "/api/agent/session/$SESSION_ID" '{"status":"failed","error_message":"AI analysis failed"}' > /dev/null
        show_fail "Could not analyze. Please try again."
        sleep 5
        exit 1
    fi

    local issue_count
    issue_count=$(json_get_safe "$ANALYSIS_RESULT" "['analysis']['issueCount']" "0")
    if [ "$issue_count" = "0" ]; then
        show_ok "No issues found! Your Mac is healthy."
        cleanup
        exit 0
    fi

    if ! wait_for_approval; then
        exit 0
    fi

    apply_fixes
    cleanup
}

main "$@"
