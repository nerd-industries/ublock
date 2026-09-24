#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Nerdy Neighbor - Install uBlock on every installed browser
.DESCRIPTION
    Finds which of Edge, Chrome and Firefox are ACTUALLY installed (the program
    itself, not leftover profile folders) and installs uBlock on each one in a
    single run, through browser policy (normal install: the user can disable
    it but not remove it):

      Edge     uBlock Origin        (or uBlock Origin Lite with $env:NN_EDGE='lite')
      Chrome   uBlock Origin Lite   (full uBlock Origin no longer runs on Chrome)
      Firefox  uBlock Origin        (also allowed in Private Windows, by policy)

    uBlock Origin Lite is set to the "Complete" filtering mode by policy.

    Chrome and Edge have NO policy that turns on "Allow in Incognito/InPrivate",
    so that toggle is flipped by hand afterwards (the script reminds you).

.NOTES
    Run:  irm ublock.nerdyneighbor.net | iex        (elevated Windows PowerShell)
    Log:  C:\ProgramData\NerdyNeighbor\ublock.log
    Options (set BEFORE the irm line, since iex can't take parameters):
      $env:NN_EDGE   = 'lite'     # Edge gets uBlock Origin Lite instead of full uBO
      $env:NN_UBLOCK = 'revert'   # remove everything this script set

    Full uBlock Origin on Edge is a Manifest V2 extension. Microsoft is turning
    MV2 off for consumers by the end of 2026. When that happens, re-run with
    $env:NN_EDGE='lite' (or flip $EdgeDefault below).
#>

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# When run via `irm ... | iex` the #Requires line is NOT enforced (that only
# works for a real .ps1 file), so check for elevation ourselves.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  This needs an ELEVATED PowerShell (Run as Administrator)." -ForegroundColor Red
    Write-Host "  Close this window, reopen PowerShell as Administrator, and run again." -ForegroundColor Yellow
    Write-Host ""
    return
}

# --- Settings ------------------------------------------------------------------
$EdgeDefault = 'origin'   # flip to 'lite' once Edge kills Manifest V2 for good

$Ext = @{
    ChromeLite = @{ Id = 'ddkjiahejlhfcafbddmgiahcphecmpfh'; Name = 'uBlock Origin Lite' }
    EdgeOrigin = @{ Id = 'odfafepnkmbhccpbejgmiehpchacaeak'; Name = 'uBlock Origin' }
    EdgeLite   = @{ Id = 'cimighlppcgcoapaliogpjjdehbnofhn'; Name = 'uBlock Origin Lite' }
    Firefox    = @{ Id = 'uBlock0@raymondhill.net';          Name = 'uBlock Origin'
                    Url = 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi' }
}
$ChromeUpdateUrl = 'https://clients2.google.com/service/update2/crx'
$EdgeUpdateUrl   = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'

$ChromePolicy  = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
$EdgePolicy    = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$FirefoxPolicy = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
$StateKey      = 'HKLM:\SOFTWARE\NerdyNeighbor\uBlock'   # remembers what we changed, for revert

# --- Logging -------------------------------------------------------------------
$LogDir  = Join-Path $env:ProgramData 'NerdyNeighbor'
$LogFile = Join-Path $LogDir 'ublock.log'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  [{1}]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    switch ($Level) {
        'ERROR' { Write-Host "  $Message" -ForegroundColor Red }
        'WARN'  { Write-Host "  $Message" -ForegroundColor Yellow }
        'OK'    { Write-Host "  $Message" -ForegroundColor Green }
        default { Write-Host "  $Message" -ForegroundColor Gray }
    }
}

# --- Who is at the keyboard? -----------------------------------------------------
# Interactive = a tech in a console, not SYSTEM from the RMM.
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$script:Interactive = [Environment]::UserInteractive -and -not $me.IsSystem -and -not [Console]::IsInputRedirected

# --- Browser detection -------------------------------------------------------------
# "Installed" = the browser's program file exists AND Windows has it registered
# (Uninstall entry / App Paths / Store package). A leftover profile folder or a
# stale registry entry alone does not count.
function Get-UninstallEntries {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    # Per-user installs (Chrome can install into AppData) live in each user's hive.
    Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
        ForEach-Object { $roots += "Registry::HKEY_USERS\$($_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" }
    foreach ($r in $roots) { Get-ItemProperty $r -ErrorAction SilentlyContinue | Where-Object DisplayName }
}

