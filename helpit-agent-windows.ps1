# HelpIT Autonomous Agent — Windows Deep Scan + Fix (v4)
# Mirrors the macOS v4 flow. Read-only deep scan, client-side allowlist, approval polling,
# safe fix execution, result reporting, self-delete. Runs as the normal user (no admin).

$ErrorActionPreference = "SilentlyContinue"
$AuthToken    = "{{AUTH_TOKEN}}"
$SessionToken = "{{SESSION_TOKEN}}"
$SessionId    = "{{SESSION_ID}}"
$ApiBase      = "https://www.helpitinc.com"
$ScriptPath   = $MyInvocation.MyCommand.Path
$PollSecs     = 4
$PollMax      = 150

Start-Process "$ApiBase/helpit-agent/session/$SessionId" | Out-Null
function Cleanup-Exit([int]$code=0){ if($ScriptPath -and (Test-Path $ScriptPath)){ Remove-Item $ScriptPath -Force -EA SilentlyContinue }; exit $code }

Write-Host "Running deep scan..."

# ---- 0. HARDWARE / OEM IDENTITY (drives vendor-specific advice) ------------
$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$os   = Get-CimInstance Win32_OperatingSystem
$gpu  = (Get-CimInstance Win32_VideoController | Select-Object -First 1).Name
$manufacturer = $cs.Manufacturer
$model        = $cs.Model
$ramGb        = [math]::Round($cs.TotalPhysicalMemory/1GB,1)

# storage media type (SSD vs HDD) + health
$sysDisk = Get-PhysicalDisk | Select-Object -First 1
$mediaType  = $sysDisk.MediaType
$diskHealth = $sysDisk.HealthStatus

# ---- 1. STORAGE ------------------------------------------------------------
$vol = Get-Volume -DriveLetter C
$totalGb = [math]::Round($vol.Size/1GB,2)
$freeGb  = [math]::Round($vol.SizeRemaining/1GB,2)
$pctUsed = if($vol.Size){ [math]::Round((($vol.Size-$vol.SizeRemaining)/$vol.Size)*100,0) } else {0}
$tempMb  = [math]::Round((Get-ChildItem $env:TEMP -Recurse -EA SilentlyContinue | Measure-Object Length -Sum).Sum/1MB,1)

# ---- 2/3. MEMORY + CPU (named offenders only) ------------------------------
$freeRamPct = if($os.TotalVisibleMemorySize){ [math]::Round(($os.FreePhysicalMemory/$os.TotalVisibleMemorySize)*100,0) } else {0}
$topCpu = Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 |
  ForEach-Object { @{ name=$_.ProcessName; cpu=[math]::Round($_.CPU,0); pid=$_.Id } }

# ---- 4. STARTUP ------------------------------------------------------------
$startup = Get-CimInstance Win32_StartupCommand | ForEach-Object { @{ name=$_.Name; location=$_.Location } }

# ---- 5. NETWORK ------------------------------------------------------------
$dnsOk = Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet

# ---- 6. SECURITY (read-only) -----------------------------------------------
$def = Get-MpComputerStatus
$defenderOn   = $def.RealTimeProtectionEnabled
$defStale     = $def.AntivirusSignatureAge   # days since last definition update
$fw = (Get-NetFirewallProfile | Where-Object {$_.Enabled -eq $true}).Count
$bitlocker = try { (Get-BitLockerVolume -MountPoint "C:").ProtectionStatus } catch { "Unknown" }
$pendingReboot = (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")

# ---- 7. BROWSER caches -----------------------------------------------------
function CacheMb($p){ if(Test-Path $p){ [math]::Round((Get-ChildItem $p -Recurse -EA SilentlyContinue | Measure-Object Length -Sum).Sum/1MB,1) } else {0} }
$chromeC = CacheMb "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
$edgeC   = CacheMb "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"

# ---- 8. EVENT LOG (recent critical/error correlation) ----------------------
$evtErrors = (Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2;StartTime=(Get-Date).AddDays(-7)} -MaxEvents 200 -EA SilentlyContinue |
  Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 |
  ForEach-Object { @{ id=$_.Name; count=$_.Count } })

# ---- 9. SYSTEM -------------------------------------------------------------
$uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays,1)

