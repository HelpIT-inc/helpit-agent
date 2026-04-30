# ══════════════════════════════════════════════════════════════════════
# HELPIT AUTONOMOUS AGENT — Windows
# Version 2.3.0 — PowerShell auto-minimizes, customer sees only portal
# ══════════════════════════════════════════════════════════════════════

$HELPIT_API_BASE = "https://agent.helpitinc.com"
$AUTH_TOKEN = "{{AUTH_TOKEN}}"
$SESSION_ID = "{{SESSION_ID}}"
$SESSION_TOKEN = "{{SESSION_TOKEN}}"
$AGENT_VERSION = "2.3.0"
$POLL_INTERVAL = 8

# ── DISPLAY HELPERS ────────────────────────────────────────────────

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                                              ║" -ForegroundColor Cyan
    Write-Host "  ║         HELPIT AUTONOMOUS TECHNICIAN         ║" -ForegroundColor Cyan
    Write-Host "  ║                                              ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    param([string]$Msg, [string]$Color = "Yellow")
    Write-Host "  $Msg" -ForegroundColor $Color
}

function Show-OK { param([string]$Msg); Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Show-Fail { param([string]$Msg); Write-Host "  [!!] $Msg" -ForegroundColor Red }

function Show-Progress {
    param([string]$Label, [int]$Pct)
    $filled = [math]::Floor(30 * $Pct / 100)
    $bar = ("█" * $filled) + ("░" * (30 - $filled))
    Write-Host "`r  [$bar] $Pct% $Label    " -NoNewline -ForegroundColor Yellow
}

function Call-API {
    param([string]$Method, [string]$Path, [hashtable]$Body = $null)
    $uri = "$HELPIT_API_BASE$Path"
    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $AUTH_TOKEN"
    }
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; TimeoutSec = 180 }
    if ($Body) { $params["Body"] = ($Body | ConvertTo-Json -Depth 10 -Compress) }

    try {
        return Invoke-RestMethod @params
    } catch {
        return @{ "_error" = $true; "message" = $_.Exception.Message }
    }
}

function Call-API-ToFile {
    param([string]$Method, [string]$Path, [string]$OutFile, [hashtable]$Body = $null)
    $uri = "$HELPIT_API_BASE$Path"
    $headers = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $AUTH_TOKEN"
    }
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; OutFile = $OutFile; TimeoutSec = 180 }
    if ($Body) { $params["Body"] = ($Body | ConvertTo-Json -Depth 10 -Compress) }

    try {
        Invoke-RestMethod @params
        return $true
    } catch {
        return $false
    }
}

# ══════════════════════════════════════════════════════════════════════
# STEP 1: CHECK TOKENS
# ══════════════════════════════════════════════════════════════════════

function Check-Auth {
    if ($AUTH_TOKEN.Length -gt 10 -and $AUTH_TOKEN.StartsWith("sess_")) {
        Show-OK "Authenticated (pre-configured session)"
        return $true
    } else {
        Show-Fail "This script was not configured properly."
        Write-Host "  Please download a new copy from the HelpIT portal." -ForegroundColor Gray
        Write-Host "  https://agent.helpitinc.com/helpit-agent/dashboard" -ForegroundColor Gray
        Read-Host "  Press Enter to exit"
        exit 1
    }
}

# ══════════════════════════════════════════════════════════════════════
# STEP 2: OPEN PORTAL + MINIMIZE POWERSHELL
# ══════════════════════════════════════════════════════════════════════

function Open-PortalSession {
    $portalUrl = "$HELPIT_API_BASE/helpit-agent/session/$SESSION_ID"
    Show-Status "Opening your HelpIT dashboard..." "Cyan"
    Show-Status $portalUrl "Yellow"
    Write-Host ""

    Start-Process $portalUrl

    # Minimize PowerShell window so customer only sees the portal
    Start-Sleep -Seconds 1
    try {
        $host.UI.RawUI.WindowTitle = "HelpIT Agent"
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
        $hwnd = [Win32]::GetConsoleWindow()
        [Win32]::ShowWindow($hwnd, 6) | Out-Null  # 6 = SW_MINIMIZE
    } catch {
        # Silent fail — minimizing is a nice-to-have
    }
}