function Find-Browsers {
    $found   = [ordered]@{}
    $entries = @(Get-UninstallEntries)
    $pf  = $env:ProgramFiles
    $pfx = ${env:ProgramFiles(x86)}

    # Edge
    $edgeExe = @("$pfx\Microsoft\Edge\Application\msedge.exe", "$pf\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($edgeExe -and ($entries | Where-Object { $_.DisplayName -eq 'Microsoft Edge' })) { $found.Edge = $edgeExe }

    # Chrome (system-wide or per-user)
    $chromeExe = @("$pf\Google\Chrome\Application\chrome.exe", "$pfx\Google\Chrome\Application\chrome.exe")
    $chromeExe += Get-ChildItem "$env:SystemDrive\Users\*\AppData\Local\Google\Chrome\Application\chrome.exe" -ErrorAction SilentlyContinue |
        ForEach-Object FullName
    $chromeReg = $entries | Where-Object { $_.DisplayName -eq 'Google Chrome' }
    $chromeHit = $chromeExe | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($chromeHit -and $chromeReg) { $found.Chrome = $chromeHit }

    # Firefox (classic installer or Microsoft Store)
    $ffReg = $entries | Where-Object { $_.DisplayName -like 'Mozilla Firefox*' -and $_.InstallLocation }
    $ffExe = $ffReg | ForEach-Object { Join-Path $_.InstallLocation 'firefox.exe' } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $ffExe) {
        $pkg = Get-AppxPackage -AllUsers -Name 'Mozilla.Firefox' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg) { $ffExe = Join-Path $pkg.InstallLocation 'VFS\ProgramFiles\Firefox Package Root\firefox.exe' }
    }
    if ($ffExe) { $found.Firefox = $ffExe }

    return $found
}

# --- Policy helpers ------------------------------------------------------------------
# ExtensionSettings is a JSON string in the registry. Merge our entry into
# whatever is already there instead of overwriting another tool's settings.
function Read-JsonPolicy([string]$Key) {
    $raw = (Get-ItemProperty -Path $Key -Name ExtensionSettings -ErrorAction SilentlyContinue).ExtensionSettings
    if ($raw -is [array]) { $raw = $raw -join '' }
    $obj = @{}
    if ($raw -and $raw.Trim()) {
        $parsed = $raw | ConvertFrom-Json
        foreach ($p in $parsed.PSObject.Properties) { $obj[$p.Name] = $p.Value }
    }
    return $obj
}

function Write-JsonPolicy([string]$Key, [hashtable]$Obj) {
    if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }
    if ($Obj.Count -eq 0) {
        Remove-ItemProperty -Path $Key -Name ExtensionSettings -ErrorAction SilentlyContinue
        return
    }
    $json = $Obj | ConvertTo-Json -Depth 10 -Compress
    New-ItemProperty -Path $Key -Name ExtensionSettings -Value $json -PropertyType String -Force | Out-Null
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'String') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Set-ChromiumExtension([string]$PolicyKey, [string]$Id, [string]$UpdateUrl, [string[]]$RemoveIds) {
    $s = Read-JsonPolicy $PolicyKey
    foreach ($r in $RemoveIds) { $s.Remove($r) }
    $s[$Id] = @{ installation_mode = 'normal_installed'; update_url = $UpdateUrl }
    Write-JsonPolicy $PolicyKey $s
}

function Set-LiteComplete([string]$PolicyKey, [string]$Id) {
    # uBlock Origin Lite reads this through chrome.storage.managed.
    Set-Reg "$PolicyKey\3rdparty\extensions\$Id\policy" 'defaultFiltering' 'complete'
}

# --- Browser restart ----------------------------------------------------------------
$ProcName = @{ Edge = 'msedge'; Chrome = 'chrome'; Firefox = 'firefox' }

