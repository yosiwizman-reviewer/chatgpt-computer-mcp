<#
Creates one fresh, private, single-use Max Connection activation link.

Run on a trusted computer that is already signed in to the Cloudflare account with
wrangler (that sign-in is the only authority; there is no admin password or endpoint).
Only the SHA-256 of the code is stored in Cloudflare. The full link is printed once and
copied to the clipboard - deliver it to the new computer privately; never commit it.

  powershell -File New-ActivationLink.ps1 [-Hours 24] [-Note "Office Mac"]
#>
param([int]$Hours = 24, [string]$Note = "")
$ErrorActionPreference = "Stop"
$b = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
$code = [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$hash = -join ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($code)) | ForEach-Object { $_.ToString("x2") })
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$exp = $now + $Hours * 3600
$safeNote = ($Note -replace "[^A-Za-z0-9 ._-]", "")
$sql = "INSERT INTO invites (code_hash, created_at, expires_at, note, state) VALUES ('$hash', $now, $exp, '$safeNote', 'new');"
Push-Location (Join-Path $PSScriptRoot "..\worker")
try { npx --yes wrangler@4 d1 execute max-connection --remote --command $sql | Out-Null; if ($LASTEXITCODE) { throw "wrangler failed ($LASTEXITCODE)" } }
finally { Pop-Location }
$link = "https://enroll.akior.io/activate#$code"
Set-Clipboard -Value $link
Write-Host "Activation link created (valid $Hours h, single use) and copied to the clipboard."