# ══════════════════════════════════════════════════════════════════════
# STEP 3: SCAN THE COMPUTER
# ══════════════════════════════════════════════════════════════════════

function Invoke-SystemScan {
    Show-Status "Scanning your computer..."

    Call-API -Method "PATCH" -Path "/api/agent/session/$SESSION_ID" -Body @{
        status = "scanning"
    } | Out-Null

    $scanData = @{}

    # OS Info
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

    # Disk Space
    Show-Progress "Disk space" 15
    try {
        $drv = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | Select-Object -First 1
        if ($drv) {
            $total = [math]::Round(($drv.Used + $drv.Free) / 1GB, 1)
            $free = [math]::Round($drv.Free / 1GB, 1)
            if (-not $scanData["hardware"]) { $scanData["hardware"] = @{} }
            $scanData["hardware"]["disk_total_gb"] = $total
            $scanData["hardware"]["disk_free_gb"] = $free
        }
    } catch { }

    # Security
    Show-Progress "Security status" 25
    try {
        $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
        $firewall = (Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $true }).Count
        $scanData["security"] = @{
            antivirus        = if ($defender) { "Windows Defender" } else { "Unknown" }
            firewall_enabled = ($firewall -gt 0)
            real_time_on     = if ($defender) { $defender.RealTimeProtectionEnabled } else { $false }
        }
        try {
            $updateSession = New-Object -ComObject Microsoft.Update.Session -ErrorAction SilentlyContinue
            if ($updateSession) {
                $searcher = $updateSession.CreateUpdateSearcher()
                $pending = $searcher.Search("IsInstalled=0").Updates.Count
                $scanData["security"]["pending_updates"] = $pending
            }
        } catch { $scanData["security"]["pending_updates"] = -1 }
    } catch {
        $scanData["security"] = @{ antivirus = "Unknown" }
    }

    # Startup Programs
    Show-Progress "Startup programs" 35
    try {
        $startupItems = @()
        $regUser = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
        if ($regUser) {
            $regUser.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
                $startupItems += @{ name = $_.Name; enabled = $true; impact = "medium"; source = "registry_user" }
            }
        }
        $regMachine = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue
        if ($regMachine) {
            $regMachine.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
                $startupItems += @{ name = $_.Name; enabled = $true; impact = "medium"; source = "registry_machine" }
            }
        }
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
    } catch { $scanData["startup_programs"] = @() }

    # Running Processes
    Show-Progress "Running processes" 50
    try {
        $procs = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 30
        $scanData["running_processes"] = (Get-Process).Count
        $scanData["top_processes"] = @($procs | ForEach-Object {
            @{ name = $_.ProcessName; memory_mb = [math]::Round($_.WorkingSet64 / 1MB); cpu_sec = [math]::Round($_.CPU, 1) }
        })
    } catch { $scanData["running_processes"] = 0 }

    # Event Log Errors
    Show-Progress "System event logs" 60
    try {
        $errors = Get-WinEvent -FilterHashtable @{
            LogName = 'System','Application'; Level = 1,2; StartTime = (Get-Date).AddDays(-7)
        } -MaxEvents 20 -ErrorAction SilentlyContinue
        $scanData["event_log_errors"] = @($errors | ForEach-Object {
            @{ source = $_.ProviderName; level = if ($_.Level -eq 1) { "Critical" } else { "Error" }
               message = $_.Message.Substring(0, [math]::Min($_.Message.Length, 200))
               timestamp = $_.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss") }
        })
    } catch { $scanData["event_log_errors"] = @() }

    # Network
    Show-Progress "Network configuration" 75
    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $dnsWorking = $true
        try { [System.Net.Dns]::GetHostAddresses("www.google.com") | Out-Null } catch { $dnsWorking = $false }
        $scanData["network"] = @{ adapter = $adapter.Name; speed_mbps = $adapter.LinkSpeed; dns = $dns; dns_working = $dnsWorking }
    } catch { $scanData["network"] = @{ error = "Could not check" } }

    # Temp Files
    Show-Progress "Temporary files" 85
    try {
        $tempSize = 0
        @($env:TEMP, "$env:LOCALAPPDATA\Temp", "$env:WINDIR\Temp") | ForEach-Object {
            if (Test-Path $_) {
                $size = (Get-ChildItem $_ -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                if ($size) { $tempSize += $size }
            }
        }
        $scanData["temp_files_gb"] = [math]::Round($tempSize / 1GB, 2)
    } catch { $scanData["temp_files_gb"] = 0 }

    # Installed Programs + Extensions
    Show-Progress "Installed programs" 92
    try {
        $programs = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue
        $programs += Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue
        $scanData["installed_programs_count"] = ($programs | Where-Object { $_.DisplayName }).Count
    } catch { $scanData["installed_programs_count"] = 0 }

    Show-Progress "Browser extensions" 97
    try {
        $extCount = 0
        $chromePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions"
        $edgePath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions"
        if (Test-Path $chromePath) { $extCount += (Get-ChildItem $chromePath -Directory -ErrorAction SilentlyContinue).Count }
        if (Test-Path $edgePath) { $extCount += (Get-ChildItem $edgePath -Directory -ErrorAction SilentlyContinue).Count }
        $scanData["browser_extensions"] = $extCount
    } catch { $scanData["browser_extensions"] = 0 }

    Show-Progress "Scan complete!" 100
    Write-Host ""

    return $scanData
}

