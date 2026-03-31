param([Parameter(Mandatory=$true)][string]$RepoRoot)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}

function Sha256HexFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("missing_file_for_hash: " + $Path) }
  $fs=[System.IO.File]::OpenRead($Path)
  $sha=[System.Security.Cryptography.SHA256]::Create()
  try{ $h=$sha.ComputeHash($fs) } finally { $sha.Dispose(); $fs.Dispose() }
  $sb=New-Object System.Text.StringBuilder
  foreach($b in $h){ [void]$sb.AppendFormat("{0:x2}",[int]$b) }
  $sb.ToString()
}

function Copy-DirTree([string]$Src,[string]$Dst){
  if(-not (Test-Path -LiteralPath $Src -PathType Container)){ Die ("MISSING_SRC_DIR: " + $Src) }
  if(Test-Path -LiteralPath $Dst){ Remove-Item -LiteralPath $Dst -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $Dst | Out-Null
  $items=@(Get-ChildItem -LiteralPath $Src -Recurse -Force)
  foreach($it in $items){
    $rel=$it.FullName.Substring($Src.Length).TrimStart("\","/")
    $out=Join-Path $Dst $rel
    if($it.PSIsContainer){
      if(-not (Test-Path -LiteralPath $out -PathType Container)){ New-Item -ItemType Directory -Force -Path $out | Out-Null }
    } else {
      $od=Split-Path -Parent $out
      if($od -and -not (Test-Path -LiteralPath $od -PathType Container)){ New-Item -ItemType Directory -Force -Path $od | Out-Null }
      Copy-Item -LiteralPath $it.FullName -Destination $out -Force
    }
  }
}

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ Die ("MISSING_REPOROOT: " + $RepoRoot) }

$PosPacketParent = Join-Path $RepoRoot "test_vectors\v1_minimal_hash_only\packet"
$NegRoot         = Join-Path $RepoRoot "test_vectors\v1_negative_suite_v1"

if(-not (Test-Path -LiteralPath $PosPacketParent -PathType Container)){ Die ("MISSING_POS_PACKET_PARENT: " + $PosPacketParent) }

$subs = @(@(Get-ChildItem -LiteralPath $PosPacketParent -Directory -Force | Select-Object -ExpandProperty FullName))
if($subs.Count -ne 1){ Die ("POS_PACKET_PARENT_NOT_SINGLE: " + $PosPacketParent + " found=" + $subs.Count) }

$posPkt = $subs[0]
$posManifest = Join-Path $posPkt "manifest.json"
if(-not (Test-Path -LiteralPath $posManifest -PathType Leaf)){ Die ("MISSING_POS_MANIFEST: " + $posManifest) }

$packetId = Sha256HexFile $posManifest

# reset neg root
if(Test-Path -LiteralPath $NegRoot){ Remove-Item -LiteralPath $NegRoot -Recurse -Force }
EnsureDir $NegRoot

# -----------------------------
# NEG 1: OptionA violation — manifest contains "packet_id"
# (This will usually trip PACKETID_DIRNAME_MISMATCH first unless verifier checks this before hashing.)
# -----------------------------
$v1  = Join-Path $NegRoot "neg_optiona_manifest_contains_packet_id"
$v1p = Join-Path $v1 "packet"
EnsureDir $v1p
$dst1 = Join-Path $v1p $packetId
Copy-DirTree $posPkt $dst1

$m1 = Join-Path $dst1 "manifest.json"
$mTxt = [System.IO.File]::ReadAllText($m1,(New-Object System.Text.UTF8Encoding($false)))
if($mTxt -notmatch '"packet_id"'){
  $new = [regex]::Replace($mTxt,'^\s*\{',('{"packet_id":"' + $packetId + '",'))
  Write-Utf8NoBomLf $m1 $new
}

# -----------------------------
# NEG 2: sha256 mismatch — tamper payload without updating sha256sums
# -----------------------------
$v2  = Join-Path $NegRoot "neg_sha256_mismatch"
$v2p = Join-Path $v2 "packet"
EnsureDir $v2p
$dst2 = Join-Path $v2p $packetId
Copy-DirTree $posPkt $dst2

$hello2 = Join-Path $dst2 "payload\hello.txt"
if(-not (Test-Path -LiteralPath $hello2 -PathType Leaf)){ Die ("MISSING_HELLO_FOR_TAMPER: " + $hello2) }
Write-Utf8NoBomLf $hello2 "HELLO"

# -----------------------------
# NEG 3: packet_id.txt mismatch (BUT sha256sums is updated so verifier reaches PACKETID_TXT_MISMATCH)
# -----------------------------
$v3  = Join-Path $NegRoot "neg_packet_id_txt_mismatch"
$v3p = Join-Path $v3 "packet"
EnsureDir $v3p
$dst3 = Join-Path $v3p $packetId
Copy-DirTree $posPkt $dst3

$pidTxt3 = Join-Path $dst3 "packet_id.txt"
if(-not (Test-Path -LiteralPath $pidTxt3 -PathType Leaf)){ Die ("MISSING_PACKET_ID_TXT: " + $pidTxt3) }

# write wrong packet_id.txt
$wrong = "0000000000000000000000000000000000000000000000000000000000000000"
Write-Utf8NoBomLf $pidTxt3 $wrong

# recompute its sha and patch sha256sums.txt line for packet_id.txt ONLY
$sumP = Join-Path $dst3 "sha256sums.txt"
if(-not (Test-Path -LiteralPath $sumP -PathType Leaf)){ Die ("MISSING_SHA256SUMS: " + $sumP) }

$hPidBad = Sha256HexFile $pidTxt3
$sumTxt  = [System.IO.File]::ReadAllText($sumP,(New-Object System.Text.UTF8Encoding($false)))
$lines = @()
foreach($ln in (($sumTxt -replace "`r`n","`n") -replace "`r","`n").TrimEnd("`n").Split("`n")){
  if($ln -match "\s{2}packet_id\.txt\s*$"){
    $lines += ($hPidBad + "  packet_id.txt")
  } else {
    $lines += $ln
  }
}
Write-Utf8NoBomLf $sumP ((@($lines) -join "`n"))

Write-Output ("PMP_NEGATIVE_VECTORS_OK: packet_id=" + $packetId + " root=" + $NegRoot) -ForegroundColor Green
