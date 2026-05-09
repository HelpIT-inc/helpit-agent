# HelpIT Autonomous Agent — Windows Comprehensive Scan (v3.0)
# - Minimizes the PowerShell window on launch (customer never sees the window)
# - Posts progress to /api/agent/scan/progress after each category
# - Submits final scan_data to /api/agent/scan
# - Closes the window automatically and self-deletes when done

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$AuthToken    = "{{AUTH_TOKEN}}"
$SessionToken = "{{SESSION_TOKEN}}"
$ApiBase      = "https://www.helpitinc.com"
$ScriptPath   = $MyInvocation.MyCommand.Path

# ─── Minimize the console window so the customer sees the portal only ──
try {
  Add-Type -Name Win -Namespace Native -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    public static extern System.IntPtr GetConsoleWindow();
"@
  $hWnd = [Native.Win]::GetConsoleWindow()
  if ($hWnd -ne [System.IntPtr]::Zero) {
    [void][Native.Win]::ShowWindow($hWnd, 6) # SW_MINIMIZE
  }
} catch {}

# ─── Helpers ───────────────────────────────────────────────────────────
function Post-Progress($step, $percent) {
  $body = @{ session_token = $SessionToken; step = $step }
  if ($null -ne $percent) { $body.percent = $percent }
  try {
    Invoke-RestMethod -Uri "$ApiBase/api/agent/scan/progress" `
      -Method Post `
      -ContentType 'application/json' `
      -Headers @{ Authorization = "Bearer $AuthToken" } `
      -Body ($body | ConvertTo-Json -Compress) `
      -TimeoutSec 5 | Out-Null
  } catch {}
}

function Cleanup-And-Exit($code) {
  # Self-delete the script (best-effort)
  try {
    if ($ScriptPath -and (Test-Path $ScriptPath)) {
      Remove-Item -Path $ScriptPath -Force -ErrorAction SilentlyContinue
    }
  } catch {}
  # Close the console window
  try {
    Stop-Process -Id $PID -Force
  } catch {}
  exit $code
}

function Get-FolderSizeGB([string]$Path) {
  if (-not (Test-Path $Path)) { return 0 }
  try {
    $bytes = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { return 0 }
    return [math]::Round($bytes / 1GB, 2)
  } catch { return 0 }
}

Post-Progress "starting" 5
Write-Host "🔍 HelpIT Autonomous Agent — Comprehensive Windows Scan"

# ─── 1. STORAGE ────────────────────────────────────────────────────────
Post-Progress "scanning_storage" 15
Write-Host "📦 Scanning storage..."
$drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
$diskTotalGb = [math]::Round($drive.Size / 1GB, 2)
$diskFreeGb  = [math]::Round($drive.FreeSpace / 1GB, 2)
$diskUsedGb  = [math]::Round(($drive.Size - $drive.FreeSpace) / 1GB, 2)
$diskPercent = if ($drive.Size -gt 0) { [math]::Round((($drive.Size - $drive.FreeSpace) / $drive.Size) * 100, 0) } else { 0 }

$topLargest = @()
try {
  $userHome = $env:USERPROFILE
  $items = Get-ChildItem -Path $userHome -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notin @('AppData','NTUSER.DAT') } |
           ForEach-Object {
             $size = if ($_.PSIsContainer) {
               (Get-ChildItem -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
             } else { $_.Length }
             [PSCustomObject]@{ path = $_.FullName; size_gb = [math]::Round(($size / 1GB), 2) }
           } | Sort-Object size_gb -Descending | Select-Object -First 5
  $topLargest = $items
} catch {}

$recycleBinGb = Get-FolderSizeGB "$env:SystemDrive\`$Recycle.Bin"
$tempGb       = Get-FolderSizeGB $env:TEMP
$winTempGb    = Get-FolderSizeGB "$env:WINDIR\Temp"
$downloadsPath = Join-Path $env:USERPROFILE 'Downloads'
$downloadsGb   = Get-FolderSizeGB $downloadsPath
$downloadsCount = (Get-ChildItem -Path $downloadsPath -File -ErrorAction SilentlyContinue).Count

# ─── 2. MEMORY ─────────────────────────────────────────────────────────
Post-Progress "scanning_memory" 30
Write-Host "🧠 Scanning memory..."
$os = Get-CimInstance Win32_OperatingSystem
$ramTotalGb     = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$ramAvailableGb = [math]::Round($os.FreePhysicalMemory   / 1MB, 2)
$ramUsedGb      = [math]::Round($ramTotalGb - $ramAvailableGb, 2)
$commitPercent  = if ($os.TotalVirtualMemorySize -gt 0) {
  [math]::Round((($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize) * 100, 0)
} else { 0 }

$topMem = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
          ForEach-Object {
            [PSCustomObject]@{ pid = $_.Id; name = $_.ProcessName; memory_mb = [math]::Round($_.WorkingSet64 / 1MB, 0) }
          }

$pageFile = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
$swapUsedGb  = if ($pageFile) { [math]::Round(($pageFile | Measure-Object CurrentUsage -Sum).Sum / 1024, 2) } else { 0 }
$swapTotalGb = if ($pageFile) { [math]::Round(($pageFile | Measure-Object AllocatedBaseSize -Sum).Sum / 1024, 2) } else { 0 }

# ─── 3. CPU ────────────────────────────────────────────────────────────
Post-Progress "scanning_cpu" 40
Write-Host "⚡ Scanning CPU..."
$cpuPercent = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
if (-not $cpuPercent) { $cpuPercent = 0 }
$processCount = (Get-Process).Count

$topCpu = Get-Process | Where-Object { $_.CPU } | Sort-Object CPU -Descending | Select-Object -First 5 |
          ForEach-Object {
            [PSCustomObject]@{ pid = $_.Id; name = $_.ProcessName; cpu_percent = [math]::Round($_.CPU, 1) }
          }

$bootTime    = $os.LastBootUpTime
$uptimeDays  = [math]::Round(((Get-Date) - $bootTime).TotalDays, 1)
$lastBootIso = $bootTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# ─── 4. STARTUP ────────────────────────────────────────────────────────
Post-Progress "scanning_startup" 55
Write-Host "🚀 Scanning startup items..."
$loginItems = @()
foreach ($p in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run') {
  try { if (Test-Path $p) { (Get-Item $p).Property | ForEach-Object { $loginItems += $_ } } } catch {}
}
$scheduledTasks = @()
try {
  $scheduledTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } |
    Select-Object -ExpandProperty TaskName -First 50
} catch {}
$autoServices = @()
try {
  $autoServices = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
    Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Running' } |
    Select-Object -ExpandProperty Name -First 50
} catch {}
$startupCount = $loginItems.Count + $scheduledTasks.Count + $autoServices.Count

# ─── 5. NETWORK ────────────────────────────────────────────────────────
Post-Progress "scanning_network" 65
Write-Host "🌐 Scanning network..."
$dnsServers = @()
try {
  $dnsServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.ServerAddresses.Count -gt 0 } |
                 Select-Object -ExpandProperty ServerAddresses -Unique)
} catch {}
$dnsResponseMs = 0
try {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $null = Resolve-DnsName -Name 'google.com' -Type A -ErrorAction SilentlyContinue
  $sw.Stop(); $dnsResponseMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
} catch {}
$pingMs = 999
try {
  $p = Test-Connection -ComputerName 8.8.8.8 -Count 2 -ErrorAction SilentlyContinue
  if ($p) { $pingMs = [math]::Round(($p | Measure-Object -Property ResponseTime -Average).Average, 0) }
} catch {}
$activeInterface = "unknown"; $activeIp = "unknown"
try {
  $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
           Sort-Object RouteMetric | Select-Object -First 1
  if ($route) {
    $iface = Get-NetIPInterface -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $activeInterface = $iface.InterfaceAlias
    $ip = (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($ip) { $activeIp = $ip }
  }
} catch {}
$dnsCacheEntries = 0
try { $dnsCacheEntries = (Get-DnsClientCache -ErrorAction SilentlyContinue | Measure-Object).Count } catch {}
$wifiSignalDbm = 0
try {
  $netshOut = netsh wlan show interfaces 2>$null
  $signalLine = $netshOut | Where-Object { $_ -match 'Signal\s+:\s+(\d+)%' }
  if ($signalLine) { $pct = [int]$Matches[1]; $wifiSignalDbm = -100 + ($pct / 2) }
} catch {}

# ─── 6. SECURITY ───────────────────────────────────────────────────────
Post-Progress "scanning_security" 75
Write-Host "🔒 Scanning security settings..."
$bitlockerEnabled = $false
try {
  $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
  if ($vol -and $vol.ProtectionStatus -eq 'On') { $bitlockerEnabled = $true }
} catch {}
$firewallEnabled = $false
try {
  $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
  if ($fw | Where-Object { $_.Enabled -eq 'True' }) { $firewallEnabled = $true }
} catch {}
$defenderEnabled = $false
try {
  $def = Get-MpComputerStatus -ErrorAction SilentlyContinue
  if ($def -and $def.RealTimeProtectionEnabled) { $defenderEnabled = $true }
} catch {}
$pendingUpdates = 0
try {
  $session  = New-Object -ComObject Microsoft.Update.Session
  $searcher = $session.CreateUpdateSearcher()
  $result   = $searcher.Search("IsInstalled=0 and IsHidden=0")
  $pendingUpdates = $result.Updates.Count
} catch {}
$uacLevel = 0
try {
  $uacLevel = (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'ConsentPromptBehaviorAdmin' -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
  if (-not $uacLevel) { $uacLevel = 0 }
} catch {}
$remoteLoginEnabled = $false
try {
  $rdp = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections
  if ($rdp -eq 0) { $remoteLoginEnabled = $true }
} catch {}

# ─── 7. BROWSER ────────────────────────────────────────────────────────
Post-Progress "scanning_browser" 85
Write-Host "🌎 Scanning browsers..."
$chromeExtPath = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Extensions'
$chromeExtCount = if (Test-Path $chromeExtPath) { (Get-ChildItem -Path $chromeExtPath -Directory -ErrorAction SilentlyContinue).Count } else { 0 }
$chromeCacheGb = Get-FolderSizeGB (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache')
$edgeCacheGb   = Get-FolderSizeGB (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache')

$browserHelpers = @()
try {
  $browserHelpers = Get-Process | Where-Object {
    $_.ProcessName -match 'chrome|edge|firefox|brave' -and $_.MainWindowTitle -eq ''
  } | Select-Object -ExpandProperty ProcessName -Unique -First 10
} catch {}

# ─── 8. SYSTEM ─────────────────────────────────────────────────────────
Post-Progress "scanning_system" 92
Write-Host "💻 Scanning system info..."
$osVersion = $os.Version
$osBuild   = $os.BuildNumber
$batteryHealth = 0
try {
  $batt = Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue
  $full = Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue
  if ($batt -and $full -and $batt.DesignedCapacity -gt 0) {
    $batteryHealth = [math]::Round(($full.FullChargedCapacity / $batt.DesignedCapacity) * 100, 0)
  }
} catch {}
$crashReportsCount = 0
try {
  $events = Get-WinEvent -FilterHashtable @{ LogName='Application'; Level=1,2; StartTime=(Get-Date).AddDays(-7) } -MaxEvents 100 -ErrorAction SilentlyContinue
  $crashReportsCount = ($events | Measure-Object).Count
} catch {}
$consoleErrors = @()
try {
  $consoleErrors = Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2; StartTime=(Get-Date).AddHours(-1) } -MaxEvents 10 -ErrorAction SilentlyContinue |
                   ForEach-Object { ($_.Message -replace '\s+',' ').Substring(0, [Math]::Min(200, $_.Message.Length)) }
} catch {}

# ─── BUILD JSON PAYLOAD ────────────────────────────────────────────────
Post-Progress "submitting" 97
Write-Host "📤 Submitting to AI..."
$scanData = [ordered]@{
  os_type = "windows"
  storage = [ordered]@{
    disk_total_gb=$diskTotalGb; disk_used_gb=$diskUsedGb; disk_free_gb=$diskFreeGb; disk_percent_used=$diskPercent
    top_largest=@($topLargest); trash_size_gb=$recycleBinGb
    temp_size_gb=$tempGb; win_temp_size_gb=$winTempGb
    downloads_size_gb=$downloadsGb; downloads_file_count=$downloadsCount
  }
  memory = [ordered]@{
    ram_total_gb=$ramTotalGb; ram_used_gb=$ramUsedGb; ram_available_gb=$ramAvailableGb
    commit_percent=$commitPercent; top_processes_memory=@($topMem)
    swap_used_gb=$swapUsedGb; swap_total_gb=$swapTotalGb
  }
  cpu = [ordered]@{
    cpu_percent=$cpuPercent; top_processes_cpu=@($topCpu)
    process_count=$processCount; uptime_days=$uptimeDays
  }
  startup = [ordered]@{
    login_items=@($loginItems); scheduled_tasks=@($scheduledTasks)
    services_auto=@($autoServices); startup_count=$startupCount
  }
  network = [ordered]@{
    dns_servers=@($dnsServers); dns_response_ms=$dnsResponseMs
    ping_8888_ms=$pingMs; active_interface=$activeInterface; active_ip=$activeIp
    dns_cache_entries=$dns<file-based-block id="summary" uiType="summary" status="success" text="" subtext="" code="" domains="" updates="[{&quot;device&quot;:&quot;web&quot;,&quot;url&quot;:&quot;/helpit-agent/session/[id]&quot;}]" thinkingType="" browserLiveUrl="" browserSize="" browserReplayUrl="" browserCurrentUrl="" simulatorWebrtcUrl="" simulatorToken="" simulatorPlatform="" simulatorReplayUrl="" simulatorLastActionType="" simulatorLastActionX="" simulatorLastActionY="" simulatorLastActionEndX="" simulatorLastActionEndY="" cancellable="false" isBackground="false" progress="" timeoutMs="" revisions="[]" suggestedRevisionId="" truncated="" todos="[]"> </file-based-block>
