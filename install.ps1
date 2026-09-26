[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImageName,
    [Parameter(Mandatory)][string]$DistroName,
    [string]$InstanceDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$ArgumentList, [string]$Phase = 'external command')
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "$Phase failed with exit code $LASTEXITCODE" }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$settingsName = "{0}.settings.psd1" -f [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
$settingsPath = Join-Path $scriptRoot $settingsName

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'wsl.exe was not found. Enable Windows Subsystem for Linux and Virtual Machine Platform, reboot, and run "wsl --install" from an elevated PowerShell prompt.'
}

$imageLeafName = Split-Path -Leaf $ImageName
if ($ImageName -ne $imageLeafName -or $imageLeafName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.wsl$') {
    throw 'ImageName must be a .wsl filename only; it is resolved from this project''s dist directory.'
}
if ($DistroName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "invalid distro name: $DistroName"
}

$artifactPath = Join-Path $scriptRoot (Join-Path 'dist' $imageLeafName)
if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "built image was not found: $artifactPath"
}
$manifestPath = "$artifactPath.txt"
$scratchEnabled = $false
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $scratchLines = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ -like 'Windows scratch directory:*' })
    if ($scratchLines.Count -gt 1) { throw "image manifest has duplicate Windows scratch settings: $manifestPath" }
    if ($scratchLines.Count -eq 1) {
        switch ($scratchLines[0]) {
            'Windows scratch directory: enabled' { $scratchEnabled = $true }
            'Windows scratch directory: disabled' { }
            default { throw "image manifest has an invalid Windows scratch setting: $manifestPath" }
        }
    }
}

$registeredDistros = @(& wsl.exe --list --quiet)
if ($LASTEXITCODE -ne 0) { throw 'wsl --list --quiet failed' }
$registeredDistros = @($registeredDistros | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
if ($registeredDistros -contains $DistroName) {
    throw "a WSL distro is already registered with this name: $DistroName"
}

$settings = @{}
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $settings = Import-PowerShellDataFile -LiteralPath $settingsPath
    foreach ($key in $settings.Keys) {
        if ($key -ne 'InstanceDirectory') { throw "unsupported setting in ${settingsPath}: $key" }
    }
}

$installArguments = @('--install', '--from-file', $artifactPath, '--name', $DistroName, '--no-launch')
$configuredInstanceDirectory = if ($PSBoundParameters.ContainsKey('InstanceDirectory')) { $InstanceDirectory } elseif ($settings.ContainsKey('InstanceDirectory')) { [string]$settings['InstanceDirectory'] } else { '' }
if ($scratchEnabled -and [string]::IsNullOrWhiteSpace($configuredInstanceDirectory)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is required for the default Windows scratch instance location' }
    $configuredInstanceDirectory = Join-Path $env:LOCALAPPDATA 'wsl-dev-builder\instances'
    New-Item -ItemType Directory -Path $configuredInstanceDirectory -Force | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($configuredInstanceDirectory)) {
    $baseDirectory = $configuredInstanceDirectory
    if (-not [System.IO.Path]::IsPathRooted($baseDirectory)) {
        throw "InstanceDirectory must be an absolute Windows path: $baseDirectory"
    }
    $baseDirectory = [System.IO.Path]::GetFullPath($baseDirectory)
    if (-not (Test-Path -LiteralPath $baseDirectory -PathType Container)) {
        throw "InstanceDirectory does not exist: $baseDirectory"
    }
    $instanceDirectory = Join-Path $baseDirectory $DistroName
    if (Test-Path -LiteralPath $instanceDirectory) {
        throw "instance storage directory already exists: $instanceDirectory"
    }
    if ($scratchEnabled -and $instanceDirectory -notmatch '^[A-Za-z]:\\') {
        throw "WindowsScratchDir requires a drive-letter instance location: $instanceDirectory"
    }
    $installArguments += @('--location', $instanceDirectory)
}

Write-Host "Installing $imageLeafName as WSL distro $DistroName"
Invoke-Checked wsl.exe $installArguments 'WSL distribution installation'

if ($scratchEnabled) {
    $vhdxFiles = @(Get-ChildItem -LiteralPath $instanceDirectory -Filter '*.vhdx' -File)
    if ($vhdxFiles.Count -ne 1) { throw "expected one VHDX in installed instance directory: $instanceDirectory" }
    $scratchPath = Join-Path $instanceDirectory 'windows-scratch'
    if (Test-Path -LiteralPath $scratchPath) { throw "Windows scratch directory already exists: $scratchPath" }
    New-Item -ItemType Directory -Path $scratchPath | Out-Null
    $smokePath = Join-Path $scratchPath 'wsl-dev-builder-smoke-whoami.exe'
    try {
        Invoke-Checked wsl.exe @('-d', $DistroName, '-u', 'root', '--cd', '/home/ubuntu', '-e', '/usr/local/lib/wsl-dev-builder/configure-windows-scratch.sh', $scratchPath) 'Windows scratch instance configuration'
        Invoke-Checked wsl.exe @('-d', $DistroName, '-u', 'root', '--cd', '/home/ubuntu', '-e', '/usr/local/lib/wsl-dev-builder/mount-windows-scratch.sh') 'initial Windows scratch mount'
        Invoke-Checked wsl.exe @('-d', $DistroName, '-u', 'ubuntu', '--cd', '/home/ubuntu', '-e', '/usr/local/lib/wsl-dev-builder/isolation-runtime.sh', 'windows-scratch') 'Windows scratch isolation validation'
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\whoami.exe') -Destination $smokePath
        Invoke-Checked wsl.exe @('-d', $DistroName, '-u', 'ubuntu', '--cd', '/mnt/windows-scratch', '-e', '/mnt/windows-scratch/wsl-dev-builder-smoke-whoami.exe') 'Windows executable launch from scratch directory'
        Invoke-Checked wsl.exe @('--terminate', $DistroName) 'restart before Windows scratch boot validation'
        Invoke-Checked wsl.exe @('-d', $DistroName, '-u', 'root', '--cd', '/home/ubuntu', '-e', 'findmnt', '-n', '-M', '/mnt/windows-scratch') 'automatic Windows scratch mount after restart'
        Invoke-Checked wsl.exe @('-d', $DistroName, '-u', 'ubuntu', '--cd', '/home/ubuntu', '-e', '/usr/local/lib/wsl-dev-builder/isolation-runtime.sh', 'windows-scratch') 'Windows scratch isolation validation after restart'
        Invoke-Checked wsl.exe @('-d', $DistroName, '-u', 'ubuntu', '--cd', '/mnt/windows-scratch', '-e', '/mnt/windows-scratch/wsl-dev-builder-smoke-whoami.exe') 'Windows executable launch after restart'
    }
    catch {
        throw "Windows scratch setup failed for installed distro '$DistroName'; it remains registered for inspection: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $smokePath) { Remove-Item -LiteralPath $smokePath -Force -ErrorAction SilentlyContinue }
        try { Invoke-Checked wsl.exe @('--terminate', $DistroName) 'post-install distro termination' } catch { Write-Warning $_.Exception.Message }
    }
    Write-Host "Windows scratch directory: $scratchPath (mounted at /mnt/windows-scratch)"
}

Write-Host "Installation complete: $DistroName"
Write-Host "Launch interactively for onboarding with: wsl.exe -d $DistroName"
