type
  TProcessEntry = record
    Size, UseCount, ID, Padding: DWORD;
    Heap: NativeUInt;
    ModuleID, Threads, ParentID: DWORD;
    Priority: Longint;
    Flags: DWORD;
    Name: array[0..259] of Char;
    TailPadding: DWORD;
  end;

  TPluginFile = record
    Path, BackupName, PayloadHash, PreviousHash: string;
    Changed: Boolean;
  end;

var
  Files: array of TPluginFile;
  CreatedDirs: TArrayOfString;
  BackupRoot, Backup: string;
  Replacing, Installed: Boolean;
  RegistrationBackup: string;
  PreviousUninstallFiles: TArrayOfString;
  UninstallGate: THandle;

function GetAttributes(Path: string): DWORD;
  external 'GetFileAttributesW@kernel32.dll stdcall';
function OpenFile(Path: string; Access, Share: DWORD; Security: NativeUInt; Creation, Flags: DWORD; Template: THandle): THandle;
  external 'CreateFileW@kernel32.dll stdcall';
function MoveFileReplace(Source, Destination: string; Flags: DWORD): Boolean;
  external 'MoveFileExW@kernel32.dll stdcall setuponly';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function CreateMutex(Security: NativeUInt; InitialOwner: LongBool; Name: string): THandle;
  external 'CreateMutexW@kernel32.dll stdcall uninstallonly';
function TakeProcessSnapshot(Flags, ID: DWORD): THandle;
  external 'CreateToolhelp32Snapshot@kernel32.dll stdcall';
function FirstProcess(Handle: THandle; var Entry: TProcessEntry): Boolean;
  external 'Process32FirstW@kernel32.dll stdcall';
function NextProcess(Handle: THandle; var Entry: TProcessEntry): Boolean;
  external 'Process32NextW@kernel32.dll stdcall';
function ComputeCrc32(Initial: DWORD; const Data: AnsiString; Size: Integer): DWORD;
  external 'RtlComputeCrc32@ntdll.dll stdcall setuponly';

procedure RequireClosedObs;
var
  Handle: THandle;
  Entry: TProcessEntry;
  Name: string;
  I: Integer;
  Found: Boolean;
begin
  Handle := TakeProcessSnapshot(2, 0);
  if Handle = THandle(-1) then RaiseException('Could not check if OBS Studio is running.');
  try
    Entry.Size := SizeOf(Entry);
    if not FirstProcess(Handle, Entry) then RaiseException('Could not check if OBS Studio is running.');
    repeat
      Name := '';
      for I := 0 to 259 do begin
        if Entry.Name[I] = #0 then Break;
        Name := Name + Entry.Name[I];
      end;
      if CompareText(Name, 'obs64.exe') = 0 then
        RaiseException('Close OBS Studio before continuing.');
      Found := NextProcess(Handle, Entry);
    until not Found;
  finally
    CloseHandle(Handle);
  end;
end;

procedure CheckPath(Path: string; Directory: Boolean);
var
  Attr: DWORD;
  ErrorCode: Integer;
