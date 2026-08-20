param(
    [switch]$KeepStagingOnFailure,
    [string[]]$Packages,
    [string[]]$AddPackages,
    [string[]]$BaseUtilities,
    [string[]]$AddBaseUtilities,
    [string]$DistributionDirectory,
    [string]$ImageName = 'ubuntu-dev',
    [string]$ImageComment = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$stagingName = '__wsl_builder'
$imageReference = 'ubuntu:24.04'
$cranePath = Join-Path $scriptRoot 'crane.exe'
$tarPath = $null
$systemTarPath = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\tar.exe' } else { $null }
if ($systemTarPath -and (Test-Path -LiteralPath $systemTarPath -PathType Leaf)) {
    $tarPath = $systemTarPath
} else {
    $tarCommand = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tarCommand) { $tarPath = $tarCommand.Source }
}
if (-not $tarPath) {
    $localTarPath = Join-Path $scriptRoot 'tar.exe'
    if (Test-Path -LiteralPath $localTarPath -PathType Leaf) { $tarPath = $localTarPath }
}
$workingDirectory = $null
$stagingImported = $false
$artifactTemp = $null
$manifestTemp = $null
$preserveStaging = $false
$defaultBaseUtilities = @('build-essential', 'g++', 'git', 'gh', 'make', 'mc', 'wget', 'curl', 'pkg-config')
$defaultPackages = @('github', 'nodejs', 'codex')
$settingsPath = Join-Path $scriptRoot 'build.settings.psd1'
$packageRoot = Join-Path $scriptRoot 'packages'

function ConvertTo-StringArray {
    param([AllowNull()][object]$Value, [string]$Name)
    if ($null -eq $Value) { return @() }
    $items = @($Value | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($items.Count -ne @($Value).Count) { throw "$Name cannot contain empty values" }
    $items
}

function Merge-UniqueStrings {
    param([string[]]$Primary, [string[]]$Additional)
    @($Primary + $Additional | Select-Object -Unique)
}

function Write-LinuxList {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Items)
    [System.IO.File]::WriteAllLines($Path, $Items, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$ArgumentList, [string]$Phase = 'external command')
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "$Phase failed with exit code $LASTEXITCODE" }
}

function Get-DistroNames {
    $lines = & wsl.exe --list --quiet
    if ($LASTEXITCODE -ne 0) { throw 'wsl --list --quiet failed' }
    @($lines | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
}

function Invoke-WslOutput {
    param([Parameter(Mandatory)][string[]]$ArgumentList, [string]$Phase = 'WSL command')
    $lines = @(& wsl.exe @ArgumentList)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "$Phase failed with exit code $exitCode" }
    (($lines | ForEach-Object { [string]$_ }) -join "`n").Replace("`0", '').Trim()
}

function Remove-StagingDistro {
    try { Invoke-Checked wsl.exe @('--terminate', $stagingName) 'staging distro termination' } catch { }
    try { Invoke-Checked wsl.exe @('--unregister', $stagingName) 'staging distro cleanup' } catch { }
}

