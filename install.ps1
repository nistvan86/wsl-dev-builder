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

$installArguments = @('--install', '--from-file', $artifactPath, '--name', $DistroName)
$configuredInstanceDirectory = if ($PSBoundParameters.ContainsKey('InstanceDirectory')) { $InstanceDirectory } elseif ($settings.ContainsKey('InstanceDirectory')) { [string]$settings['InstanceDirectory'] } else { '' }
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
    $installArguments += @('--location', $instanceDirectory)
}

Write-Host "Installing $imageLeafName as WSL distro $DistroName"
Invoke-Checked wsl.exe $installArguments 'WSL distribution installation'

Write-Host "Launching $DistroName interactively for first-run onboarding"
& wsl.exe -d $DistroName
if ($LASTEXITCODE -ne 0) { throw "interactive WSL launch failed with exit code $LASTEXITCODE" }
