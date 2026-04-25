#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# HELPIT AUTONOMOUS AGENT — macOS
# Version 1.0.0
# ══════════════════════════════════════════════════════════════════════
#
# This script is downloaded from the HelpIT portal.
# It scans the customer's Mac, sends data to HelpIT's AI,
# waits for approval on the portal, fixes issues, and cleans up.
#
# TO RUN: Open Terminal, then drag this file in and press Enter
# Or: chmod +x helpit-agent-mac.sh && ./helpit-agent-mac.sh
# ══════════════════════════════════════════════════════════════════════

HELPIT_API_BASE="https://YOUR_DOMAIN"
AGENT_VERSION="1.0.0"
POLL_INTERVAL=8
TOKEN_DIR="$HOME/.helpit"
TOKEN_FILE="$TOKEN_DIR/token.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# ── DISPLAY HELPERS ────────────────────────────────────────────────

show_banner() {
    clear
    echo ""
    echo -e "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║                                              ║${NC}"
    echo -e "  ${CYAN}║         HELPIT AUTONOMOUS TECHNICIAN         ║${NC}"
    echo -e "  ${CYAN}║         AI-Powered Computer Repair            ║${NC}"
    echo -e "  ${CYAN}║                                              ║${NC}"
    echo -e "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

show_step() {
    echo ""
    echo -e "  ${GRAY}── STEP $1 ──────────────────────────────────${NC}"
    echo -e "  ${WHITE}$2${NC}"
    echo ""
}

show_ok() {
    echo -e "    ${GREEN}[OK]${NC} $1"
}

show_fail() {
    echo -e "    ${RED}[!!]${NC} $1"
}

show_status() {
    echo -e "    ${YELLOW}$1${NC}"
}

# ── API HELPER ─────────────────────────────────────────────────────

call_api() {
    local method="$1"
    local path="$2"
    local token="$3"
    local body="$4"

    local url="${HELPIT_API_BASE}${path}"
    local args=(-s -S -w "\n%{http_code}" -H "Content-Type: application/json")

    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi

    if [ "$method" = "GET" ]; then
        args+=(-X GET)
    elif [ "$method" = "POST" ]; then
        args+=(-X POST)
        if [ -n "$body" ]; then
            args+=(-d "$body")
        fi
    elif [ "$method" = "PATCH" ]; then
        args+=(-X PATCH)
        if [ -n "$body" ]; then
            args+=(-d "$body")
        fi
    fi

    local response
    response=$(curl "${args[@]}" "$url" 2>/dev/null)

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body_text
    body_text=$(echo "$response" | sed '$d')

    echo "$body_text"
    return 0
}

# ── JSON HELPERS (using Python since macOS has it) ─────────────────

json_get() {
    local json="$1"
    local key="$2"
    echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d$key)" 2>/dev/null
}

