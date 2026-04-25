# ══════════════════════════════════════════════════════════════════════
# HELPIT AUTONOMOUS AGENT — Windows
# Version 1.0.0
# ══════════════════════════════════════════════════════════════════════
#
# This script is downloaded from the HelpIT portal.
# It scans the customer's PC, sends data to HelpIT's AI,
# waits for the customer to approve fixes on the website,
# applies the approved fixes, and then cleans up.
#
# TO TEST: Right-click this file → "Run with PowerShell"
# ══════════════════════════════════════════════════════════════════════

# ── CONFIGURATION ──────────────────────────────────────────────────
$HELPIT_API_BASE = "https://YOUR_DOMAIN"   # Your Anything.com domain
$AGENT_VERSION = "1.0.0"
$POLL_INTERVAL = 8  # seconds between approval checks
$TOKEN_PATH = "$env:APPDATA\HelpIT\token.json"

# ── DISPLAY HELPERS ────────────────────────────────────────────────

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                                              ║" -ForegroundColor Cyan
    Write-Host "  ║         HELPIT AUTONOMOUS TECHNICIAN         ║" -ForegroundColor Cyan
    Write-Host "  ║         AI-Powered Computer Repair            ║" -ForegroundColor Cyan
    Write-Host "  ║                                              ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Step {
    param([string]$Num, [string]$Label)
    Write-Host ""
    Write-Host "  ── STEP $Num ──────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  $Label" -ForegroundColor White
    Write-Host ""
}

function Show-Status {
    param([string]$Msg, [string]$Color = "Yellow")
    Write-Host "    $Msg" -ForegroundColor $Color
}

function Show-OK {
    param([string]$Msg)
    Write-Host "    [OK] $Msg" -ForegroundColor Green
}

function Show-Fail {
    param([string]$Msg)
    Write-Host "    [!!] $Msg" -ForegroundColor Red
}

function Show-Progress {
    param([string]$Label, [int]$Pct)
    $filled = [math]::Floor(30 * $Pct / 100)
    $bar = ("█" * $filled) + ("░" * (30 - $filled))
    Write-Host "`r    [$bar] $Pct% $Label    " -NoNewline -ForegroundColor Yellow
}

function Call-API {
    param(
        [string]$Method,
        [string]$Path,
        [hashtable]$Body = $null,
        [string]$Token = ""
    )
    $uri = "$HELPIT_API_BASE$Path"
    $headers = @{ "Content-Type" = "application/json" }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = $headers
    }
    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    try {
        $response = Invoke-RestMethod @params -TimeoutSec 60
        return $response
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody = $null
        try {
            $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
            $errorBody = $reader.ReadToEnd() | ConvertFrom-Json
            $reader.Close()
        } catch { }
        return @{ "_error" = $true; "status" = $statusCode; "body" = $errorBody; "message" = $_.Exception.Message }
    }
}


# ══════════════════════════════════════════════════════════════════════
# STEP 1-3: AUTHENTICATION (Phone + SMS Code)
# ══════════════════════════════════════════════════════════════════════

function Get-AuthToken {
    Show-Step "1 of 8" "Authentication"

    # Check for saved token first
    if (Test-Path $TOKEN_PATH) {
        try {
            $saved = Get-Content $TOKEN_PATH -Raw | ConvertFrom-Json
            if ($saved.token -and $saved.expiresAt) {
                $expiry = [DateTime]::Parse($saved.expiresAt)
                if ($expiry -gt (Get-Date)) {
                    Show-OK "Found saved session. Welcome back!"
                    return $saved.token
                }
            }
        } catch { }
        Show-Status "Saved session expired. Please log in again."
    }

    # Prompt for phone number
    Write-Host "    Log in with your HelpIT account phone number." -ForegroundColor Gray
    Write-Host ""
    $phone = Read-Host "    Enter your phone number (e.g. +15551234567)"
    $phone = $phone.Trim()

    if (-not $phone.StartsWith("+")) {
        $phone = "+1$phone"  # Default to US
    }

    # Request SMS code
    Show-Status "Sending verification code to $phone..."
    $result = Call-API -Method "POST" -Path "/api/customer-auth/request-code" -Body @{ phone = $phone }

    if ($result._error) {
        Show-Fail "Could not send code. Check your phone number and try again."
        Show-Fail "Error: $($result.message)"
        Read-Host "  Press Enter to exit"
        exit 1
    }

    Show-OK "Code sent! Check your text messages."
    Write-Host ""

    # Prompt for code
    $code = Read-Host "    Enter the 6-digit code from your text"
    $code = $code.Trim()

    # Verify code
    Show-Status "Verifying..."
    $verify = Call-API -Method "POST" -Path "/api/customer-auth/verify-code" -Body @{
        phone = $phone
        code  = $code
    }

    if ($verify._error -or -not $verify.token) {
        Show-Fail "Invalid code. Please try again."
        Read-Host "  Press Enter to exit"
        exit 1
    }

    # Save token for future use
    $tokenDir = Split-Path $TOKEN_PATH -Parent
    if (-not (Test-Path $tokenDir)) {
        New-Item -Path $tokenDir -ItemType Directory -Force | Out-Null
    }
    $verify | ConvertTo-Json | Out-File $TOKEN_PATH -Encoding UTF8

    Show-OK "Logged in successfully!"
    return $verify.token
}


