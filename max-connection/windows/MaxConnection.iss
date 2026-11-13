; Max Connection - Windows installer (Inno Setup 6)
; Build: ISCC.exe /DAppVersion=0.1.0 MaxConnection.iss
; One installer for x64 and ARM64 Windows: it downloads the matching, checksum-pinned
; Chat On Steroids build at install time and installs cloudflared as a service.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{6C2E3B1F-9A1D-4E8B-9B7C-4D1A2F0E5A11}
AppName=Max Connection
AppVersion={#AppVersion}
AppPublisher=Max Connection (laboratory build)
DefaultDirName={localappdata}\MaxConnection\app
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist\max-connection
OutputBaseFilename=Max-Connection-Setup-{#AppVersion}-windows
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Max Connection
SetupLogging=yes

[Files]
Source: "Install-MaxConnection.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "ConnectionHelper.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Uninstall-MaxConnection.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; DestName: "README.txt"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Max Connection\Connection helper"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command ""$s = Get-Content '{localappdata}\MaxConnection\state.json' -Raw | ConvertFrom-Json; & '{app}\ConnectionHelper.ps1' -Hostname $s.hostname -Port $s.port -Name $s.friendly_name"""
Name: "{userprograms}\Max Connection\Repair connection"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Install-MaxConnection.ps1"""
Name: "{userprograms}\Max Connection\Install log"; Filename: "{localappdata}\MaxConnection\install.log"

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -STA -File ""{app}\Install-MaxConnection.ps1"" -Activation ""{param:ACTIVATION|}"""; StatusMsg: "Connecting this computer (installs Chat On Steroids and the tunnel service)..."; Flags: waituntilterminated

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-MaxConnection.ps1"""; RunOnceId: "MaxConnectionUninstall"; Flags: waituntilterminated

[Code]
function InitializeSetup(): Boolean;
begin
  Result := True;
end;