json_get_safe() {
    local json="$1"
    local key="$2"
    local default="$3"
    local result
    result=$(echo "$json" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    val=d$key
    print(val if val is not None else '$default')
except:
    print('$default')
" 2>/dev/null)
    echo "${result:-$default}"
}


# ══════════════════════════════════════════════════════════════════════
# STEP 1-3: AUTHENTICATION
# ══════════════════════════════════════════════════════════════════════

get_auth_token() {
    show_step "1 of 8" "Authentication"

    # Check saved token
    if [ -f "$TOKEN_FILE" ]; then
        local saved_token
        saved_token=$(json_get "$(cat "$TOKEN_FILE")" "['token']")
        local expires
        expires=$(json_get "$(cat "$TOKEN_FILE")" "['expiresAt']")

        if [ -n "$saved_token" ] && [ -n "$expires" ]; then
            # Simple expiry check
            local exp_epoch
            exp_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${expires%%.*}" "+%s" 2>/dev/null || echo 0)
            local now_epoch
            now_epoch=$(date "+%s")

            if [ "$exp_epoch" -gt "$now_epoch" ] 2>/dev/null; then
                show_ok "Found saved session. Welcome back!"
                AUTH_TOKEN="$saved_token"
                return 0
            fi
        fi
        show_status "Saved session expired. Please log in again."
    fi

    # Prompt for phone
    echo -e "    ${GRAY}Log in with your HelpIT account phone number.${NC}"
    echo ""
    read -rp "    Enter your phone number (e.g. +15551234567): " phone
    phone=$(echo "$phone" | xargs)  # trim

    if [[ ! "$phone" == +* ]]; then
        phone="+1$phone"
    fi

    # Request SMS code
    show_status "Sending verification code to $phone..."
    local result
    result=$(call_api "POST" "/api/customer-auth/request-code" "" "{\"phone\":\"$phone\"}")

    local ok
    ok=$(json_get_safe "$result" "['ok']" "false")
    if [ "$ok" != "True" ] && [ "$ok" != "true" ]; then
        show_fail "Could not send code. Check your phone number."
        read -rp "  Press Enter to exit"
        exit 1
    fi

    show_ok "Code sent! Check your text messages."
    echo ""

    read -rp "    Enter the 6-digit code: " code
    code=$(echo "$code" | xargs)

    # Verify code
    show_status "Verifying..."
    local verify
    verify=$(call_api "POST" "/api/customer-auth/verify-code" "" "{\"phone\":\"$phone\",\"code\":\"$code\"}")

    local token
    token=$(json_get_safe "$verify" "['token']" "")
    if [ -z "$token" ]; then
        show_fail "Invalid code. Please try again."
        read -rp "  Press Enter to exit"
        exit 1
    fi

    # Save token
    mkdir -p "$TOKEN_DIR"
    echo "$verify" > "$TOKEN_FILE"

    show_ok "Logged in successfully!"
    AUTH_TOKEN="$token"
}


# ══════════════════════════════════════════════════════════════════════
# STEP 4: CHECK SUBSCRIPTION
# ══════════════════════════════════════════════════════════════════════

check_subscription() {
    show_step "2 of 8" "Checking your subscription"

    local status
    status=$(call_api "GET" "/api/agent/status" "$AUTH_TOKEN")

    local has_access
    has_access=$(json_get_safe "$status" "['hasAutonomousAccess']" "false")

    if [ "$has_access" != "True" ] && [ "$has_access" != "true" ]; then
        show_fail "Your plan does not include HELPIT Autonomous."
        echo -e "    ${YELLOW}Upgrade in the HelpIT mobile app.${NC}"
        read -rp "  Press Enter to exit"
        exit 1
    fi

    local tier remaining sessions_used sessions_per_month
    tier=$(json_get_safe "$status" "['access']['tier']" "unknown")
    remaining=$(json_get_safe "$status" "['access']['remaining']" "0")
    sessions_used=$(json_get_safe "$status" "['access']['sessionsUsed']" "0")
    sessions_per_month=$(json_get_safe "$status" "['access']['sessionsPerMonth']" "0")
    local full_name
    full_name=$(json_get_safe "$status" "['user']['full_name']" "User")

    local is_unlimited
    is_unlimited=$(json_get_safe "$status" "['access']['isUnlimited']" "false")

    if [ "$is_unlimited" != "True" ] && [ "$is_unlimited" != "true" ] && [ "$remaining" = "0" ]; then
        show_fail "You've used all $sessions_per_month sessions this month."
        echo -e "    ${YELLOW}Sessions reset at the start of your next billing period.${NC}"
        read -rp "  Press Enter to exit"
        exit 1
    fi

    show_ok "Plan: $(echo "$tier" | tr '[:lower:]' '[:upper:]')  |  Sessions: ${sessions_used}/${sessions_per_month}  |  ${remaining} remaining"
    echo -e "    ${CYAN}Welcome, $full_name!${NC}"

    STATUS_JSON="$status"
}


# ══════════════════════════════════════════════════════════════════════
# STEP 5: CREATE SESSION
# ══════════════════════════════════════════════════════════════════════

create_session() {
    show_step "3 of 8" "Starting repair session"

    local os_version
    os_version=$(sw_vers -productVersion 2>/dev/null || echo "macOS Unknown")
    local os_name
    os_name=$(sw_vers -productName 2>/dev/null || echo "macOS")

    local result
    result=$(call_api "POST" "/api/agent/session" "$AUTH_TOKEN" \
        "{\"os_type\":\"mac\",\"os_version\":\"$os_name $os_version\",\"agent_version\":\"$AGENT_VERSION\"}")

    SESSION_ID=$(json_get_safe "$result" "['session']['id']" "")
    SESSION_TOKEN=$(json_get_safe "$result" "['session']['session_token']" "")

    if [ -z "$SESSION_ID" ]; then
        show_fail "Could not start session."
        local err
        err=$(json_get_safe "$result" "['error']" "Unknown error")
        show_fail "Error: $err"
        read -rp "  Press Enter to exit"
        exit 1
    fi

    local remaining
    remaining=$(json_get_safe "$result" "['access']['remaining']" "?")
    show_ok "Session created: ${SESSION_ID:0:8}..."
    show_ok "Remaining after this: $remaining"
}


# ══════════════════════════════════════════════════════════════════════
# STEP 6-7: SCAN THE MAC
# ══════════════════════════════════════════════════════════════════════

run_system_scan() {
    show_step "4 of 8" "Scanning your Mac"

    # Update status
    call_api "PATCH" "/api/agent/session/$SESSION_ID" "$AUTH_TOKEN" '{"status":"scanning"}' > /dev/null

    # Build scan data using Python for proper JSON
    local scan_json
    scan_json=$(python3 << 'PYEOF'
import json, subprocess, os, platform, time, socket

scan = {}

# OS Info
try:
    scan["os"] = {
        "name": subprocess.check_output(["sw_vers", "-productName"], text=True).strip(),
        "version": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
        "build": subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(),
        "architecture": platform.machine(),
    }
    # Uptime
    boot = subprocess.check_output(["sysctl", "-n", "kern.boottime"], text=True)
    boot_sec = int(boot.split("sec = ")[1].split(",")[0])
    scan["os"]["uptime_hours"] = round((time.time() - boot_sec) / 3600, 1)
except Exception as e:
    scan["os"] = {"name": "macOS", "error": str(e)}

print("  Scanning: OS info...", file=__import__('sys').stderr)

# Hardware
try:
    cpu = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
    mem_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip())
    mem_total_gb = round(mem_bytes / (1024**3), 1)

    vm = subprocess.check_output(["vm_stat"], text=True)
    pages_free = int([l for l in vm.split("\n") if "Pages free" in l][0].split(":")[1].strip().rstrip("."))
    pages_inactive = int([l for l in vm.split("\n") if "Pages inactive" in l][0].split(":")[1].strip().rstrip("."))
    available_gb = round((pages_free + pages_inactive) * 4096 / (1024**3), 1)

    df = subprocess.check_output(["df", "-g", "/"], text=True).split("\n")[1].split()
    disk_total = int(df[1])
    disk_free = int(df[3])

    scan["hardware"] = {
        "cpu": cpu,
        "ram_total_gb": mem_total_gb,
        "ram_available_gb": available_gb,
        "disk_total_gb": disk_total,
        "disk_free_gb": disk_free,
    }
except Exception as e:
    scan["hardware"] = {"error": str(e)}

print("  Scanning: Hardware...", file=__import__('sys').stderr)

# Security
try:
    firewall = subprocess.check_output(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"], text=True)
    fw_enabled = "enabled" in firewall.lower()

    # Check for pending software updates
    try:
        updates = subprocess.check_output(["softwareupdate", "-l", "--no-scan"], text=True, timeout=10)
        pending = updates.count("* Label:")
    except:
        pending = -1

    scan["security"] = {
        "antivirus": "macOS XProtect (built-in)",
        "firewall_enabled": fw_enabled,
        "pending_updates": pending,
    }
except Exception as e:
    scan["security"] = {"error": str(e)}

print("  Scanning: Security...", file=__import__('sys').stderr)

# Startup Programs (Launch Agents)
try:
    launch_agents = []
    dirs = [
        os.path.expanduser("~/Library/LaunchAgents"),
        "/Library/LaunchAgents",
    ]
    for d in dirs:
        if os.path.isdir(d):
            for f in os.listdir(d):
                if f.endswith(".plist"):
                    launch_agents.append({"name": f.replace(".plist",""), "enabled": True, "impact": "medium"})
    scan["startup_programs"] = launch_agents
except:
    scan["startup_programs"] = []

print("  Scanning: Startup programs...", file=__import__('sys').stderr)

# Running Processes
try:
    ps = subprocess.check_output(["ps", "aux"], text=True)
    lines = ps.strip().split("\n")[1:]
    scan["running_processes"] = len(lines)

    # Top memory consumers
    top = subprocess.check_output(["ps", "aux", "--sort=-%mem"], text=True).split("\n")[1:11]
    top_procs = []
    for line in top:
        parts = line.split()
        if len(parts) > 10:
            top_procs.append({
                "name": parts[10].split("/")[-1],
                "memory_mb": round(float(parts[3]) * mem_total_gb * 1024 / 100, 0),
            })
    scan["top_processes"] = top_procs
except:
    scan["running_processes"] = 0

print("  Scanning: Processes...", file=__import__('sys').stderr)

# Network
try:
    dns_working = True
    try:
        socket.getaddrinfo("www.google.com", 80)
    except:
        dns_working = False

    dns_servers = subprocess.check_output(["scutil", "--dns"], text=True)
    dns_list = [l.split(":")[1].strip() for l in dns_servers.split("\n") if "nameserver" in l][:4]

    scan["network"] = {
        "dns_working": dns_working,
        "dns": list(set(dns_list)),
    }
except:
    scan["network"] = {"dns_working": True}

print("  Scanning: Network...", file=__import__('sys').stderr)

# Temp/Cache files
try:
    cache_size = 0
    cache_dirs = [
        os.path.expanduser("~/Library/Caches"),
        "/tmp",
    ]
    for d in cache_dirs:
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

print("  Scanning: Cache files...", file=__import__('sys').stderr)

# Browser extensions
try:
    ext_count = 0
    chrome_ext = os.path.expanduser("~/Library/Application Support/Google/Chrome/Default/Extensions")
    safari_ext = os.path.expanduser("~/Library/Safari/Extensions")
    if os.path.isdir(chrome_ext):
        ext_count += len(os.listdir(chrome_ext))
    if os.path.isdir(safari_ext):
        ext_count += len(os.listdir(safari_ext))
    scan["browser_extensions"] = ext_count
except:
    scan["browser_extensions"] = 0

# Installed apps count
try:
    apps = os.listdir("/Applications")
    scan["installed_programs_count"] = len([a for a in apps if a.endswith(".app")])
except:
    scan["installed_programs_count"] = 0

print(json.dumps(scan))
PYEOF
)

    echo ""
    show_ok "Scan complete!"

    SCAN_DATA="$scan_json"
}


# ══════════════════════════════════════════════════════════════════════
# STEP 8: SUBMIT TO AI
# ══════════════════════════════════════════════════════════════════════

submit_scan_data() {
    show_step "5 of 8" "Sending to AI for analysis"
    show_status "Claude AI is analyzing your system... (15-30 seconds)"

    local body
    body=$(python3 -c "
import json, sys
scan = json.loads('''$SCAN_DATA''')
payload = {'session_token': '$SESSION_TOKEN', 'scan_data': scan}
print(json.dumps(payload))
")

    ANALYSIS_RESULT=$(call_api "POST" "/api/agent/scan" "$AUTH_TOKEN" "$body")

    local ok
    ok=$(json_get_safe "$ANALYSIS_RESULT" "['ok']" "false")

    if [ "$ok" != "True" ] && [ "$ok" != "true" ]; then
        show_fail "AI analysis failed."
        return 1
    fi

    show_ok "Analysis complete!"
    echo ""

    # Display summary
    local health summary issue_count critical_count
    health=$(json_get_safe "$ANALYSIS_RESULT" "['analysis']['overallHealth']" "unknown")
    summary=$(json_get_safe "$ANALYSIS_RESULT" "['analysis']['summary']" "Analysis complete.")
    issue_count=$(json_get_safe "$ANALYSIS_RESULT" "['analysis']['issueCount']" "0")
    critical_count=$(json_get_safe "$ANALYSIS_RESULT" "['analysis']['criticalCount']" "0")

    local health_color="$WHITE"
    case "$health" in
        good) health_color="$GREEN" ;;
        fair) health_color="$YELLOW" ;;
        poor|critical) health_color="$RED" ;;
    esac

    echo -e "    Health: ${health_color}$(echo "$health" | tr '[:lower:]' '[:upper:]')${NC}"
    echo -e "    ${GRAY}$summary${NC}"
    echo ""
    echo -e "    Found ${WHITE}$issue_count issue(s)${NC}"
    if [ "$critical_count" != "0" ]; then
        echo -e "    ${RED}($critical_count critical)${NC}"
    fi

    # Display individual issues
    python3 << PYEOF