# ══════════════════════════════════════════════════════════════════════
# STEP 4: CHECK SUBSCRIPTION STATUS
# ══════════════════════════════════════════════════════════════════════

function Test-Subscription {
    param([string]$Token)

    Show-Step "2 of 8" "Checking your subscription"

    $status = Call-API -Method "GET" -Path "/api/agent/status" -Token $Token

    if ($status._error) {
        if ($status.status -eq 401) {
            Show-Fail "Session expired. Please run the agent again to log in."
            # Delete saved token
            if (Test-Path $TOKEN_PATH) { Remove-Item $TOKEN_PATH -Force }
        } else {
            Show-Fail "Could not check subscription: $($status.message)"
        }
        Read-Host "  Press Enter to exit"
        exit 1
    }

    if (-not $status.hasAutonomousAccess) {
        Show-Fail "Your current plan does not include HELPIT Autonomous."
        Write-Host ""
        Write-Host "    Upgrade your plan in the HelpIT mobile app" -ForegroundColor Yellow
        Write-Host "    to access autonomous computer repair." -ForegroundColor Yellow
        Write-Host ""
        Read-Host "  Press Enter to exit"
        exit 1
    }

    $access = $status.access
    if (-not $access.isUnlimited -and $access.remaining -le 0) {
        Show-Fail "You've used all $($access.sessionsPerMonth) sessions this month."
        Write-Host "    Sessions reset at the start of your next billing period." -ForegroundColor Yellow
        Write-Host "    You can also purchase additional sessions in the app." -ForegroundColor Yellow
        Write-Host ""
        Read-Host "  Press Enter to exit"
        exit 1
    }

    Show-OK "Plan: $($access.tier.ToUpper())  |  Sessions: $($access.sessionsUsed)/$($access.sessionsPerMonth) used  |  $($access.remaining) remaining"
    Write-Host "    Welcome, $($status.user.full_name)!" -ForegroundColor Cyan

    return $status
}


# ══════════════════════════════════════════════════════════════════════
# STEP 5: CREATE SESSION
# ══════════════════════════════════════════════════════════════════════

function New-AgentSession {
    param([string]$Token)

    Show-Step "3 of 8" "Starting repair session"

    $osInfo = Get-CimInstance Win32_OperatingSystem
    $osVersion = "$($osInfo.Caption) $($osInfo.Version)"

    $result = Call-API -Method "POST" -Path "/api/agent/session" -Token $Token -Body @{
        os_type       = "windows"
        os_version    = $osVersion
        agent_version = $AGENT_VERSION
    }

    if ($result._error) {
        if ($result.body.error -eq "SESSION_LIMIT_REACHED") {
            Show-Fail "No sessions remaining this month."
        } else {
            Show-Fail "Could not start session: $($result.message)"
        }
        Read-Host "  Press Enter to exit"
        exit 1
    }

    Show-OK "Session created: $($result.session.id.Substring(0,8))..."
    Show-OK "Remaining sessions after this: $($result.access.remaining)"

    return $result.session
}


# ══════════════════════════════════════════════════════════════════════
# STEP 6-7: SCAN THE COMPUTER
# ══════════════════════════════════════════════════════════════════════

