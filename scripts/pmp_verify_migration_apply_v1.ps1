param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$false)][string]$PlanPath,
  [Parameter(Mandatory=$false)][string]$ApplySummaryPath,
  [Parameter(Mandatory=$false)][string]$StateDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$Code,[string]$Detail){
  throw ("PMP_VERIFY_APPLY_FAIL:" + $Code + ":" + $Detail)
}

function EnsureDir([string]$Path){
  if([string]::IsNullOrWhiteSpace($Path)){ Die "ENSUREDIR_EMPTY" "Path was null/empty" }
  if(-not (Test-Path -LiteralPath $Path -PathType Container)){
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}

function Append-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($Path,$t,$enc)
}

function Read-Utf8NoBomLf([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Die "FILE_MISSING" $Path
  }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $t = [System.IO.File]::ReadAllText($Path,$enc)
  return $t.Replace("`r`n","`n").Replace("`r","`n")
}

function Get-InvariantNumberString([object]$Value){
  if($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]){
    $d = [double]$Value
    if([double]::IsNaN($d) -or [double]::IsInfinity($d)){
      Die "NONFINITE_NUMBER" ([string]$Value)
    }
  }
  return [System.Convert]::ToString($Value,[System.Globalization.CultureInfo]::InvariantCulture)
}

