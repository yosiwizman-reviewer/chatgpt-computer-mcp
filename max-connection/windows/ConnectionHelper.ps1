<#
Max Connection connection helper (Windows).

Chat On Steroids shows each plugin URL with its local address
(http://127.0.0.1:<port>/mcp/<surface>/<secret>). When you press its Copy button,
this window swaps the local address for this computer's permanent public hostname
and puts the ready-to-paste URL back on the clipboard. It never reads Chat On
Steroids' stored secrets; it only sees what you copy.
#>
param(
  [Parameter(Mandatory)][string]$Hostname,
  [Parameter(Mandatory)][int]$Port,
  [string]$Name = $env:COMPUTERNAME
)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$cosExe = Join-Path $env:LOCALAPPDATA "Programs\Chat On Steroids\Chat On Steroids.exe"
$pattern = "^http://127\.0\.0\.1:$Port/mcp/(core|desktop)/([A-Za-z0-9_-]{43})$"

$form = New-Object Windows.Forms.Form
$form.Text = "Max Connection - $Name"
$form.Size = New-Object Drawing.Size(720, 520)
$form.StartPosition = "CenterScreen"
$form.TopMost = $true
$form.Font = New-Object Drawing.Font("Segoe UI", 11)

$intro = New-Object Windows.Forms.Label
$intro.Location = New-Object Drawing.Point(16, 12); $intro.Size = New-Object Drawing.Size(680, 130)
$intro.Text = "This computer is connected as  $Hostname`r`n`r`n" +
  "1. In Chat On Steroids open Settings > Setup > step 5 and press Copy next to each MCP SERVER URL.`r`n" +
  "   This window turns it into the permanent address below and copies it again.`r`n" +
  "2. In ChatGPT: Plugins > Add > Add custom MCP server. Use the name and URL below,`r`n" +
  "   Authentication: No authentication. Tick 'I understand', then Create, then Connect."
$form.Controls.Add($intro)

function Add-Row([int]$y, [string]$label, [string]$value) {
  $l = New-Object Windows.Forms.Label
  $l.Location = New-Object Drawing.Point(16, $y); $l.Size = New-Object Drawing.Size(120, 26); $l.Text = $label
  $t = New-Object Windows.Forms.TextBox
  $t.Location = New-Object Drawing.Point(140, $y); $t.Size = New-Object Drawing.Size(440, 26); $t.ReadOnly = $true; $t.Text = $value
  $b = New-Object Windows.Forms.Button
  $b.Location = New-Object Drawing.Point(590, ($y - 2)); $b.Size = New-Object Drawing.Size(100, 30); $b.Text = "Copy"
  $b.Add_Click({ if ($t.Text) { [Windows.Forms.Clipboard]::SetText($t.Text) } }.GetNewClosure())
  $form.Controls.AddRange(@($l, $t, $b))
  return $t
}

$coreName = Add-Row 150 "Core name"    "Max Connection - $Name - Core"
$coreUrl  = Add-Row 185 "Core URL"     ""
$deskName = Add-Row 240 "Desktop name" "Max Connection - $Name - Desktop"
$deskUrl  = Add-Row 275 "Desktop URL"  ""
$coreUrl.Text = "(press Copy next to the Core URL in Chat On Steroids)"
$deskUrl.Text = "(press Copy next to the Desktop URL in Chat On Steroids)"

$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(16, 320); $status.Size = New-Object Drawing.Size(680, 50)
$status.ForeColor = [Drawing.Color]::DarkGreen
$form.Controls.Add($status)

$openCos = New-Object Windows.Forms.Button
$openCos.Location = New-Object Drawing.Point(16, 390); $openCos.Size = New-Object Drawing.Size(260, 40)
$openCos.Text = "Open Chat On Steroids"
$openCos.Add_Click({ if (Test-Path $cosExe) { Start-Process $cosExe } })
$openGpt = New-Object Windows.Forms.Button
$openGpt.Location = New-Object Drawing.Point(290, 390); $openGpt.Size = New-Object Drawing.Size(260, 40)
$openGpt.Text = "Open ChatGPT plugins"
$openGpt.Add_Click({ Start-Process "https://chatgpt.com/plugins" })
$form.Controls.AddRange(@($openCos, $openGpt))

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 700
$timer.Add_Tick({
  try { $clip = [Windows.Forms.Clipboard]::GetText().Trim() } catch { return }
  if ($clip -match $pattern) {
    $public = "https://$Hostname/mcp/$($Matches[1])/$($Matches[2])"
    if ($Matches[1] -eq "core") { $coreUrl.Text = $public } else { $deskUrl.Text = $public }
    [Windows.Forms.Clipboard]::SetText($public)
    $status.Text = "Converted the $($Matches[1]) URL. It is on the clipboard now - paste it into ChatGPT."
  }
})
$timer.Start()

$form.Add_Shown({ Start-Process "https://chatgpt.com/plugins"; if (Test-Path $cosExe) { Start-Process $cosExe } })
[void]$form.ShowDialog()
