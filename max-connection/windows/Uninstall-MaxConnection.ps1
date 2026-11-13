<#
Removes what Max Connection added on this computer: the Cloudflared service it installed
(only if the Max Connection marker is present) and its local state. Chat On Steroids is
left installed. The Cloudflare tunnel record stays in the account; reinstalling with a new
activation link on this computer reuses it.
#>
$ErrorActionPreference = "Continue"
$marker = "C:\ProgramData\MaxConnection\owner.txt"
if (Test-Path $marker) {
  $cmd = "& 'C:\Program Files (x86)\cloudflared\cloudflared.exe' service uninstall; Remove-Item 'C:\ProgramData\MaxConnection' -Recurse -Force"
  try { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList "-NoProfile -Command $cmd" } catch {}
}
# Keep the machine identity so a reinstall gets the same hostname; remove downloads and logs.
Remove-Item (Join-Path $env:LOCALAPPDATA "MaxConnection\downloads") -Recurse -Force -ErrorAction SilentlyContinue
