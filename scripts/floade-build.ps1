param([int]$Jobs = 2)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repoRoot
$env:RUSTUP_HOME = Join-Path $repoRoot '.floade-tools\rustup'
$shortCargo = Join-Path $env:USERPROFILE '.frd-cargo'
$cargoDirectory = Join-Path $repoRoot '.floade-tools\cargo'
if (Test-Path -LiteralPath $shortCargo) {
    if ((Get-Item -LiteralPath $shortCargo).Target -ne $cargoDirectory) {
        throw 'Short Cargo path points to another directory'
    }
} else {
    New-Item -ItemType Junction -Path $shortCargo -Target $cargoDirectory | Out-Null
}
$env:CARGO_HOME = $shortCargo
$env:VCPKG_ROOT = Join-Path $repoRoot '.floade-tools\vcpkg'
$env:VCPKG_INSTALLED_ROOT = Join-Path $env:VCPKG_ROOT 'installed'
$clang = Get-ChildItem (Join-Path $repoRoot '.floade-tools\llvm') -Filter libclang.dll -Recurse | Select-Object -First 1
if (-not $clang) { throw 'LLVM libclang.dll is missing' }
$env:LIBCLANG_PATH = $clang.DirectoryName
$env:PATH = "$shortCargo\bin;$env:PATH"
$includeDirectory = Join-Path $env:VCPKG_INSTALLED_ROOT 'x64-windows-static\include'
foreach ($header in @('libavcodec\avcodec.h', 'opus\opus_multistream.h', 'vpx\vp8dx.h', 'aom\aom_encoder.h', 'libyuv.h', 'jpeglib.h')) {
    if (-not (Test-Path -LiteralPath (Join-Path $includeDirectory $header))) {
        throw "Native dependency not installed: $header"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'src\bridge_generated.io.rs'))) {
    throw 'Generate the matching Rust Flutter bridge before building'
}
$buildLog = Join-Path $repoRoot '.floade-tools\cargo-release.log'
& (Join-Path $shortCargo 'bin\cargo.exe') build --locked --lib --release --features flutter,hwcodec,vram -j $Jobs *> $buildLog
if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $buildLog -Tail 35
    throw 'Modified RustDesk core build failed'
}
$frontend = Join-Path $repoRoot '.floade-tools\upstream-1.5.0\windows-x86_64'
$output = Join-Path $repoRoot 'floade-artifacts\windows-x86_64'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Get-ChildItem -LiteralPath $frontend | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $output -Recurse -Force
}
$builtDll = Join-Path $repoRoot 'target\release\librustdesk.dll'
$stockHash = (Get-FileHash -LiteralPath (Join-Path $frontend 'librustdesk.dll')).Hash
$customHash = (Get-FileHash -LiteralPath $builtDll).Hash
if ($customHash -eq $stockHash) { throw 'The candidate must contain the modified core' }
Copy-Item -LiteralPath $builtDll -Destination (Join-Path $output 'librustdesk.dll') -Force
@{
    source_commit = (git rev-parse HEAD)
    source_worktree_modified = [bool](git status --porcelain)
    source_files = @('src/client.rs', 'src/client/io_loop.rs', 'src/core_main.rs', 'src/client/low_latency.rs', 'src/client/io_loop/low_latency.rs') | ForEach-Object {
        @{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot $_)).Hash }
    }
    native_core_sha256 = $customHash
    upstream_native_core_sha256 = $stockHash
    upstream_bundle_sha256 = 'd006697cb522e79a25cfad489f7b45de32c778407b2887c4870280bf7a2308c2'
    features = @('flutter', 'hwcodec', 'vram')
    frontend = 'Official RustDesk 1.5.0 x64'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'floade-build.json') -Encoding utf8
Write-Output "Built candidate: $output"