# ══════════════════════════════════════════════════════════════════════
# STEP 4: SUBMIT SCAN DATA TO AI
# ══════════════════════════════════════════════════════════════════════

function Submit-ScanData {
    param([hashtable]$ScanData)

    Show-Status "Sending to AI for analysis..." "Yellow"

    $result = Call-API -Method "POST" -Path "/api/agent/scan" -Body @{
        session_token = $SESSION_TOKEN
        scan_data     = $ScanData
    }

    if ($result._error) {
        Show-Fail "AI analysis failed: $($result.message)"
        return $null
    }

    Show-OK "Analysis complete! Check your browser for results."
    return $result
}

# ══════════════════════════════════════════════════════════════════════
# STEP 5: WAIT FOR APPROVAL (customer approves on portal)
# ══════════════════════════════════════════════════════════════════════

function Wait-ForApproval {
    Show-Status "Waiting for you to approve fixes in the browser..." "Yellow"

    $approvalFile = "$env:TEMP\helpit_approval_$PID.json"
    $maxWait = 600
    $elapsed = 0

    while ($elapsed -lt $maxWait) {
        Start-Sleep -Seconds $POLL_INTERVAL
        $elapsed += $POLL_INTERVAL

        $success = Call-API-ToFile -Method "GET" -Path "/api/agent/session/$SESSION_ID" -OutFile $approvalFile

        if (-not $success) { continue }

        try {
            $sessionData = Get-Content $approvalFile -Raw | ConvertFrom-Json
            $status = $sessionData.session.status

            if ($status -eq "fixing") {
                Show-OK "Fixes approved! Applying now..."
                return $approvalFile
            }
            elseif ($status -eq "cancelled") {
                Show-Status "Session cancelled. No changes made." "Yellow"
                Remove-Item $approvalFile -Force -ErrorAction SilentlyContinue
                return $null
            }
        } catch { }
    }

    Show-Fail "Timed out waiting for approval."
    Remove-Item $approvalFile -Force -ErrorAction SilentlyContinue
    return $null
}

# ══════════════════════════════════════════════════════════════════════
# STEP 6: APPLY FIXES (reads from temp file — no JSON quoting issues)
# ══════════════════════════════════════════════════════════════════════

