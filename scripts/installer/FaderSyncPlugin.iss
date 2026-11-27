#ifndef Version
  #error Pass the version read from FaderSyncPlugin.csproj.
#endif
#ifndef FileVersion
  #error Pass the numeric version read from FaderSyncPlugin.csproj.
#endif
#ifndef PluginBinary
  #error Pass the path to the built Windows DLL.
#endif
#ifndef LicensePath
  #error Pass the path to the packaged LICENSE.
#endif

#define PluginName "GoXLR Fader Sync Plugin"
#define DllName "FaderSyncPlugin.dll"
#define Url "https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin"
#define OriginalLicensePath SourcePath + "..\..\LICENSE"

[Setup]
AppName={#PluginName}
AppId=FaderSyncPlugin-{code:InstallKey}
AppVersion={#Version}
AppPublisher=Malte Linke
AppPublisherURL={#Url}
AppSupportURL={#Url}/issues
AppUpdatesURL={#Url}/releases
AppCopyright=Copyright (C) Malte Linke
VersionInfoVersion={#FileVersion}
VersionInfoProductVersion={#FileVersion}
VersionInfoProductTextVersion={#Version}
VersionInfoTextVersion={#Version}
SetupArchitecture=x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
WizardStyle=modern
DisableStartupPrompt=yes
SetupIconFile=FaderSyncPlugin.ico
DefaultDirName={commonappdata}\obs-studio\FaderSyncPlugin-installs
DisableDirPage=yes
DisableProgramGroupPage=yes
DirExistsWarning=no
UsePreviousAppDir=no
UsePreviousLanguage=no
UninstallDisplayName={code:DisplayName}
UninstallDisplayIcon={uninstallexe}
UninstallLogMode=overwrite
SetupMutex=Global\FaderSyncPluginSetup
AppMutex=OBSStudioCore
CloseApplications=no
RestartApplications=no
OutputBaseFilename=FaderSyncPlugin-win-x64-installer
Compression=lzma2
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#PluginBinary}"; Flags: dontcopy
Source: "{#LicensePath}"; Flags: dontcopy

[Dirs]
Name: "{code:DataDir}"

[UninstallDelete]
Type: files; Name: "{code:BinaryDir}\{#DllName}"
Type: files; Name: "{code:LicenseDir}\LICENSE"

[Registry]
Root: HKLM; Subkey: "{code:InstallRegistryKey}"; ValueType: string; ValueName: "Root"; ValueData: "{code:SelectedRoot}"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKLM; Subkey: "{code:InstallRegistryKey}"; ValueType: dword; ValueName: "Mode"; ValueData: "{code:SelectedMode}"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKLM; Subkey: "{code:InstallRegistryKey}"; ValueType: dword; ValueName: "Major"; ValueData: "{code:SelectedMajor}"; Flags: uninsdeletevalue uninsdeletekeyifempty

[Code]
const
  ModuleName = 'FaderSyncPlugin';
  ModuleFile = '{#DllName}';
  LicenseHash = '{#GetSHA256OfFile(LicensePath)}';
  OriginalLicenseHash = '{#GetSHA256OfFile(OriginalLicensePath)}';
  InstallsKey = 'SOFTWARE\FaderSyncPlugin\Installations';
  UninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\';
  UnknownMode = 0;
  StandardMode = 1;
  PortableMode = 2;
  ObsExe = '\bin\64bit\obs64.exe';

#include "ObsInstallations.iss"
#include "PluginFiles.iss"
