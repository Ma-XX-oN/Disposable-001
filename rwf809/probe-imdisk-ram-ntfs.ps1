# RWF809 Gate 3 preliminary: native Windows RAM-backed NTFS functionality.
param([Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
New-Item -Path $Output -ItemType Directory -Force | Out-Null
$zip=Join-Path $env:RUNNER_TEMP 'rwf809-imdisk-2.1.2.zip'
$dir=Join-Path $env:RUNNER_TEMP 'rwf809-imdisk-package'
$report=[ordered]@{stage='START';source='https://static.ltr-data.se/files/imdisk.zip';runner=$env:ImageOS;image_version=$env:ImageVersion;ram_drive='R:'}
$mounted=$false
function Persist { $report | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $Output 'imdisk-probe.json') -Encoding utf8 }
try {
  if (-not $env:RUNNER_TEMP -or $env:RUNNER_OS -ne 'Windows') {throw 'Windows hosted runner required'}
  if (Get-PSDrive R -ErrorAction SilentlyContinue) {throw 'Drive R: already in use'}
  if (Test-Path -LiteralPath $zip) {throw 'Refuse to overwrite prior package'}
  Invoke-WebRequest -Uri $report.source -OutFile $zip -ErrorAction Stop
  $report.zip_bytes=(Get-Item $zip).Length
  $report.zip_sha256=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  Expand-Archive -Path $zip -DestinationPath $dir -ErrorAction Stop
  $inf=@(Get-ChildItem -LiteralPath $dir -Filter imdisk.inf -Recurse -File)
  if ($inf.Count -ne 1) {throw "Expected unique ImDisk INF, found $($inf.Count)"}
  $txt=Get-Content -LiteralPath $inf[0].FullName -Raw
  if ($txt -notmatch 'DriverVer\s*=\s*05/09/2026,2\.1\.2') {throw 'Expected ImDisk 2.1.2 INF revision'}
  $drivers=@(Get-ChildItem -LiteralPath $dir -Filter 'imdisk.sys' -Recurse -File)
  if (-not $drivers.Count) {throw 'No ImDisk kernel driver found'}
  $report.driver_signatures=@($drivers | ForEach-Object {
    $sig=Get-AuthenticodeSignature $_.FullName
    [pscustomobject]@{name=$_.Name;path=$_.FullName.Substring($dir.Length);sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant();status=[string]$sig.Status;signer=if ($sig.SignerCertificate) {$sig.SignerCertificate.Subject} else {''}}
  })
  $catalogs=@(Get-ChildItem -LiteralPath $dir -Filter '*.cat' -Recurse -File)
  $report.catalog_signatures=@($catalogs | ForEach-Object {
    $sig=Get-AuthenticodeSignature $_.FullName
    [pscustomobject]@{name=$_.Name;status=[string]$sig.Status;signer=if ($sig.SignerCertificate) {$sig.SignerCertificate.Subject} else {''}}
  })
  if (-not @($report.driver_signatures | Where-Object {$_.status -eq 'Valid'}).Count -and
      -not @($report.catalog_signatures | Where-Object {$_.status -eq 'Valid'}).Count) {
    throw 'No Authenticode-valid embedded driver or catalog; do not install'
  }
  $cli=@(Get-ChildItem -LiteralPath $dir -Filter 'imdisk.exe' -Recurse -File | Where-Object {$_.FullName -match '(?i)amd64|x64'})
  if ($cli.Count -ne 1) {throw "Expected unique x64 imdisk CLI; got $($cli.Count)"}
  Write-Host "RWF809_RAM_DRIVER_DOWNLOAD_PASS sha256=$($report.zip_sha256) bytes=$($report.zip_bytes)"
  # The prior rundll32 SetupAPI path blocked in CI; use supported PnPUtil.
  $stdout=Join-Path $Output 'pnputil-stdout.txt'
  $stderr=Join-Path $Output 'pnputil-stderr.txt'
  $arguments='/add-driver "'+$inf[0].FullName+'" /install'
  $setup=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\pnputil.exe') -ArgumentList $arguments -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
  if (-not $setup.WaitForExit(30000)) {
    Stop-Process -Id $setup.Id -Force -ErrorAction SilentlyContinue
    throw 'PnPUtil did not complete in 30 seconds'
  }
  $report.pnputil_exit=$setup.ExitCode
  if ($setup.ExitCode -ne 0) {throw "PnPUtil INF install failed $($setup.ExitCode)"}
  $report.service_query=(& sc.exe query ImDisk 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) {throw "ImDisk not registered as service: $($report.service_query)"}
  if ($report.service_query -notmatch '(?mi)STATE\s*:\s*4\s+RUNNING') {
    $start=(& sc.exe start ImDisk 2>&1 | Out-String)
    $report.service_start=$start
  }
  $report.service_final=(& sc.exe query ImDisk 2>&1 | Out-String)
  if ($report.service_final -notmatch '(?mi)STATE\s*:\s*4\s+RUNNING') {throw 'ImDisk service failed to run'}
  & $cli[0].FullName -a -s '512M' -m 'R:' -p '/fs:ntfs /q /y'
  if ($LASTEXITCODE -ne 0) {throw "ImDisk RAM volume allocation failed $LASTEXITCODE"}
  $mounted=$true
  $info=(& fsutil.exe fsinfo volumeinfo 'R:' 2>&1 | Out-String)
  $report.volume_info=$info
  if ($LASTEXITCODE -ne 0 -or $info -notmatch 'File System Name\s*:\s*NTFS') {throw "RAM volume is not NTFS: $info"}
  $target='R:\rwf809-ram-proof.bin'
  [byte[]]$data=0..255
  [IO.File]::WriteAllBytes($target,$data)
  $readback=[IO.File]::ReadAllBytes($target)
  if (-not [Linq.Enumerable]::SequenceEqual[byte]($data,$readback)) {throw 'RAM NTFS byte identity failed'}
  $report.file_sha256=(Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
  $report.stage='PASS'
  Write-Host "RWF809_RAM_NTFS_PASS driver=ImDisk2.1.2 bytes=512M fs=NTFS sha256=$($report.file_sha256)"
} catch {
  $report.stage='FAIL';$report.failure=$_.Exception.Message
  Write-Host "RWF809_RAM_NTFS_FAIL $($report.failure)"
  throw
} finally {
  if ($mounted) {
    try {& $cli[0].FullName -D -m 'R:' | Out-Null} catch {Write-Warning "RAM cleanup: $_"}
  }
  Persist
}