import json, sys
try:
    data = json.loads('''$(echo "$ANALYSIS_RESULT" | sed "s/'/\\\\'/g")''')
    issues = data.get("analysis", {}).get("issues", [])
    for issue in issues:
        sev = issue.get("severity", "low").upper()
        color = {"CRITICAL": "\033[0;31m", "HIGH": "\033[0;31m", "MEDIUM": "\033[1;33m", "LOW": "\033[0;32m"}.get(sev, "\033[0;37m")
        print(f"\n    {color}[{sev}]\033[0m \033[1;37m{issue.get('title','')}\033[0m")
        print(f"      \033[0;37m{issue.get('description','')}\033[0m")
        fix = issue.get("fix", {})
        print(f"      \033[0;36mFix: {fix.get('description','N/A')}\033[0m")
except Exception as e:
    print(f"    Could not display issues: {e}", file=sys.stderr)
PYEOF

    echo ""
    return 0
}


# ══════════════════════════════════════════════════════════════════════
# STEP 9: WAIT FOR APPROVAL
# ══════════════════════════════════════════════════════════════════════

wait_for_approval() {
    show_step "6 of 8" "Waiting for your approval"

    local portal_url="${HELPIT_API_BASE}/helpit-agent/session/${SESSION_ID}"

    echo -e "  ${CYAN}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${CYAN}│                                                    │${NC}"
    echo -e "  ${CYAN}│  Review and approve fixes at:                      │${NC}"
    echo -e "  ${CYAN}│                                                    │${NC}"
    echo -e "  ${YELLOW}│  $portal_url${NC}"
    echo -e "  ${CYAN}│                                                    │${NC}"
    echo -e "  ${CYAN}│  Or approve in the HelpIT mobile app.              │${NC}"
    echo -e "  ${CYAN}│                                                    │${NC}"
    echo -e "  ${CYAN}└────────────────────────────────────────────────────┘${NC}"
    echo ""

    # Open browser
    open "$portal_url" 2>/dev/null || true

    # Poll for approval
    local elapsed=0
    local max_wait=600

    while [ $elapsed -lt $max_wait ]; do
        echo -ne "\r    ${YELLOW}Waiting for approval...${NC}   "
        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))

        local session_data
        session_data=$(call_api "GET" "/api/agent/session/$SESSION_ID" "$AUTH_TOKEN")

        local status
        status=$(json_get_safe "$session_data" "['session']['status']" "")

        if [ "$status" = "fixing" ]; then
            echo ""
            show_ok "Fixes approved! Starting repairs..."
            APPROVED_FIXES="$session_data"
            return 0
        elif [ "$status" = "cancelled" ]; then
            echo ""
            show_status "Session cancelled. No changes made."
            return 1
        fi
    done

    echo ""
    show_fail "Timed out (10 minutes). No changes made."
    return 1
}


