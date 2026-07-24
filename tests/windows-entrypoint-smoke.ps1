$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$manage = Join-Path $root 'manage.ps1'
$runner = Join-Path $PSScriptRoot 'run-smoke.ps1'

if (-not (Test-Path -LiteralPath $manage)) {
    throw 'manage.ps1 is missing'
}
if (-not (Test-Path -LiteralPath $runner)) {
    throw 'tests/run-smoke.ps1 is missing'
}

$help = (& $manage --help 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $help -notmatch 'grill-adapter') {
    throw "manage.ps1 --help failed (exit $LASTEXITCODE): $help"
}

$smoke = (& $runner -Name 'install-project-wiring-smoke.sh' -AdapterRoot $root 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $smoke -notmatch 'install project-wiring smoke OK') {
    throw "run-smoke.ps1 failed (exit $LASTEXITCODE): $smoke"
}

Write-Output 'windows entrypoint smoke OK'
