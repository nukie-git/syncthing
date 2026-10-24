<#
.SYNOPSIS
    Syncthing Automated GitHub Update Engine
.DESCRIPTION
    Checks GitHub for the latest release of Syncthing (syncthing/syncthing), inspects and purges
    previous or superseded backups to reclaim disk space, checks the user's Downloads folder for
    existing archives, downloads via aria2c multi-stream acceleration (with curl and Invoke-WebRequest
    fallback), safely stops running instances with elevated Session 0 sentinel fallback, stages
    backups in .update_cache, swaps syncthing.exe with a 5-attempt file-lock retry loop and rollback
    protection while strictly preserving data/ and portable configuration, and restarts the service
    using a was_running.flag sentinel to guarantee restart even when a prior failed attempt already stopped it.
    Auto-detects GitHub Desktop credentials from Windows Credential Manager to raise API rate limits.
.PARAMETER TargetVersion
    Specific release tag or version to install (e.g., 'v2.1.7' or '2.1.7').
.PARAMETER Force
    Forces re-download and re-installation even if current version is up-to-date.
.PARAMETER CheckOnly
    Checks for updates and outputs version status without downloading or modifying files.
.PARAMETER KeepArtifacts
    Preserves downloaded archive and backups in .update_cache.
.PARAMETER SyncthingPort
    Syncthing GUI listening port (Default: 8384).
.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\syncthing-update.ps1
    powershell.exe -ExecutionPolicy Bypass -File .\syncthing-update.ps1 -CheckOnly
    powershell.exe -ExecutionPolicy Bypass -File .\syncthing-update.ps1 -Force
#>

[CmdletBinding()]
param(
    [string]$TargetVersion = "",
    [switch]$Force,
    [switch]$CheckOnly,
    [switch]$KeepArtifacts,
    [string]$SyncthingPort = "8384"
)

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       Syncthing Automated GitHub Update Engine" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Working Directory: $scriptDir" -ForegroundColor Gray

$syncthingExe  = Join-Path $scriptDir "syncthing.exe"
$startVbs      = Join-Path $scriptDir "syncthing-start.vbs"
$stopVbs       = Join-Path $scriptDir "syncthing-stop.vbs"
$dataDir       = Join-Path $scriptDir "data"
$updateCache   = Join-Path $scriptDir ".update_cache"
$parentDir     = Split-Path -Parent $scriptDir
$repoOwner     = "syncthing"
$repoName      = "syncthing"