# ══════════════════════════════════════════════════════════════════════
# STEP 10: APPLY FIXES
# ══════════════════════════════════════════════════════════════════════

apply_fixes() {
    show_step "7 of 8" "Fixing your Mac"

    # Create Time Machine snapshot if possible
    echo -e "    ${YELLOW}Creating safety snapshot...${NC}"
    tmutil localsnapshot / 2>/dev/null && show_ok "Time Machine snapshot created." || show_status "Snapshot skipped (not critical)."
    echo ""

    # Extract and execute fixes
    python3 << PYEOF
import json, subprocess, sys, os

try:
    data = json.loads('''$(echo "$APPROVED_FIXES" | sed "s/'/\\\\'/g")''')
    fixes = data.get("session", {}).get("fixes_approved", [])

    if not fixes:
        print("    No fixes to apply.")
        sys.exit(0)

    total = len(fixes)
    for i, fix in enumerate(fixes, 1):
        title = fix.get("title", "Unknown fix")
        fix_info = fix.get("fix", {})
        command = fix_info.get("command", "")
        description = fix_info.get("description", "")

        print(f"\n    [{i}/{total}] \033[1;37m{title}\033[0m")
        print(f"      Running: {description}")

        result = "success"
        error_details = None

        if command:
            try:
                output = subprocess.run(
                    command, shell=True, capture_output=True, text=True, timeout=120
                )
                if output.returncode == 0:
                    print(f"    \033[0;32m[OK]\033[0m {description} — Done")
                else:
                    result = "failed"
                    error_details = output.stderr[:200] if output.stderr else "Non-zero exit code"
                    print(f"    \033[0;31m[!!]\033[0m Failed: {error_details}")
            except subprocess.TimeoutExpired:
                result = "failed"
                error_details = "Command timed out after 120 seconds"
                print(f"    \033[0;31m[!!]\033[0m Timed out")
            except Exception as e:
                result = "failed"
                error_details = str(e)
                print(f"    \033[0;31m[!!]\033[0m Error: {e}")
        else:
            print(f"    \033[0;32m[OK]\033[0m Noted in report (no automated command)")

        # Report result to server
        import urllib.request
        report_body = json.dumps({
            "session_token": "$SESSION_TOKEN",
            "fix_id": title,
            "result": result,
            "error_details": error_details
        }).encode()
        req = urllib.request.Request(
            "${HELPIT_API_BASE}/api/agent/fix-result",
            data=report_body,
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer $AUTH_TOKEN"
            },
            method="POST"
        )
        try:
            urllib.request.urlopen(req, timeout=10)
        except:
            pass

