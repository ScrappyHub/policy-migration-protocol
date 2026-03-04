param(
  # Canonical invocation:
  #   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  #     -File scripts\check_ports_pmp_v1.ps1 -PortsCsv "55432,58080"
  [Parameter(Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [string]$PortsCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$m){ throw $m }

# Parse PortsCsv deterministically (no pipeline member-access hazards)
$raw = $PortsCsv -split ","
$tokens = New-Object System.Collections.Generic.List[string]
foreach($x in $raw){
  if($null -eq $x){ continue }
  $s = $x.Trim()
  if($s.Length -gt 0){ [void]$tokens.Add($s) }
}
if($tokens.Count -lt 1){ Die "EMPTY_PORT_LIST" }

$ports = New-Object System.Collections.Generic.List[int]
foreach($s in $tokens){
  $n = 0
  if(-not [int]::TryParse($s,[ref]$n)){ Die ("INVALID_PORT_TOKEN: " + $s) }
  if($n -lt 1 -or $n -gt 65535){ Die ("INVALID_PORT: " + $n) }
  [void]$ports.Add($n)
}

# CIM-free listener probe (stable)
$ip = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
$listeners = @($ip.GetActiveTcpListeners())

foreach($p in $ports){
  $inUse = $false
  foreach($ep in $listeners){
    if($null -ne $ep -and $ep.Port -eq $p){ $inUse = $true; break }
  }
  if($inUse){ Die ("PORT_IN_USE: " + $p) }
}

Write-Host ("PORTS_OK: " + (($ports.ToArray()) -join ",")) -ForegroundColor Green
exit 0