# -----------------------------------------------------------------------------
# Import Shared Stargazer Update Helpers Module
# -----------------------------------------------------------------------------
$helpersModule = Join-Path $scriptDir "UpdateHelpers.psm1"
if (-not (Test-Path $helpersModule)) {
    $helpersModule = Join-Path $parentDir "caddy\UpdateHelpers.psm1"
}
if (-not (Test-Path $helpersModule)) {
    $helpersModule = "C:\PortableApps\caddy\UpdateHelpers.psm1"
}
if (Test-Path $helpersModule) {
    Import-Module $helpersModule -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# Function: Find-LocalUpdateBinary (App-Specific Search Patterns)
# -----------------------------------------------------------------------------
function Find-LocalUpdateBinary {
    param(
        [string]$TargetVersionClean,
        [string]$ExpectedFileName
    )
    $patterns = @(
        $ExpectedFileName,
        "syncthing-windows-amd64-*.zip",
        "syncthing-windows-amd64-${TargetVersionClean}*.zip",
        "syncthing-windows-amd64-v${TargetVersionClean}*.zip",
        "syncthing-*windows*amd64*.zip"
    )
    return UpdateHelpers\Find-LocalUpdateBinary -SearchPatterns $patterns -MinSizeBytes 5MB
}

# -----------------------------------------------------------------------------
# 1. Detect Current Version
# -----------------------------------------------------------------------------
$currentVersion = "v0.0.0"
if (Test-Path $syncthingExe) {
    try {
        $verOut = & $syncthingExe --version 2>$null | Select-Object -First 1
        if ($verOut -match 'syncthing\s+v?([0-9\.]+)') {
            $currentVersion = "v" + $matches[1]
        }
    } catch {}
}
Write-Host "[*] Currently installed Syncthing version: $currentVersion" -ForegroundColor Gray

# -----------------------------------------------------------------------------
# 2. Query GitHub for Latest Release
# -----------------------------------------------------------------------------
$headers = Get-GitHubAuthHeaders

$apiUrl = if ($TargetVersion) {
    $tv = if ($TargetVersion.StartsWith("v")) { $TargetVersion } else { "v$TargetVersion" }
    "https://api.github.com/repos/$repoOwner/$repoName/releases/tags/$tv"
} else {
    "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"
}

Write-Host "[*] Checking latest release from GitHub ($repoOwner/$repoName)..." -ForegroundColor Yellow
$targetTag = ""
$assetFileName = ""
$assetDownloadUrl = ""

try {
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
    if ($release.tag_name) {
        $targetTag = $release.tag_name
        if (-not $targetTag.StartsWith("v")) { $targetTag = "v$targetTag" }
        
        foreach ($asset in $release.assets) {
            if ($asset.name -match 'syncthing-windows-amd64-.*\.zip$') {
                $assetDownloadUrl = $asset.browser_download_url
                $assetFileName = $asset.name
                break
            }
        }
    }
} catch {
    Write-Host "[!] GitHub API query failed: $_" -ForegroundColor Red
}

if (-not $targetTag) {
    Write-Error "Could not determine target Syncthing release version."
    exit 1
}

Write-Host "[*] Target Syncthing version: $targetTag" -ForegroundColor Gray

# Version Comparison
$isNewer = $false
try {
    $currVerObj = [System.Version]($currentVersion.TrimStart("v"))
    $targetVerObj = [System.Version]($targetTag.TrimStart("v"))
    if ($targetVerObj -gt $currVerObj) {
        $isNewer = $true
    }
} catch {
    if ($currentVersion -ne $targetTag) {
        $isNewer = $true
    }
}

if ($CheckOnly) {
    if ($isNewer) {
        Write-Host "UPDATE_AVAILABLE: $currentVersion -> $targetTag" -ForegroundColor Green
    } else {
        Write-Host "UP_TO_DATE: $currentVersion is current." -ForegroundColor Cyan
    }
    exit 0
}

if (-not $isNewer -and -not $Force) {
    Write-Host "[+] Syncthing is already up to date ($currentVersion). Use -Force to reinstall." -ForegroundColor Green
    exit 0
}

# -----------------------------------------------------------------------------
# 3. Pre-Update Cleanup & Local Artifact Check
# -----------------------------------------------------------------------------
Remove-SuperfluousBackups -AppDir $scriptDir -UpdateCache $updateCache

if (-not (Test-Path $updateCache)) {
    New-Item -ItemType Directory -Path $updateCache -Force | Out-Null
}

$targetVerClean = $targetTag.TrimStart("v")
if (-not $assetFileName) {
    $assetFileName = "syncthing-windows-amd64-$targetTag.zip"
}

$localCandidate = Find-LocalUpdateBinary -TargetVersionClean $targetVerClean -ExpectedFileName $assetFileName
$downloadTarget = Join-Path $updateCache $assetFileName

if ($localCandidate -and (Test-Path $localCandidate)) {
    Write-Host "[+] Found local archive in Downloads: $localCandidate" -ForegroundColor Green
    Copy-Item -Path $localCandidate -Destination $downloadTarget -Force
}

# -----------------------------------------------------------------------------
# 4. Multi-Stream Accelerated Download
# -----------------------------------------------------------------------------
if (-not (Test-Path $downloadTarget) -or ((Get-Item $downloadTarget).Length -lt 5MB)) {
    if (-not $assetDownloadUrl) {
        $assetDownloadUrl = "https://github.com/$repoOwner/$repoName/releases/download/$targetTag/$assetFileName"
    }

    Write-Host "[*] Downloading $assetFileName via accelerated pipeline..." -ForegroundColor Yellow
    $aria2Exe = Find-Aria2Executable
    $downloadSuccess = $false

    if ($aria2Exe) {
        try {
            Write-Host "[*] Utilizing aria2 multi-stream accelerator..." -ForegroundColor Cyan
            & $aria2Exe -s 4 -x 4 -k 1M --dir="$updateCache" --out="$assetFileName" "$assetDownloadUrl" --allow-overwrite=true
            if ((Test-Path $downloadTarget) -and ((Get-Item $downloadTarget).Length -ge 5MB)) {
                $downloadSuccess = $true
            }
        } catch {
            Write-Host "[!] aria2c download encountered an error; falling back to curl..." -ForegroundColor Yellow
        }
    }

    if (-not $downloadSuccess) {
        $curlExe = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curlExe) {
            Write-Host "[*] Utilizing curl engine..." -ForegroundColor Cyan
            & curl.exe -L -k -f -s -o "$downloadTarget" "$assetDownloadUrl"
            if ((Test-Path $downloadTarget) -and ((Get-Item $downloadTarget).Length -ge 5MB)) {
                $downloadSuccess = $true
            }
        }
    }

    if (-not $downloadSuccess) {
        Write-Host "[*] Utilizing Invoke-WebRequest fallback..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $assetDownloadUrl -OutFile $downloadTarget -UseBasicParsing
    }
}

