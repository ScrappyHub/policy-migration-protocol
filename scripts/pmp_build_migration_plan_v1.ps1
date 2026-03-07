param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$false)][string]$InputPath,
  [Parameter(Mandatory=$false)][string]$OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$Code,[string]$Detail){
  throw ("PMP_PLAN_BUILD_FAIL:" + $Code + ":" + $Detail)
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
    Die "INPUT_MISSING" $Path
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

function Get-Utf8NoBomBytes([string]$Text,[bool]$EnsureLf){
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if($EnsureLf -and -not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  return $enc.GetBytes($t)
}

function Get-Sha256HexFromText([string]$Text,[bool]$EnsureLf){
  return (Get-Sha256HexFromBytes (Get-Utf8NoBomBytes $Text $EnsureLf))
}

function Get-StringArraySortedUnique([object]$Value){
  $list = New-Object System.Collections.Generic.List[string]

  if($null -eq $Value){
    return @()
  }

  foreach($item in @($Value)){
    if($null -eq $item){ continue }
    $s = [string]$item
    if([string]::IsNullOrWhiteSpace($s)){ continue }
    [void]$list.Add($s)
  }

  $arr = $list.ToArray()
  [Array]::Sort($arr,[System.StringComparer]::Ordinal)

  $dedup = New-Object System.Collections.Generic.List[string]
  $prev = $null
  foreach($s in $arr){
    if($null -eq $prev -or $s -ne $prev){
      [void]$dedup.Add($s)
      $prev = $s
    }
  }
  return $dedup.ToArray()
}

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){
  Die "REPOROOT_MISSING" $RepoRoot
}

if([string]::IsNullOrWhiteSpace($InputPath)){
  $InputPath = Join-Path $RepoRoot "inputs\migration_request.json"
}
if([string]::IsNullOrWhiteSpace($OutDir)){
  $OutDir = Join-Path $RepoRoot "artifacts\migration_plan"
}

$InputPath = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).Path
EnsureDir $OutDir

$rawInput = Read-Utf8NoBomLf $InputPath

try{
  $request = $rawInput | ConvertFrom-Json -ErrorAction Stop
} catch {
  Die "INPUT_JSON_INVALID" $_.Exception.Message
}

if($null -eq $request){ Die "INPUT_JSON_NULL" $InputPath }

if([string]$request.schema -ne "pmp.migration.request.v1"){
  Die "REQUEST_SCHEMA_INVALID" ([string]$request.schema)
}
if([string]::IsNullOrWhiteSpace([string]$request.migration_key)){
  Die "REQUEST_MIGRATION_KEY_MISSING" $InputPath
}
if([string]::IsNullOrWhiteSpace([string]$request.source_system)){
  Die "REQUEST_SOURCE_SYSTEM_MISSING" $InputPath
}
if([string]::IsNullOrWhiteSpace([string]$request.target_system)){
  Die "REQUEST_TARGET_SYSTEM_MISSING" $InputPath
}

$inputSteps = @($request.steps)
if($inputSteps.Count -lt 1){
  Die "REQUEST_STEPS_EMPTY" $InputPath
}

$normalizedSteps = New-Object System.Collections.Generic.List[object]
$seenStepKeys = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)

$index = 0
foreach($step in $inputSteps){
  $index += 1
  if($null -eq $step){ Die "STEP_NULL" ("index=" + $index) }

  $stepKey = [string]$step.step_key
  $operation = [string]$step.operation
  $targetRef = [string]$step.target_ref

  if([string]::IsNullOrWhiteSpace($stepKey)){ Die "STEP_KEY_MISSING" ("index=" + $index) }
  if([string]::IsNullOrWhiteSpace($operation)){ Die "STEP_OPERATION_MISSING" $stepKey }
  if([string]::IsNullOrWhiteSpace($targetRef)){ Die "STEP_TARGET_REF_MISSING" $stepKey }
  if(-not $seenStepKeys.Add($stepKey)){ Die "STEP_KEY_DUPLICATE" $stepKey }

  $ordinal = $index
  if($null -ne $step.PSObject.Properties['ordinal'] -and $null -ne $step.ordinal){
    try{
      $ordinal = [int]$step.ordinal
    } catch {
      Die "STEP_ORDINAL_INVALID" $stepKey
    }
  }
  if($ordinal -lt 1){ Die "STEP_ORDINAL_LT1" $stepKey }

  $dependencies = @()
  if($null -ne $step.PSObject.Properties['dependencies']){
    $dependencies = Get-StringArraySortedUnique $step.dependencies
  }

  $payload = $null
  if($null -ne $step.PSObject.Properties['payload']){
    $payload = $step.payload
  }

  $payloadCanon = ConvertTo-CanonicalJson $payload
  $payloadHash = Get-Sha256HexFromText $payloadCanon $true

  $normalized = [ordered]@{
    step_key       = $stepKey
    ordinal        = $ordinal
    operation      = $operation
    target_ref     = $targetRef
    dependencies   = @($dependencies)
    payload        = $payload
    payload_sha256 = $payloadHash
  }

  [void]$normalizedSteps.Add([pscustomobject]$normalized)
}

$stepArray = $normalizedSteps.ToArray()
$sortedSteps = @(
  $stepArray |
    Sort-Object -Property `
      @{ Expression = { [int]$_.ordinal }; Ascending = $true }, `
      @{ Expression = { [string]$_.step_key }; Ascending = $true }
)

$requestCanon = ConvertTo-CanonicalJson $request
$requestSha256 = Get-Sha256HexFromText $requestCanon $true

$plan = [ordered]@{
  schema         = "pmp.migration.plan.v1"
  plan_version   = 1
  migration_key  = [string]$request.migration_key
  source_system  = [string]$request.source_system
  target_system  = [string]$request.target_system
  request_sha256 = $requestSha256
  step_count     = @($sortedSteps).Count
  steps          = @($sortedSteps)
}

$planJson = ConvertTo-CanonicalJson ([pscustomobject]$plan)
$planPath = Join-Path $OutDir "migration_plan.json"
$planShaPath = Join-Path $OutDir "migration_plan.sha256.txt"

Write-Utf8NoBomLf $planPath $planJson

$planFileBytes = Get-Utf8NoBomBytes $planJson $true
$planSha256 = Get-Sha256HexFromBytes $planFileBytes
Write-Utf8NoBomLf $planShaPath ($planSha256 + "  migration_plan.json")

Write-Output ("PMP_PLAN_BUILD_OK: " + $planPath)
Write-Output ("PMP_PLAN_SHA256: " + $planSha256)
Write-Output ("PMP_PLAN_STEPS: " + @($sortedSteps).Count)
