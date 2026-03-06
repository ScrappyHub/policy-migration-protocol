param(
  [Parameter(Mandatory=$false)][string]$ComposeProject = "pmp",
  [Parameter(Mandatory=$false)][string]$NetworkName    = "pmp_net",
  [Parameter(Mandatory=$false)][string]$DbContainer    = "pmp_db",
  [Parameter(Mandatory=$false)][string]$ApiContainer   = "pmp_api",
  [Parameter(Mandatory=$false)][int]$DbHostPort        = 55432,
  [Parameter(Mandatory=$false)][int]$ApiHostPort       = 58080,
  [Parameter(Mandatory=$false)][string]$DbVolume       = "pmp_db_data"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$Code,[string]$Detail){
  throw ("PMP_ISOLATION_FAIL:" + $Code + ":" + $Detail)
}

function Run-Docker([string[]]$Argv){
  $out = & docker @Argv 2>&1
  if($LASTEXITCODE -ne 0){
    $msg = (($out | Out-String).Trim())
    Die "DOCKER_CMD_FAILED" (($Argv -join " ") + " :: " + $msg)
  }
  return $out
}

function To-Lines($InputObject){
  $s = ($InputObject | Out-String)
  $s = $s.Replace("`r`n","`n").Replace("`r","`n")
  $raw = @($s -split "`n")
  $res = New-Object System.Collections.Generic.List[string]
  foreach($line in @(@($raw))){
    if(-not [string]::IsNullOrWhiteSpace($line)){
      [void]$res.Add($line.Trim())
    }
  }
  return $res.ToArray()
}

function Get-LabelValue($Labels,[string]$Key){
  if($null -eq $Labels){ return $null }
  if($Labels -is [hashtable]){ return [string]$Labels[$Key] }
  $prop = $Labels.PSObject.Properties[$Key]
  if($null -ne $prop){ return [string]$prop.Value }
  return $null
}

function Assert-ProjectLabel([string]$Kind,[string]$Name,$Labels){
  $project = Get-LabelValue $Labels "com.docker.compose.project"
  if([string]::IsNullOrWhiteSpace($project)){
    Die "LABEL_PROJECT_MISSING" ($Kind + ":" + $Name)
  }
  if($project -ne $ComposeProject){
    Die "LABEL_PROJECT_MISMATCH" ($Kind + ":" + $Name + ": expected=" + $ComposeProject + " got=" + $project)
  }
}

$null = Run-Docker @("version")

$psLines = To-Lines (Run-Docker @("ps","--filter",("label=com.docker.compose.project=" + $ComposeProject),"--format","{{.Names}}|{{.Status}}|{{.Ports}}|{{.Image}}"))
if(@($psLines).Count -lt 1){
  Die "PMP_CONTAINERS_MISSING" ("project=" + $ComposeProject)
}

$found = @{}
foreach($ln in @(@($psLines))){
  $parts = $ln -split "\|",4
  if($parts.Length -lt 4){ Die "PS_FORMAT_BAD" $ln }
  $name   = $parts[0]
  $status = $parts[1]
  $ports  = $parts[2]
  $image  = $parts[3]
  $found[$name] = [ordered]@{
    name   = $name
    status = $status
    ports  = $ports
    image  = $image
  }
}

foreach($required in @(@($DbContainer,$ApiContainer))){
  if(-not $found.ContainsKey($required)){
    Die "CONTAINER_NOT_FOUND" $required
  }
}

foreach($k in @(@($found.Keys))){
  if(($k -ne $DbContainer) -and ($k -ne $ApiContainer)){
    Die "EXTRA_PMP_CONTAINER" $k
  }
}

$db  = $found[$DbContainer]
$api = $found[$ApiContainer]

if(([string]$db.status)  -notmatch "^Up"){ Die "DB_NOT_UP"  ([string]$db.status) }
if(([string]$api.status) -notmatch "^Up"){ Die "API_NOT_UP" ([string]$api.status) }

$needDb  = ":" + $DbHostPort.ToString()  + "->5432/tcp"
$needApi = ":" + $ApiHostPort.ToString() + "->8080/tcp"

if(([string]$db.ports) -notmatch [regex]::Escape($needDb)){
  Die "DB_PORT_MISMATCH" ("need=" + $needDb + " got=" + [string]$db.ports)
}
if(([string]$api.ports) -notmatch [regex]::Escape($needApi)){
  Die "API_PORT_MISMATCH" ("need=" + $needApi + " got=" + [string]$api.ports)
}

$netJson = Run-Docker @("network","inspect",$NetworkName,"--format","{{json .Labels}}")
$netLine = (To-Lines $netJson | Select-Object -First 1)
try{
  $netLabels = $netLine | ConvertFrom-Json -ErrorAction Stop
} catch {
  Die "NETWORK_LABELS_JSON_BAD" ($NetworkName + ":" + $netLine)
}
Assert-ProjectLabel "network" $NetworkName $netLabels

$volJson = Run-Docker @("volume","inspect",$DbVolume,"--format","{{json .Labels}}")
$volLine = (To-Lines $volJson | Select-Object -First 1)
try{
  $volLabels = $volLine | ConvertFrom-Json -ErrorAction Stop
} catch {
  Die "VOLUME_LABELS_JSON_BAD" ($DbVolume + ":" + $volLine)
}
Assert-ProjectLabel "volume" $DbVolume $volLabels

$mountsJson = Run-Docker @("inspect",$DbContainer,"--format","{{json .Mounts}}")
$mountsLine = (To-Lines $mountsJson | Select-Object -First 1)
try{
  $mounts = $mountsLine | ConvertFrom-Json -ErrorAction Stop
} catch {
  Die "DB_MOUNTS_JSON_BAD" ($DbContainer + ":" + $mountsLine)
}

$okMount = $false
foreach($m in @(@($mounts))){
  $t = [string]$m.Type
  $n = [string]$m.Name
  $d = [string]$m.Destination
  if(($t -eq "volume") -and ($n -eq $DbVolume) -and ($d -eq "/var/lib/postgresql/data")){
    $okMount = $true
  }
}
if(-not $okMount){
  Die "DB_VOLUME_MOUNT_MISMATCH" ("need=" + $DbVolume + " to /var/lib/postgresql/data")
}

Write-Output ("PMP_ISOLATION_OK: project=" + $ComposeProject + " db_port=" + $DbHostPort + " api_port=" + $ApiHostPort)
