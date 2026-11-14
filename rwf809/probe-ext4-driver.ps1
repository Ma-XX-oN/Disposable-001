# RWF 809 native Windows ext4 driver download/install/load capability probe.
# Run only in a disposable Windows runner, not on a persistent workstation.
param([Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$uri = 'https://github.com/bobranten/Ext4Fsd/releases/download/v0.71/Ext2Fsd-0.71-setup.exe'
$expectedSize = 6837744
$installer = Join-Path $env:RUNNER_TEMP 'Ext2Fsd-0.71-setup.exe'
$extract = Join-Path $env:RUNNER_TEMP 'rwf809-ext4fsd-inspect'
$report = [ordered]@{
  candidate='Ext4Fsd 0.71 / Ext2Fsd-0.71-setup.exe'
  official_url=$uri; expected_release_size_bytes=$expectedSize
  runner_image=$env:ImageOS; runner_image_version=$env:ImageVersion
  stage='initial'; attempted_install=$false; loaded=$false
}
function Write-Report {
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Output 'driver-probe.json') -Encoding utf8
}
try {
  if ($env:RUNNER_OS -ne 'Windows' -or -not $env:RUNNER_TEMP) { throw 'Disposable Windows Actions runner required' }
  $os = Get-CimInstance Win32_OperatingSystem
  $report.os = [ordered]@{caption=$os.Caption;version=$os.Version;build=$os.BuildNumber}
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator privileges unavailable'
  }
  if (Test-Path -LiteralPath $installer) { throw 'Refuse to reuse existing installer path' }
  Write-Host "RWF809_DRIVER_DOWNLOAD_BEGIN $uri"
  Invoke-WebRequest -Uri $uri -OutFile $installer -MaximumRedirection 10 -ErrorAction Stop
  $package = Get-Item -LiteralPath $installer
  $report.download_size_bytes = $package.Length
  $report.download_sha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($package.Length -ne $expectedSize) { throw "Official release asset length mismatch expected=$expectedSize actual=$($package.Length)" }
  $sig = Get-AuthenticodeSignature -FilePath $installer
  $report.installer_signature = [ordered]@{
    status=[string]$sig.Status
    signer=if ($sig.SignerCertificate) {$sig.SignerCertificate.Subject} else {''}
    issuer=if ($sig.SignerCertificate) {$sig.SignerCertificate.Issuer} else {''}
  }
  Write-Host "RWF809_DRIVER_DOWNLOAD_PASS bytes=$($package.Length) sha256=$($report.download_sha256) signature=$($sig.Status)"
  $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
  if (-not $sevenZip) {throw '7-Zip unavailable for package format inspection'}
  $listing = (& $sevenZip.Source l -slt $installer 2>&1 | Out-String)
  $listing | Set-Content -LiteralPath (Join-Path $Output 'package-listing.txt') -Encoding utf8
  if ($LASTEXITCODE -ne 0) {throw "7z listing rejected installer: $LASTEXITCODE"}
  $report.package_format = if ($listing -match '(?mi)^Type = Nsis\s*$') {'NSIS'} elseif ($listing -match '(?mi)^Type = Inno Setup\s*$') {'Inno'} else {'UNKNOWN'}
  New-Item -ItemType Directory -Path $extract -Force | Out-Null
  $extractedLog = (& $sevenZip.Source x -y "-o$extract" $installer 2>&1 | Out-String)
  $extractedLog | Set-Content -LiteralPath (Join-Path $Output 'extract-listing.txt') -Encoding utf8
  if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed exit=$LASTEXITCODE" }
  $sysFiles = @(Get-ChildItem -LiteralPath $extract -Filter '*.sys' -Recurse -File -ErrorAction Stop)
  $catFiles = @(Get-ChildItem -LiteralPath $extract -Filter '*.cat' -Recurse -File -ErrorAction Stop)
  $report.drivers = @($sysFiles | ForEach-Object {
    $s = Get-AuthenticodeSignature -FilePath $_.FullName
    [pscustomobject]@{
      file=$_.Name; relative_path=$_.FullName.Substring($extract.Length)
      length=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      signature=[string]$s.Status
      signer=if ($s.SignerCertificate) {$s.SignerCertificate.Subject} else {''}
    }
  })
  $report.catalogs = @($catFiles | ForEach-Object {
    $s = Get-AuthenticodeSignature -FilePath $_.FullName
    [pscustomobject]@{file=$_.Name;signature=[string]$s.Status;signer=if ($s.SignerCertificate) {$s.SignerCertificate.Subject} else {''}}
  })
  if (-not $sysFiles.Count) { throw 'Installer contained no inspectable .sys driver' }
  if (-not @($report.drivers | Where-Object {$_.signature -eq 'Valid'}).Count -and
      -not @($report.catalogs | Where-Object {$_.signature -eq 'Valid'}).Count) {
    throw 'No Authenticode-valid embedded driver or catalog; do not execute installer'
  }
  if ($report.package_format -notin @('NSIS','Inno')) {
    throw "Silent installation switch not verified for format $($report.package_format)"
  }
  $arguments = if ($report.package_format -eq 'NSIS') {'/S'} else {'/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'}
  Write-Host "RWF809_DRIVER_INSTALL_BEGIN format=$($report.package_format) switches=$arguments"
  $report.attempted_install=$true
  $process = Start-Process -FilePath $installer -ArgumentList $arguments -PassThru -Wait -ErrorAction Stop
  $report.installer_exit_code=$process.ExitCode
  if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {throw "Installer failed exit=$($process.ExitCode)"}
  $scQuery = (& sc.exe query Ext2Fsd 2>&1 | Out-String)
  $report.service_after_install=$scQuery
  if ($LASTEXITCODE -ne 0) {throw "Ext2Fsd driver service not registered: $scQuery"}
  $scStart = (& sc.exe start Ext2Fsd 2>&1 | Out-String)
  $report.service_start_output=$scStart
  $report.service_start_exit_code=$LASTEXITCODE
  $scFinal = (& sc.exe query Ext2Fsd 2>&1 | Out-String)
  $report.service_final=$scFinal
  $report.loaded = $scFinal -match '(?mi)STATE\s*:\s*4\s+RUNNING'
  if (-not $report.loaded) {throw "Driver not running on Windows Server 2025: $scFinal"}
  $report.stage='download-install-load-pass'
  Write-Host "RWF809_EXT4_DRIVER_LOAD_PASS sha256=$($report.download_sha256) os=$($os.Caption) build=$($os.BuildNumber)"
} catch {
  $report.failure = $_.Exception.Message
  Write-Host "RWF809_EXT4_DRIVER_PROBE_FAIL $($report.failure)"
  throw
} finally {
  Write-Report
}