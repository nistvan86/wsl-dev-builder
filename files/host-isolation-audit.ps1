[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-ItemStatus {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][object]$Value)
    $display = if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { '<not detected>' } else { [string]$Value }
    Write-Host ("{0}: {1}" -f $Name, $display)
}

Write-Host 'WSL host isolation audit (read-only)'
Write-ItemStatus 'WSL status' ((& wsl.exe --status 2>&1 | Out-String).Trim())
Write-ItemStatus 'WSL version' ((& wsl.exe --version 2>&1 | Out-String).Trim())
Write-ItemStatus 'Windows version' ((Get-CimInstance Win32_OperatingSystem).Caption + ' ' + (Get-CimInstance Win32_OperatingSystem).Version)

$wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
Write-ItemStatus 'Global .wslconfig' (if (Test-Path -LiteralPath $wslConfigPath) { $wslConfigPath } else { 'absent' })
if (Test-Path -LiteralPath $wslConfigPath -PathType Leaf) {
    $globalConfig = Get-Content -LiteralPath $wslConfigPath -Raw
    Write-ItemStatus 'WSLg guiApplications=false' ([bool]($globalConfig -match '(?im)^\s*guiApplications\s*=\s*false\s*$'))
    Write-ItemStatus 'WSL networkingMode' (([regex]::Match($globalConfig, '(?im)^\s*networkingMode\s*=\s*(\S+)\s*$')).Groups[1].Value)
}

$hyperVFirewallCommand = Get-Command Get-NetFirewallHyperVVMSetting -ErrorAction SilentlyContinue
if ($hyperVFirewallCommand) {
    Write-ItemStatus 'Hyper-V firewall settings' ((Get-NetFirewallHyperVVMSetting | Out-String).Trim())
} else {
    Write-ItemStatus 'Hyper-V firewall settings' 'Get-NetFirewallHyperVVMSetting unavailable'
}

$dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
$dockerDesktopPaths = @(
    (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
    (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
Write-ItemStatus 'Docker Desktop' (if ($dockerDesktopPaths) { $dockerDesktopPaths -join '; ' } else { 'not detected' })
Write-ItemStatus 'docker.exe' (if ($dockerCommand) { $dockerCommand.Source } else { 'not detected' })
$dockerDistro = (& wsl.exe --list --quiet 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ -eq 'docker-desktop' })
Write-ItemStatus 'docker-desktop WSL distro' (if ($dockerDistro) { 'present; review WSL Integration settings' } else { 'not detected' })

Write-Host 'No host settings were changed by this audit.'
