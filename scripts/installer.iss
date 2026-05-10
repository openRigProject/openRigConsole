; openRig Console — Inno Setup installer script
; Compile with: iscc scripts\installer.iss
; Or run: scripts\build_windows_installer.ps1 (which compiles this automatically)

#define AppName      "openRig Console"
#define AppPublisher "openRig"
#define AppURL       "https://openrig.radio"
#define AppExeName   "openrig_console.exe"
#define AppId        "openRigConsole"

; Version is passed in from build_windows_installer.ps1 via /DAppVersion=x.y.z
; If not provided, fall back to a placeholder.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

; Build output directory — passed as absolute path from build_windows_installer.ps1
; via /DBuildDir=<path>. Falls back to a path relative to the project root for
; local use (iscc invoked from the project root, not the scripts/ directory).
#ifndef BuildDir
  #define BuildDir SourcePath + "\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{{#AppId}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
; Installer output
OutputDir=build
OutputBaseFilename=openRigConsole-{#AppVersion}-windows-setup
; Compression
Compression=lzma2/ultra64
SolidCompression=yes
; Require 64-bit Windows
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
; Appearance
WizardStyle=modern
; No admin required — installs to {autopf} which is Program Files on admin,
; or the user's local app data on non-admin.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Version info shown in Add/Remove Programs
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Installer
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Main executable
Source: "{#BuildDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; All DLLs alongside the executable
Source: "{#BuildDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

; Flutter data directory (assets, fonts, ICU data, etc.)
Source: "{#BuildDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Start Menu
Name: "{group}\{#AppName}";     Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
; Desktop (optional — only created if user chose the task)
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; \
  Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; \
  Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Clean up any runtime-generated files in the install directory
Type: filesandordirs; Name: "{app}"
