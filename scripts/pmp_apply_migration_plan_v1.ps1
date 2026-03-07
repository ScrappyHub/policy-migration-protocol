param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$false)][string]$PlanPath,
  [Parameter(Mandatory=$false)][string]$OutDir,
  [Parameter(Mandatory=$false)][switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$Code,[string]$Detail){
  throw ("PMP_PLAN_APPLY_FAIL:" + $Code + ":" + $Detail)
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

function Append-NdjsonReceipt([string]$Path,[object]$Obj){
  $line = ConvertTo-CanonicalJson $Obj
  $dir = Split-Path -Parent $Path
  EnsureDir $dir

  $existing = ""
  if(Test-Path -LiteralPath $Path -PathType Leaf){
    $existing = Read-Utf8NoBomLf $Path
  }
  if($existing.Length -gt 0 -and -not $existing.EndsWith("`n")){
    $existing += "`n"
  }
  $existing += $line + "`n"
  Write-Utf8NoBomLf $Path $existing
}

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){
  Die "REPOROOT_MISSING" $RepoRoot
}

if([string]::IsNullOrWhiteSpace($PlanPath)){
  $PlanPath = Join-Path $RepoRoot "artifacts\migration_plan\migration_plan.json"
}
if([string]::IsNullOrWhiteSpace($OutDir)){
  $OutDir = Join-Path $RepoRoot "artifacts\migration_apply"
}

$PlanPath = (Resolve-Path -LiteralPath $PlanPath -ErrorAction Stop).Path
EnsureDir $OutDir

$ReceiptsPath = Join-Path $RepoRoot "proofs\receipts\pmp_apply.ndjson"
$ApplyStateDir = Join-Path $RepoRoot "state\applied_steps"
EnsureDir $ApplyStateDir

$planText = Read-Utf8NoBomLf $PlanPath
$planSha256 = Get-Sha256HexFromText $planText $true

try{
  $plan = $planText | ConvertFrom-Json -ErrorAction Stop
} catch {
  Die "PLAN_JSON_INVALID" $_.Exception.Message
}

if($null -eq $plan){ Die "PLAN_JSON_NULL" $PlanPath }
if([string]$plan.schema -ne "pmp.migration.plan.v1"){
  Die "PLAN_SCHEMA_INVALID" ([string]$plan.schema)
}

$steps = @($plan.steps)
if($steps.Count -lt 1){
  Die "PLAN_STEPS_EMPTY" $PlanPath
}

$seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
$applied = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)

$stepIndex = 0
foreach($step in $steps){
  $stepIndex += 1
  if($null -eq $step){ Die "PLAN_STEP_NULL" ("index=" + $stepIndex) }

  $stepKey = [string]$step.step_key
  $operation = [string]$step.operation
  $targetRef = [string]$step.target_ref

  if([string]::IsNullOrWhiteSpace($stepKey)){ Die "PLAN_STEP_KEY_MISSING" ("index=" + $stepIndex) }
  if([string]::IsNullOrWhiteSpace($operation)){ Die "PLAN_STEP_OPERATION_MISSING" $stepKey }
  if([string]::IsNullOrWhiteSpace($targetRef)){ Die "PLAN_STEP_TARGET_REF_MISSING" $stepKey }

  if(-not $seen.Add($stepKey)){
    Die "PLAN_STEP_KEY_DUPLICATE" $stepKey
  }

  $dependencies = @()
  if($null -ne $step.PSObject.Properties['dependencies']){
    $dependencies = @($step.dependencies)
  }

  foreach($dep in @($dependencies)){
    $depKey = [string]$dep
    if([string]::IsNullOrWhiteSpace($depKey)){ continue }
    if(-not $seen.Contains($depKey)){
      Die "DEPENDENCY_NOT_SATISFIED" ($stepKey + ":missing_prior=" + $depKey)
    }
    if(-not $applied.Contains($depKey)){
      Die "DEPENDENCY_NOT_APPLIED" ($stepKey + ":dep=" + $depKey)
    }
  }

  $payloadCanon = ConvertTo-CanonicalJson $step.payload
  $payloadSha256 = Get-Sha256HexFromText $payloadCanon $true

  $stepRecord = [ordered]@{
    schema         = "pmp.applied.step.v1"
    plan_sha256    = $planSha256
    migration_key  = [string]$plan.migration_key
    step_key       = $stepKey
    ordinal        = [int]$step.ordinal
    operation      = $operation
    target_ref     = $targetRef
    dependencies   = @(@($dependencies))
    payload_sha256 = $payloadSha256
    what_if        = [bool]$WhatIf
    applied        = $true
  }

  $stepFile = Join-Path $ApplyStateDir ($stepKey + ".applied.json")
  $stepFileJson = ConvertTo-CanonicalJson ([pscustomobject]$stepRecord)
  Write-Utf8NoBomLf $stepFile $stepFileJson

  $receipt = [ordered]@{
    schema         = "pmp.apply.receipt.v1"
    plan_sha256    = $planSha256
    migration_key  = [string]$plan.migration_key
    step_key       = $stepKey
    ordinal        = [int]$step.ordinal
    operation      = $operation
    target_ref     = $targetRef
    payload_sha256 = $payloadSha256
    what_if        = [bool]$WhatIf
    ok             = $true
  }
  Append-NdjsonReceipt $ReceiptsPath ([pscustomobject]$receipt)

  [void]$applied.Add($stepKey)
}

$summary = [ordered]@{
  schema        = "pmp.apply.summary.v1"
  plan_sha256   = $planSha256
  migration_key = [string]$plan.migration_key
  step_count    = @($steps).Count
  what_if       = [bool]$WhatIf
  ok            = $true
}
$summaryPath = Join-Path $OutDir "apply_summary.json"
Write-Utf8NoBomLf $summaryPath (ConvertTo-CanonicalJson ([pscustomobject]$summary))

Write-Output ("PMP_PLAN_APPLY_OK: " + $summaryPath)
Write-Output ("PMP_PLAN_APPLY_SHA256: " + $planSha256)
Write-Output ("PMP_PLAN_APPLY_STEPS: " + @($steps).Count)
Write-Output ("PMP_PLAN_APPLY_RECEIPTS: " + $ReceiptsPath)
