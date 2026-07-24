[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Name,
    [string]$AdapterRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot $Name
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "Smoke script not found: $script"
}
if ([IO.Path]::GetExtension($script) -ne '.sh') {
    throw "Smoke runner accepts .sh scripts: $Name"
}

$resolver = Join-Path $AdapterRoot 'scripts\resolve-bash.ps1'
if (-not (Test-Path -LiteralPath $resolver -PathType Leaf)) {
    throw "Bash resolver not found under adapter root: $AdapterRoot"
}
$bash = & $resolver
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$arguments = @($script, $AdapterRoot)
if ($ProjectRoot) {
    $arguments += $ProjectRoot
}
& $bash @arguments
exit $LASTEXITCODE
