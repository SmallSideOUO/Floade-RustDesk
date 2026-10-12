param([switch]$NoConnect, [switch]$DisableLowLatency, [switch]$DisableGpuTexture)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$binary = Join-Path $repoRoot 'floade-artifacts\windows-x86_64\rustdesk.exe'
$manifest = Join-Path $repoRoot 'floade-artifacts\windows-x86_64\floade-build.json'
if (-not (Test-Path -LiteralPath $manifest)) { throw 'Build the modified candidate first' }
$metadata = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
$dll = Join-Path (Split-Path -Parent $binary) 'librustdesk.dll'
if ((Get-FileHash -LiteralPath $dll).Hash -ne $metadata.native_core_sha256) {
    throw 'Candidate native core checksum does not match its build manifest'
}
if (Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" | Where-Object { $_.ExecutablePath -eq $binary }) {
    throw 'Close the candidate before switching profiles or launching another test'
}
& (Join-Path $PSScriptRoot 'floade-configure-gpu.ps1') -DisableGpuTexture:$DisableGpuTexture
$env:FLOADE_RUSTDESK_TEST_PROFILE = '1'
$env:FLOADE_RUSTDESK_LOW_LATENCY = if ($DisableLowLatency) { '0' } else { '1' }
$env:RUST_LOG = 'info,webrtc-sctp=warn,webrtc=warn,webrtc_ice::agent::agent_internal=error,webrtc::peer_connection=error'
$profileConfig = Join-Path $env:APPDATA 'FloadeRustDesk\config'
$sourceNetworkConfig = Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml'
$targetNetworkConfig = Join-Path $profileConfig 'FloadeRustDesk2.toml'
if ((Test-Path -LiteralPath $sourceNetworkConfig) -and -not (Test-Path -LiteralPath $targetNetworkConfig)) {
    New-Item -ItemType Directory -Path $profileConfig -Force | Out-Null
    Copy-Item -LiteralPath $sourceNetworkConfig -Destination $targetNetworkConfig
}
$sourceCodecConfig = Join-Path $env:APPDATA 'RustDesk\config\RustDesk_hwcodec.toml'
$targetCodecConfig = Join-Path $profileConfig 'FloadeRustDesk_hwcodec.toml'
if ((Test-Path -LiteralPath $sourceCodecConfig) -and -not (Test-Path -LiteralPath $targetCodecConfig)) {
    New-Item -ItemType Directory -Path $profileConfig -Force | Out-Null
    Copy-Item -LiteralPath $sourceCodecConfig -Destination $targetCodecConfig
}
$arguments = @('--no-server')
if (-not $NoConnect) {
    $sourcePeers = Join-Path $env:APPDATA 'RustDesk\config\peers'
    $peers = @(Get-ChildItem -LiteralPath $sourcePeers -Filter '*.toml')
    if ($peers.Count -ne 1 -or $peers[0].BaseName -notmatch '^\d+$') {
        throw 'Automatic launch requires exactly one saved numeric peer; use -NoConnect otherwise'
    }
    $targetPeers = Join-Path $env:APPDATA 'FloadeRustDesk\config\peers'
    New-Item -ItemType Directory -Path $targetPeers -Force | Out-Null
    $targetPeer = Join-Path $targetPeers $peers[0].Name
    if (-not (Test-Path -LiteralPath $targetPeer)) {
        Copy-Item -LiteralPath $peers[0].FullName -Destination $targetPeer
    }
    $arguments += @('--connect', $peers[0].BaseName)
}
$process = Start-Process -FilePath $binary -WorkingDirectory (Split-Path -Parent $binary) -ArgumentList $arguments -WindowStyle Hidden -PassThru
Write-Output "Candidate process started: $($process.Id); profile: FloadeRustDesk"