function Restart-Browsers([string[]]$Names) {
    $running = $Names | Where-Object { Get-Process $ProcName[$_] -ErrorAction SilentlyContinue }
    if (-not $running) { return $true }
    if (-not $script:Interactive) {
        Write-Log ("{0} is open - uBlock installs next time it is fully closed and reopened." -f ($running -join ', ')) 'WARN'
        return $false
    }
    $a = Read-Host ("  Close {0} now to finish installing? Unsaved tabs will close. [Y/n]" -f ($running -join ', '))
    if ($a.Trim().ToLower() -eq 'n') {
        Write-Log "Skipped browser restart - uBlock installs after the browser is fully closed." 'WARN'
        return $false
    }
    # Policies are only re-read when EVERY process exits (startup boost keeps Edge alive).
    foreach ($n in $running) { Get-Process $ProcName[$n] -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Write-Log ("Closed {0}." -f ($running -join ', '))
    return $true
}

# --- Revert ---------------------------------------------------------------------------
function Invoke-Revert {
    Write-Log "Reverting uBlock policies..."
    foreach ($pair in @(
        @{ Key = $ChromePolicy;  Ids = @($Ext.ChromeLite.Id) },
        @{ Key = $EdgePolicy;    Ids = @($Ext.EdgeOrigin.Id, $Ext.EdgeLite.Id) },
        @{ Key = $FirefoxPolicy; Ids = @($Ext.Firefox.Id) }
    )) {
        if (Test-Path $pair.Key) {
            $s = Read-JsonPolicy $pair.Key
            foreach ($id in $pair.Ids) { $s.Remove($id) }
            Write-JsonPolicy $pair.Key $s
        }
    }
    foreach ($p in @("$ChromePolicy\3rdparty\extensions\$($Ext.ChromeLite.Id)",
                     "$EdgePolicy\3rdparty\extensions\$($Ext.EdgeLite.Id)")) {
        Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ((Get-ItemProperty $StateKey -ErrorAction SilentlyContinue).SetMV2 -eq 1) {
        Remove-ItemProperty -Path $EdgePolicy -Name ExtensionManifestV2Availability -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $StateKey -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Policies removed. uBlock stays installed but can now be removed normally from each browser." 'OK'
}

# --- Main -------------------------------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  Nerdy Neighbor - Install uBlock (Edge / Chrome / Firefox)" -ForegroundColor Cyan
    Write-Host ""
    Write-Log "=== Run started on $env:COMPUTERNAME (user: $env:USERNAME, interactive: $script:Interactive) ==="

    if ("$env:NN_UBLOCK".Trim().ToLower() -eq 'revert') { Invoke-Revert; Write-Host ""; return }

    $edgeMode = "$env:NN_EDGE".Trim().ToLower()
    if (-not $edgeMode) { $edgeMode = $EdgeDefault }
    if ($edgeMode -notin @('origin', 'lite')) {
        Write-Log "Unknown NN_EDGE '$edgeMode' - use 'origin' or 'lite'." 'ERROR'
        return
    }

    $browsers = Find-Browsers
    if ($browsers.Count -eq 0) {
        Write-Log "No Edge, Chrome or Firefox install found - nothing to do." 'WARN'
        return
    }
    Write-Log ("Found: {0}" -f (($browsers.Keys | ForEach-Object { "$_ ($($browsers[$_]))" }) -join '; '))

    $done = @()

    if ($browsers.Contains('Edge')) {
        if ($edgeMode -eq 'lite') {
            Set-ChromiumExtension $EdgePolicy $Ext.EdgeLite.Id $EdgeUpdateUrl @($Ext.EdgeOrigin.Id)
            Set-LiteComplete $EdgePolicy $Ext.EdgeLite.Id
            $edgeExt = $Ext.EdgeLite
            Write-Log "Edge: uBlock Origin Lite (Complete filtering) set to install." 'OK'
        } else {
            Set-ChromiumExtension $EdgePolicy $Ext.EdgeOrigin.Id $EdgeUpdateUrl @($Ext.EdgeLite.Id)
            Remove-Item "$EdgePolicy\3rdparty\extensions\$($Ext.EdgeLite.Id)" -Recurse -Force -ErrorAction SilentlyContinue
            # Keep Manifest V2 extensions (full uBO) allowed for as long as Edge permits.
            $cur = (Get-ItemProperty $EdgePolicy -ErrorAction SilentlyContinue).ExtensionManifestV2Availability
            if ($null -eq $cur) {
                Set-Reg $EdgePolicy 'ExtensionManifestV2Availability' 2 'DWord'
                Set-Reg $StateKey 'SetMV2' 1 'DWord'
            }
            $edgeExt = $Ext.EdgeOrigin
            Write-Log "Edge: uBlock Origin set to install." 'OK'
        }
        $done += 'Edge'
    }

    if ($browsers.Contains('Chrome')) {
        Set-ChromiumExtension $ChromePolicy $Ext.ChromeLite.Id $ChromeUpdateUrl @()
        Set-LiteComplete $ChromePolicy $Ext.ChromeLite.Id
        Write-Log "Chrome: uBlock Origin Lite (Complete filtering) set to install." 'OK'
        $done += 'Chrome'
    }

    if ($browsers.Contains('Firefox')) {
        $s = Read-JsonPolicy $FirefoxPolicy
        $s[$Ext.Firefox.Id] = @{
            installation_mode = 'normal_installed'
            install_url       = $Ext.Firefox.Url
            private_browsing  = $true
        }
        Write-JsonPolicy $FirefoxPolicy $s
        Write-Log "Firefox: uBlock Origin set to install, allowed in Private Windows." 'OK'
        $done += 'Firefox'
    }

    Set-Reg $StateKey 'LastRun' (Get-Date -Format s)
    Set-Reg $StateKey 'EdgeMode' $edgeMode

    # Apply now: extensions install once each browser fully restarts.
    Restart-Browsers $done | Out-Null
    $chromium = @($done | Where-Object { $_ -in 'Edge', 'Chrome' })
    if ($chromium) {
        Write-Host ""
        Write-Log ("Manual step: in {0}, open the extensions page, click uBlock > Details, and turn on 'Allow in Incognito' (Edge: 'Allow in InPrivate')." -f ($chromium -join ' and ')) 'WARN'
    }

    Write-Host ""
    Write-Log ("Done: uBlock set up on {0}." -f ($done -join ', ')) 'OK'
    Write-Host ""
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" 'ERROR'
    Write-Host "  Log: $LogFile" -ForegroundColor Yellow
    Write-Host ""
}
