# RWF809 ONLY: same exact C filesystem workload, CPU.Light vs CPU.Verbose and no ETW.
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [Parameter(Mandatory=$true)][string]$Output,
  [Parameter(Mandatory=$true)][string]$ReaderDll
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$exePath=(Resolve-Path -LiteralPath $Exe).Path
$readerPath=(Resolve-Path -LiteralPath $ReaderDll).Path
$out=[IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$expectedSource='d18a959ecc7ec551ae0b83d68b7155965edee4f4'
if ($env:RWF809_SOURCE_SHA -ne $expectedSource) {throw "Benchmark source SHA wrong: $env:RWF809_SOURCE_SHA"}
if (-not (Get-Command wpr.exe -ErrorAction SilentlyContinue)) {throw 'WPR unavailable'}
if (-not (Get-Command dotnet.exe -ErrorAction SilentlyContinue)) {throw '.NET reader unavailable'}
if (Test-Path Env:RWF809_DOBBY_DLL) {Remove-Item Env:RWF809_DOBBY_DLL}
$profiles=(& wpr.exe -profiles 2>&1 | Out-String)
$profiles | Set-Content -Encoding utf8 -LiteralPath (Join-Path $out 'wpr-profiles.txt')
if ($LASTEXITCODE -ne 0 -or $profiles -notmatch '(?im)\bCPU\b') {throw 'WPR CPU profile unavailable'}
$identity=[ordered]@{
  source_sha=$expectedSource
  reader_origin_sha='b0211bc69cfaf97c338877c141fa425aad1724d2'
  runner_os=$env:RUNNER_OS; runner_image=$env:ImageOS; runner_image_version=$env:ImageVersion
  executable_sha256=(Get-FileHash $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
  workload='EXACT pinned --etw-workload 8000 files x 871 bytes, four API modes, 1 and 4 threads'
  trace_profiles=@('untraced','CPU.Light','untraced','CPU.Light')
  started_utc=[DateTime]::UtcNow.ToString('o')
}
$identity | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $out 'identity.json')
$prepare=(& $exePath --etw-prepare 2>&1 | Out-String)
$prepare | Set-Content -Encoding utf8 (Join-Path $out 'prepare.txt')
if ($LASTEXITCODE -ne 0 -or $prepare -notmatch 'RWF809_ETW_PREPARE_PASS') {throw "Original fixture preparation FAILED: $prepare"}
function Exec {
  param([string]$Cmd,[string[]]$Arguments,[string]$Log)
  $message=(& $Cmd @Arguments 2>&1 | Out-String)
  $exit=$LASTEXITCODE
  $message | Set-Content -Encoding utf8 -LiteralPath (Join-Path $out $Log)
  if ($exit -ne 0) {throw "$Cmd failed exit=$exit args=$($Args -join ' ') output=$message"}
  return $message
}
function Run-Pinned {
  param([string]$Stage)
  $raw=Exec -Cmd $exePath -Arguments @('--etw-workload') -Log "$Stage-measurements.txt"
  $lines=@($raw -split '\r?\n' | Where-Object {$_ -like 'RWF809_NT_CSV *'})
  if ($lines.Count -ne 48 -or -not $raw.Contains('RWF809_ETW_PASS') -or $raw.Contains('RWF809_NT_PASS')) {
    throw "Pinned workload incomplete stage=$Stage samples=$($lines.Count)"
  }
  $keys=[System.Collections.Generic.HashSet[string]]::new()
  foreach ($line in $lines) {
    $f=$line.Substring('RWF809_NT_CSV '.Length).Split(',')
    if ($f.Count -ne 12) {throw "CSV field count wrong $line"}
    $mode=$f[0];$rnd=[int]$f[3];$threads=[int]$f[4]
    if ($mode -notin @('win32_all','nt_all','win32_metadata','nt_metadata') -or
        $threads -notin @(1,4) -or $rnd -notin @(999,0,1,2,3,4) -or
        [int]$f[1] -ne 0 -or [int]$f[2] -ne 871 -or
        [int]$f[10] -ne 8000 -or [int64]$f[11] -ne 6968000) {
      throw "Unexpected workload or fixture $line"
    }
    if (-not $keys.Add("$mode/$threads/$rnd")) {throw "Duplicate measurement $line"}
    foreach ($v in $f[5..9]) {
      $num=[double]::Parse($v,[Globalization.CultureInfo]::InvariantCulture)
      if ([double]::IsNaN($num) -or [double]::IsInfinity($num) -or $num -lt 0) {
        throw "Invalid duration $line"
      }
    }
  }
  Write-Host "RWF809_KERNEL_PINNED_WORKLOAD_PASS stage=$Stage count=$($keys.Count)"
}
$stages=@(
  @{name='01-untraced';profile=''},
  @{name='02-cpu-light';profile='CPU.Light'},
  @{name='03-untraced';profile=''},
  @{name='04-cpu-light';profile='CPU.Light'}
)
foreach ($stage in $stages) {
  $name=[string]$stage.name
  $profile=[string]$stage.profile
  Write-Host "RWF809_KERNEL_STAGE_BEGIN $name $profile"
  if (-not $profile) {
    Run-Pinned -Stage $name
    continue
  }
  $active=$false
  $stopped=$false
  $etl=Join-Path $out "$name.etl"
  try {
    Exec -Cmd 'wpr.exe' -Arguments @('-start',$profile,'-filemode') -Log "$name-start.txt" | Out-Null
    $active=$true
    Run-Pinned -Stage $name
    $status=Exec -Cmd 'wpr.exe' -Arguments @('-status','collectors') -Log "$name-status.txt"
    $counter=@([regex]::Matches($status,'(?im)Events Lost\s*:\s*(\d+)'))
    if ($counter.Count -lt 1) {throw "Loss counter absent for $name; cannot certify trace"}
    foreach ($m in $counter) {
      if ([int64]$m.Groups[1].Value -ne 0) {throw "$name reported lost ETW events $($m.Groups[1].Value)"}
    }
    Exec -Cmd 'wpr.exe' -Arguments @('-stop',$etl) -Log "$name-stop.txt" | Out-Null
    $stopped=$true
  } finally {
    if ($active -and -not $stopped) {
      try {Exec -Cmd 'wpr.exe' -Arguments @('-cancel') -Log "$name-cancel.txt" | Out-Null}
      catch {Write-Warning "WPR cancellation failed: $_"}
    }
  }
  if (-not (Test-Path $etl) -or (Get-Item $etl).Length -le 4096) {throw "$name ETL missing or empty"}
  $etlHash=(Get-FileHash $etl -Algorithm SHA256).Hash.ToLowerInvariant()
  [pscustomobject]@{
    stage=$name;profile=$profile;etl_bytes=(Get-Item $etl).Length
    etl_sha256=$etlHash;events_lost=0
    source_sha=$expectedSource;binary_sha256=$identity.executable_sha256
  } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $out "$name-identity.json")
  $analysis=Join-Path $out "$name-kernel"
  New-Item -ItemType Directory -Path $analysis -Force | Out-Null
  $result=(& dotnet $readerPath $etl $analysis 2>&1 | Out-String)
  $code=$LASTEXITCODE
  $result | Set-Content -Encoding utf8 -LiteralPath (Join-Path $out "$name-reader-log.txt")
  if ($code -ne 0 -or -not $result.Contains('RWF809_KERNEL_ETW_ATTRIBUTION_PASS')) {
    throw "Kernel TraceProcessor failed stage=$name code=$code output=$result"
  }
  Write-Host "RWF809_KERNEL_LIGHT_STAGE_PASS $name sha=$etlHash"
}
Write-Host 'RWF809_KERNEL_LIGHT_CPU_COMPARISON_PASS 192 rows 160 measured 2 ETL captures zero lost'
