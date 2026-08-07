$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap.ps1'
. $scriptPath

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wsl-dev-builder-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    foreach ($name in @(
        'ubuntu-dev-2025-12-31.wsl',
        'ubuntu-dev-2026-08-07.wsl',
        'ubuntu-dev-2026-08-07-2.wsl',
        'ubuntu-dev-2026-08-07-10.wsl',
        'not-an-image.wsl'
    )) { New-Item -ItemType File -Path (Join-Path $testRoot $name) | Out-Null }
    $selected = [IO.Path]::GetFileName((Select-LatestImage -Directory $testRoot))
    if ($selected -ne 'ubuntu-dev-2026-08-07-10.wsl') { throw "latest artifact selection failed: $selected" }
    if ((Get-ArtifactInfo -FileName 'ubuntu-dev-2026-08-07-0.wsl') -ne $null) { throw 'zero artifact index was accepted' }
    if ((Get-ArtifactInfo -FileName 'ubuntu-dev-2026-02-30.wsl') -ne $null) { throw 'invalid artifact date was accepted' }
    Write-Output 'bootstrap-selection: passed'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
