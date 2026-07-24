[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
$resolver = Join-Path $PSScriptRoot 'scripts\resolve-bash.ps1'
$bash = & $resolver
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $bash (Join-Path $PSScriptRoot 'manage.sh') @Arguments
exit $LASTEXITCODE
