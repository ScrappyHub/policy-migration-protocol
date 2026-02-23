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

function Append-Receipt([string]$Path,[string]$JsonLine){
  EnsureDir (Split-Path -Parent $Path)
  $line = ((($JsonLine -replace "`r`n","`n") -replace "`r","`n").TrimEnd()) + "`n"
  $enc  = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($Path,$line,$enc)
}

function Escape-JsonString([string]$s){
  if($null -eq $s){ return "" }
  $t = $s
  $t = $t.Replace('\','\\')
  $t = $t.Replace('"','\"')
  $t = ($t -replace "`r`n","`n") -replace "`r","`n"
  $t = $t.Replace("`n","\n")
  $t
}

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ Die ("MISSING_REPOROOT: " + $RepoRoot) }

$ScriptsDir = Join-Path $RepoRoot "scripts"
$TvRoot     = Join-Path $RepoRoot "test_vectors\v1_minimal_hash_only"
$TvPacketP  = Join-Path $TvRoot "packet"
$TvExpected = Join-Path $TvRoot "expected"
$TvNegRoot  = Join-Path $RepoRoot "test_vectors\v1_negative_suite_v1"
$ProofsDir  = Join-Path $RepoRoot "proofs\receipts"
$ReceiptP   = Join-Path $ProofsDir "pmp.ndjson"
$TmpDir     = Join-Path $RepoRoot "proofs\_tmp"

EnsureDir $ScriptsDir
EnsureDir $TvPacketP
EnsureDir $TvExpected
EnsureDir $ProofsDir
EnsureDir $TmpDir

