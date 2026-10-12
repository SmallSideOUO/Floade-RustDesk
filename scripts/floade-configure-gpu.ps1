param([switch]$DisableGpuTexture)
$ErrorActionPreference = 'Stop'
$profileConfig = Join-Path $env:APPDATA 'FloadeRustDesk\config'
New-Item -ItemType Directory -Path $profileConfig -Force | Out-Null
$path = Join-Path $profileConfig 'FloadeRustDesk_local.toml'
$text = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw } else { "[options]`n" }
$backup = Join-Path $profileConfig 'FloadeRustDesk_local.before-gpu-tuning.toml'
if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $path -Destination $backup
}
if ($text -notmatch '(?m)^\[options\]\s*$') { $text += "`n[options]`n" }
$value = if ($DisableGpuTexture) { 'N' } else { 'Y' }
$pattern = '(?ms)(^\[options\][ \t]*\r?\n)(.*?)(?=^\[|\z)'
$text = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    $body = $match.Groups[2].Value
    foreach ($key in @('allow-d3d-render', 'use-texture-render')) {
        $keyPattern = '(?m)^' + [regex]::Escape($key) + '[ \t]*=.*$'
        $setting = "$key = '$value'"
        if ($body -match $keyPattern) {
            $body = [regex]::Replace($body, $keyPattern, $setting)
        } else {
            $body = "$setting`n$body"
        }
    }
    return $match.Groups[1].Value + $body
})
[System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
