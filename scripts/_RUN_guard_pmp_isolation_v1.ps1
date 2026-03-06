param([Parameter(Mandatory=$false)][string]$RepoRoot = (Resolve-Path -LiteralPath ".").Path)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$g = Join-Path $RepoRoot "scripts\guard_pmp_isolation_v1.ps1"
if(-not (Test-Path -LiteralPath $g -PathType Leaf)){ throw ("MISSING_GUARD: " + $g) }
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $g | Out-Host
if($LASTEXITCODE -ne 0){ throw ("PMP_GUARD_EXIT_NONZERO: " + $LASTEXITCODE) }
Write-Output "PMP_GUARD_RUN_OK"