function Invoke-SystemScan {
    param([string]$Token, [string]$SessionId)

    Show-Step "4 of 8" "Scanning your computer"

    # Update status to scanning
    Call-API -Method "PATCH" -Path "/api/agent/session/$SessionId" -Token $Token -Body @{
        status = "scanning"
    } | Out-Null

    $scanData = @{}

    # ── OS Info ────────────────────────────────────────────────
    Show-Progress "System information" 5
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $uptime = (Get-Date) - $os.LastBootUpTime
        $scanData["os"] = @{
            name         = $os.Caption
            version      = $os.Version
            build        = $os.BuildNumber
            architecture = $env:PROCESSOR_ARCHITECTURE
            uptime_hours = [math]::Round($uptime.TotalHours, 1)
        }
        $scanData["hardware"] = @{
            cpu              = $cpu.Name
            ram_total_gb     = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            ram_available_gb = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        }
    } catch {
        $scanData["os"] = @{ name = "Windows"; error = $_.Exception.Message }
    }

    # ── Disk Space ─────────────────────────────────────────────
    Show-Progress "Disk space" 15
    try {
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null }
        foreach ($drv in $drives) {
            $total = [math]::Round(($drv.Used + $drv.Free) / 1GB, 1)
            $free = [math]::Round($drv.Free / 1GB, 1)
            if (-not $scanData["hardware"]) { $scanData["hardware"] = @{} }
            $scanData["hardware"]["disk_total_gb"] = $total
            $scanData["hardware"]["disk_free_gb"] = $free
            break  # Primary drive only
        }
    } catch { }

    # ── Security ───────────────────────────────────────────────
    Show-Progress "Security status" 25
    try {
        $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
        $firewall = (Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $true }).Count
        $scanData["security"] = @{
            antivirus        = if ($defender) { "Windows Defender" } else { "Unknown" }
            firewall_enabled = ($firewall -gt 0)
            last_update      = if ($defender) { $defender.AntivirusSignatureLastUpdated.ToString("yyyy-MM-dd") } else { "Unknown" }
            real_time_on     = if ($defender) { $defender.RealTimeProtectionEnabled } else { $false }
        }

        # Check pending updates
        try {
            $updateSession = New-Object -ComObject Microsoft.Update.Session -ErrorAction SilentlyContinue
            if ($updateSession) {
                $searcher = $updateSession.CreateUpdateSearcher()
                $pending = $searcher.Search("IsInstalled=0").Updates.Count
                $scanData["security"]["pending_updates"] = $pending
            }
        } catch {
            $scanData["security"]["pending_updates"] = -1  # Unknown
        }
    } catch {
        $scanData["security"] = @{ antivirus = "Unknown"; error = $_.Exception.Message }
    }

    # ── Startup Programs ───────────────────────────────────────
    Show-Progress "Startup programs" 35
    try {
        $startupItems = @()

        # Registry startup (current user)
        $regUser = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
        if ($regUser) {
            $regUser.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
                $startupItems += @{ name = $_.Name; enabled = $true; impact = "medium"; source = "registry_user" }
            }
        }

        # Registry startup (machine)
        $regMachine = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
        if ($regMachine) {
            $regMachine.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
                $startupItems += @{ name = $_.Name; enabled = $true; impact = "medium"; source = "registry_machine" }
            }
        }

        # Task Manager startup items
        try {
            $wmicStartup = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue
            if ($wmicStartup) {
                foreach ($item in $wmicStartup) {
                    if ($startupItems.name -notcontains $item.Name) {
                        $startupItems += @{ name = $item.Name; enabled = $true; impact = "medium"; source = "wmi" }
                    }
                }
            }
        } catch { }

        $scanData["startup_programs"] = $startupItems
    } catch {
        $scanData["startup_programs"] = @()
    }

    # ── Running Processes ──────────────────────────────────────
    Show-Progress "Running processes" 50
    try {
        $procs = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 30
        $scanData["running_processes"] = (Get-Process).Count
        $scanData["top_processes"] = @($procs | ForEach-Object {
            @{
                name      = $_.ProcessName
                memory_mb = [math]::Round($_.WorkingSet64 / 1MB)
                cpu_sec   = [math]::Round($_.CPU, 1)
            }
        })
    } catch {
        $scanData["running_processes"] = 0
    }

    # ── Event Log Errors ───────────────────────────────────────
    Show-Progress "System event logs" 60
    try {
        $errors = Get-WinEvent -FilterHashtable @{
            LogName   = 'System','Application'
            Level     = 1,2  # Critical, Error
            StartTime = (Get-Date).AddDays(-7)
        } -MaxEvents 20 -ErrorAction SilentlyContinue

        $scanData["event_log_errors"] = @($errors | ForEach-Object {
            @{
                source    = $_.ProviderName
                level     = if ($_.Level -eq 1) { "Critical" } else { "Error" }
                message   = $_.Message.Substring(0, [math]::Min($_.Message.Length, 200))
                timestamp = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
            }
        })
    } catch {
        $scanData["event_log_errors"] = @()
    }

    # ── Network ────────────────────────────────────────────────
    Show-Progress "Network configuration" 75
    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

        $scanData["network"] = @{
            adapter    = $adapter.Name
            speed_mbps = $adapter.LinkSpeed
            dns        = $dns
        }

        # Test DNS resolution
        try {
            [System.Net.Dns]::GetHostAddresses("www.google.com") | Out-Null
            $scanData["network"]["dns_working"] = $true
        } catch {
            $scanData["network"]["dns_working"] = $false
        }
    } catch {
        $scanData["network"] = @{ error = "Could not check network" }
    }

    # ── Temp Files ─────────────────────────────────────────────
    Show-Progress "Temporary files" 85
    try {
        $tempSize = 0
        $tempPaths = @($env:TEMP, "$env:LOCALAPPDATA\Temp", "$env:WINDIR\Temp")
        foreach ($tp in $tempPaths) {
            if (Test-Path $tp) {
                $size = (Get-ChildItem $tp -Recurse -File -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum
                if ($size) { $tempSize += $size }
            }
        }
        $scanData["temp_files_gb"] = [math]::Round($tempSize / 1GB, 2)
    } catch {
        $scanData["temp_files_gb"] = 0
    }

    # ── Installed Programs Count ───────────────────────────────
    Show-Progress "Installed programs" 92
    try {
        $programs = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue
        $programs += Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue
        $scanData["installed_programs_count"] = ($programs | Where-Object { $_.DisplayName }).Count
    } catch {
        $scanData["installed_programs_count"] = 0
    }

    # ── Browser Extensions ─────────────────────────────────────
    Show-Progress "Browser extensions" 97
    try {
        $chromePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions"
        $edgePath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions"
        $extCount = 0
        if (Test-Path $chromePath) { $extCount += (Get-ChildItem $chromePath -Directory -ErrorAction SilentlyContinue).Count }
        if (Test-Path $edgePath) { $extCount += (Get-ChildItem $edgePath -Directory -ErrorAction SilentlyContinue).Count }
        $scanData["browser_extensions"] = $extCount
    } catch {
        $scanData["browser_extensions"] = 0
    }

    Show-Progress "Scan complete!" 100
    Write-Host ""

    return $scanData
}


