param([Parameter(Mandatory=$true)][string]$PacketDir)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function Sha256HexFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("missing_file_for_hash: " + $Path) }; $fs=[System.IO.File]::OpenRead($Path); $sha=[System.Security.Cryptography.SHA256]::Create(); try{ $h=$sha.ComputeHash($fs) } finally { $sha.Dispose(); $fs.Dispose() }; $sb=New-Object System.Text.StringBuilder; foreach($b in $h){ [void]$sb.AppendFormat("{0:x2}",[int]$b) }; $sb.ToString() }
function ReadAllTextUtf8NoBom([string]$p){ [System.IO.File]::ReadAllText($p,(New-Object System.Text.UTF8Encoding($false))) }

if(-not (Test-Path -LiteralPath $PacketDir -PathType Container)){ Die ("MISSING_PACKETDIR: " + $PacketDir) }
$pkt = $PacketDir
$m0 = Join-Path $pkt "manifest.json"
if(-not (Test-Path -LiteralPath $m0 -PathType Leaf)){
  $subs = @(@(Get-ChildItem -LiteralPath $pkt -Directory -Force | Select-Object -ExpandProperty FullName))
  if($subs.Count -ne 1){ Die ("PacketDir must be a packet folder (has manifest.json) OR a parent containing exactly one packet folder. dir=" + $pkt + " subdirs=" + $subs.Count) }
  $pkt = $subs[0]
  $m0 = Join-Path $pkt "manifest.json"
  if(-not (Test-Path -LiteralPath $m0 -PathType Leaf)){ Die ("missing_manifest_after_select: " + $m0) }
}

$pktLeaf = Split-Path -Leaf $pkt
$packetId = Sha256HexFile $m0
if($pktLeaf -ne $packetId){ Die ("PACKETID_DIRNAME_MISMATCH: dir=" + $pktLeaf + " expected=" + $packetId) }

# Option A guard: manifest MUST NOT contain packet_id
$mTxt = ReadAllTextUtf8NoBom $m0
if($mTxt -match "packet_id"){ Die "OPTIONA_VIOLATION_manifest_contains_packet_id" }

# If packet_id.txt exists, it must match derived packetId
$pidPath = Join-Path $pkt "packet_id.txt"
if(Test-Path -LiteralPath $pidPath -PathType Leaf){
  $packetId = (ReadAllTextUtf8NoBom $pidPath).Replace("`r`n","`n").Replace("`r","`n").Trim()
  if([string]::IsNullOrWhiteSpace($packetId)){ Die "empty_packet_id_txt" }
  if($packetId -ne $packetId){ Die ("PACKETID_TXT_MISMATCH: txt=" + $packetId + " expected=" + $packetId) }
}

# Verify sha256sums.txt entries against exact on-disk bytes
$sumsPath = Join-Path $pkt "sha256sums.txt"
if(-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)){ Die ("missing_sha256sums: " + $sumsPath) }
$lines = (ReadAllTextUtf8NoBom $sumsPath).Replace("`r`n","`n").Replace("`r","`n").Split("`n") | Where-Object { $_ -ne "" }
foreach($ln in $lines){
  $m = [regex]::Match($ln, '^([0-9a-f]{64})\s+\*?(.+)$')
  if(-not $m.Success){ Die ("bad_sha256sums_line: " + $ln) }
  $hex = $m.Groups[1].Value
  $rel = $m.Groups[2].Value.Trim()
  $fp = Join-Path $pkt $rel
  if(-not (Test-Path -LiteralPath $fp -PathType Leaf)){ Die ("sha256sums_missing_file: " + $rel) }
  $act = Sha256HexFile $fp
  if($act -ne $hex){ Die ("sha256_mismatch: " + $rel + " expected=" + $hex + " actual=" + $act) }
}

# --- PMP_PATCH_ENFORCE_PACKETID_TXT_V1 ---
# Enforce packet_id.txt contents equals derived PacketId (sha256(manifest.json bytes))
# Supports -PacketDir being either:
#  (a) the packet root dir (contains manifest.json), or
#  (b) the parent packet dir containing exactly one PacketId subdir
function PMP-ResolvePacketRoot([string]$PacketDir){
  if(-not (Test-Path -LiteralPath $PacketDir -PathType Container)){ Die ("MISSING_PACKETDIR: " + $PacketDir) }
  $m = Join-Path $PacketDir "manifest.json"
  if(Test-Path -LiteralPath $m -PathType Leaf){ return $PacketDir }

  $subs = @(@(Get-ChildItem -LiteralPath $PacketDir -Directory -Force -ErrorAction Stop | Select-Object -ExpandProperty FullName))
  if($subs.Count -ne 1){ Die ("PACKET_PARENT_NOT_SINGLE: " + $PacketDir + " found=" + $subs.Count) }
  $cand = $subs[0]
  $m2 = Join-Path $cand "manifest.json"
  if(-not (Test-Path -LiteralPath $m2 -PathType Leaf)){ Die ("MISSING_MANIFEST_IN_PACKETROOT: " + $cand) }
  return $cand
}

$__pmpRoot = PMP-ResolvePacketRoot $PacketDir
$__pmpManifest = Join-Path $__pmpRoot "manifest.json"
$__pmpExpected = Sha256HexFile $__pmpManifest

$__pmpPidTxt = Join-Path $__pmpRoot "packet_id.txt"
if(-not (Test-Path -LiteralPath $__pmpPidTxt -PathType Leaf)){ Die ("MISSING_PACKET_ID_TXT: " + $__pmpPidTxt) }
$__pmpActual = ([System.IO.File]::ReadAllText($__pmpPidTxt,(New-Object System.Text.UTF8Encoding($false))) -replace "
","
").Trim()
if($__pmpActual -ne $__pmpExpected){
  Die ("PACKETID_TXT_MISMATCH:
actual=" + $__pmpActual + "
expected=" + $__pmpExpected)
}
# --- /PMP_PATCH_ENFORCE_PACKETID_TXT_V1 ---
Write-Host ("VERIFY_OK: optionA packet_id=" + $packetId + " dir=" + $pkt) -ForegroundColor Green
