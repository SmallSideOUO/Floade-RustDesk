$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$output = Join-Path $root 'floade-artifacts/branded-windows-x64'
$release = Join-Path $root 'flutter/build/windows/x64/runner/Release'
if (-not (Test-Path -LiteralPath (Join-Path $release 'rustdesk.exe'))) { throw 'Build the Flutter frontend first' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
Get-ChildItem -LiteralPath $release | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $output -Recurse -Force }
Move-Item -LiteralPath (Join-Path $output 'rustdesk.exe') -Destination (Join-Path $output 'FloadeRemote.exe') -Force
Copy-Item -LiteralPath LICENCE -Destination (Join-Path $output 'AGPL-3.0.txt') -Force
$hashes = @{}
Get-ChildItem -LiteralPath $output -File -Recurse | Where-Object { $_.Name -ne 'floade-build.json' } | ForEach-Object { $hashes[$_.FullName.Substring($output.Length + 1).Replace('\','/')] = (Get-FileHash -LiteralPath $_.FullName).Hash }
@{ schema = 1; upstream_version = '1.5.0'; source_repository = 'https://github.com/SmallSideOUO/Floade-RustDesk'; source_commit = (git rev-parse HEAD); files = $hashes } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'floade-build.json') -Encoding utf8
Write-Output "Branded runtime: $output"