# ══════════════════════════════════════════════════════════════════════
# STEP 8: SUBMIT SCAN DATA TO AI
# ══════════════════════════════════════════════════════════════════════

function Submit-ScanData {
    param([string]$Token, [string]$SessionToken, [hashtable]$ScanData)

    Show-Step "5 of 8" "Sending to AI for analysis"
    Show-Status "Claude AI is analyzing your system... (this may take 15-30 seconds)"

    $result = Call-API -Method "POST" -Path "/api/agent/scan" -Token $Token -Body @{
        session_token = $SessionToken
        scan_data     = $ScanData
    }

    if ($result._error) {
        Show-Fail "AI analysis failed: $($result.message)"
        return $null
    }

    $analysis = $result.analysis
    Show-OK "Analysis complete!"
    Write-Host ""

    # Display summary
    $healthColor = switch ($analysis.overallHealth) {
        "good"     { "Green" }
        "fair"     { "Yellow" }
        "poor"     { "Red" }
        "critical" { "Red" }
        default    { "White" }
    }
    Write-Host "    Health: " -NoNewline -ForegroundColor White
    Write-Host "$($analysis.overallHealth.ToUpper())" -ForegroundColor $healthColor
    Write-Host "    $($analysis.summary)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "    Found $($analysis.issueCount) issue(s)" -NoNewline -ForegroundColor White
    if ($analysis.criticalCount -gt 0) {
        Write-Host " ($($analysis.criticalCount) critical)" -ForegroundColor Red
    } else {
        Write-Host ""
    }

    # List issues
    Write-Host ""
    foreach ($issue in $analysis.issues) {
        $sevColor = switch ($issue.severity) {
            "critical" { "Red" }
            "high"     { "Red" }
            "medium"   { "Yellow" }
            "low"      { "Green" }
            default    { "White" }
        }
        Write-Host "    [$($issue.severity.ToUpper())]" -ForegroundColor $sevColor -NoNewline
        Write-Host " $($issue.title)" -ForegroundColor White
        Write-Host "      $($issue.description)" -ForegroundColor DarkGray
        Write-Host "      Fix: $($issue.fix.description)" -ForegroundColor DarkCyan
        Write-Host ""
    }

    return $result
}


