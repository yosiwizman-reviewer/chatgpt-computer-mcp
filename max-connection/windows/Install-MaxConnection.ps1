<#
Max Connection for Windows — installs and connects one computer.

Runs as the signed-in user (Chat On Steroids must live in the user's session to see the
desktop). Only the cloudflared part asks Windows for administrator rights.

  1. Reads the private activation link (argument, clipboard, or a prompt).
  2. Installs Chat On Steroids (pinned, checksum-verified) if missing or older than 2.1.52.
  3. Configures it: "Local only" tunnel mode, plugin URLs and port kept across restarts,
     auto-connect, start at sign-in, desktop control for ChatGPT calls.
  4. Redeems the activation link at the enrollment service -> this computer's own
     Cloudflare Tunnel + hostname + tunnel token.
  5. Installs cloudflared (pinned, checksum-verified) as an automatic Windows service.
  6. Verifies the public hostname reaches this computer, then opens the connection helper.

Nothing secret is written to the log. The machine secret is kept with Windows DPAPI
(current user). Re-running is safe: same machine -> same hostname and tunnel.
#>
[CmdletBinding()]
param(
  [string]$Activation = "",
  [string]$EnrollUrl = "https://enroll.akior.io",
  [string]$FriendlyName = $env:COMPUTERNAME,
  [switch]$NoHelper,
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Version = "0.1.0"
$Pins = @{
  CosVersion  = "2.1.53"
  CosMin      = [version]"2.1.52"
  CosX64Url   = "https://github.com/totec448-spec/chat-on-steroids/releases/download/v2.1.53/Chat-On-Steroids-Setup-x64.exe"
  CosX64Sha   = "090eab9289e7a1f4f1767b622fbb186ab631a6f055e9620f15bf6e4e7eb773bb"
  CosArmUrl   = "https://github.com/totec448-spec/chat-on-steroids/releases/download/v2.1.53/Chat-On-Steroids-Setup-arm64.exe"
  CosArmSha   = "66e6eecfc96e1e811509fbe719681786cffc30cc0e79edf8c628b38278b13666"
  CfdUrl      = "https://github.com/cloudflare/cloudflared/releases/download/2026.11.0/cloudflared-windows-amd64.msi"
  CfdSha      = "a8500dc66eb21b1b48e5f362809afb6d583099f283ed253bbf69a9c0e0c90999"
}

$Home_     = Join-Path $env:LOCALAPPDATA "MaxConnection"
$StatePath = Join-Path $Home_ "state.json"
$LogPath   = Join-Path $Home_ "install.log"
$CosData   = Join-Path $env:APPDATA "chat-on-steroids"
$CosConfig = Join-Path $CosData "config.json"
$CosLog    = Join-Path $CosData "app.log"
New-Item -ItemType Directory -Force -Path $Home_ | Out-Null

function Log([string]$msg) {
  $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"), $msg
  Add-Content -Path $LogPath -Value $line
  if (-not $Quiet) { Write-Host $msg }
}
function Fail([string]$msg) { Log "FAILED: $msg"; throw $msg }

# ---------------------------------------------------------------- state

function Load-State {
  if (Test-Path $StatePath) { return Get-Content $StatePath -Raw | ConvertFrom-Json }
  return [pscustomobject]@{}
}
function Save-State($s) { $s | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8 }
function Set-Prop($o, $n, $v) { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v -Force }

function New-B64Url([int]$bytes) {
  $b = New-Object byte[] $bytes
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  return [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-MachineSecret($state) {
  if ($state.machine_secret_dpapi) {
    $ss = ConvertTo-SecureString $state.machine_secret_dpapi
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
  }
  $plain = New-B64Url 32
  Set-Prop $state "machine_secret_dpapi" (ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString)
  return $plain
}

# ---------------------------------------------------------------- activation

function Get-ActivationCode([string]$given) {
  $candidates = @($given)
  try { Add-Type -AssemblyName System.Windows.Forms; $candidates += [Windows.Forms.Clipboard]::GetText() } catch {}
  foreach ($c in $candidates) {
    if ($c -and $c -match '(?:#|^)([A-Za-z0-9_-]{40,64})\s*$') { return $Matches[1] }
  }
  Add-Type -AssemblyName Microsoft.VisualBasic
  $typed = [Microsoft.VisualBasic.Interaction]::InputBox(
    "Paste the private Max Connection activation link for this computer.", "Max Connection", "")
  if ($typed -match '(?:#|^)([A-Za-z0-9_-]{40,64})\s*$') { return $Matches[1] }
  return $null
}

# ---------------------------------------------------------------- downloads

function Get-Verified([string]$url, [string]$sha, [string]$name) {
  $dir = Join-Path $Home_ "downloads"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $file = Join-Path $dir $name
  if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $sha.ToUpper()) {
    Log "Downloading $name"
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
  }
  $got = (Get-FileHash $file -Algorithm SHA256).Hash
  if ($got -ne $sha.ToUpper()) { Remove-Item $file -Force; Fail "Checksum mismatch for $name" }
  Log "Verified $name (sha256 $($sha.Substring(0,12))...)"
  return $file
}

# ---------------------------------------------------------------- Chat On Steroids

function Get-CosInstall {
  $keys = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
  $hit = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "Chat On Steroids*" } | Select-Object -First 1
  if (-not $hit) { return $null }
  $exe = $null
  if ($hit.DisplayIcon) { $exe = ($hit.DisplayIcon -split ',')[0].Trim('"') }
  if (-not $exe -or -not (Test-Path $exe)) { $exe = Join-Path $env:LOCALAPPDATA "Programs\Chat On Steroids\Chat On Steroids.exe" }
  [pscustomobject]@{ Version = [version]($hit.DisplayVersion -replace '[^0-9.].*$', ''); Exe = $exe }
}

function Ensure-Cos {
  $cos = Get-CosInstall
  if ($cos -and $cos.Version -ge $Pins.CosMin -and (Test-Path $cos.Exe)) {
    Log "Chat On Steroids $($cos.Version) already installed - reusing it"
    return $cos
  }
  $arm = $env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64"
  $file = if ($arm) { Get-Verified $Pins.CosArmUrl $Pins.CosArmSha "Chat-On-Steroids-Setup-arm64.exe" } else { Get-Verified $Pins.CosX64Url $Pins.CosX64Sha "Chat-On-Steroids-Setup-x64.exe" }
  Log "Installing Chat On Steroids $($Pins.CosVersion) for this user"
  Stop-Cos
  $p = Start-Process -FilePath $file -ArgumentList "/S", "/currentuser" -Wait -PassThru
  if ($p.ExitCode -ne 0) { Fail "Chat On Steroids installer exited with $($p.ExitCode)" }
  $cos = Get-CosInstall
  if (-not $cos) { Fail "Chat On Steroids did not register after install" }
  return $cos
}

function Stop-Cos {
  Get-Process -Name "Chat On Steroids" -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
}

function Start-CosAndGetPort($cos, [int]$timeoutSec = 60) {
  $mark = if (Test-Path $CosLog) { (Get-Item $CosLog).Length } else { 0 }
  Start-Process -FilePath $cos.Exe | Out-Null
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    if (-not (Test-Path $CosLog)) { continue }
    $fs = [IO.File]::Open($CosLog, 'Open', 'Read', 'ReadWrite')
    try {
      if ($fs.Length -lt $mark) { $mark = 0 }
      $fs.Seek($mark, 'Begin') | Out-Null
      $tail = (New-Object IO.StreamReader($fs)).ReadToEnd()
    } finally { $fs.Dispose() }
    $m = [regex]::Matches($tail, 'server started on 127\.0\.0\.1:(\d+)')
    if ($m.Count) { return [int]$m[$m.Count - 1].Groups[1].Value }
  }
  Fail "Chat On Steroids did not start its local server within $timeoutSec s"
}