# ---- assemble payload ------------------------------------------------------
$payload = @{
  platform = "windows"
  hardware = @{ manufacturer=$manufacturer; model=$model; cpu=$cpu.Name; gpu=$gpu; ram_gb=$ramGb;
                bios=$bios.SMBIOSBIOSVersion; storage_type=$mediaType; disk_health=$diskHealth;
                os_name=$os.Caption; os_build=$os.BuildNumber }
  storage  = @{ total_gb=$totalGb; free_gb=$freeGb; percent_used=$pctUsed; temp_mb=$tempMb }
  memory   = @{ free_pct=$freeRamPct }
  cpu      = @{ top_processes=$topCpu }
  startup  = @{ items=$startup }
  network  = @{ dns_ok=$dnsOk }
  security = @{ defender_on=$defenderOn; definition_age_days=$defStale; firewall_profiles_on=$fw;
                bitlocker=$bitlocker.ToString(); pending_reboot=$pendingReboot }
  browser  = @{ chrome_cache_mb=$chromeC; edge_cache_mb=$edgeC }
  system   = @{ uptime_days=$uptimeDays; event_errors=$evtErrors }
}

$body = @{ sessionId=$SessionId; scan=$payload } | ConvertTo-Json -Depth 8
Invoke-RestMethod -Uri "$ApiBase/api/agent/scan" -Method Post -Body $body -ContentType "application/json" `
  -Headers @{ Authorization="Bearer $AuthToken"; "X-Session-Token"=$SessionToken } | Out-Null

Write-Host "Scan submitted. Review and approve fixes in your browser."

# ---- CLIENT-SIDE SAFETY ALLOWLIST (defense-in-depth) -----------------------
function Test-SafeCommand([string]$c){
  $deny = @('Format-','Remove-Item -Path "C:\\\\"','reg delete','bcdedit','diskpart','Stop-Computer','Restart-Computer','net user','sc delete')
  foreach($d in $deny){ if($c -match [regex]::Escape($d)){ return $false } }
  $allow = @(
    '^Remove-Item -Path "\$env:TEMP',
    '^Clear-RecycleBin',
    '^Clear-DnsClientCache',
    '^Stop-Process -Name ',
    '^Remove-Item -Path "\$env:LOCALAPPDATA\\Microsoft\\Windows\\Explorer\\thumbcache',
    '^Remove-Item -Path "\$env:LOCALAPPDATA\\Google\\Chrome',
    '^Remove-Item -Path "\$env:LOCALAPPDATA\\Microsoft\\Edge'
  )
  foreach($a in $allow){ if($c -match $a){ return $true } }
  return $false
}

# ---- poll for approval -----------------------------------------------------
$approved = $null
for($i=0; $i -lt $PollMax; $i++){
  $r = Invoke-RestMethod -Uri "$ApiBase/api/agent/session/$SessionId/approved" `
        -Headers @{ Authorization="Bearer $AuthToken"; "X-Session-Token"=$SessionToken } -EA SilentlyContinue
  if($r.status -eq "cancelled"){ Write-Host "Session cancelled."; Cleanup-Exit 0 }
  if($r.fixes -and $r.fixes.Count -gt 0){ $approved = $r; break }
  Start-Sleep -Seconds $PollSecs
}
if(-not $approved){ Write-Host "No fixes approved (timeout)."; Cleanup-Exit 0 }

# ---- execute approved fixes ------------------------------------------------
foreach($f in $approved.fixes){
  if([string]::IsNullOrWhiteSpace($f.command)){ continue }
  if(Test-SafeCommand $f.command){
    try { $out = (Invoke-Expression $f.command 2>&1 | Out-String); $status="success" }
    catch { $out = $_.Exception.Message; $status="failed" }
  } else { $out="blocked by client safety allowlist"; $status="blocked" }
  $rb = @{ sessionId=$SessionId; fixId=$f.id; status=$status; output=$out } | ConvertTo-Json -Depth 4
  Invoke-RestMethod -Uri "$ApiBase/api/agent/fix-result" -Method Post -Body $rb -ContentType "application/json" `
    -Headers @{ Authorization="Bearer $AuthToken"; "X-Session-Token"=$SessionToken } | Out-Null
}

Write-Host "All approved fixes complete."
Cleanup-Exit 0
