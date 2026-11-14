# RWF809: same native executable, identical fixture, matched NTFS/ReFS/ext4 VHDX.
# Never format an existing runner disk. No Dobby, ETW, or Defender changes.
param([Parameter(Mandatory = $true)][string]$Output)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Output = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$sourceSha = 'd18a959ecc7ec551ae0b83d68b7155965edee4f4'
$blobs = @{
  'rwf809_win32_nt.c' = 'e4cb44674b15f816acd1fd073c5753276f3fd031'
  'rwf809_win32_nt_dobby.h' = 'cec50442bdf4f2b60b6ec8a552e7b3881c7163d6'
}
$created = [System.Collections.Generic.List[string]]::new()
$volumes = @{}
$rows = [System.Collections.Generic.List[object]]::new()
function Invoke-Fixture {
  param([string]$Exe, [string]$Directory, [string]$Argument)
  Push-Location -LiteralPath $Directory
  try {
    $raw = (& $Exe $Argument 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "App $Argument exit=$LASTEXITCODE at $Directory : $raw" }
    return $raw
  } finally { Pop-Location }
}
function New-PrivateVolume {
  param([ValidateSet('NTFS','ReFS')][string]$Fs)
  $path = Join-Path $env:RUNNER_TEMP "rwf809-$($Fs.ToLowerInvariant())-$env:GITHUB_RUN_ID.vhdx"
  if (Test-Path -LiteralPath $path) { throw "Existing VHDX cannot be overwritten: $path" }
  New-VHD -Path $path -SizeBytes 8GB -Dynamic -ErrorAction Stop | Out-Null
  $created.Add($path)
  $disk = Mount-VHD -Path $path -Passthru -ErrorAction Stop | Get-Disk -ErrorAction Stop
  if ($disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'RAW') {
    throw "Refuse to modify pre-existing/system disk $($disk.Number) $($disk.PartitionStyle)"
  }
  $disk | Initialize-Disk -PartitionStyle GPT -ErrorAction Stop | Out-Null
  $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
  if ($part.DriveLetter -in @('C','D')) { throw 'Unexpected protected drive letter' }
  Write-Host "RWF809_FS_FORMAT_BEGIN filesystem=$Fs disk=$($disk.Number) size_bytes=$($disk.Size)"
  $part | Format-Volume -FileSystem $Fs -AllocationUnitSize 4096 -NewFileSystemLabel "RWF809$Fs" -Force -Confirm:$false -ErrorAction Stop | Out-Null
  $vol = Get-Volume -DriveLetter $part.DriveLetter -ErrorAction Stop
  if ([string]$vol.FileSystemType -ne $Fs -or $vol.AllocationUnitSize -ne 4096) {
    throw "Wrong filesystem/cluster $Fs actual=$($vol.FileSystemType)/$($vol.AllocationUnitSize)"
  }
  $root = ('{0}:\bench' -f $vol.DriveLetter)
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return [pscustomobject]@{
    fs = $Fs; drive = ('{0}:' -f $vol.DriveLetter); path = $root
    vhd = $path; disk = $disk.Number; size_bytes = $disk.Size
    cluster_bytes = $vol.AllocationUnitSize
  }
}