function Configure-Cos($cos, [string]$name) {
  if (-not (Test-Path $CosConfig)) {
    Log "First start of Chat On Steroids to create its settings"
    Start-CosAndGetPort $cos | Out-Null
  }
  Stop-Cos
  Copy-Item $CosConfig "$CosConfig.max-connection-backup" -Force
  $c = Get-Content $CosConfig -Raw | ConvertFrom-Json
  foreach ($sec in "tunnel", "mcp", "ui") { if (-not $c.$sec) { Set-Prop $c $sec ([pscustomobject]@{}) } }
  Set-Prop $c.tunnel "kind" "manual"                 # Local only - Max Connection runs the tunnel
  Set-Prop $c.mcp "persistentUrls" $true             # same port + plugin paths after restarts
  Set-Prop $c.ui "autoConnect" $true
  Set-Prop $c.ui "startAtLogin" $true
  Set-Prop $c.ui "minimizeToTray" $true
  Set-Prop $c.ui "desktopUnattributed" $true         # ChatGPT (without the browser extension) may use the desktop
  Set-Prop $c "connectorSuffix" $name
  if (-not $c.roots -or @($c.roots).Count -eq 0) {
    $shared = Join-Path $env:USERPROFILE "Max Connection"
    New-Item -ItemType Directory -Force -Path $shared | Out-Null
    Set-Prop $c "roots" @([pscustomobject]@{ name = "max-connection"; path = $shared })
  }
  $c | ConvertTo-Json -Depth 30 | Set-Content -Path $CosConfig -Encoding UTF8
  Log "Configured Chat On Steroids (Local only, kept URLs, auto-connect, start at sign-in, desktop on)"
}

