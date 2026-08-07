param(
    [string]$Name,
    [string]$Location,
    [string]$ImagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$ArgumentList, [string]$Phase = 'external command')
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "$Phase failed with exit code $LASTEXITCODE" }
}

function Get-DistroNames {
    $lines = @(& wsl.exe --list --quiet)
    if ($LASTEXITCODE -ne 0) { throw 'wsl --list --quiet failed' }
    @($lines | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
}

function Get-ArtifactInfo {
    param([Parameter(Mandatory)][string]$FileName)
    $match = [regex]::Match($FileName, '^ubuntu-dev-(?<date>\d{4}-\d{2}-\d{2})(?:-(?<index>\d+))?\.wsl$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($match.Groups['date'].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { return $null }
    $index = if ($match.Groups['index'].Success) { [int]$match.Groups['index'].Value } else { 1 }
    if ($index -lt 1) { return $null }
    [pscustomobject]@{ Date = $date; Index = $index; Name = $FileName }
}

function Select-LatestImage {
    param([Parameter(Mandatory)][string]$Directory)
    $candidates = @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.wsl' | ForEach-Object {
        $info = Get-ArtifactInfo -FileName $_.Name
        if ($info) { $info | Add-Member -NotePropertyName Path -NotePropertyValue $_.FullName -PassThru }
    } | Sort-Object Date, Index -Descending)
    if ($candidates.Count -eq 0) { throw "no ubuntu-dev-YYYY-MM-DD(.N).wsl artifact found beside $Directory" }
    $candidates[0].Path
}

function Invoke-WslChecked {
    param([Parameter(Mandatory)][string[]]$ArgumentList, [string]$Phase = 'WSL command')
    & wsl.exe @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "$Phase failed with exit code $LASTEXITCODE" }
}

function Invoke-WslIdentityValidation {
    param([Parameter(Mandatory)][string]$DistroName)
    Invoke-WslChecked @('-d', $DistroName, '--', 'bash', '-ilc', 'test "$(id -un)" = ubuntu && test "$(id -u)" = 1000 && for tool in gh codex node npm bwrap; do command -v "$tool" >/dev/null || exit 1; done') 'developer tooling validation'
}

function Invoke-GitHubAuthentication {
    param([Parameter(Mandatory)][string]$DistroName)
    $hostGh = Get-Command gh.exe -ErrorAction SilentlyContinue
    $hostGhPath = if ($hostGh) { $hostGh.Source } else { Join-Path ${env:ProgramFiles} 'GitHub CLI\gh.exe' }
    if (-not (Test-Path -LiteralPath $hostGhPath -PathType Leaf)) { $hostGhPath = $null }
    $usableHostGh = $false
    if ($hostGhPath) {
        $hostToken = ((& $hostGhPath auth token --hostname github.com 2>$null | Out-String).Trim())
        $usableHostGh = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($hostToken))
    }
    if ($usableHostGh) {
        try {
            # The token is passed only through stdin; it is never an argument or file.
            $hostToken | & wsl.exe -d $DistroName -u ubuntu -- gh auth login --hostname github.com --git-protocol https --with-token
            if ($LASTEXITCODE -ne 0) { throw "GitHub token import failed with exit code $LASTEXITCODE" }
        } finally {
            Remove-Variable hostToken -ErrorAction SilentlyContinue
        }
    } else {
        Invoke-WslChecked @('-d', $DistroName, '-u', 'ubuntu', '--', 'gh', 'auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https') 'interactive GitHub authentication'
    }
    Invoke-WslChecked @('-d', $DistroName, '-u', 'ubuntu', '--', 'gh', 'auth', 'setup-git', '--hostname', 'github.com') 'GitHub git helper setup'
    Invoke-WslChecked @('-d', $DistroName, '-u', 'ubuntu', '--', 'gh', 'auth', 'status', '--hostname', 'github.com') 'GitHub authentication validation'
}

function Invoke-CodexAuthentication {
    param([Parameter(Mandatory)][string]$DistroName)
    Invoke-WslChecked @('-d', $DistroName, '-u', 'ubuntu', '--', 'bash', '-ilc', 'codex login --device-auth') 'Codex device authentication'
    Invoke-WslChecked @('-d', $DistroName, '-u', 'ubuntu', '--', 'bash', '-ilc', 'codex login status') 'Codex authentication validation'
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Name is required and must contain only letters, numbers, dot, underscore, or hyphen' }
        if ([string]::IsNullOrWhiteSpace($Location)) { throw 'Location is required' }
        if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'wsl.exe was not found' }
        $help = (& wsl.exe --help | Out-String) -replace "`0", ''
        if ($LASTEXITCODE -ne 0 -and [string]::IsNullOrWhiteSpace($help)) { throw 'wsl --help failed' }
        foreach ($option in @('--install', '--from-file', '--name', '--location')) { if ($help -notmatch [regex]::Escape($option)) { throw "installed WSL does not advertise required option $option" } }
        $image = if ($ImagePath) { $ImagePath } else { Select-LatestImage -Directory $scriptRoot }
        $image = [IO.Path]::GetFullPath($image)
        if (-not (Test-Path -LiteralPath $image -PathType Leaf)) { throw "image file was not found: $image" }
        if ([IO.Path]::GetExtension($image) -ne '.wsl') { throw 'ImagePath must point to a .wsl file' }
        if ((Get-DistroNames) -contains $Name) { throw "a distro named '$Name' is already registered; refusing to overwrite it" }
        $locationFull = [IO.Path]::GetFullPath($Location)
        if (Test-Path -LiteralPath $locationFull -PathType Leaf) { throw "Location is an existing file: $locationFull" }
        if ((Test-Path -LiteralPath $locationFull -PathType Container) -and @(Get-ChildItem -LiteralPath $locationFull -Force).Count -gt 0) { throw "Location is not empty: $locationFull" }

        Write-Host "Installing $Name from $image"
        Invoke-Checked wsl.exe @('--install', '--from-file', $image, '--name', $Name, '--location', $locationFull) 'WSL developer distro installation'
        Invoke-WslIdentityValidation -DistroName $Name
        Write-Host 'Authenticating GitHub (credentials remain inside this distro)'
        Invoke-GitHubAuthentication -DistroName $Name
        Write-Host 'Authenticating Codex with device auth'
        Invoke-CodexAuthentication -DistroName $Name
        Write-Host "Bootstrap succeeded: $Name"
    } catch {
        Write-Error "Bootstrap failed: $($_.Exception.Message). The created distro, if any, was left registered."
        exit 1
    }
}