begin
  if (Length(Path) < 3) or (Copy(Path, 2, 2) <> ':\') then
    RaiseException('Setup requires a local drive path: ' + Path);
  while Path <> '' do begin
    Attr := GetAttributes(Path);
    if Attr = $FFFFFFFF then begin
      ErrorCode := DLLGetLastError;
      if (ErrorCode <> 2) and (ErrorCode <> 3) then
        RaiseException('Could not access ' + Path + ': ' + SysErrorMessage(ErrorCode));
    end
    else if ((Attr and $400) <> 0) or (((Attr and $10) <> 0) <> Directory) then
      RaiseException('Setup cannot safely use this redirected or conflicting path: ' + Path);
    if (Length(Path) = 3) and (Path[3] = '\') then Exit;
    Path := ExtractFileDir(Path);
    Directory := True;
  end;
end;

procedure CheckReplaceable(Path: string);
var
  Handle: THandle;
begin
  CheckPath(Path, False);
  if not FileExists(Path) then Exit;
  if (GetAttributes(Path) and 1) <> 0 then RaiseException('A plugin file is read-only: ' + Path);
  Handle := OpenFile(Path, $10000, 7, 0, 3, $200000, 0);
  if Handle = THandle(-1) then
    RaiseException('A plugin file is locked or cannot be replaced: ' + Path);
  CloseHandle(Handle);
end;

procedure AddFile(Path, BackupName, PayloadHash: string);
var
  I: Integer;
begin
  for I := 0 to GetArrayLength(Files) - 1 do
    if PathSame(Files[I].Path, Path) then Exit;
  I := GetArrayLength(Files);
  SetArrayLength(Files, I + 1);
  Files[I].Path := Path;
  Files[I].BackupName := BackupName;
  Files[I].PayloadHash := PayloadHash;
end;

function BinaryDir(Param: string): string;
begin
  Result := ModuleDir(Target);
end;

function LicenseDir(Param: string): string;
begin
  if Target.Mode = StandardMode then Result := SharedPluginRoot
  else if Target.Major < 33 then Result := Target.Root + '\data\obs-plugins\' + ModuleName
  else Result := ModuleDir(Target);
end;

function DataDir(Param: string): string;
begin
  Result := LicenseDir('');
  if (Target.Mode <> PortableMode) or (Target.Major >= 33) then Result := Result + '\data';
end;

function IsPluginLicense(Path: string): Boolean;
var
  Bytes: AnsiString;
  Text: string;
  Notices: Integer;
begin
  { The original license identifies both legacy and bundled copies. }
  Result := False;
  if not LoadStringFromFile(Path, Bytes) then Exit;
  Text := Bytes;
  StringChangeEx(Text, #13#10, #10, True);
  Notices := Pos(#10#10 + 'Third-party notices for GoXLR Fader Sync Plugin' + #10, Text);
  if Notices > 0 then Text := Copy(Text, 1, Notices - 1);
  Result := CompareText(GetSHA256OfString(Text), OriginalLicenseHash) = 0;
end;

function IsPluginDll(Path: string): Boolean;
var
  Bytes: AnsiString;
  Image: string;
begin
  Result := False;
  if not ReadX64Image(Path, Bytes) then Exit;
  Image := Bytes;
  { Search for the ASCII export names and UTF-16LE copyright marker. }
  Result := (Pos(ModuleFile + #0, Image) > 0) and
    (Pos('obs_module_load' + #0, Image) > 0) and
    (Pos('obs_module_set_pointer' + #0, Image) > 0) and
    (Pos('M'#0'a'#0'l'#0't'#0'e'#0' '#0'L'#0'i'#0'n'#0'k'#0'e'#0, Image) > 0);
end;

procedure CheckPluginFile(Path: string);
var
  Owned: Boolean;
begin
  CheckReplaceable(Path);
  if not FileExists(Path) then Exit;
  if CompareText(ExtractFileName(Path), ModuleFile) = 0 then Owned := IsPluginDll(Path)
  else Owned := IsPluginLicense(Path);
  if not Owned then RaiseException('This file does not belong to GoXLR Fader Sync Plugin: ' + Path);
end;

procedure AddLegacyLicense(Path, BackupName: string);
begin
  if IsPluginLicense(Path) then AddFile(Path, BackupName, '');
end;

procedure PlanFiles;
var
  LegacyBin, LegacyData, Modern: string;
begin
  SetArrayLength(Files, 0);
  LegacyBin := Target.Root + '\obs-plugins\64bit';
  LegacyData := Target.Root + '\data\obs-plugins\' + ModuleName;
  if Target.Mode = PortableMode then begin
    Modern := Target.Root + '\plugins\' + ModuleName;
    BackupRoot := Target.Root + '\FaderSyncPlugin-backups';
  end
  else begin
    Modern := SharedPluginRoot;
    BackupRoot := ExpandConstant('{commonappdata}\obs-studio\FaderSyncPlugin-backups');
  end;

  AddFile(BinaryDir('') + '\' + ModuleFile, 'previous.dll', '{#GetSHA256OfFile(PluginBinary)}');
  AddFile(LicenseDir('') + '\LICENSE', 'previous-LICENSE', LicenseHash);
  AddFile(Modern + '\' + ModuleFile, 'modern.dll', '');
  AddLegacyLicense(Modern + '\LICENSE', 'modern-LICENSE');
  if Target.Mode = StandardMode then
    AddFile(Modern + '\bin\64bit\' + ModuleFile, 'programdata-legacy.dll', '');
  AddFile(LegacyBin + '\' + ModuleFile, 'obs-root.dll', '');
  AddLegacyLicense(LegacyData + '\LICENSE', 'obs-root-LICENSE');
end;

procedure CheckOverride(Dir: string; Modern: Boolean);
var
  I: Integer;
  FileName: string;
begin
  if Dir = '' then Exit;
  Dir := NormalizeRoot(Dir);
  if Modern then Dir := Dir + '\' + ModuleName;
  FileName := Dir + '\' + ModuleFile;
  for I := 0 to GetArrayLength(Files) - 1 do
    if PathSame(FileName, Files[I].Path) then Exit;
  if FileExists(FileName) then
    RaiseException('A plugin copy exists in an OBS custom plugin path. Resolve the duplicate before installing: ' + FileName);
end;

procedure CheckOtherInstallations;
var
  I: Integer;
begin
  if Target.Mode <> StandardMode then Exit;
  for I := 0 to GetArrayLength(Installs) - 1 do begin
    if (Installs[I].Mode <> StandardMode) or (Installs[I].Major < 32) then Continue;
    if (Installs[I].Major < 33) <> (Target.Major < 33) then
      RaiseException('OBS ' + Installs[I].Version + ' at ' + Installs[I].Root +
        ' needs a different layout in the shared ProgramData directory. Choose a Portable installation to keep them independent.');
    if (Target.Major < 33) and not PathSame(Installs[I].Root, Target.Root) and
      FileExists(Installs[I].Root + '\obs-plugins\64bit\' + ModuleFile) then
      RaiseException('Another OBS installation has a separate copy of the plugin: ' + Installs[I].Root +
        '. Resolve that duplicate or select that installation first.');
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): string;
var
  I: Integer;
  Current: TObsInstall;
begin
  Result := '';
  try
    RequireClosedObs;
    if not ReadObsInstall(Target.Root, Target.Mode, Current) or
      (Current.Major <> Target.Major) or (Current.Mode <> Target.Mode) then
      RaiseException('The selected OBS Studio installation changed. Restart Setup and select it again.');
    CheckOtherInstallations;
    PlanFiles;
    if Target.Major >= 33 then begin
      CheckOverride(GetEnv('OBS_PLUGINS_PATH'), True);
      if GetEnv('OBS_LEGACY_PLUGINS_DATA_PATH') <> '' then
        CheckOverride(GetEnv('OBS_LEGACY_PLUGINS_PATH'), False);
    end
    else if GetEnv('OBS_PLUGINS_DATA_PATH') <> '' then
      CheckOverride(GetEnv('OBS_PLUGINS_PATH'), False);
    CheckPath(ExpandConstant('{app}'), True);
    CheckPath(BackupRoot, True);
    CheckPath(DataDir(''), True);
    for I := 0 to GetArrayLength(Files) - 1 do CheckPluginFile(Files[I].Path);
  except
    Result := GetExceptionMessage;
  end;
end;

procedure SavePreviousFiles;
var
  I, Count: Integer;
  Instructions: TArrayOfString;
  CopyPath: string;
begin
  SetArrayLength(Instructions, GetArrayLength(Files) + 4);
  Instructions[0] := 'Close OBS Studio.';
  Instructions[1] := 'Uninstall this GoXLR Fader Sync Plugin from Windows Installed apps.';
  Instructions[2] := 'Copy the files listed below from this backup to their original paths:';
  Instructions[3] := 'To restore a previous installer-managed installation, run its original Setup for the same OBS instance.';
  Count := 4;
  for I := 0 to GetArrayLength(Files) - 1 do begin
    CheckPluginFile(Files[I].Path);
    if not FileExists(Files[I].Path) then Continue;
    if Backup = '' then begin
      Backup := BackupRoot + '\' + GetDateTimeString('yyyymmdd-hhnnss', '-', ':') + '-' + IntToStr(Random(1000000000));
      CheckPath(Backup, True);
      if not ForceDirectories(BackupRoot) or not CreateDir(Backup) then
        RaiseException('Could not create the plugin backup: ' + Backup);
    end;
    Files[I].PreviousHash := GetSHA256OfFile(Files[I].Path);
    CopyPath := Backup + '\' + Files[I].BackupName;
    if not CopyFile(Files[I].Path, CopyPath, True) or
      (CompareText(GetSHA256OfFile(CopyPath), Files[I].PreviousHash) <> 0) then
      RaiseException('Could not back up ' + Files[I].Path);
    Instructions[Count] := Files[I].BackupName + ' -> ' + Files[I].Path;
    Count := Count + 1;
  end;
  if Backup <> '' then begin
    SetArrayLength(Instructions, Count);
    if not SaveStringsToUTF8File(Backup + '\Restore.txt', Instructions, False) then
      RaiseException('Could not save backup instructions to ' + Backup);
    Log('Previous files backed up to ' + Backup);
  end;
end;

procedure RequireOriginal(Index: Integer);
var
  Path: string;
begin
  Path := Files[Index].Path;
  CheckReplaceable(Path);
  if Files[Index].PreviousHash = '' then begin
    if not FileExists(Path) then Exit;
  end
  else if FileExists(Path) and (CompareText(GetSHA256OfFile(Path), Files[Index].PreviousHash) = 0) then Exit;
  RaiseException('A plugin file changed during setup: ' + Path);
end;

procedure EnsureDirectory(Path: string);
var
  I: Integer;
  Parent: string;
begin
  CheckPath(Path, True);
  if DirExists(Path) then Exit;
  Parent := ExtractFileDir(Path);
  if (Parent = '') or PathSame(Path, Parent) then RaiseException('Installation drive is unavailable: ' + Path);
  EnsureDirectory(Parent);
  if not CreateDir(Path) then RaiseException('Could not create the plugin directory: ' + Path);
  I := GetArrayLength(CreatedDirs);
  SetArrayLength(CreatedDirs, I + 1);
  CreatedDirs[I] := Path;
end;

procedure ReplaceFile(Source, Destination, ExpectedHash: string);
var
  Temporary: string;
begin
  CheckPath(Destination, False);
  EnsureDirectory(ExtractFileDir(Destination));
  Temporary := Destination + '.setup-' + IntToStr(Random(1000000000)) + '.tmp';
  CheckPath(Temporary, False);
  if FileExists(Temporary) then RaiseException('A setup file already exists: ' + Temporary);
  try
    if not CopyFile(Source, Temporary, True) or
      (CompareText(GetSHA256OfFile(Temporary), ExpectedHash) <> 0) then
      RaiseException('Could not stage or verify the plugin file: ' + Destination);
    if not MoveFileReplace(Temporary, Destination, 9) then
      RaiseException('Could not replace ' + Destination + ': ' + SysErrorMessage(DLLGetLastError));
  finally
    DeleteFile(Temporary);
  end;
end;

function InstalledAppsKey: string;
var
  AppId: AnsiString;
begin
  AppId := 'FaderSyncPlugin-' + InstallKey('');
  // Inno shortens ASCII AppIds over 57 characters when it builds the registry key.
  Result := AppId;
  if Length(AppId) > 57 then
    Result := Copy(Result, 1, 48) + '~' + Format('%.8x', [ComputeCrc32(0, AppId, Length(AppId))]);
  Result := UninstallKey + Result + '_is1';
end;

procedure ExportRegistration(Key, Destination: string);
var
  ExitCode: Integer;
begin
  if not Exec(ExpandConstant('{sys}\reg.exe'), 'export "HKLM\' + Key + '" "' + Destination + '" /y',
    '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
    RaiseException('Could not back up the existing installation registration.');
end;

procedure SaveUninstallFile(Path: string);
var
  CopyPath: string;
  Index: Integer;
begin
  CheckPath(Path, False);
  if not FileExists(Path) then Exit;
  CopyPath := RegistrationBackup + '\' + ExtractFileName(Path);
  if not CopyFile(Path, CopyPath, True) or (GetSHA256OfFile(CopyPath) <> GetSHA256OfFile(Path)) then
    RaiseException('Could not back up ' + Path);
  Index := GetArrayLength(PreviousUninstallFiles);
  SetArrayLength(PreviousUninstallFiles, Index + 1);
  PreviousUninstallFiles[Index] := Path;
end;

procedure SaveRegistration;
var
  Path, Name, Key: string;
begin
  RegistrationBackup := ExpandConstant('{tmp}\previous-installation');
  if not CreateDir(RegistrationBackup) then RaiseException('Could not create the installation registration backup.');
  Key := InstallRegistryKey('');
  if RegKeyExists(HKLM64, Key) then ExportRegistration(Key, RegistrationBackup + '\target.reg');
  Key := InstalledAppsKey;
  if not RegKeyExists(HKLM64, Key) then Exit;
  ExportRegistration(Key, RegistrationBackup + '\uninstall.reg');
  if not RegQueryStringValue(HKLM64, Key, 'UninstallString', Path) then Exit;
  Path := RemoveQuotes(Path);
  Name := Lowercase(ExtractFileName(Path));
  if not PathSame(ExtractFileDir(Path), ExpandConstant('{app}')) or (Length(Name) <> 12) or
    (Copy(Name, 1, 5) <> 'unins') or (Copy(Name, 9, 4) <> '.exe') or
    (StrToIntDef(Copy(Name, 6, 3), -1) < 0) then
    RaiseException('The existing uninstaller does not belong to this installation.');
  SaveUninstallFile(Path);
  SaveUninstallFile(ChangeFileExt(Path, '.dat'));
  SaveUninstallFile(ChangeFileExt(Path, '.msg'));
end;

procedure RestoreRegistration(Key, Name: string);
var
  Saved, Current: string;
  ExitCode: Integer;
begin
  Saved := RegistrationBackup + '\' + Name;
  if RegKeyExists(HKLM64, Key) then begin
    if FileExists(Saved) then begin
      Current := RegistrationBackup + '\current.reg';
      ExportRegistration(Key, Current);
      if GetSHA256OfFile(Current) = GetSHA256OfFile(Saved) then Exit;
    end;
    if not RegDeleteKeyIncludingSubkeys(HKLM64, Key) then
      RaiseException('Could not clear an incomplete installation registration.');
  end;
  if FileExists(Saved) and
    (not Exec(ExpandConstant('{sys}\reg.exe'), 'import "' + Saved + '"', '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or
      (ExitCode <> 0)) then
    RaiseException('Could not restore the previous installation registration.');
end;

procedure InstallPayload;
var
  I: Integer;
  Key, Path: string;
begin
  { Inno does not restore overwritten files and allows skipping failed copies.
    Commit the payload as one unit and let Inno own its install/uninstall records. }
  SavePreviousFiles;
  ExtractTemporaryFile(ModuleFile);
  ExtractTemporaryFile('LICENSE');
  RequireClosedObs;
  SaveRegistration;
  Key := InstallRegistryKey('');
  Replacing := True;

  for I := 0 to GetArrayLength(Files) - 1 do begin
    if (Files[I].PayloadHash = '') and (Files[I].PreviousHash = '') then Continue;
    RequireOriginal(I);
    Path := Files[I].Path;
    if Files[I].PayloadHash <> '' then
      ReplaceFile(AddBackslash(ExpandConstant('{tmp}')) + ExtractFileName(Path), Path, Files[I].PayloadHash)
    else if not DeleteFile(Path) then
      RaiseException('Could not remove the old plugin file: ' + Path);
    Files[I].Changed := True;
    if Files[I].PayloadHash <> '' then Log('Installed plugin file ' + Path)
    else Log('Removed old plugin file ' + Path);
  end;

  if not RegWriteStringValue(HKLM64, Key, 'Root', Target.Root) or
    not RegWriteDWordValue(HKLM64, Key, 'Mode', Target.Mode) or
    not RegWriteDWordValue(HKLM64, Key, 'Major', Target.Major) then
    RaiseException('Could not register the selected OBS installation.');
end;

procedure CurStepChanged(Step: TSetupStep);
begin
  if Step = ssInstall then InstallPayload;
  if Step = ssPostInstall then Installed := True;
end;

procedure CurPageChanged(PageID: Integer);
begin
  if (PageID = wpFinished) and (Backup <> '') then begin
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
      'Previous files and restore instructions:' + #13#10 + Backup;
    WizardForm.FinishedLabel.WordWrap := True;
  end;
end;

procedure RestoreFile(Index: Integer);
var
  Path, CopyPath: string;
begin
  Path := Files[Index].Path;
  CheckPath(Path, False);
  if Files[Index].PreviousHash = '' then begin
    if FileExists(Path) and not DeleteFile(Path) then RaiseException('Could not remove ' + Path);
    Exit;
  end;
  if FileExists(Path) and (CompareText(GetSHA256OfFile(Path), Files[Index].PreviousHash) = 0) then Exit;

  CopyPath := Backup + '\' + Files[Index].BackupName;
  CheckPath(CopyPath, False);
  ReplaceFile(CopyPath, Path, Files[Index].PreviousHash);
end;

procedure DeinitializeSetup;
var
  I: Integer;
  Errors, Path, CopyPath, Hash: string;
begin
  if not Replacing or Installed then Exit;
  Errors := '';
  for I := GetArrayLength(Files) - 1 downto 0 do
    if Files[I].Changed then begin
      try
        RestoreFile(I);
      except
        Errors := Errors + #13#10 + GetExceptionMessage;
      end;
    end;
  for I := GetArrayLength(CreatedDirs) - 1 downto 0 do RemoveDir(CreatedDirs[I]);

  for I := 0 to GetArrayLength(PreviousUninstallFiles) - 1 do begin
    try
      Path := PreviousUninstallFiles[I];
      CopyPath := RegistrationBackup + '\' + ExtractFileName(Path);
      Hash := GetSHA256OfFile(CopyPath);
      CheckPath(Path, False);
      if not FileExists(Path) or (GetSHA256OfFile(Path) <> Hash) then ReplaceFile(CopyPath, Path, Hash);
    except
      Errors := Errors + #13#10 + GetExceptionMessage;
    end;
  end;
  try
    RestoreRegistration(InstallRegistryKey(''), 'target.reg');
  except
    Errors := Errors + #13#10 + GetExceptionMessage;
  end;
  try
    RestoreRegistration(InstalledAppsKey, 'uninstall.reg');
  except
    Errors := Errors + #13#10 + GetExceptionMessage;
  end;
  if Errors = '' then Log('Previous plugin files restored.')
  else begin
    Errors := 'Setup could not finish restoring the previous installation.' + Errors + #13#10 + 'Backup: ' + Backup;
    Log(Errors);
    SuppressibleMsgBox(Errors, mbError, MB_OK, IDOK);
  end;
end;

function InitializeUninstall: Boolean;
var
  Key: string;
  Mode, Major: Cardinal;
begin
  Result := False;
  try
    RequireClosedObs;
    UninstallGate := CreateMutex(0, False, 'Global\FaderSyncPluginSetup');
    if UninstallGate = 0 then RaiseException('Could not lock the plugin installation.');
    if DLLGetLastError = 183 then RaiseException('Close the other plugin setup or uninstaller before continuing.');
    CheckPath(ExpandConstant('{app}'), True);
    Key := InstallsKey + '\' + ExtractFileName(ExpandConstant('{app}'));
    if not RegQueryStringValue(HKLM64, Key, 'Root', Target.Root) or
      not RegQueryDWordValue(HKLM64, Key, 'Mode', Mode) or
      not RegQueryDWordValue(HKLM64, Key, 'Major', Major) then
      RaiseException('The plugin installation record is missing.');
    Target.Mode := Mode;
    Target.Major := Major;
    CheckPluginFile(BinaryDir('') + '\' + ModuleFile);
    CheckPluginFile(LicenseDir('') + '\LICENSE');
    Result := True;
  except
    if UninstallGate <> 0 then CloseHandle(UninstallGate);
    UninstallGate := 0;
    SuppressibleMsgBox(GetExceptionMessage, mbError, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(Step: TUninstallStep);
var
  Binary, License: string;
begin
  if Step <> usUninstall then Exit;
  RequireClosedObs;
  Binary := BinaryDir('') + '\' + ModuleFile;
  License := LicenseDir('') + '\LICENSE';
  CheckPluginFile(Binary);
  CheckPluginFile(License);
  // Abort before Inno discards the uninstall log if a file cannot be removed.
  if (FileExists(Binary) and not DeleteFile(Binary)) or (FileExists(License) and not DeleteFile(License)) then
    RaiseException('Close OBS Studio, check access to the plugin files, and try uninstalling again.');
end;

procedure DeinitializeUninstall;
begin
  if UninstallGate <> 0 then CloseHandle(UninstallGate);
end;