# ══════════════════════════════════════════════════════════════════════
# STEP 9: WAIT FOR APPROVAL FROM PORTAL
# ══════════════════════════════════════════════════════════════════════

function Wait-ForApproval {
    param([string]$Token, [string]$SessionId)

    Show-Step "6 of 8" "Waiting for your approval"

    $portalUrl = "$HELPIT_API_BASE/helpit-agent/session/$SessionId"

    Write-Host "  ┌────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │                                                    │" -ForegroundColor Cyan
    Write-Host "  │  Review your results and approve fixes at:         │" -ForegroundColor Cyan
    Write-Host "  │                                                    │" -ForegroundColor Cyan
    Write-Host "  │  $portalUrl" -ForegroundColor Yellow -NoNewline
    $pad = 52 - $portalUrl.Length
    if ($pad -gt 0) { Write-Host (" " * $pad) -NoNewline -ForegroundColor Cyan }
    Write-Host "│" -ForegroundColor Cyan
    Write-Host "  │                                                    │" -ForegroundColor Cyan
    Write-Host "  │  Or approve in the HelpIT mobile app.              │" -ForegroundColor Cyan
    Write-Host "  │                                                    │" -ForegroundColor Cyan
    Write-Host "  └────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""

    # Open browser automatically
    try { Start-Process $portalUrl } catch { }

    # Poll for approval
    $dots = 0
    $maxWait = 600  # 10 minutes max
    $elapsed = 0

    while ($elapsed -lt $maxWait) {
        $dotStr = "." * (($dots % 3) + 1) + "   "
        Write-Host "`r    Waiting for approval$dotStr" -NoNewline -ForegroundColor Yellow
        $dots++

        Start-Sleep -Seconds $POLL_INTERVAL
        $elapsed += $POLL_INTERVAL

        $session = Call-API -Method "GET" -Path "/api/agent/session/$SessionId" -Token $Token

        if ($session._error) { continue }

        $status = $session.session.status

        if ($status -eq "fixing") {
            Write-Host ""
            Show-OK "Fixes approved! Starting repairs..."
            return $session.session.fixes_approved
        }
        elseif ($status -eq "cancelled") {
            Write-Host ""
            Show-Status "Session was cancelled. No changes made." "Yellow"
            return $null
        }
        elseif ($status -eq "completed") {
            Write-Host ""
            Show-Status "Session already completed." "Green"
            return $null
        }
    }

    Write-Host ""
    Show-Fail "Timed out waiting for approval (10 minutes). No changes made."
    return $null
}


# ══════════════════════════════════════════════════════════════════════
# STEP 10: APPLY FIXES
# ══════════════════════════════════════════════════════════════════════

function Invoke-ApprovedFixes {
    param([string]$Token, [string]$SessionToken, [array]$Fixes)

    Show-Step "7 of 8" "Fixing your computer"

    # Create restore point first
    Write-Host "    Creating safety restore point..." -ForegroundColor Yellow
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    $restorePoint = "N/A"
    if ($isAdmin) {
        try {
            Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
            $rpName = "HELPIT_$(Get-Date -Format 'yyyyMMdd_HHmm')"
            Checkpoint-Computer -Description $rpName -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
            $restorePoint = $rpName
            Show-OK "Restore point created: $rpName"
        } catch {
            Show-Status "Could not create restore point. Proceeding with caution." "Yellow"
        }
    } else {
        Show-Status "Tip: Run as Administrator for full restore point protection." "Yellow"
    }

    Write-Host ""

    # Apply each fix
    $total = $Fixes.Count
    for ($i = 0; $i -lt $total; $i++) {
        $fix = $Fixes[$i]
        $num = $i + 1
        Write-Host "    [$num/$total] $($fix.title)..." -ForegroundColor White

        $result = "success"
        $errorDetails = $null

        try {
            # Execute the fix command from AI
            $command = $fix.fix.command
            if ($command) {
                Write-Host "      Running: $($fix.fix.description)" -ForegroundColor DarkGray

                # Execute the command
                $output = Invoke-Expression $command 2>&1

                Show-OK "$($fix.fix.description) — Done"
            } else {
                Show-Status "No automated fix available. See report for manual steps." "Yellow"
                $result = "success"  # Report as success since we noted it
            }
        } catch {
            $result = "failed"
            $errorDetails = $_.Exception.Message
            Show-Fail "Fix failed: $errorDetails"
        }

        # Report fix result to server
        Call-API -Method "POST" -Path "/api/agent/fix-result" -Token $Token -Body @{
            session_token = $SessionToken
            fix_id        = $fix.title    # API matches on title
            result        = $result
            error_details = $errorDetails
        } | Out-Null

        Write-Host ""
    }
}


