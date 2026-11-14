# RWF 809 Gate 1: verify downloaded ext4 VHDX mounts read/write in native Windows.
param([Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
New-Item -Path $Output -ItemType Directory -Force | Out-Null
$path=Join-Path $env:GITHUB_WORKSPACE 'ext4-image\rwf809-ext4.vhdx'
$manifest=Join-Path $env:GITHUB_WORKSPACE 'ext4-image\vhdx.sha256'
$report=[ordered]@{candidate='Ext4Fsd v0.71 native Windows ext4 gate';stage='start';runner=$env:ImageOS;version=$env:ImageVersion}
$mounted=$false
function Emit {
  $report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Output 'mount-verification.json') -Encoding utf8
}
function Assign-Drive {
  param([uint32]$DiskNumber,[uint32]$PartitionNumber)
  $part=Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
  if ($part.DriveLetter) {return ('{0}:' -f $part.DriveLetter)}
  $used=@(Get-PSDrive -PSProvider FileSystem | ForEach-Object {$_.Name})
  $chosen= @('R','S','T','U','V') | Where-Object {$_ -notin $used} | Select-Object -First 1
  if (-not $chosen) {throw 'No free letter for test ext4 partition'}
  Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -AccessPath ("$($chosen):") -ErrorAction Stop
  return ("$($chosen):")
}
try {
  if (-not (Test-Path -LiteralPath $path) -or -not (Test-Path -LiteralPath $manifest)) {throw 'Pinned VHDX artifacts missing'}
  $expected=(Get-Content -LiteralPath $manifest -Raw).Trim().Split(' ')[0].ToLowerInvariant()
  $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  $report.vhdx_sha256=$actual
  if ($expected -ne $actual) {throw "VHDX digest mismatch expected=$expected actual=$actual"}
  $service=(& sc.exe query Ext2Fsd 2>&1 | Out-String)
  if ($service -notmatch '(?mi)STATE\s*:\s*4\s+RUNNING') {throw "Ext2Fsd driver is not running: $service"}
  $disk=Mount-VHD -Path $path -Passthru -ErrorAction Stop | Get-Disk -ErrorAction Stop
  $mounted=$true
  if ($disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'GPT') {
    throw "Mounted VHDX is not a safe GPT test disk: disk=$($disk.Number)"
  }
  $parts=@(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Where-Object {$_.Size -gt 500MB})
  if ($parts.Count -ne 1) {throw "Expected one test data partition; observed=$($parts.Count)"}
  $report.disk_number=$disk.Number
  $report.partition_type=[string]$parts[0].GptType
  $report.disk_partitions=@(Get-Partition -DiskNumber $disk.Number | Select-Object PartitionNumber,DriveLetter,Size,GptType,AccessPaths)
  $drive=Assign-Drive -DiskNumber $disk.Number -PartitionNumber $parts[0].PartitionNumber
  $report.assigned_drive=$drive
  $vol=(& fsutil.exe fsinfo volumeinfo $drive 2>&1 | Out-String)
  $report.volumeinfo=$vol
  $report.service=$service
  if ($LASTEXITCODE -ne 0) {throw "Unable to query mounted ext4 volume $drive : $vol"}
  $root=Join-Path $drive 'rwf809-native-ext4'
  New-Item -Path $root -ItemType Directory -Force -ErrorAction Stop | Out-Null
  $bytes=New-Object byte[] 65537
  for ($i=0;$i -lt $bytes.Length;$i++) {$bytes[$i]=[byte](($i*37+11)%256)}
  $target=Join-Path $root 'pattern.bin'
  [IO.File]::WriteAllBytes($target,$bytes)
  $readback=[IO.File]::ReadAllBytes($target)
  if (-not [Linq.Enumerable]::SequenceEqual[byte]($bytes,$readback)) {throw 'Native read-after-write byte mismatch'}
  $sha=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
  for ($n=0;$n -lt 100;$n++){
    $sub=Join-Path $root ('file-{0:d3}.bin' -f $n)
    [IO.File]::WriteAllBytes($sub,[byte[]]@($n%256))
  }
  if (@(Get-ChildItem -LiteralPath $root -Filter 'file-*.bin').Count -ne 100) {throw 'Directory enumeration mismatch'}
  $renamed=Join-Path $root 'renamed.bin'
  [IO.File]::Move((Join-Path $root 'file-000.bin'),$renamed)
  if (-not (Test-Path -LiteralPath $renamed)) {throw 'Rename did not persist'}
  Remove-Item -LiteralPath $renamed -Force
  $report.first_readwrite='PASS'
  (& fltmc.exe instances 2>&1 | Out-String) | Set-Content -Path (Join-Path $Output 'filter-instances-after-mount.txt') -Encoding utf8
  Dismount-VHD -Path $path -ErrorAction Stop
  $mounted=$false
  $disk=Mount-VHD -Path $path -Passthru -ErrorAction Stop | Get-Disk -ErrorAction Stop
  $mounted=$true
  if ($disk.IsBoot -or $disk.IsSystem -or $disk.PartitionStyle -ne 'GPT') {throw 'Unsafe remounted VHDX identity'}
  $parts=@(Get-Partition -DiskNumber $disk.Number | Where-Object {$_.Size -gt 500MB})
  if ($parts.Count -ne 1) {throw 'Data partition missing after remount'}
  $drive=Assign-Drive -DiskNumber $disk.Number -PartitionNumber $parts[0].PartitionNumber
  $target=Join-Path (Join-Path $drive 'rwf809-native-ext4') 'pattern.bin'
  if (-not (Test-Path -LiteralPath $target)) {throw 'Data disappeared after remount'}
  $readback=[IO.File]::ReadAllBytes($target)
  if (-not [Linq.Enumerable]::SequenceEqual[byte]($bytes,$readback)) {throw 'Persisted bytes mismatch'}
  if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) {throw 'Persisted SHA mismatch'}
  $report.second_readwrite='PASS'
  $report.file_sha256=$sha
  $report.stage='PASS'
  Write-Host "RWF809_NATIVE_EXT4_MOUNT_WRITE_REMOUNT_PASS drive=$drive sha=$sha image=$actual"
} catch {
  $report.stage='FAIL'
  $report.error=$_.Exception.Message
  Write-Host "RWF809_NATIVE_EXT4_GATE_FAIL $($report.error)"
  throw
} finally {
  if ($mounted) {
    try {Dismount-VHD -Path $path -ErrorAction Stop} catch {Write-Warning "Test VHDX cleanup: $_"}
  }
  Emit
}
