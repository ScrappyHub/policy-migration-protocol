param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$c,[string]$d){
  throw ("PMP_NEG_SELFTEST_FAIL:" + $c + ":" + $d)
}

function Q([string]$s){
  if($null -eq $s){ return '""' }
  return '"' + $s.Replace('"','\"') + '"'
}

function Run-Child([string]$ScriptPath,[string[]]$Argv){
  if(-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)){
    Die "CHILD_SCRIPT_MISSING" $ScriptPath
  }

  $psExe = (Get-Command powershell.exe -ErrorAction Stop).Source

  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add('-NoProfile')
  [void]$parts.Add('-NonInteractive')
  [void]$parts.Add('-ExecutionPolicy')
  [void]$parts.Add('Bypass')
  [void]$parts.Add('-File')
  [void]$parts.Add((Q $ScriptPath))
  foreach($a in $Argv){
    [void]$parts.Add((Q $a))
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = ($parts.ToArray() -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  return [pscustomobject]@{
    ExitCode = $p.ExitCode
    StdOut   = $stdout.Replace("`r`n","`n").Replace("`r","`n")
    StdErr   = $stderr.Replace("`r`n","`n").Replace("`r","`n")
  }
}

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){
  Die "REPOROOT_MISSING" $RepoRoot
}

$ScriptsDir = Join-Path $RepoRoot "scripts"
$MakeNeg    = Join-Path $ScriptsDir "pmp_make_negative_vectors_v1.ps1"
$Build      = Join-Path $ScriptsDir "pmp_build_migration_plan_v1.ps1"
$Verify     = Join-Path $ScriptsDir "pmp_verify_migration_apply_v1.ps1"

Write-Output "NEGSELFTEST: MAKE_VECTORS"
$r0 = Run-Child $MakeNeg @("-RepoRoot",$RepoRoot)
$r0.StdOut | Out-Host
if(-not [string]::IsNullOrWhiteSpace($r0.StdErr)){ $r0.StdErr | Out-Host }
if($r0.ExitCode -ne 0){ Die "MAKE_NEG_EXIT_NONZERO" ([string]$r0.ExitCode) }
if(($r0.StdOut + "`n" + $r0.StdErr) -notmatch 'PMP_NEGATIVE_VECTORS_OK:'){
  Die "MAKE_NEG_TOKEN_MISSING" "PMP_NEGATIVE_VECTORS_OK"
}

$NegRoot = Join-Path $RepoRoot "test_vectors\negative_apply_v1"

$neg1 = Join-Path $NegRoot "neg_duplicate_step_key\migration_request.json"
$neg2 = Join-Path $NegRoot "neg_dependency_order_invalid\migration_plan.json"
$neg3Plan  = Join-Path $NegRoot "neg_state_payload_sha_mismatch\migration_plan.json"
$neg3Apply = Join-Path $NegRoot "neg_state_payload_sha_mismatch\apply_summary.json"
$neg3State = Join-Path $NegRoot "neg_state_payload_sha_mismatch\applied_steps"

if(-not (Test-Path -LiteralPath $neg1 -PathType Leaf)){ Die "NEG1_NOT_CREATED" $neg1 }
if(-not (Test-Path -LiteralPath $neg2 -PathType Leaf)){ Die "NEG2_NOT_CREATED" $neg2 }
if(-not (Test-Path -LiteralPath $neg3Plan -PathType Leaf)){ Die "NEG3_PLAN_NOT_CREATED" $neg3Plan }
if(-not (Test-Path -LiteralPath $neg3Apply -PathType Leaf)){ Die "NEG3_APPLY_NOT_CREATED" $neg3Apply }
if(-not (Test-Path -LiteralPath $neg3State -PathType Container)){ Die "NEG3_STATE_NOT_CREATED" $neg3State }

Write-Output "NEGSELFTEST: DUPLICATE_STEP_KEY"
$r1 = Run-Child $Build @(
  "-RepoRoot",$RepoRoot,
  "-InputPath",$neg1,
  "-OutDir",(Join-Path $RepoRoot "artifacts\neg_duplicate_step_key_out")
)
$r1.StdOut | Out-Host
if(-not [string]::IsNullOrWhiteSpace($r1.StdErr)){ $r1.StdErr | Out-Host }
if($r1.ExitCode -eq 0){ Die "EXPECTED_FAIL_BUT_PASSED" "neg_duplicate_step_key" }
if(($r1.StdOut + "`n" + $r1.StdErr) -notmatch 'STEP_KEY_DUPLICATE'){
  Die "NEG1_TOKEN_MISSING" "STEP_KEY_DUPLICATE"
}

Write-Output "NEGSELFTEST: DEPENDENCY_ORDER_INVALID"
$r2 = Run-Child $Verify @(
  "-RepoRoot",$RepoRoot,
  "-PlanPath",$neg2,
  "-ApplySummaryPath",(Join-Path $RepoRoot "artifacts\migration_apply\apply_summary.json"),
  "-StateDir",(Join-Path $RepoRoot "state\applied_steps")
)
$r2.StdOut | Out-Host
if(-not [string]::IsNullOrWhiteSpace($r2.StdErr)){ $r2.StdErr | Out-Host }
if($r2.ExitCode -eq 0){ Die "EXPECTED_FAIL_BUT_PASSED" "neg_dependency_order_invalid" }
if(($r2.StdOut + "`n" + $r2.StdErr) -notmatch 'DEPENDENCY_ORDER_INVALID'){
  Die "NEG2_TOKEN_MISSING" "DEPENDENCY_ORDER_INVALID"
}

Write-Output "NEGSELFTEST: STATE_PAYLOAD_SHA_MISMATCH"
$r3 = Run-Child $Verify @(
  "-RepoRoot",$RepoRoot,
  "-PlanPath",$neg3Plan,
  "-ApplySummaryPath",$neg3Apply,
  "-StateDir",$neg3State
)
$r3.StdOut | Out-Host
if(-not [string]::IsNullOrWhiteSpace($r3.StdErr)){ $r3.StdErr | Out-Host }
if($r3.ExitCode -eq 0){ Die "EXPECTED_FAIL_BUT_PASSED" "neg_state_payload_sha_mismatch" }
if(($r3.StdOut + "`n" + $r3.StdErr) -notmatch 'STATE_PAYLOAD_SHA_MISMATCH'){
  Die "NEG3_TOKEN_MISSING" "STATE_PAYLOAD_SHA_MISMATCH"
}

Write-Output "PMP_NEGATIVE_SELFTEST_OK"
