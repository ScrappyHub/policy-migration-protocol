param([Parameter(Mandatory=$true)][string]$RepoRoot)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$PSExe  = (Get-Command powershell.exe -ErrorAction Stop).Source
$Guard  = Join-Path (Join-Path $RepoRoot "scripts") "guard_pmp_isolation_v1.ps1"

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Guard | Out-Host
if($LASTEXITCODE -ne 0){
  throw ("PMP_GUARD_EXIT_NONZERO: " + $LASTEXITCODE)
}
Write-Output "PMP_GUARD_RUN_OK"
