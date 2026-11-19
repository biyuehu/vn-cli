[CmdletBinding()]
param(
    [string]$Version = "latest",
    [string]$InstallDir = "$HOME\.senavn\bin",
    [string]$Repo = "biyuehu/vn-cli"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$C_RESET   = "`e[0m"
$C_BOLD    = "`e[1m"
$C_CYAN    = "`e[36m"
$C_GREEN   = "`e[32m"
$C_YELLOW  = "`e[33m"
$C_RED     = "`e[31m"
$C_MAGENTA = "`e[35m"

function Write-Step {
    param([string]$Text)
    Write-Host "${C_CYAN}${C_BOLD}==>${C_RESET} ${C_BOLD}${Text}${C_RESET}"
}

function Write-Success {
    param([string]$Text)
    Write-Host "${C_GREEN}${C_BOLD}✔${C_RESET} ${Text}"
}

function Write-Warn {
    param([string]$Text)
    Write-Host "${C_YELLOW}${C_BOLD}!${C_RESET} ${Text}"
}

function Write-Failure {
    param([string]$Text)
    Write-Host "${C_RED}${C_BOLD}✖ Error:${C_RESET} ${Text}"
    exit 1
}

$runningProcesses = Get-Process -Name "sena", "SenaVN", "sena-guard" -ErrorAction SilentlyContinue
if ($runningProcesses) {
    Write-Warn "Terminating active SenaVN processes before upgrade..."
    $runningProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

Write-Step "Resolving SenaVN Release ($Version)..."

$headers = @{
    "User-Agent" = "SenaVN-Installer/2.0"
}
if ($env:GITHUB_TOKEN) {
    $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
}

$releaseApiUrl = if ($Version -eq "latest") {
    "https://api.github.com/repos/$Repo/releases/latest"
} else {
    "https://api.github.com/repos/$Repo/releases/tags/$Version"
}

try {
    $releaseInfo = Invoke-RestMethod -Uri $releaseApiUrl -Headers $headers -Method Get
} catch {
    Write-Failure "Failed to fetch release information from GitHub API: $_"
}

$resolvedTag = $releaseInfo.tag_name
Write-Success "Found release ${C_MAGENTA}${resolvedTag}${C_RESET}"

if (-not (Test-Path $InstallDir)) {
    Write-Step "Creating install directory: $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

$assetsToDownload = @(
    @{
        RemotePattern = "sena-x86_64-windows.exe"
        LocalTargets  = @("sena.exe", "SenaVN.exe")
        Required      = $true
    },
    @{
        RemotePattern = "sena-guard-x86_64-windows.exe"
        LocalTargets  = @("sena-guard.exe")
        Required      = $true
    },
    @{
        RemotePattern = "LICENSE"
        LocalTargets  = @("LICENSE")
        Required      = $false
    }
)

foreach ($item in $assetsToDownload) {
    $asset = $releaseInfo.assets | Where-Object { $_.name -like "*$($item.RemotePattern)*" } | Select-Object -First 1

    if (-not $asset) {
        if ($item.Required) {
            Write-Failure "Required asset '$($item.RemotePattern)' not found in release $resolvedTag."
        } else {
            Write-Warn "Optional asset '$($item.RemotePattern)' not found, skipping."
            continue
        }
    }

    $primaryTarget = $item.LocalTargets[0]
    $downloadPath = Join-Path $InstallDir $primaryTarget

    Write-Step "Downloading ${C_CYAN}$($asset.name)${C_RESET} -> $primaryTarget..."
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath -UseBasicParsing
    } catch {
        Write-Failure "Failed to download $($asset.name): $_"
    }

    for ($i = 1; $i -lt $item.LocalTargets.Count; $i++) {
        $secondaryTarget = $item.LocalTargets[$i]
        $secondaryPath = Join-Path $InstallDir $secondaryTarget
        Copy-Item -Path $downloadPath -Destination $secondaryPath -Force
    }
    Write-Success "Installed $primaryTarget"
}

Write-Step "Configuring Environment PATH..."

$userPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
$resolvedInstallDir = (Resolve-Path $InstallDir).Path

$pathSegments = ($userPath -split ';') | Where-Object { $_ -ne "" }
if ($pathSegments -notcontains $resolvedInstallDir) {
    Write-Step "Adding $resolvedInstallDir to User PATH..."
    $newUserPath = ($pathSegments + $resolvedInstallDir) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newUserPath, [EnvironmentVariableTarget]::User)
    Write-Success "Persisted to User PATH."
} else {
    Write-Success "Install directory is already in User PATH."
}

if (($env:PATH -split ';') -notcontains $resolvedInstallDir) {
    $env:PATH = "$env:PATH;$resolvedInstallDir"
}

$senaInstalled = Join-Path $InstallDir "sena.exe"
if (Test-Path $senaInstalled) {
    Write-Host ""
    Write-Host "${C_GREEN}${C_BOLD}====================================================${C_RESET}"
    Write-Host "${C_GREEN}${C_BOLD}   SenaVN (GalKeeper 2.0) Installed Successfully!   ${C_RESET}"
    Write-Host "${C_GREEN}${C_BOLD}====================================================${C_RESET}"
    Write-Host ""
    Write-Host "  ${C_BOLD}Binary Path :${C_RESET} $resolvedInstallDir"
    Write-Host "  ${C_BOLD}Version     :${C_RESET} $resolvedTag"
    Write-Host ""
    Write-Host "Quick Start:"
    Write-Host "  ${C_CYAN}sena${C_RESET}                   # Launch interactive TUI"
    Write-Host "  ${C_CYAN}sena add <name> <id>${C_RESET}   # Add a game from VNDB"
    Write-Host "  ${C_CYAN}sena use <id>${C_RESET}          # Link executable via TUI picker"
    Write-Host "  ${C_CYAN}sena run <id>${C_RESET}          # Launch and track gameplay"
    Write-Host ""
} else {
    Write-Failure "Verification failed: $senaInstalled does not exist."
}
