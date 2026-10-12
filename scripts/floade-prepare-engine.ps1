$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'floade-engine.json') -Raw | ConvertFrom-Json
$directory = Join-Path $root '.floade-tools/custom-engine'
$archive = Join-Path $directory 'windows-x64-release.zip'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
if (-not (Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri $pin.assetUrl -OutFile $archive -UseBasicParsing }
if ((Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $pin.assetSha256) { throw 'Pinned Flutter engine archive digest mismatch' }
$extracted = Join-Path $directory 'extracted'
Expand-Archive -LiteralPath $archive -DestinationPath $extracted -Force
$destination = Join-Path $root '.floade-tools/flutter/bin/cache/artifacts/engine/windows-x64-release'
if (-not (Test-Path -LiteralPath $destination)) { throw 'Run Flutter precache --windows first' }
foreach ($required in @('flutter_windows.dll', 'gen_snapshot.exe')) {
  if (-not (Test-Path -LiteralPath (Join-Path $extracted $required))) { throw "Engine component missing: $required" }
}
$installedEngine = Join-Path $destination 'flutter_windows.dll'
$cache = Join-Path $root 'flutter/.dart_tool/flutter_build'
if ((Test-Path -LiteralPath $installedEngine) -and (Test-Path -LiteralPath $cache) -and
    (Get-FileHash -LiteralPath $installedEngine).Hash -ne (Get-FileHash -LiteralPath (Join-Path $extracted 'flutter_windows.dll')).Hash) {
  Rename-Item -LiteralPath $cache -NewName ('flutter_build.engine-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
}
Get-ChildItem -LiteralPath $extracted -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $destination -Force }
Write-Output 'Prepared the pinned Flutter engine and matching AOT generator together.'