# ---------------------------------------------------------------- enrollment

function Invoke-Enroll($code, $state, $secret, [int]$port, [string]$name) {
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64") { "arm64" } else { "x64" }
  $body = @{ code = $code; machine_secret = $secret; machine_id = $state.machine_id; name = $name; os = "windows"; arch = $arch; port = $port } | ConvertTo-Json
  for ($i = 1; $i -le 4; $i++) {
    try {
      return Invoke-RestMethod -Method Post -Uri "$EnrollUrl/v1/enroll" -ContentType "application/json" -Body $body -TimeoutSec 60
    } catch {
      $status = $_.Exception.Response.StatusCode.value__
      if ($status -in 400, 403, 429) { Fail "Activation refused ($status). Ask for a new activation link." }
      Log "Enrollment attempt $i failed ($status); retrying"
      Start-Sleep -Seconds (5 * $i)
    }
  }
  Fail "Enrollment service unreachable"
}

# ---------------------------------------------------------------- cloudflared (elevated)

function Install-TunnelService([string]$token) {
  $msi = Get-Verified $Pins.CfdUrl $Pins.CfdSha "cloudflared-windows-amd64.msi"
  # Hand the token to the elevated step through a file only this user can read; it is deleted at once.
  $tokFile = Join-Path $Home_ ("t-" + [guid]::NewGuid().ToString("N"))
  Set-Content -Path $tokFile -Value $token -NoNewline -Encoding ASCII
  icacls $tokFile /inheritance:r /grant:r "$($env:USERNAME):(R,D)" "SYSTEM:(F)" "Administrators:(F)" | Out-Null
  $result = Join-Path $Home_ "elevated-result.txt"
  Remove-Item $result -ErrorAction SilentlyContinue
  $elevated = @"
`$ErrorActionPreference = 'Stop'
try {
  `$exe = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
  if (-not (Test-Path `$exe)) { `$p = Start-Process msiexec.exe -ArgumentList '/i', '"$msi"', '/qn', '/norestart' -Wait -PassThru; if (`$p.ExitCode -ne 0) { throw "msiexec `$(`$p.ExitCode)" } }
  `$svc = Get-Service Cloudflared -ErrorAction SilentlyContinue
  `$marker = 'C:\ProgramData\MaxConnection\owner.txt'
  if (`$svc -and -not (Test-Path `$marker)) { throw 'A Cloudflared service not installed by Max Connection already exists; leaving it untouched.' }
  if (`$svc) { & `$exe service uninstall 2>&1 | Out-Null; Start-Sleep 2 }
  `$t = Get-Content '$tokFile' -Raw
  & `$exe service install `$t 2>&1 | Out-Null
  Remove-Item '$tokFile' -Force
  New-Item -ItemType Directory -Force -Path 'C:\ProgramData\MaxConnection' | Out-Null
  Set-Content `$marker 'Max Connection'
  sc.exe failure Cloudflared reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
  Start-Service Cloudflared -ErrorAction SilentlyContinue
  'OK ' + (Get-Service Cloudflared).Status | Set-Content '$result'
} catch { 'ERR ' + `$_.Exception.Message | Set-Content '$result'; Remove-Item '$tokFile' -Force -ErrorAction SilentlyContinue }
"@
  $script = Join-Path $Home_ "elevated-step.ps1"
  Set-Content -Path $script -Value $elevated -Encoding UTF8
  Log "Asking Windows for administrator rights to install the tunnel service"
  try {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
  } catch {
    Remove-Item $tokFile -Force -ErrorAction SilentlyContinue
    Fail "Administrator permission was declined; the tunnel service was not installed. Run the installer again to retry."
  } finally { Remove-Item $script -Force -ErrorAction SilentlyContinue }
  $r = if (Test-Path $result) { Get-Content $result -Raw } else { "ERR no result" }
  Remove-Item $result -ErrorAction SilentlyContinue
  if ($r -notmatch '^OK') { Fail "Tunnel service: $($r.Trim())" }
  Log "Tunnel service installed: $($r.Trim())"
}

function Test-PublicReach([string]$hostname, [int]$timeoutSec = 120) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      Invoke-WebRequest -Method Post -Uri "https://$hostname/mcp/core/reachability-check" -Body "{}" -ContentType "application/json" -UseBasicParsing -TimeoutSec 15 | Out-Null
    } catch {
      $s = $_.Exception.Response.StatusCode.value__
      # 404 comes from Chat On Steroids itself (wrong path) = tunnel and app are both up.
      if ($s -eq 404) { return $true }
    }
    Start-Sleep -Seconds 5
  }
  return $false
}

# ---------------------------------------------------------------- main

Log "Max Connection $Version installer starting on $env:COMPUTERNAME ($env:PROCESSOR_ARCHITECTURE)"
$state = Load-State
if (-not $state.machine_id) { Set-Prop $state "machine_id" ([guid]::NewGuid().ToString()) }
$secret = Get-MachineSecret $state
Set-Prop $state "friendly_name" $FriendlyName
Save-State $state

$code = Get-ActivationCode $Activation
if (-not $code -and -not $state.hostname) { Fail "No activation link was provided." }

$cos = Ensure-Cos
Configure-Cos $cos $FriendlyName
$port = Start-CosAndGetPort $cos
Log "Chat On Steroids local server on port $port"
Stop-Cos
$port2 = Start-CosAndGetPort $cos
if ($port2 -ne $port) { Fail "Local port changed across restart ($port -> $port2); 'Keep plugin URLs across restarts' is not active" }
Log "Port $port kept across a restart"

if ($code) {
  $r = Invoke-Enroll $code $state $secret $port $FriendlyName
  Set-Prop $state "hostname" $r.hostname
  Set-Prop $state "tunnel_id" $r.tunnel_id
  Set-Prop $state "port" $port
  Save-State $state
  Log "Enrolled as $($r.hostname)"
  Install-TunnelService $r.tunnel_token
  $r = $null
} elseif ($state.port -ne $port) {
  Log "Updating tunnel to new local port $port"
  Invoke-RestMethod -Method Post -Uri "$EnrollUrl/v1/update-port" -ContentType "application/json" -Body (@{ machine_secret = $secret; port = $port } | ConvertTo-Json) | Out-Null
  Set-Prop $state "port" $port; Save-State $state
}
$secret = $null

if (Test-PublicReach $state.hostname) { Log "Verified: https://$($state.hostname) reaches this computer" }
else { Fail "https://$($state.hostname) did not reach this computer within 2 minutes" }

Set-Prop $state "installed_version" $Version
Set-Prop $state "installed_at" (Get-Date -Format o)
Save-State $state

if (-not $NoHelper) {
  $helper = Join-Path $PSScriptRoot "ConnectionHelper.ps1"
  Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$helper`" -Hostname $($state.hostname) -Port $port -Name `"$FriendlyName`""
}
Log "Done."