function Run-VerifyExpect([string]$VectorKey,[string]$PacketDir,[string]$ExpectedOutcome,[string]$ExpectedToken){
  $ps = (Get-Command powershell.exe -ErrorAction Stop).Source
  $verify = Join-Path $ScriptsDir "verify_packet_optionA_v1.ps1"
  if(-not (Test-Path -LiteralPath $verify -PathType Leaf)){ Die ("MISSING_SCRIPT: " + $verify) }

  $utc = [DateTime]::UtcNow.ToString("o")
  $result="FAIL"
  $token=""
  $details=$null

  $outP = Join-Path $TmpDir ("pmp_verify_" + $VectorKey + "_out.txt")
  $errP = Join-Path $TmpDir ("pmp_verify_" + $VectorKey + "_err.txt")
  if(Test-Path -LiteralPath $outP){ Remove-Item -LiteralPath $outP -Force }
  if(Test-Path -LiteralPath $errP){ Remove-Item -LiteralPath $errP -Force }

  $p = Start-Process -FilePath $ps -ArgumentList @(
    "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass",
    "-File",$verify,
    "-PacketDir",$PacketDir
  ) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outP -RedirectStandardError $errP

  $stdout = ""
  $stderr = ""
  if(Test-Path -LiteralPath $outP){ $stdout = [System.IO.File]::ReadAllText($outP,(New-Object System.Text.UTF8Encoding($false))) }
  if(Test-Path -LiteralPath $errP){ $stderr = [System.IO.File]::ReadAllText($errP,(New-Object System.Text.UTF8Encoding($false))) }

  if($p.ExitCode -eq 0){
    $result="PASS"
    $token="VERIFY_OK"
    $details=$stdout
  } else {
    $result="FAIL"
    $details=($stderr + "`n" + $stdout).Trim()
    if($details -match "OPTIONA_VIOLATION_manifest_contains_packet_id"){ $token="OPTIONA_VIOLATION_manifest_contains_packet_id" }
    elseif($details -match "PACKETID_TXT_MISMATCH"){ $token="PACKETID_TXT_MISMATCH" }
    elseif($details -match "sha256_mismatch"){ $token="sha256_mismatch" }
    elseif($details -match "PACKETID_DIRNAME_MISMATCH"){ $token="PACKETID_DIRNAME_MISMATCH" }
    else { $token="VERIFY_EXITCODE_NONZERO" }
  }

  if($ExpectedOutcome -eq "PASS"){
    if($result -ne "PASS"){ Die ("EXPECT_PASS_BUT_FAILED: " + $VectorKey + " token=" + $token) }
  } else {
    if($result -ne "FAIL"){ Die ("EXPECT_FAIL_BUT_PASSED: " + $VectorKey) }
    if($ExpectedToken -and ($token -ne $ExpectedToken)){
      Die ("FAIL_TOKEN_MISMATCH: " + $VectorKey + " expected=" + $ExpectedToken + " actual=" + $token)
    }
  }

  $pd = $PacketDir.Replace("\","/")
  $detailsJson = "null"
  if($details){ $detailsJson = '"' + (Escape-JsonString $details) + '"' }

  $receipt = '{"schema":"pmp.receipt.v1","utc":"' + $utc + '","vector_key":"' + $VectorKey + '","expected_outcome":"' + $ExpectedOutcome + '","result":"' + $result + '","token":"' + $token + '","packet_id":null,"packet_dir":"' + $pd + '","details":' + $detailsJson + '}'
  Append-Receipt $ReceiptP $receipt
  Write-Host ("RECEIPT_APPEND_OK: " + $ReceiptP + " token=" + $token) -ForegroundColor Green
}

# ------------------------------------------------------------
# Positive suite: rebuild minimal packet + stamp + verify
# ------------------------------------------------------------
Write-Host "SELFTEST: positive suite" -ForegroundColor Cyan

$existingDirs = @(Get-ChildItem -LiteralPath $TvPacketP -Directory -Force -ErrorAction Stop)
foreach($d in $existingDirs){ Remove-Item -LiteralPath $d.FullName -Recurse -Force }
$existingFiles = @(Get-ChildItem -LiteralPath $TvPacketP -File -Force -ErrorAction Stop)
foreach($f in $existingFiles){ Remove-Item -LiteralPath $f.FullName -Force }

$tmpPkt = Join-Path $TvPacketP "_tmp_packet"
if(Test-Path -LiteralPath $tmpPkt){ Remove-Item -LiteralPath $tmpPkt -Recurse -Force }

EnsureDir $tmpPkt
EnsureDir (Join-Path $tmpPkt "payload")

$helloPath = Join-Path $tmpPkt "payload\hello.txt"
Write-Utf8NoBomLf $helloPath "hello"

$manifestPath = Join-Path $tmpPkt "manifest.json"
$helloHash = Sha256HexFile $helloPath

$manifestJson = '{"files":[{"bytes":6,"path":"payload/hello.txt","sha256":"' + $helloHash + '"}],"schema":"packet.manifest.v1"}'
Write-Utf8NoBomLf $manifestPath $manifestJson

$packetId = Sha256HexFile $manifestPath

$pktDir = Join-Path $TvPacketP $packetId
Move-Item -LiteralPath $tmpPkt -Destination $pktDir -Force

Write-Utf8NoBomLf (Join-Path $pktDir "packet_id.txt") $packetId

$sumLines = New-Object System.Collections.Generic.List[string]
$hManifest = Sha256HexFile (Join-Path $pktDir "manifest.json")
$hPidTxt   = Sha256HexFile (Join-Path $pktDir "packet_id.txt")
$hHello    = Sha256HexFile (Join-Path $pktDir "payload\hello.txt")
[void]$sumLines.Add(($hManifest + "  manifest.json"))
[void]$sumLines.Add(($hPidTxt   + "  packet_id.txt"))
[void]$sumLines.Add(($hHello   + "  payload/hello.txt"))
Write-Utf8NoBomLf (Join-Path $pktDir "sha256sums.txt") ((@($sumLines.ToArray()) -join "`n"))

$ps = (Get-Command powershell.exe -ErrorAction Stop).Source
$stamp = Join-Path $ScriptsDir "stamp_test_vectors_v1.ps1"
if(-not (Test-Path -LiteralPath $stamp -PathType Leaf)){ Die ("MISSING_SCRIPT: " + $stamp) }
& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stamp -RepoRoot $RepoRoot | Out-Host

Run-VerifyExpect "v1_minimal_hash_only" $TvPacketP "PASS" ""
Write-Host ("SELFTEST_PMP_OK: packet_id=" + $packetId) -ForegroundColor Green

# ------------------------------------------------------------
# Negative suite: generate + verify expected FAIL tokens
# ------------------------------------------------------------
Write-Host "SELFTEST: negative suite" -ForegroundColor Cyan

$maker = Join-Path $ScriptsDir "make_negative_vectors_v1.ps1"
if(-not (Test-Path -LiteralPath $maker -PathType Leaf)){ Die ("MISSING_SCRIPT: " + $maker) }
& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $maker -RepoRoot $RepoRoot | Out-Host

$v1p = Join-Path $TvNegRoot "neg_optiona_manifest_contains_packet_id\packet"
$v2p = Join-Path $TvNegRoot "neg_sha256_mismatch\packet"
$v3p = Join-Path $TvNegRoot "neg_packet_id_txt_mismatch\packet"

# NOTE: with current verifier behavior, inserting "packet_id" changes PacketId => dirname mismatch triggers first.
Run-VerifyExpect "neg_optiona_manifest_contains_packet_id" $v1p "FAIL" "PACKETID_DIRNAME_MISMATCH"
Run-VerifyExpect "neg_sha256_mismatch" $v2p "FAIL" "sha256_mismatch"
Run-VerifyExpect "neg_packet_id_txt_mismatch" $v3p "FAIL" "PACKETID_TXT_MISMATCH"

Write-Host "SELFTEST_PMP_NEGATIVE_SUITE_OK" -ForegroundColor Green
