; Programme d installation de PSADToolkit (Inno Setup 6).
;
; Genere par installer\Build-Installer.ps1, qui prepare le dossier source, compile
; PSADToolkit.exe et telecharge les prerequis livres (dossier prereq), puis appelle :
;   ISCC.exe /DAppVersion=3.2.0-test1 /DFileVersion=3.2.0.0 /DSourceDir=... /DOutputDir=... PSADToolkit.iss

#ifndef AppVersion
  #error "Definir AppVersion : utiliser installer\Build-Installer.ps1"
#endif
#ifndef FileVersion
  #define FileVersion "0.0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\stage"
#endif
#ifndef OutputDir
  #define OutputDir "..\build\installer"
#endif

[Setup]
AppId={{6C1C3E1E-5B7A-4F55-9C2B-3D0B6E0F2A41}
AppName=PSADToolkit
AppVersion={#AppVersion}
AppVerName=PSADToolkit {#AppVersion}
AppPublisher=PSADToolkit
AppComments=Administration Active Directory
VersionInfoVersion={#FileVersion}
VersionInfoProductVersion={#FileVersion}
VersionInfoDescription=Installation de PSADToolkit
DefaultDirName={autopf}\PSADToolkit
DefaultGroupName=PSADToolkit
DisableDirPage=no
DisableProgramGroupPage=yes
LicenseFile={#SourceDir}\LICENSE
InfoBeforeFile=AVANT-INSTALLATION.txt
OutputDir={#OutputDir}
OutputBaseFilename=PSADToolkit-Setup-{#AppVersion}
SetupIconFile=PSADToolkit.ico
UninstallDisplayIcon={app}\PSADToolkit.exe
UninstallDisplayName=PSADToolkit {#AppVersion}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; PowerShell 7 s installe pour la machine, et Program Files exige l elevation.
PrivilegesRequired=admin
; PowerShell 7.4 exige Windows 10 1607 ou Windows Server 2016 au minimum.
MinVersion=10.0.14393
ArchitecturesAllowed=x64compatible arm64
ArchitecturesInstallIn64BitMode=x64compatible arm64
CloseApplications=yes
SetupLogging=yes

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
french.DesktopIcon=Creer un raccourci sur le Bureau
english.DesktopIcon=Create a desktop shortcut
french.Prerequisites=Installation de PowerShell 7 et de GliderUI (quelques minutes)...
english.Prerequisites=Installing PowerShell 7 and GliderUI (a few minutes)...
french.PrerequisitesFailed=PSADToolkit est installe, mais la preparation de PowerShell 7 ou de GliderUI a echoue (code %1).%n%nElle sera retentee au premier lancement. Journal : %2
english.PrerequisitesFailed=PSADToolkit is installed, but preparing PowerShell 7 or GliderUI failed (code %1).%n%nIt will be retried on first launch. Log: %2
french.Launch=Lancer PSADToolkit
english.Launch=Launch PSADToolkit

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[InstallDelete]
; Une mise a jour remplace les scripts : retirer ceux qu une ancienne version aurait
; laisses, pour ne jamais charger un fichier orphelin.
Type: filesandordirs; Name: "{app}\UI"
Type: filesandordirs; Name: "{app}\Private"
Type: filesandordirs; Name: "{app}\Public"
Type: filesandordirs; Name: "{app}\Tools"
Type: filesandordirs; Name: "{app}\prereq"

[Icons]
Name: "{autoprograms}\PSADToolkit"; Filename: "{app}\PSADToolkit.exe"; WorkingDir: "{app}"; Comment: "Administration Active Directory"
Name: "{autodesktop}\PSADToolkit"; Filename: "{app}\PSADToolkit.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\PSADToolkit.exe"; Description: "{cm:Launch}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Params: String;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := CustomMessage('Prerequisites');
    Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\Launcher.ps1') +
      '" -InstallOnly -Scope AllUsers -Silent';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, ExpandConstant('{app}'),
      SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      ResultCode := -1;
    if ResultCode <> 0 then
      SuppressibleMsgBox(FmtMessage(CustomMessage('PrerequisitesFailed'),
        [IntToStr(ResultCode), ExpandConstant('{commonappdata}\PSADToolkit\Logs\install.log')]),
        mbInformation, MB_OK, IDOK);
  end;
end;