except Exception as e:
    print(f"    Error applying fixes: {e}", file=sys.stderr)
PYEOF
}


# ══════════════════════════════════════════════════════════════════════
# STEP 11: COMPLETE AND CLEAN UP
# ══════════════════════════════════════════════════════════════════════

complete_session() {
    show_step "8 of 8" "Session complete"

    echo -e "  ${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║                                              ║${NC}"
    echo -e "  ${GREEN}║     SESSION COMPLETE                         ║${NC}"
    echo -e "  ${GREEN}║                                              ║${NC}"
    echo -e "  ${GREEN}║     View full report in your HelpIT portal.  ║${NC}"
    echo -e "  ${GREEN}║     Undo via Time Machine if needed.         ║${NC}"
    echo -e "  ${GREEN}║                                              ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "    ${GRAY}This window will close in 15 seconds.${NC}"
    echo -e "    ${GRAY}The agent will delete itself.${NC}"
    echo ""

    sleep 15

    # Clean up token
    rm -f "$TOKEN_FILE" 2>/dev/null
    rmdir "$TOKEN_DIR" 2>/dev/null

    # Self-delete
    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    (sleep 3 && rm -f "$script_path") &
}


# ══════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════

main() {
    show_banner

    # 1-3. Auth
    get_auth_token

    # 4. Check subscription
    check_subscription

    # 5. Create session
    create_session

    # 6-7. Scan
    run_system_scan

    # 8. Submit to AI
    if ! submit_scan_data; then
        call_api "PATCH" "/api/agent/session/$SESSION_ID" "$AUTH_TOKEN" '{"status":"failed","error_message":"AI analysis failed"}' > /dev/null
        read -rp "  Press Enter to exit"
        exit 1
    fi

    local issue_count
    issue_count=$(json_get_safe "$ANALYSIS_RESULT" "['analysis']['issueCount']" "0")

    if [ "$issue_count" = "0" ]; then
        show_ok "No issues found! Your Mac is healthy."
        complete_session
        exit 0
    fi

    # 9. Wait for approval
    if ! wait_for_approval; then
        exit 0
    fi

    # 10. Apply fixes
    apply_fixes

    # 11. Done
    complete_session
}

main "$@"
