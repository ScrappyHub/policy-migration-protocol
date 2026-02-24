param(
  [Parameter(Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [int[]]$Ports
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

foreach($p in $Ports){
  $inUse = $false
  try {
    $c = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction Stop
    if($null -ne $c){ $inUse = $true }
  } catch {
    Die ("PORT_CHECK_FAILED: " + $p + "`n" + $_.Exception.Message)
  }
  if($inUse){ Die ("PORT_IN_USE: " + $p) }
}

Write-Host ("PORTS_OK: " + ($Ports -join ",")) -ForegroundColor Green