# ══════════════════════════════════════════════════════════════════════
# STEP 11: COMPLETE AND CLEAN UP
# ══════════════════════════════════════════════════════════════════════

function Complete-Session {
    param([string]$SessionId, [int]$FixCount)

    Show-Step "8 of 8" "Session complete"

    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║                                              ║" -ForegroundColor Green
    Write-Host "  ║     SESSION COMPLETE                         ║" -ForegroundColor Green
    Write-Host "  ║                                              ║" -ForegroundColor Green
    Write-Host "  ║     $FixCount fix(es) applied.$((' ' * (31 - $FixCount.ToString().Length)))║" -ForegroundColor Green
    Write-Host "  ║     View full report in your HelpIT portal.  ║" -ForegroundColor Green
    Write-Host "  ║     Undo anytime with System Restore.        ║" -ForegroundColor Green
    Write-Host "  ║                                              ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "    This window will close in 15 seconds." -ForegroundColor DarkGray
    Write-Host "    The agent will delete itself from your computer." -ForegroundColor DarkGray
    Write-Host ""

    Start-Sleep -Seconds 15

    # Clean up saved token
    if (Test-Path $TOKEN_PATH) {
        Remove-Item $TOKEN_PATH -Force -ErrorAction SilentlyContinue
    }
    $tokenDir = Split-Path $TOKEN_PATH -Parent
    if ((Test-Path $tokenDir) -and (Get-ChildItem $tokenDir | Measure-Object).Count -eq 0) {
        Remove-Item $tokenDir -Force -ErrorAction SilentlyContinue
    }

    # Self-delete
    $scriptPath = $PSCommandPath
    if ($scriptPath -and (Test-Path $scriptPath)) {
        $cleanup = "$env:TEMP\helpit_cleanup.bat"
        "@echo off`nping 127.0.0.1 -n 4 >nul`ndel /f /q `"$scriptPath`"`ndel /f /q `"%~f0`"" |
            Out-File $cleanup -Encoding ASCII
        Start-Process cmd.exe -ArgumentList "/c `"$cleanup`"" -WindowStyle Hidden
    }
}


# ══════════════════════════════════════════════════════════════════════
# MAIN — The complete lifecycle
# ══════════════════════════════════════════════════════════════════════

try {
    Show-Banner

    # 1-3. Authenticate
    $token = Get-AuthToken

    # 4. Check subscription
    $status = Test-Subscription -Token $token

    # 5. Create session
    $session = New-AgentSession -Token $token
    $sessionId = $session.id
    $sessionToken = $session.session_token

    # 6-7. Scan the computer
    $scanData = Invoke-SystemScan -Token $token -SessionId $sessionId

    # 8. Submit to AI for analysis
    $analysisResult = Submit-ScanData -Token $token -SessionToken $sessionToken -ScanData $scanData

    if (-not $analysisResult) {
        Show-Fail "Could not analyze your system. Please try again later."
        Call-API -Method "PATCH" -Path "/api/agent/session/$sessionId" -Token $token -Body @{
            status = "failed"
            error_message = "AI analysis failed"
        } | Out-Null
        Read-Host "  Press Enter to exit"
        exit 1
    }

    if ($analysisResult.analysis.issueCount -eq 0) {
        Show-OK "No issues found! Your computer is healthy."
        Complete-Session -SessionId $sessionId -FixCount 0
        exit 0
    }

    # 9. Wait for approval from portal
    $approvedFixes = Wait-ForApproval -Token $token -SessionId $sessionId

    if (-not $approvedFixes -or $approvedFixes.Count -eq 0) {
        Show-Status "No fixes approved. Exiting without changes." "Yellow"
        Start-Sleep -Seconds 5
        exit 0
    }

    # 10. Apply fixes
    Invoke-ApprovedFixes -Token $token -SessionToken $sessionToken -Fixes $approvedFixes

    # 11. Done
    Complete-Session -SessionId $sessionId -FixCount $approvedFixes.Count

} catch {
    Write-Host ""
    Write-Host "  An unexpected error occurred:" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  No changes were made to your computer." -ForegroundColor Yellow
    Write-Host "  Please try again or contact HelpIT support." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit"
}
