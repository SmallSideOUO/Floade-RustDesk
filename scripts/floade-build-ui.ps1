param([int]$Jobs = 2)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
$env:RUSTUP_HOME = Join-Path $root '.floade-tools/rustup'
$env:CARGO_HOME = Join-Path $env:USERPROFILE '.frd-cargo'
$env:RUSTUP_TOOLCHAIN = '1.75.0'
$env:VCPKG_ROOT = Join-Path $root '.floade-tools/vcpkg'
$env:VCPKG_INSTALLED_ROOT = Join-Path $env:VCPKG_ROOT 'installed'
$env:LIBCLANG_PATH = (Get-ChildItem (Join-Path $root '.floade-tools/llvm') -Filter libclang.dll -Recurse | Select-Object -First 1).DirectoryName
$llvmRoot = Join-Path $root '.floade-tools/llvm-ffigen'
New-Item -ItemType Directory -Path (Join-Path $llvmRoot 'bin') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $env:LIBCLANG_PATH 'libclang.dll') -Destination (Join-Path $llvmRoot 'bin/libclang.dll') -Force
$env:PATH = "$root/.floade-tools/flutter/bin;$env:CARGO_HOME/bin;$env:PATH"
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:RUST_LOG = 'info'
& "$env:CARGO_HOME/bin/flutter_rust_bridge_codegen.exe" --rust-input src/flutter_ffi.rs --dart-output flutter/lib/generated_bridge.dart --c-output flutter/macos/Runner/bridge_generated.h --llvm-path $llvmRoot *> .floade-tools/floade-bridge.log
if ($LASTEXITCODE -ne 0) { Get-Content .floade-tools/floade-bridge.log -Tail 25; throw 'Bridge generation failed' }
& "$env:CARGO_HOME/bin/cargo.exe" build --locked --lib --release --features flutter,hwcodec,vram -j $Jobs *> .floade-tools/floade-native.log
if ($LASTEXITCODE -ne 0) { Get-Content .floade-tools/floade-native.log -Tail 30; throw 'Native build failed' }
Push-Location flutter
try {
  & "$root/.floade-tools/flutter/bin/flutter.bat" build windows --release --dart-define=FLOADE_REMOTE=true --no-pub *> ../.floade-tools/floade-ui.log
  if ($LASTEXITCODE -ne 0) { Get-Content ../.floade-tools/floade-ui.log -Tail 30; throw 'Flutter build failed' }
} finally { Pop-Location }
& (Join-Path $PSScriptRoot 'floade-stage-runtime.ps1')
