[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-CandidatePaths {
    $paths = New-Object System.Collections.Generic.List[string]

    if ($env:GRILL_ADAPTER_BASH) {
        [void]$paths.Add($env:GRILL_ADAPTER_BASH)
        return $paths
    }

    $commandNames = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        @('bash.exe', 'bash')
    } else {
        @('bash')
    }
    foreach ($name in $commandNames) {
        try {
            foreach ($command in @(Get-Command $name -All -ErrorAction Stop)) {
                if ($command.Source) {
                    [void]$paths.Add($command.Source)
                } elseif ($command.Path) {
                    [void]$paths.Add($command.Path)
                }
            }
        } catch {
            # A missing candidate is expected; continue with known install locations.
        }
    }

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        @(
            (Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe'),
            (Join-Path ${env:ProgramFiles} 'Git\usr\bin\bash.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\bash.exe'),
            'C:\msys64\usr\bin\bash.exe',
            'C:\cygwin64\bin\bash.exe'
        ) | ForEach-Object {
            if ($_ -and (Test-Path -LiteralPath $_)) {
                [void]$paths.Add($_)
            }
        }
    }

    return $paths | Select-Object -Unique
}

foreach ($candidate in Get-CandidatePaths) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        continue
    }
    try {
        & $candidate -lc 'exit 0' 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Output $candidate
            exit 0
        }
    } catch {
        # This candidate may be a WSL launcher or a broken installation.
    }
}

Write-Error @'
No usable Bash installation was found.
On Windows, install Git for Windows (Git Bash), then rerun this command.
Alternatively set GRILL_ADAPTER_BASH to a real bash.exe path.
The Windows WSL bash shim is not sufficient when WSL has no /bin/bash.
'@
exit 1
