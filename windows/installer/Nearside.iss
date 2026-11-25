; Nearside's installer (Inno Setup 7). windows\scripts\release.ps1 builds it, once per architecture:
;   ISCC /DVersion=0.2.0 /DArch=x64|arm64 /DSource=<the app's folder> [/DSign /Snearside=<signtool command>] Nearside.iss
; For everyone on the PC, in Program Files: Windows' camera service only loads a camera from a
; folder that only administrators can change.

#ifndef Version
  #error Pass /DVersion=<version>
#endif
#ifndef Arch
  #error Pass /DArch=x64 or /DArch=arm64
#endif
#ifndef Source
  #error Pass /DSource=<the published app folder>
#endif
#ifndef Output
  #define Output "..\build\release"
#endif

[Setup]
; Never change AppId: it's how an update finds the installed copy.
AppId={{799C5799-6D48-4290-8D27-D73DEC50C003}
AppName=Nearside
AppVersion={#Version}
AppVerName=Nearside {#Version}
AppPublisher=Nearside
AppPublisherURL=https://ramiejleh.github.io/Nearside/
AppSupportURL=https://github.com/ramiejleh/Nearside/issues
AppUpdatesURL=https://github.com/ramiejleh/Nearside/releases
VersionInfoVersion={#Version}
DefaultDirName={autopf}\Nearside
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=admin
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; Not on Arm PCs: the camera service there can't load an x64 camera (they get the arm64 installer).
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
#endif
MinVersion=10.0.22000
OutputDir={#Output}
OutputBaseFilename=Nearside-{#Version}-{#Arch}
SetupIconFile=..\App\Assets\Nearside.ico
UninstallDisplayIcon={app}\Nearside.exe
UninstallDisplayName=Nearside
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; Nearside quits before an update runs this; anything still running is closed.
CloseApplications=force
RestartApplications=no
#ifdef Sign
SignTool=nearside
SignedUninstaller=yes
#endif

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Excludes: "NearsideCamera.dll"; Flags: ignoreversion recursesubdirs createallsubdirs
; The camera service may have the old one loaded: replaced at the next restart if so.
Source: "{#Source}\NearsideCamera.dll"; DestDir: "{app}"; Flags: ignoreversion restartreplace uninsrestartdelete

[Icons]
Name: "{autoprograms}\Nearside"; Filename: "{app}\Nearside.exe"

[Run]
Filename: "{sys}\regsvr32.exe"; Parameters: "/s ""{app}\NearsideCamera.dll"""; Flags: runhidden waituntilterminated; StatusMsg: "Setting up Nearside Camera..."
Filename: "{app}\Nearside.exe"; Description: "Open Nearside"; Flags: nowait postinstall skipifsilent runasoriginaluser
; An update (WinSparkle passes /RELAUNCH): Nearside starts again by itself.
Filename: "{app}\Nearside.exe"; Flags: nowait runasoriginaluser; Check: Relaunching

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im Nearside.exe"; Flags: runhidden waituntilterminated; RunOnceId: "StopNearside"
Filename: "{sys}\regsvr32.exe"; Parameters: "/u /s ""{app}\NearsideCamera.dll"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveCamera"

[Code]
function Relaunching: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/RELAUNCH') = 0 then Result := True;
end;

{ An update: the camera service lets go of the old camera DLL when stopped (it starts again
  when an app next opens a camera). }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
  if FileExists(ExpandConstant('{app}\NearsideCamera.dll')) then
  begin
    Exec(ExpandConstant('{sys}\sc.exe'), 'stop FrameServer', '', SW_HIDE, ewWaitUntilTerminated, Code);
    Sleep(1500);
  end;
end;

{ Start at sign-in (Settings) is per person: this removes it for whoever uninstalls. }
procedure CurUninstallStepChanged(Step: TUninstallStep);
begin
  if Step = usPostUninstall then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Nearside');
end;
