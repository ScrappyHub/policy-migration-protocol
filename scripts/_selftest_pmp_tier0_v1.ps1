param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$Code,[string]$Detail){
  throw ("PMP_SELFTEST_FAIL:" + $Code + ":" + $Detail)
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

  $pieces = New-Object System.Collections.Generic.List[string]
  [void]$pieces.Add('-NoProfile')
  [void]$pieces.Add('-NonInteractive')
  [void]$pieces.Add('-ExecutionPolicy')
  [void]$pieces.Add('Bypass')
  [void]$pieces.Add('-File')
  [void]$pieces.Add((Q $ScriptPath))

  foreach($a in $Argv){
    [void]$pieces.Add((Q $a))
  }

  $argLine = ($pieces.ToArray() -join ' ')

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = $argLine
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
$Build  = Join-Path $ScriptsDir "pmp_build_migration_plan_v1.ps1"
$Apply  = Join-Path $ScriptsDir "pmp_apply_migration_plan_v1.ps1"
$Verify = Join-Path $ScriptsDir "pmp_verify_migration_apply_v1.ps1"

$InputPath         = Join-Path $RepoRoot "inputs\migration_request.json"
$PlanOutDir        = Join-Path $RepoRoot "artifacts\migration_plan"
$ApplyOutDir       = Join-Path $RepoRoot "artifacts\migration_apply"
$VerifyOutDir      = Join-Path $RepoRoot "artifacts\migration_verify"
$PlanPath          = Join-Path $PlanOutDir "migration_plan.json"
$ApplySummaryPath  = Join-Path $ApplyOutDir "apply_summary.json"
$StateDir          = Join-Path $RepoRoot "state\applied_steps"

Write-Output "SELFTEST: BUILD"
$r1 = Run-Child $Build @(
  "-RepoRoot",$RepoRoot,
  "-InputPath",$InputPath,
  "-OutDir",$PlanOutDir
)
$r1.StdOut | Out-Host
if(-not [string]::IsNullOrWhiteSpace($r1.StdErr)){ $r1.StdErr | Out-Host }
if($r1.ExitCode -ne 0){ Die "BUILD_EXIT_NONZERO" ([string]$r1.ExitCode) }
if($r1.StdOut -notmatch 'PMP_PLAN_BUILD_OK:'){ Die "BUILD_TOKEN_MISSING" "PMP_PLAN_BUILD_OK" }

Write-Output "SELFTEST: APPLY"
$r2 = Run-Child $Apply @(
  "-RepoRoot",$RepoRoot,
  "-PlanPath",$PlanPath,
  "-OutDir",$ApplyOutDir
)
$r2.StdOut | Out-Host
if(-not [string]::IsNullOrWhiteSpace($r2.StdErr)){ $r2.StdErr | Out-Host }
if($r2.ExitCode -ne 0){ Die "APPLY_EXIT_NONZERO" ([string]$r2.ExitCode) }
if($r2.StdOut -notmatch 'PMP_PLAN_APPLY_OK:'){ Die "APPLY_TOKEN_MISSING" "PMP_PLAN_APPLY_OK" }

Write-Output "SELFTEST: VERIFY"
$r3 = Run-Child $Verify @(
  "-RepoRoot",$RepoRoot,
  "-PlanPath",$PlanPath,
  "-ApplySummaryPath",$ApplySummaryPath,
  "-StateDir",$StateDir
)
$r3.StdOut | Out-Host
if(-not [string]::IsNullOrWhiteSpace($r3.StdErr)){ $r3.StdErr | Out-Host }
if($r3.ExitCode -ne 0){ Die "VERIFY_EXIT_NONZERO" ([string]$r3.ExitCode) }
if($r3.StdOut -notmatch 'PMP_VERIFY_APPLY_OK:'){ Die "VERIFY_TOKEN_MISSING" "PMP_VERIFY_APPLY_OK" }

Write-Output "PMP_SELFTEST_OK"