function Invoke-ApprovedFixes {
    param([string]$ApprovalFile)

    # Create restore point
    Show-Status "Creating safety restore point..." "Yellow"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        try {
            Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
            $rpName = "HELPIT_$(Get-Date -Format 'yyyyMMdd_HHmm')"
            Checkpoint-Computer -Description $rpName -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
            Show-OK "Restore point: $rpName"
        } catch {
            Show-Status "Could not create restore point. Continuing safely." "Yellow"
        }
    } else {
        Show-Status "Tip: Run as Administrator for restore point protection." "DarkGray"
    }

    Write-Host ""

    # Read fixes from temp file (avoids JSON quoting issues)
    try {
        $sessionData = Get-Content $ApprovalFile -Raw | ConvertFrom-Json
        $fixes = $sessionData.session.fixes_approved
    } catch {
        Show-Fail "Could not read fix data: $($_.Exception.Message)"
        return
    }

    if (-not $fixes -or $fixes.Count -eq 0) {
        Show-Status "No fixes to apply." "Yellow"
        return
    }

    $total = $fixes.Count
    for ($i = 0; $i -lt $total; $i++) {
        $fix = $fixes[$i]
        $num = $i + 1
        Write-Host "  [$num/$total] $($fix.title)" -ForegroundColor White

        $command = $fix.fix.command
        $description = $fix.fix.description
        Write-Host "    Running: $description" -ForegroundColor DarkGray

        $result = "success"
        $errorDetails = $null

        if ($command) {
            try {
                $output = Invoke-Expression $command 2>&1
                Show-OK $description
            } catch {
                $result = "failed"
                $errorDetails = $_.Exception.Message
                Show-Fail "Failed: $errorDetails"
            }
        } else {
            Show-OK "Manual recommendation noted"
        }

        # Report fix result to server
        try {
            Call-API -Method "POST" -Path "/api/agent/fix-result" -Body @{
                session_token = $SESSION_TOKEN
                fix_id        = $fix.title
                result        = $result
                error_details = $errorDetails
            } | Out-Null
        } catch { }

        Write-Host ""
    }

    # Clean up temp file
    Remove-Item $ApprovalFile -Force -ErrorAction SilentlyContinue
}

# ══════════════════════════════════════════════════════════════════════
# STEP 7: CLEANUP AND EXIT
# ══════════════════════════════════════════════════════════════════════

function Complete-AndExit {
    Write-Host ""
    Show-OK "All done! Check your browser for the full report."
    Write-Host "  This window will close in 5 seconds." -ForegroundColor DarkGray

    Start-Sleep -Seconds 5

    # Self-delete the script
    $scriptPath = $PSCommandPath
    if ($scriptPath -and (Test-Path $scriptPath)) {
        $cleanup = "$env:TEMP\helpit_cleanup.bat"
        "@echo off`nping 127.0.0.1 -n 4 >nul`ndel /f /q `"$scriptPath`"`ndel /f /q `"%~f0`"" |
            Out-File $cleanup -Encoding ASCII
        Start-Process cmd.exe -ArgumentList "/c `"$cleanup`"" -WindowStyle Hidden
    }

    # Close the PowerShell window
    try {
        [System.Environment]::Exit(0)
    } catch {
        exit 0
    }
}

# ══════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════

try {
    Show-Banner

    # 1. Check tokens
    Check-Auth

    # 2. Open portal + minimize PowerShell
    Open-PortalSession

    # 3. Scan
    $scanData = Invoke-SystemScan

    # 4. Send to AI
    $analysis = Submit-ScanData -ScanData $scanData
    if (-not $analysis) {
        Call-API -Method "PATCH" -Path "/api/agent/session/$SESSION_ID" -Body @{
            status = "failed"; error_message = "AI analysis failed"
        } | Out-Null
        Show-Fail "Could not analyze. Check your browser."
        Start-Sleep -Seconds 5
        exit 1
    }

    if ($analysis.analysis.issueCount -eq 0) {
        Show-OK "No issues found! Your computer is healthy."
        Complete-AndExit
        exit 0
    }

    # 5. Wait for approval
    $approvalFile = Wait-ForApproval
    if (-not $approvalFile) {
        Show-Status "No fixes approved." "Yellow"
        Start-Sleep -Seconds 5
        exit 0
    }

    # 6. Apply fixes
    Invoke-ApprovedFixes -ApprovalFile $approvalFile

    # 7. Done
    Complete-AndExit

} catch {
    Write-Host ""
    Show-Fail "Error: $($_.Exception.Message)"
    Show-Status "No changes were made." "Yellow"
    Start-Sleep -Seconds 10
}