function Mount-VerifiedExt4 {
  $path=Join-Path $env:GITHUB_WORKSPACE 'ext4-image\rwf809-ext4.vhdx'
  $manifest=Join-Path $env:GITHUB_WORKSPACE 'ext4-image\vhdx.sha256'
  if (-not (Test-Path -LiteralPath $path) -or -not (Test-Path -LiteralPath $manifest)) {
    throw 'Validated ext4 image and hash manifest are required'
  }
  $expect=(Get-Content -LiteralPath $manifest -Raw).Trim().Split(' ')[0].ToLowerInvariant()
  $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($expect -ne $actual) {throw "Ext4 image mismatch expected=$expect actual=$actual"}
  $service=(& sc.exe query Ext2Fsd 2>&1 | Out-String)
  if ($service -notmatch '(?mi)STATE\s*:\s*4\s+RUNNING') {throw 'Ext4Fsd service not running'}
  $disk=Mount-VHD -Path $path -Passthru -ErrorAction Stop | Get-Disk -ErrorAction Stop
  $created.Add($path)
  if ($disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'GPT') {throw "Unsafe ext4 test VHDX $($disk.Number)"}
  $parts=@(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Where-Object {$_.Size -gt 500MB})
  if ($parts.Count -ne 1) {throw 'Expected exactly one GPT ext4 test partition'}
  $letter=[string]$parts[0].DriveLetter
  if (-not $letter) {
    $letters=@(Get-PSDrive -PSProvider FileSystem | ForEach-Object {$_.Name})
    $letter=@('R','S','T','U','V') | Where-Object {$_ -notin $letters} | Select-Object -First 1
    if (-not $letter) {throw 'No free drive letter for ext4'}
    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $parts[0].PartitionNumber -AccessPath "$($letter):" -ErrorAction Stop
  }
  $drive="$($letter):"
  $info=(& fsutil.exe fsinfo volumeinfo $drive 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0 -or $info -notmatch 'File System Name\s*:\s*EXT4' -or $info -notmatch 'Is ReadWrite') {
    throw "Not a writable native ext4 volume: $info"
  }
  $root=Join-Path $drive 'bench'
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return [pscustomobject]@{
    fs='ext4';drive=$drive;path=$root;vhd=$path;disk=$disk.Number
    size_bytes=$disk.Size;cluster_bytes=4096;image_sha256=$actual
    volumeinfo=$info
  }
}
try {
  if (-not $env:RUNNER_TEMP -or -not $env:GITHUB_RUN_ID) { throw 'Missing CI identity' }
  foreach ($tool in @('New-VHD','Mount-VHD','Format-Volume','git.exe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Tool unavailable $tool" }
  }
  $srcDir = Join-Path $env:RUNNER_TEMP "rwf809-source-$env:GITHUB_RUN_ID"
  New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
  foreach ($name in $blobs.Keys) {
    $dest = Join-Path $srcDir $name
    Invoke-WebRequest "https://raw.githubusercontent.com/Ma-XX-oN/git/$sourceSha/preload/perf/$name" -OutFile $dest -ErrorAction Stop
    $actual = (& git.exe hash-object -- $dest | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $blobs[$name]) { throw "Pinned blob mismatch $name $actual" }
  }
  $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
  $vs = (& $vswhere -latest -products '*' -property installationPath | Out-String).Trim()
  if (-not $vs) { throw 'MSVC not installed' }
  $dev = Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
  $exe = Join-Path $srcDir 'rwf809_win32_nt.exe'
  $csrc = Join-Path $srcDir 'rwf809_win32_nt.c'
  $cmd = 'call "' + $dev + '" -no_logo -arch=amd64 && cl /nologo /O2 /W4 /WX /Fe:"' + $exe + '" "' + $csrc + '"'
  & cmd.exe /d /c $cmd
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw 'Native build failed' }
  $exeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
  $defender = try {
    Get-MpComputerStatus | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled, AntivirusSignatureVersion
  } catch { [pscustomobject]@{ error = $_.Exception.Message } }
  (& fltmc.exe filters | Out-String) | Set-Content -LiteralPath (Join-Path $Output 'filters.txt') -Encoding utf8
  $backingFs = (Get-Volume -DriveLetter $env:RUNNER_TEMP.Substring(0,1)).FileSystemType.ToString()
  $volumes['NTFS'] = New-PrivateVolume -Fs NTFS
  $volumes['ReFS'] = New-PrivateVolume -Fs ReFS
  $volumes['ext4'] = Mount-VerifiedExt4
  (& fltmc.exe instances | Out-String) | Set-Content -LiteralPath (Join-Path $Output 'filter-instances.txt') -Encoding utf8
  $devDriveQueries = @{}
  foreach ($fs in @('NTFS','ReFS','ext4')) {
    try {
      $query = (& fsutil.exe devdrv query $volumes[$fs].drive 2>&1 | Out-String).Trim()
      $devDriveQueries[$fs] = [pscustomobject]@{ exit_code = $LASTEXITCODE; description = $query }
    } catch {
      $devDriveQueries[$fs] = [pscustomobject]@{ error = $_.Exception.Message }
    }
  }
  foreach ($fs in @('NTFS','ReFS','ext4')) {
    $prepared = Invoke-Fixture -Exe $exe -Directory $volumes[$fs].path -Argument '--etw-prepare'
    if ($prepared -notmatch 'RWF809_ETW_PREPARE_PASS') { throw "Fixture failed $fs" }
    $warm = Invoke-Fixture -Exe $exe -Directory $volumes[$fs].path -Argument '--etw-workload'
    if (([regex]::Matches($warm, '(?m)^RWF809_NT_CSV ')).Count -ne 48 -or
        $warm -notmatch 'RWF809_ETW_PASS') { throw "Initial warmup failed $fs" }
    Write-Host "RWF809_FS_FIXTURE_PASS $fs $($volumes[$fs].drive)"
  }
  @{
    source_sha = $sourceSha; source_blob_ids = $blobs
    benchmark_binary_sha256 = $exeHash
    runner = $env:ImageOS; runner_version = $env:ImageVersion
    backing_filesystem = $backingFs
    vhd_type = '8GiB each; NTFS/ReFS dynamic, ext4 QEMU-converted dynamic; GPT, 4KiB allocation units'
    defender = $defender; volumes = @($volumes['NTFS'], $volumes['ReFS'], $volumes['ext4'])
    dev_drive_queries = $devDriveQueries
    schedule = 'NTFS,ReFS,ext4,ReFS,ext4,NTFS repeated 4x; 8 workloads per FS'
    config = 'No tracing, no Dobby, no Dev Drive flags, no Defender changes'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Output 'identity.json') -Encoding utf8
  $sessionNum = @{ NTFS = 0; ReFS = 0; ext4 = 0 }
  foreach ($fs in (@('NTFS','ReFS','ext4','ReFS','ext4','NTFS') * 4)) {
    $sessionNum[$fs]++
    $session = $sessionNum[$fs]
    $raw = Invoke-Fixture -Exe $exe -Directory $volumes[$fs].path -Argument '--etw-workload'
    $lines = @($raw -split '\r?\n' | Where-Object { $_ -like 'RWF809_NT_CSV *' })
    if ($lines.Count -ne 48 -or ([regex]::Matches($raw, '(?m)^RWF809_ETW_PASS ')).Count -ne 1) {
      throw "Incomplete workload $fs/$session lines=$($lines.Count)"
    }
    $unique = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in $lines) {
      $f = $line.Substring(14).Split(',')
      if ($f.Count -ne 12) { throw "Wrong CSV field count $line" }
      $mode = $f[0]; $round = [int]$f[3]; $threads = [int]$f[4]
      if ($mode -notin @('win32_all','nt_all','win32_metadata','nt_metadata') -or
          $threads -notin @(1,4) -or $round -notin @(999,0,1,2,3,4) -or
          [int]$f[1] -ne 0 -or [int]$f[2] -ne 871 -or
          [int]$f[10] -ne 8000 -or [int64]$f[11] -ne 6968000) {
        throw "Wrong benchmark data: $line"
      }
      if (-not $unique.Add("$mode/$threads/$round")) { throw "Duplicate: $line" }
      $timings = @(5..9 | ForEach-Object {
        [double]::Parse($f[$_], [Globalization.CultureInfo]::InvariantCulture)
      })
      if (@($timings | Where-Object { [double]::IsNaN($_) -or [double]::IsInfinity($_) -or $_ -lt 0 }).Count) {
        throw "Invalid measurement $line"
      }
      $rows.Add([pscustomobject]@{
        filesystem = $fs; session = $session; mode = $mode
        round = $round; threads = $threads; wall_ms = $timings[0]
        open_ms = $timings[1]; read_ms = $timings[2]
        close_ms = $timings[3]; metadata_ms = $timings[4]
        files = 8000; bytes = 6968000
      })
    }
    if ($unique.Count -ne 48) { throw "Missing combinations $fs/$session" }
    Write-Host "RWF809_FS_SESSION_PASS $fs $session (48 records)"
  }
  if ($rows.Count -ne 1152) { throw "Expected 768 rows, got $($rows.Count)" }
  $rows | Export-Csv -LiteralPath (Join-Path $Output 'measurements.csv') -NoTypeInformation -Encoding utf8
  $summary = @()
  $groups = @($rows | Where-Object { $_.round -ne 999 } | Group-Object -Property filesystem, mode, threads)
  foreach ($group in $groups) {
    $r = $group.Group[0]
    $vals = @($group.Group | ForEach-Object { $_.wall_ms } | Sort-Object)
    if ($vals.Count -ne 40) { throw "Expected 40 measured rounds: $($group.Name)" }
    $summary += [pscustomobject]@{
      filesystem = $r.filesystem; mode = $r.mode; threads = $r.threads
      n = 40; median_wall_ms = ($vals[19] + $vals[20]) / 2
      p95_nearest_rank_ms = $vals[37]; min_ms = $vals[0]; max_ms = $vals[39]
    }
  }
  if ($summary.Count -ne 24) { throw "Expected 16 summary groups" }
  $summary | Export-Csv -LiteralPath (Join-Path $Output 'summary.csv') -NoTypeInformation -Encoding utf8
  $summary | Sort-Object mode, threads, filesystem | Format-Table -AutoSize | Out-String | Write-Host
  Write-Host "RWF809_FS_COMPARISON_PASS source=$sourceSha binary=$exeHash 1152 rows 960 measured 24 summaries"
} finally {
  foreach ($path in $created) {
    try {
      if (Test-Path -LiteralPath $path) {
        Dismount-VHD -Path $path -ErrorAction Stop
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
      }
    } catch { Write-Warning "Only experiment VHD cleanup failed: $path $_" }
  }
}