function Escape-JsonString([string]$Value){
  if($null -eq $Value){ return 'null' }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach($ch in $Value.ToCharArray()){
    $code = [int][char]$ch
    switch($code){
      8  { [void]$sb.Append('\b'); continue }
      9  { [void]$sb.Append('\t'); continue }
      10 { [void]$sb.Append('\n'); continue }
      12 { [void]$sb.Append('\f'); continue }
      13 { [void]$sb.Append('\r'); continue }
      34 { [void]$sb.Append('\"'); continue }
      92 { [void]$sb.Append('\\'); continue }
    }
    if($code -lt 32){
      [void]$sb.Append('\u')
      [void]$sb.Append($code.ToString('x4'))
    } else {
      [void]$sb.Append($ch)
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Get-ObjectPropertyNamesSorted([object]$Value){
  $names = New-Object System.Collections.Generic.List[string]
  foreach($p in $Value.PSObject.Properties){
    if($p.MemberType -eq 'NoteProperty' -or $p.MemberType -eq 'Property'){
      if($null -ne $p.Name){ [void]$names.Add([string]$p.Name) }
    }
  }
  $arr = $names.ToArray()
  [Array]::Sort($arr,[System.StringComparer]::Ordinal)
  return $arr
}

function ConvertTo-CanonicalJson([object]$Value){
  if($null -eq $Value){ return 'null' }

  if($Value -is [string]){ return (Escape-JsonString $Value) }
  if($Value -is [bool]){ if([bool]$Value){ return 'true' } else { return 'false' } }

  if(
    ($Value -is [byte]) -or ($Value -is [sbyte]) -or
    ($Value -is [int16]) -or ($Value -is [uint16]) -or
    ($Value -is [int32]) -or ($Value -is [uint32]) -or
    ($Value -is [int64]) -or ($Value -is [uint64]) -or
    ($Value -is [single]) -or ($Value -is [double]) -or
    ($Value -is [decimal])
  ){
    return (Get-InvariantNumberString $Value)
  }

  if($Value -is [System.Collections.IDictionary]){
    $keys = New-Object System.Collections.Generic.List[string]
    foreach($k in $Value.Keys){
      [void]$keys.Add([string]$k)
    }
    $arr = $keys.ToArray()
    [Array]::Sort($arr,[System.StringComparer]::Ordinal)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach($k in $arr){
      $v = $Value[$k]
      [void]$parts.Add(((Escape-JsonString $k) + ':' + (ConvertTo-CanonicalJson $v)))
    }
    return ('{' + (($parts.ToArray()) -join ',') + '}')
  }

  if($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])){
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($item in $Value){
      [void]$parts.Add((ConvertTo-CanonicalJson $item))
    }
    return ('[' + (($parts.ToArray()) -join ',') + ']')
  }

  $propNames = @(Get-ObjectPropertyNamesSorted $Value)
  if($propNames.Count -gt 0){
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($name in $propNames){
      $prop = $Value.PSObject.Properties[$name]
      [void]$parts.Add(((Escape-JsonString $name) + ':' + (ConvertTo-CanonicalJson $prop.Value)))
    }
    return ('{' + (($parts.ToArray()) -join ',') + '}')
  }

  return (Escape-JsonString ([string]$Value))
}

function Get-Utf8NoBomBytes([string]$Text,[bool]$EnsureLf){
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if($EnsureLf -and -not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  return $enc.GetBytes($t)
}

function Get-Sha256HexFromBytes([byte[]]$Bytes){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try{
    $hash = $sha.ComputeHash($Bytes)
  } finally {
    $sha.Dispose()
  }
  $sb = New-Object System.Text.StringBuilder
  foreach($b in $hash){
    [void]$sb.AppendFormat('{0:x2}',[int]$b)
  }
  return $sb.ToString()
}

function Get-Sha256HexFromText([string]$Text,[bool]$EnsureLf){
  return (Get-Sha256HexFromBytes (Get-Utf8NoBomBytes $Text $EnsureLf))
}

function Parse-JsonFile([string]$Path){
  $raw = Read-Utf8NoBomLf $Path
  try{
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    Die "JSON_INVALID" ($Path + " :: " + $_.Exception.Message)
  }
}

function Add-Receipt([string]$ReceiptPath,[string]$Result,[string]$Token,[string]$PlanSha,[int]$StepCount,[string]$Detail){
  $obj = [ordered]@{
    schema      = "pmp.verify.apply.receipt.v1"
    utc         = [DateTime]::UtcNow.ToString("o")
    result      = $Result
    token       = $Token
    plan_sha256 = $PlanSha
    step_count  = $StepCount
    detail      = $Detail
  }
  $line = ConvertTo-CanonicalJson ([pscustomobject]$obj)
  Append-Utf8NoBomLf $ReceiptPath $line
}

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){
  Die "REPOROOT_MISSING" $RepoRoot
}

if([string]::IsNullOrWhiteSpace($PlanPath)){
  $PlanPath = Join-Path $RepoRoot "artifacts\migration_plan\migration_plan.json"
}
if([string]::IsNullOrWhiteSpace($ApplySummaryPath)){
  $ApplySummaryPath = Join-Path $RepoRoot "artifacts\migration_apply\apply_summary.json"
}
if([string]::IsNullOrWhiteSpace($StateDir)){
  $StateDir = Join-Path $RepoRoot "state\applied_steps"
}

$ReceiptPath = Join-Path $RepoRoot "proofs\receipts\pmp_verify_apply.ndjson"
EnsureDir (Split-Path -Parent $ReceiptPath)

$PlanPath = (Resolve-Path -LiteralPath $PlanPath -ErrorAction Stop).Path
$ApplySummaryPath = (Resolve-Path -LiteralPath $ApplySummaryPath -ErrorAction Stop).Path
$StateDir = (Resolve-Path -LiteralPath $StateDir -ErrorAction Stop).Path

$planRaw = Read-Utf8NoBomLf $PlanPath
$plan = Parse-JsonFile $PlanPath
$summary = Parse-JsonFile $ApplySummaryPath

if([string]$plan.schema -ne "pmp.migration.plan.v1"){
  Die "PLAN_SCHEMA_INVALID" ([string]$plan.schema)
}
if([string]$summary.schema -ne "pmp.apply.summary.v1"){
  Die "SUMMARY_SCHEMA_INVALID" ([string]$summary.schema)
}

$planSha = Get-Sha256HexFromText $planRaw $true

if([string]$summary.plan_sha256 -ne $planSha){
  Die "SUMMARY_PLAN_SHA_MISMATCH" ("expected=" + $planSha + " got=" + [string]$summary.plan_sha256)
}
if([string]$summary.migration_key -ne [string]$plan.migration_key){
  Die "SUMMARY_MIGRATION_KEY_MISMATCH" ("expected=" + [string]$plan.migration_key + " got=" + [string]$summary.migration_key)
}

$planSteps = @($plan.steps)
if($planSteps.Count -lt 1){
  Die "PLAN_STEPS_EMPTY" $PlanPath
}

$stateFiles = @(Get-ChildItem -LiteralPath $StateDir -File -Filter *.applied.json | Sort-Object Name)
if($stateFiles.Count -ne $planSteps.Count){
  Die "STATE_FILE_COUNT_MISMATCH" ("state=" + $stateFiles.Count + " plan=" + $planSteps.Count)
}

$planIndex = @{}
foreach($s in $planSteps){
  $k = [string]$s.step_key
  if([string]::IsNullOrWhiteSpace($k)){ Die "PLAN_STEP_KEY_EMPTY" "blank" }
  if($planIndex.ContainsKey($k)){ Die "PLAN_STEP_KEY_DUPLICATE" $k }
  $planIndex[$k] = $s
}

$stateIndex = @{}
foreach($sf in $stateFiles){
  $st = Parse-JsonFile $sf.FullName
  $k = [string]$st.step_key
  if([string]::IsNullOrWhiteSpace($k)){ Die "STATE_STEP_KEY_EMPTY" $sf.Name }
  if($stateIndex.ContainsKey($k)){ Die "STATE_STEP_KEY_DUPLICATE" $k }
  $stateIndex[$k] = $st
}

$seenOrdinals = New-Object System.Collections.Generic.HashSet[int]
foreach($planStep in $planSteps){
  $stepKey = [string]$planStep.step_key
  if(-not $stateIndex.ContainsKey($stepKey)){ Die "STATE_STEP_NOT_FOUND" $stepKey }

  $stateStep = $stateIndex[$stepKey]
  $planOrdinal = [int]$planStep.ordinal
  $stateOrdinal = [int]$stateStep.ordinal

  if($planOrdinal -ne $stateOrdinal){ Die "STATE_ORDINAL_MISMATCH" $stepKey }
  if(-not $seenOrdinals.Add($planOrdinal)){ Die "ORDINAL_DUPLICATE" ([string]$planOrdinal) }

  if([string]$stateStep.operation -ne [string]$planStep.operation){ Die "STATE_OPERATION_MISMATCH" $stepKey }
  if([string]$stateStep.target_ref -ne [string]$planStep.target_ref){ Die "STATE_TARGET_REF_MISMATCH" $stepKey }
  if([string]$stateStep.migration_key -ne [string]$plan.migration_key){ Die "STATE_MIGRATION_KEY_MISMATCH" $stepKey }
  if([string]$stateStep.plan_sha256 -ne $planSha){ Die "STATE_PLAN_SHA_MISMATCH" $stepKey }
  if([string]$stateStep.payload_sha256 -ne [string]$planStep.payload_sha256){ Die "STATE_PAYLOAD_SHA_MISMATCH" $stepKey }

  $deps = @($planStep.dependencies)
  foreach($dep in $deps){
    $depKey = [string]$dep
    if([string]::IsNullOrWhiteSpace($depKey)){ Die "DEPENDENCY_BLANK" $stepKey }
    if(-not $planIndex.ContainsKey($depKey)){ Die "DEPENDENCY_NOT_IN_PLAN" ($stepKey + " -> " + $depKey) }
    $depOrdinal = [int]$planIndex[$depKey].ordinal
    if($depOrdinal -ge $planOrdinal){
      Die "DEPENDENCY_ORDER_INVALID" ($stepKey + " -> " + $depKey)
    }
    if(-not $stateIndex.ContainsKey($depKey)){
      Die "DEPENDENCY_STATE_MISSING" ($stepKey + " -> " + $depKey)
    }
  }
}

$maxOrdinal = $planSteps.Count
for($i = 1; $i -le $maxOrdinal; $i++){
  if(-not $seenOrdinals.Contains($i)){
    Die "ORDINAL_GAP" ([string]$i)
  }
}

$verifyObj = [ordered]@{
  schema              = "pmp.migration.apply.verify.v1"
  migration_key       = [string]$plan.migration_key
  plan_sha256         = $planSha
  verified_step_count = $planSteps.Count
  result              = "PASS"
  token               = "PMP_VERIFY_APPLY_OK"
}

$VerifyOutDir = Join-Path $RepoRoot "artifacts\migration_verify"
EnsureDir $VerifyOutDir

$VerifyPath = Join-Path $VerifyOutDir "verify_summary.json"
$VerifyShaPath = Join-Path $VerifyOutDir "verify_summary.sha256.txt"

$verifyJson = ConvertTo-CanonicalJson ([pscustomobject]$verifyObj)
Write-Utf8NoBomLf $VerifyPath $verifyJson
$verifySha = Get-Sha256HexFromText $verifyJson $true
Write-Utf8NoBomLf $VerifyShaPath ($verifySha + "  verify_summary.json")

Add-Receipt $ReceiptPath "PASS" "PMP_VERIFY_APPLY_OK" $planSha $planSteps.Count "verify ok"

Write-Output ("PMP_VERIFY_APPLY_OK: " + $VerifyPath)
Write-Output ("PMP_VERIFY_APPLY_SHA256: " + $verifySha)
Write-Output ("PMP_VERIFY_APPLY_STEPS: " + $planSteps.Count)
Write-Output ("PMP_VERIFY_APPLY_RECEIPTS: " + $ReceiptPath)
