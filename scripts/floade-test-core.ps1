$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$env:RUSTUP_HOME = Join-Path $repoRoot '.floade-tools\rustup'
$env:CARGO_HOME = Join-Path $repoRoot '.floade-tools\cargo'
$compiler = Join-Path $env:CARGO_HOME 'bin\rustc.exe'
$testBinary = Join-Path $repoRoot '.floade-tools\low-latency-tests.exe'
& $compiler --test (Join-Path $repoRoot 'src\client\low_latency.rs') --edition 2021 -o $testBinary
if ($LASTEXITCODE -ne 0) { throw 'Low latency strategy compilation failed' }
& $testBinary
if ($LASTEXITCODE -ne 0) { throw 'Low latency strategy tests failed' }
