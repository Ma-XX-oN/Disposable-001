# RWF809: inspect exact official ImDisk CLI PE dependencies (no driver installation).
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Join-Path $env:GITHUB_WORKSPACE 'ram-dependencies'
New-Item -ItemType Directory -Path $root -Force | Out-Null
$zip=Join-Path $env:RUNNER_TEMP 'imdisk.zip'
$unpack=Join-Path $env:RUNNER_TEMP 'imdisk-extracted'
Invoke-WebRequest 'https://static.ltr-data.se/files/imdisk.zip' -OutFile $zip
$hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne 'd42059314384992b5e7754a5734e66e7ad0ad7971f69a2b5aa106429b47c4a9c') {throw 'Package digest changed'}
Expand-Archive -LiteralPath $zip -DestinationPath $unpack -ErrorAction Stop
$files=@(Get-ChildItem -Path $unpack -Recurse -File | ForEach-Object {
  [pscustomobject]@{path=$_.FullName.Substring($unpack.Length);bytes=$_.Length}
})
$files | Export-Csv (Join-Path $root 'contents.csv') -NoTypeInformation
$cli=@(Get-ChildItem -Path $unpack -Filter imdisk.exe -Recurse -File | Where-Object {$_.FullName -match '(?i)amd64|x64'})
if ($cli.Count -ne 1) {throw "Expected unique x64 CLI, found $($cli.Count)"}
$installer=(Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Microsoft Visual Studio\Installer\vswhere.exe')
$vs=(& $installer -latest -products '*' -property installationPath | Out-String).Trim()
if (-not $vs) {throw 'Visual Studio toolchain unavailable'}
$dev=Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
$cmd='call "'+$dev+'" -no_logo -arch=amd64 && dumpbin /dependents "'+$cli[0].FullName+'"'
$stdout=Join-Path $root 'dumpbin-stdout.txt'
$stderr=Join-Path $root 'dumpbin-stderr.txt'
$p=Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d','/c',$cmd) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
if (-not $p.WaitForExit(20000)) {Stop-Process -Id $p.Id -Force;throw 'dumpbin blocked'}
if ($p.ExitCode -ne 0) {throw "dumpbin failed exit=$($p.ExitCode)"}
$imports=Get-Content -LiteralPath $stdout -Raw
Write-Host "RWF809_IMDISK_DEPENDENCIES_PASS sha=$hash"
Write-Host $imports