try {
    $settings = @{}
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $settings = Import-PowerShellDataFile -LiteralPath $settingsPath
        $allowedSettings = @('DistributionDirectory', 'BaseUtilities', 'Packages')
        foreach ($key in $settings.Keys) { if ($key -notin $allowedSettings) { throw "unsupported setting in ${settingsPath}: $key" } }
    }
    $configuredBaseUtilities = if ($settings.ContainsKey('BaseUtilities')) { ConvertTo-StringArray $settings['BaseUtilities'] 'BaseUtilities' } else { $defaultBaseUtilities }
    $configuredPackages = if ($settings.ContainsKey('Packages')) { ConvertTo-StringArray $settings['Packages'] 'Packages' } else { $defaultPackages }
    $selectedBaseUtilities = if ($BaseUtilities) { ConvertTo-StringArray $BaseUtilities 'BaseUtilities override' } else { $configuredBaseUtilities }
    $selectedPackages = if ($Packages) { ConvertTo-StringArray $Packages 'Packages override' } else { $configuredPackages }
    $selectedBaseUtilities = Merge-UniqueStrings $selectedBaseUtilities (ConvertTo-StringArray $AddBaseUtilities 'AddBaseUtilities')
    $selectedPackages = Merge-UniqueStrings $selectedPackages (ConvertTo-StringArray $AddPackages 'AddPackages')
    foreach ($systemPackage in $selectedBaseUtilities) { if ($systemPackage -notmatch '^[A-Za-z0-9.+:-]+$') { throw "invalid base utility package: $systemPackage" } }
    if ($ImageName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "invalid image name: $ImageName" }
    foreach ($package in $selectedPackages) { if ($package -notmatch '^[a-z][a-z0-9-]*$') { throw "invalid package module: $package" } }
    $configuredDistributionDirectory = if ($settings.ContainsKey('DistributionDirectory')) { [string]$settings['DistributionDirectory'] } else { './dist' }
    $requestedDistributionDirectory = if ($DistributionDirectory) { $DistributionDirectory } else { $configuredDistributionDirectory }
    $distributionPath = if ([System.IO.Path]::IsPathRooted($requestedDistributionDirectory)) { $requestedDistributionDirectory } else { Join-Path $scriptRoot $requestedDistributionDirectory }
    $distributionPath = [System.IO.Path]::GetFullPath($distributionPath)

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'wsl.exe was not found. Enable Windows Subsystem for Linux and Virtual Machine Platform in Windows Features, reboot, and run "wsl --install" from an elevated PowerShell prompt.'
    }
    if (-not (Test-Path -LiteralPath $cranePath -PathType Leaf)) {
        throw "crane.exe was not found beside build.ps1. Download the Windows binary from https://github.com/google/go-containerregistry/releases, rename it to crane.exe, and place it here: $cranePath"
    }
    if ([string]::IsNullOrWhiteSpace($tarPath)) {
        throw "tar.exe was not found. It is normally included with Windows; place a compatible tar.exe beside build.ps1 if it is missing: $(Join-Path $scriptRoot 'tar.exe')"
    }
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) { throw "required package directory is missing: $packageRoot" }
    foreach ($package in $selectedPackages) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $package) -PathType Container)) { throw "selected package module is missing: $package" }
    }
    foreach ($requiredPath in @(
        (Join-Path $scriptRoot 'files/provision.sh'),
        (Join-Path $scriptRoot 'files/wsl.conf'),
        (Join-Path $scriptRoot 'files/wsl-distribution.conf'),
        (Join-Path $scriptRoot 'files/isolation-runtime.sh'),
        (Join-Path $scriptRoot 'files/onboard-agent-distro')
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "required project file is missing: $requiredPath" }
    }
    $help = (& wsl.exe --help | Out-String)
    # Some WSL builds return -1 for the help display under Windows PowerShell's
    # native UTF-16 console bridge despite emitting complete help text. Treat a
    # non-empty help response as usable, but never relax checks for real actions.
    if ($LASTEXITCODE -ne 0 -and [string]::IsNullOrWhiteSpace($help)) { throw 'wsl --help failed' }
    $help = $help -replace "`0", ''
    foreach ($option in @('--import', '--export', '--terminate', '--unregister', '--version')) {
        if ($help -notmatch [regex]::Escape($option)) { throw "installed WSL does not advertise required option $option" }
    }
    & wsl.exe --version *> $null
    if ($LASTEXITCODE -ne 0) { throw 'WSL --version is unavailable; update WSL before building' }
    $distros = Get-DistroNames
    if ($distros -contains $stagingName) { Write-Host "Removing reserved staging distro $stagingName"; Remove-StagingDistro }

    $workingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("wsl-builder-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    $rootfsTar = Join-Path $workingDirectory 'rootfs.tar'
    $storagePath = Join-Path $workingDirectory 'storage'
    New-Item -ItemType Directory -Path $storagePath -Force | Out-Null

    Write-Host "[1/6] Exporting $imageReference with crane"
    $architecture = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
    Invoke-Checked $cranePath @('--platform', "linux/$architecture", 'export', $imageReference, $rootfsTar) 'crane export'

    Write-Host '[2/6] Adding provisioning inputs to disposable rootfs archive'
    $linuxConfigDir = '/opt/wsl-dev-builder/files'
    $provisionPath = '/opt/wsl-dev-builder/provision.sh'
    $wslConfig = Join-Path $scriptRoot 'files/wsl.conf'
    $wslDistributionConfig = Join-Path $scriptRoot 'files/wsl-distribution.conf'
    $overlayDirectory = Join-Path $workingDirectory 'rootfs-overlay'
    New-Item -ItemType Directory -Path (Join-Path $overlayDirectory 'opt/wsl-dev-builder/files') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $overlayDirectory 'opt/wsl-dev-builder/packages') -Force | Out-Null
    Write-LinuxList (Join-Path $overlayDirectory 'opt/wsl-dev-builder/base-utilities.txt') $selectedBaseUtilities
    Write-LinuxList (Join-Path $overlayDirectory 'opt/wsl-dev-builder/selected-packages.txt') $selectedPackages
    Copy-Item -Path (Join-Path $packageRoot '*') -Destination (Join-Path $overlayDirectory 'opt/wsl-dev-builder/packages') -Recurse
    Copy-Item -LiteralPath (Join-Path $scriptRoot 'files/provision.sh') -Destination (Join-Path $overlayDirectory 'opt/wsl-dev-builder/provision.sh')
    Copy-Item -LiteralPath (Join-Path $scriptRoot 'files/isolation-runtime.sh') -Destination (Join-Path $overlayDirectory 'opt/wsl-dev-builder/files/isolation-runtime.sh')
    Copy-Item -LiteralPath (Join-Path $scriptRoot 'files/onboard-agent-distro') -Destination (Join-Path $overlayDirectory 'opt/wsl-dev-builder/files/onboard-agent-distro')
    Copy-Item -LiteralPath $wslConfig -Destination (Join-Path $overlayDirectory 'opt/wsl-dev-builder/files/wsl.conf')
    Copy-Item -LiteralPath $wslDistributionConfig -Destination (Join-Path $overlayDirectory 'opt/wsl-dev-builder/files/wsl-distribution.conf')
    Invoke-Checked $tarPath @('-rf', $rootfsTar, '-C', $overlayDirectory, 'opt/wsl-dev-builder/provision.sh', 'opt/wsl-dev-builder/base-utilities.txt', 'opt/wsl-dev-builder/selected-packages.txt', 'opt/wsl-dev-builder/packages', 'opt/wsl-dev-builder/files/wsl.conf', 'opt/wsl-dev-builder/files/wsl-distribution.conf', 'opt/wsl-dev-builder/files/isolation-runtime.sh', 'opt/wsl-dev-builder/files/onboard-agent-distro') 'adding provisioning inputs to rootfs archive'

    Write-Host '[3/6] Importing rootfs into WSL2'
    Invoke-Checked wsl.exe @('--import', $stagingName, $storagePath, $rootfsTar, '--version', '2') 'WSL import'
    $stagingImported = $true

    Write-Host '[4/6] Provisioning and validating Linux image'
    Invoke-Checked wsl.exe @('-d', $stagingName, '-u', 'root', '--', 'bash', $provisionPath, $linuxConfigDir, '/opt/wsl-dev-builder/base-utilities.txt', '/opt/wsl-dev-builder/selected-packages.txt', '/opt/wsl-dev-builder/packages') 'Linux provisioning'
    Invoke-Checked wsl.exe @('-d', $stagingName, '-u', 'root', '--', 'bash', '-lc', 'dpkg --audit; test -f /etc/wsl.conf; test -f /etc/wsl-distribution.conf') 'final Linux validation'
    Invoke-Checked wsl.exe @('-d', $stagingName, '-u', 'ubuntu', '--', 'bash', '-i', '-c', 'set -e; while IFS= read -r tool; do command -v "$tool"; done < /usr/local/lib/wsl-dev-builder/required-tools.txt') 'fresh ubuntu shell tooling validation'

    Write-Host '[5/6] Restarting for WSL default-user validation'
    Invoke-Checked wsl.exe @('--terminate', $stagingName) 'staging termination before validation'
    $defaultIdentity = Invoke-WslOutput @('-d', $stagingName, '--', 'id', '-un') 'default-user validation'
    if ($defaultIdentity -ne 'ubuntu') { throw "default WSL user validation failed (got '$defaultIdentity')" }
    $defaultUid = Invoke-WslOutput @('-d', $stagingName, '--', 'id', '-u') 'default-UID validation'
    if ($defaultUid -ne '1000') { throw "default UID validation failed (got '$defaultUid')" }
    Invoke-Checked wsl.exe @('-d', $stagingName, '-u', 'ubuntu', '--', '/usr/local/lib/wsl-dev-builder/isolation-runtime.sh') 'runtime isolation validation'
    Invoke-WslOutput @('-d', $stagingName, '-u', 'root', '--', 'sh', '-c', 'ps -p 1 -o comm= | grep -qx systemd') 'systemd PID 1 validation' | Out-Null
    $resolvedModules = Invoke-WslOutput @('-d', $stagingName, '-u', 'root', '--', 'cat', '/usr/local/lib/wsl-dev-builder/image-modules.txt') 'image module manifest retrieval'

    Write-Host '[6/6] Exporting final artifact'
    Invoke-Checked wsl.exe @('--terminate', $stagingName) 'staging termination before export'
    New-Item -ItemType Directory -Path $distributionPath -Force | Out-Null
    $date = Get-Date -Format 'yyyy-MM-dd'
    $index = 1
    do {
        $suffix = if ($index -eq 1) { '' } else { "-$index" }
        $artifact = Join-Path $distributionPath "$ImageName-$date$suffix.wsl"
        $index++
    } while ((Test-Path -LiteralPath $artifact) -or (Test-Path -LiteralPath "$artifact.txt"))
    $artifactTemp = Join-Path $workingDirectory 'artifact.wsl.partial'
    $manifestTemp = Join-Path $workingDirectory 'artifact.wsl.txt.partial'
    $manifestLines = @(
        'WSL Dev Builder image manifest'
        ''
        "Ubuntu base image: $imageReference"
    )
    if (-not [string]::IsNullOrWhiteSpace($ImageComment)) {
        $manifestLines += @('', 'Image comment:') + @($ImageComment -split "`r?`n")
    }
    $manifestLines += @('', 'Installed modules:') + @($resolvedModules -split "`n") + @('', 'Base utilities:') + $selectedBaseUtilities
    [System.IO.File]::WriteAllLines($manifestTemp, $manifestLines, [System.Text.UTF8Encoding]::new($false))
    Invoke-Checked wsl.exe @('--export', $stagingName, $artifactTemp) 'WSL export'
    if (-not (Test-Path -LiteralPath $artifactTemp -PathType Leaf)) { throw 'WSL export did not produce an artifact' }
    Invoke-Checked wsl.exe @('--unregister', $stagingName) 'staging distro cleanup'
    $stagingImported = $false
    Move-Item -LiteralPath $artifactTemp -Destination $artifact
    $artifactTemp = $null
    Move-Item -LiteralPath $manifestTemp -Destination "$artifact.txt"
    $manifestTemp = $null
    Write-Host "Build succeeded: $artifact"
}
catch {
    $preserveStaging = $KeepStagingOnFailure.IsPresent
    Write-Error "Build failed: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($stagingImported -and -not $preserveStaging) { Remove-StagingDistro }
    if ($artifactTemp -and (Test-Path -LiteralPath $artifactTemp)) { Remove-Item -LiteralPath $artifactTemp -Force -ErrorAction SilentlyContinue }
    if ($manifestTemp -and (Test-Path -LiteralPath $manifestTemp)) { Remove-Item -LiteralPath $manifestTemp -Force -ErrorAction SilentlyContinue }
    if ($workingDirectory -and (Test-Path -LiteralPath $workingDirectory)) { Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue }
}