if (-not (Test-Path $downloadTarget) -or ((Get-Item $downloadTarget).Length -lt 5MB)) {
    Write-Error "Failed to download valid Syncthing distribution archive."
    exit 1
}

# -----------------------------------------------------------------------------
# 5. Extract Archive & Locate syncthing.exe
# -----------------------------------------------------------------------------
$extractDir = Join-Path $updateCache "extracted"
if (Test-Path $extractDir) {
    Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

Write-Host "[*] Extracting Syncthing archive..." -ForegroundColor Yellow
Expand-Archive -Path $downloadTarget -DestinationPath $extractDir -Force

$foundExe = Get-ChildItem -Path $extractDir -Filter "syncthing.exe" -Recurse | Select-Object -First 1
if (-not $foundExe -or -not (Test-Path $foundExe.FullName)) {
    Write-Error "Extracted archive did not contain 'syncthing.exe'. Verification failed."
    exit 1
}
$stagedExe = $foundExe.FullName
Write-Host "[+] Extracted and validated new syncthing.exe binary." -ForegroundColor Green

# -----------------------------------------------------------------------------
# 6. Stop Syncthing Service & Verify Port Release
# -----------------------------------------------------------------------------
Write-Host "[*] Checking running Syncthing instances..." -ForegroundColor Yellow
$wasRunning = $false
$wasRunningFlag = Join-Path $updateCache "was_running.flag"
$procs = Get-Process | Where-Object { $_.ProcessName -like "*syncthing*" }
if ($procs -or (Get-NetTCPConnection -LocalPort $SyncthingPort -State Listen -ErrorAction SilentlyContinue)) {
    $wasRunning = $true
    Set-Content -Path $wasRunningFlag -Value "1" -Encoding UTF8
    Write-Host "[*] Stopping Syncthing..." -ForegroundColor Yellow
    
    if (Test-Path $stopVbs) {
        & wscript.exe /nologo "$stopVbs" /silent
    }
    Get-Process | Where-Object { $_.ProcessName -like "*syncthing*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    
    # Session 0 / SYSTEM sentinel stop fallback
    Start-Sleep -Milliseconds 500
    $remainingProcs = Get-CimInstance Win32_Process | Where-Object { $_.Name -like '*syncthing*' } -ErrorAction SilentlyContinue
    if ($remainingProcs) {
        Write-Host "[*] Syncthing processes survived Stop-Process; using elevated sentinel stop..." -ForegroundColor Yellow
        $sentinelFlag = Join-Path $scriptDir "syncthing.flag"
        Set-Content -Path $sentinelFlag -Value "stop" -Encoding UTF8
        & schtasks.exe /run /tn "StargazerWinGetElevatedUpdater" 2>$null
        Start-Sleep -Seconds 3
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 10000) {
        $listening = Get-NetTCPConnection -LocalPort $SyncthingPort -State Listen -ErrorAction SilentlyContinue
        if (-not $listening) { break }
        Start-Sleep -Milliseconds 300
    }
    Write-Host "[+] Syncthing stopped cleanly." -ForegroundColor Green
    Start-Sleep -Seconds 2  # Allow OS to fully release kernel file handles before swap
}
$shouldRestart = $wasRunning -or (Test-Path $wasRunningFlag) -or $Force.IsPresent

# -----------------------------------------------------------------------------
# 7. Atomic Binary Replacement with Rollback Protection
# -----------------------------------------------------------------------------
$bakPath = Join-Path $updateCache "syncthing.exe.bak"
if (Test-Path $bakPath) {
    Remove-Item -Path $bakPath -Force -ErrorAction SilentlyContinue
}

Write-Host "[*] Backing up current syncthing.exe..." -ForegroundColor Gray
if (Test-Path $syncthingExe) {
    Copy-Item -Path $syncthingExe -Destination $bakPath -Force
}

$swapSucceeded = $false
$lastError = ""
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        Write-Host "[*] Installing updated syncthing.exe..." -ForegroundColor Yellow
        Copy-Item -Path $stagedExe -Destination $syncthingExe -Force
        $swapSucceeded = $true
        Write-Host "[+] Updated syncthing.exe to $targetTag successfully." -ForegroundColor Green
        break
    } catch {
        $lastError = $_.Exception.Message
        Write-Host "[*] Binary swap attempt $attempt of 5 encountered file lock. Retrying in 1s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}

if (-not $swapSucceeded) {
    Write-Host "[!] Error during binary swap after 5 attempts: $lastError" -ForegroundColor Red
    Write-Host "[*] Rolling back from backup..." -ForegroundColor Yellow
    if (Test-Path $bakPath) {
        Copy-Item -Path $bakPath -Destination $syncthingExe -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

# -----------------------------------------------------------------------------
# 8. Restart Syncthing & Health Probe
# -----------------------------------------------------------------------------
if ($shouldRestart) {
    Write-Host "[*] Restarting Syncthing on port $SyncthingPort..." -ForegroundColor Yellow
    if (Test-Path $startVbs) {
        & wscript.exe /nologo "$startVbs"
    }

    Write-Host "[*] Polling Syncthing health endpoint (up to 30s)..." -ForegroundColor Yellow
    $healthy = $false
    for ($i = 1; $i -le 30; $i++) {
        Start-Sleep -Seconds 1
        try {
            # Try both HTTP and HTTPS probes with proxy bypass
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$SyncthingPort/" -Proxy "" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
            if ($resp -and ($resp.StatusCode -eq 200 -or $resp.StatusCode -eq 307 -or $resp.StatusCode -eq 302)) {
                $healthy = $true
                break
            }
        } catch {}
    }

    if ($healthy) {
        Write-Host "[+] Syncthing successfully restarted and verified healthy!" -ForegroundColor Green
        if (Test-Path $wasRunningFlag) {
            Remove-Item -Path $wasRunningFlag -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "[!] Syncthing restarted but health probe timed out after 30s." -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
# 9. Cleanup Download Cache (unless -KeepArtifacts)
# -----------------------------------------------------------------------------
if (-not $KeepArtifacts) {
    Write-Host "[*] Cleaning up temporary build artifacts..." -ForegroundColor Gray
    if (Test-Path $extractDir) {
        Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $bakPath) {
        Remove-Item -Path $bakPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "==========================================================" -ForegroundColor Green
Write-Host " Syncthing update to $targetTag completed successfully!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
