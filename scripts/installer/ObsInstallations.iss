type
  TObsInstall = record
    Root: string;
    Version: string;
    Major: Integer;
    Mode: Integer;
  end;

var
  Installs: array of TObsInstall;
  Target: TObsInstall;
  TargetPage: TInputDirWizardPage;
  Instances: TNewComboBox;
  ModeLabel, StatusLabel: TNewStaticText;
  Modes: TNewComboBox;
  ObsArgument: string;
  ModeArgument: Integer;
  Refreshing: Boolean;

function NormalizeRoot(Path: string): string;
begin
  StringChangeEx(Path, '/', '\', True);
  Result := RemoveBackslashUnlessRoot(ExpandFileName(Trim(Path)));
end;

function HasPortableMarker(Root: string): Boolean;
begin
  Result := FileExists(Root + '\portable_mode') or FileExists(Root + '\portable_mode.txt') or
    FileExists(Root + '\obs_portable_mode') or FileExists(Root + '\obs_portable_mode.txt');
end;

function ReadX64Image(Path: string; var Image: AnsiString): Boolean;
var
  PE: Integer;
begin
  Result := False;
  if not LoadStringFromFile(Path, Image) or (Length(Image) < 64) then Exit;
  if (Image[1] <> 'M') or (Image[2] <> 'Z') or (Ord(Image[63]) <> 0) or
    (Ord(Image[64]) <> 0) then Exit;
  PE := 1 + Ord(Image[61]) + 256 * Ord(Image[62]);
  if (PE + 5 > Length(Image)) or (Copy(Image, PE, 4) <> 'PE' + #0 + #0) then Exit;
  Result := (Ord(Image[PE + 4]) = $64) and (Ord(Image[PE + 5]) = $86);
end;

function ReadObsInstall(Path: string; Mode: Integer; var Install: TObsInstall): Boolean;
var
  Major, Minor, Revision, Build: Word;
  Image: AnsiString;
begin
  Result := False;
  Install.Root := '';
  if Trim(Path) = '' then Exit;
  Path := NormalizeRoot(Path);
  if (Length(Path) < 3) or (Copy(Path, 2, 2) <> ':\') then Exit;
  if not GetVersionComponents(Path + ObsExe, Major, Minor, Revision, Build) or
    not ReadX64Image(Path + ObsExe, Image) then Exit;

  if HasPortableMarker(Path) then Mode := PortableMode;
  Install.Root := Path;
  Install.Major := Major;
  Install.Version := Format('%d.%d.%d', [Major, Minor, Revision]);
  Install.Mode := Mode;
  Result := True;
end;

function FindInstall(Root: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to GetArrayLength(Installs) - 1 do
    if PathSame(Installs[I].Root, Root) then begin
      Result := I;
      Exit;
    end;
end;

procedure AddInstall(Path: string; Mode: Integer);
var
  Install: TObsInstall;
  I: Integer;
begin
  if not ReadObsInstall(Path, Mode, Install) then Exit;
  I := FindInstall(Install.Root);
  if I >= 0 then Exit;
  I := GetArrayLength(Installs);
  SetArrayLength(Installs, I + 1);
  Installs[I] := Install;
  Log('Detected OBS ' + Install.Version + ' at ' + Install.Root);
end;

procedure AddRegistryPath(RootKey: Integer; Key, Value: string);
var
  Root: string;
begin
  if RegQueryStringValue(RootKey, Key, Value, Root) then AddInstall(Root, StandardMode);
end;

function VdfValue(Line, Key: string): string;
var
  CloseQuote: Integer;
begin
  Result := '';
  Line := Trim(Line);
  if CompareText(Copy(Line, 1, Length(Key) + 2), '"' + Key + '"') <> 0 then Exit;
  Line := Trim(Copy(Line, Length(Key) + 3, Length(Line)));
  if Copy(Line, 1, 1) <> '"' then Exit;
  Delete(Line, 1, 1);
  CloseQuote := Pos('"', Line);
  if CloseQuote <= 1 then Exit;
  Result := Copy(Line, 1, CloseQuote - 1);
  StringChangeEx(Result, '\\', '\', True);
end;

procedure AddSteamLibrary(Root: string);
var
  Lines: TArrayOfString;
  I: Integer;
  Folder: string;
begin
  Root := NormalizeRoot(Root) + '\steamapps';
  if not LoadStringsFromFile(Root + '\appmanifest_1905180.acf', Lines) then Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Folder := VdfValue(Lines[I], 'installdir');
    if (Folder <> '') and (ExtractFileName(Folder) = Folder) and
      (Folder <> '.') and (Folder <> '..') then begin
      AddInstall(Root + '\common\' + Folder, StandardMode);
      Exit;
    end;
  end;
end;

procedure AddSteam(Root: string);
var
  Lines: TArrayOfString;
  I: Integer;
  LibraryPath: string;
begin
  if Root = '' then Exit;
  Root := NormalizeRoot(Root);
  AddSteamLibrary(Root);
  if not LoadStringsFromFile(Root + '\steamapps\libraryfolders.vdf', Lines) then Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    LibraryPath := VdfValue(Lines[I], 'path');
    if LibraryPath <> '' then AddSteamLibrary(LibraryPath);
  end;
end;

procedure DetectInstallations;
var
  Keys: TArrayOfString;
  I: Integer;
  Mode: Cardinal;
  Root, Key: string;
begin
  if RegGetSubkeyNames(HKLM64, InstallsKey, Keys) then
    for I := 0 to GetArrayLength(Keys) - 1 do begin
      Key := InstallsKey + '\' + Keys[I];
      if RegQueryStringValue(HKLM64, Key, 'Root', Root) and
        RegQueryDWordValue(HKLM64, Key, 'Mode', Mode) then AddInstall(Root, Mode);
    end;

  AddRegistryPath(HKLM64, 'SOFTWARE\OBS Studio', '');
  AddRegistryPath(HKLM32, 'SOFTWARE\OBS Studio', '');
  AddRegistryPath(HKCU, 'SOFTWARE\OBS Studio', '');
  AddRegistryPath(HKLM64, UninstallKey + 'OBS Studio', 'InstallLocation');
  AddRegistryPath(HKLM32, UninstallKey + 'OBS Studio', 'InstallLocation');
  AddRegistryPath(HKLM32, UninstallKey + 'Steam App 1905180', 'InstallLocation');
  AddRegistryPath(HKLM64, UninstallKey + 'Steam App 1905180', 'InstallLocation');
  if RegQueryStringValue(HKCU, 'SOFTWARE\Valve\Steam', 'SteamPath', Root) then AddSteam(Root);
  if RegQueryStringValue(HKLM32, 'SOFTWARE\Valve\Steam', 'InstallPath', Root) then AddSteam(Root);
  AddInstall(ExpandConstant('{pf64}\obs-studio'), StandardMode);
  AddInstall(ExpandConstant('{localappdata}\Programs\obs-studio'), StandardMode);
end;

function ModeName(Mode: Integer): string;
begin
  case Mode of
    StandardMode: Result := 'Standard';
    PortableMode: Result := 'Portable';
    else Result := '';
  end;
end;

function SharedPluginRoot: string;
begin
  Result := ExpandConstant('{commonappdata}\obs-studio\plugins\') + ModuleName;
end;

function ModuleDir(const Install: TObsInstall): string;
begin
  if Install.Mode = PortableMode then begin
    if Install.Major < 33 then Result := Install.Root + '\obs-plugins\64bit'
    else Result := Install.Root + '\plugins\' + ModuleName;
  end
  else begin
    Result := SharedPluginRoot;
    if Install.Major < 33 then Result := Result + '\bin\64bit';
  end;
end;

function TargetFromPage: TObsInstall;
var
  I, Mode: Integer;
  Root: string;
begin
  Root := TargetPage.Values[0];
  I := FindInstall(NormalizeRoot(Root));
  Mode := UnknownMode;
  if I >= 0 then Mode := Installs[I].Mode;
  if not ReadObsInstall(Root, Mode, Result) then Exit;
  if ModeArgument <> UnknownMode then Result.Mode := ModeArgument;
  if (Result.Mode = UnknownMode) and (Modes.ItemIndex >= 0) then Result.Mode := Modes.ItemIndex + 1;
end;

procedure UpdateTarget(Sender: TObject);
var
  Preview: TObsInstall;
  Index: Integer;
begin
  if Refreshing then Exit;
  Refreshing := True;
  try
    if Sender = Instances then begin
      Index := Instances.ItemIndex;
      if (Index >= 0) and (Index < GetArrayLength(Installs)) then
        TargetPage.Values[0] := Installs[Index].Root
      else TargetPage.Values[0] := '';
    end;
    if Sender <> Modes then Modes.ItemIndex := -1;
    Preview := TargetFromPage;
    Modes.Visible := (Preview.Root <> '') and
      (Preview.Mode = UnknownMode) or ((Preview.Root <> '') and (Sender = Modes));
    ModeLabel.Visible := Modes.Visible;
    if Preview.Root = '' then StatusLabel.Caption := 'Select the folder containing OBS Studio.'
    else if Preview.Major < 32 then StatusLabel.Caption := 'This version requires OBS Studio 32 or newer.'
    else if Preview.Mode = UnknownMode then StatusLabel.Caption := 'Select the mode you use to start OBS Studio.'
    else StatusLabel.Caption := 'OBS ' + Preview.Version + ' (' + ModeName(Preview.Mode) + ')' + #13#10 +
      ModuleDir(Preview) + '\' + ModuleFile;
  finally
    Refreshing := False;
  end;
end;

procedure InitializeWizard;
var
  I, Top: Integer;
  Multi: Boolean;
  Arg: string;
begin
  DetectInstallations;
  ObsArgument := ExpandConstant('{param:OBS|}');
  if WizardSilent and (ObsArgument = '') and (GetArrayLength(Installs) <> 1) then begin
    Log('Specify the OBS Studio folder with /OBS="path".');
    SuppressibleMsgBox('Specify the OBS Studio folder with /OBS="path".', mbError, MB_OK, IDOK);
    Abort;
  end;
  Arg := ExpandConstant('{param:MODE|}');
  if CompareText(Arg, 'standard') = 0 then ModeArgument := StandardMode
  else if CompareText(Arg, 'portable') = 0 then ModeArgument := PortableMode
  else if Arg <> '' then RaiseException('Use /MODE=standard or /MODE=portable.');

  Multi := GetArrayLength(Installs) > 1;
  TargetPage := CreateInputDirPage(wpWelcome, 'OBS Studio', 'Choose the OBS Studio installation',
    'Setup installs the plugin for the OBS Studio folder shown below.', False, '');
  TargetPage.Add('OBS Studio folder:');
  Instances := TNewComboBox.Create(WizardForm);
  Instances.Parent := TargetPage.Surface;
  Instances.Style := csDropDownList;
  Instances.Width := TargetPage.SurfaceWidth;
  Instances.Top := TargetPage.Edits[0].Top;
  Instances.Visible := Multi;
  for I := 0 to GetArrayLength(Installs) - 1 do
    Instances.Items.Add('OBS ' + Installs[I].Version + ' (' + ModeName(Installs[I].Mode) + ') - ' + Installs[I].Root);
  Instances.Items.Add('Choose another folder');
  if Multi then begin
    TargetPage.Edits[0].Top := Instances.Top + Instances.Height + ScaleY(8);
    TargetPage.Buttons[0].Top := TargetPage.Edits[0].Top;
  end;
  Top := TargetPage.Edits[0].Top + TargetPage.Edits[0].Height + ScaleY(12);
  ModeLabel := TNewStaticText.Create(WizardForm);
  ModeLabel.Parent := TargetPage.Surface;
  ModeLabel.Top := Top;
  ModeLabel.Caption := 'OBS Studio mode:';
  Modes := TNewComboBox.Create(WizardForm);
  Modes.Parent := TargetPage.Surface;
  Modes.Style := csDropDownList;
  Modes.Items.Add('Standard');
  Modes.Items.Add('Portable');
  Modes.Top := Top + ScaleY(20);
  Modes.Width := ScaleX(140);
  StatusLabel := TNewStaticText.Create(WizardForm);
  StatusLabel.Parent := TargetPage.Surface;
  StatusLabel.AutoSize := False;
  StatusLabel.WordWrap := True;
  StatusLabel.Top := Modes.Top + Modes.Height + ScaleY(8);
  StatusLabel.Width := TargetPage.SurfaceWidth;
  StatusLabel.Height := ScaleY(60);

  if ObsArgument <> '' then TargetPage.Values[0] := ObsArgument
  else if GetArrayLength(Installs) = 1 then TargetPage.Values[0] := Installs[0].Root;
  TargetPage.Edits[0].OnChange := @UpdateTarget;
  Modes.OnChange := @UpdateTarget;
  Instances.OnChange := @UpdateTarget;
  UpdateTarget(nil);
end;

function InstallKey(Param: string): string;
begin
  if Target.Mode = PortableMode then
    Result := 'portable-' + GetSHA256OfUnicodeString(Lowercase(Target.Root))
  else Result := 'standard';
end;

function InstallRegistryKey(Param: string): string;
begin
  Result := InstallsKey + '\' + InstallKey('');
end;

function DisplayName(Param: string): string;
begin
  Result := '{#PluginName}';
  if Target.Mode = PortableMode then Result := Result + ' (Portable: ' + ExtractFileName(Target.Root) + ')';
end;

function SelectedRoot(Param: string): string;
begin
  Result := Target.Root;
end;

function SelectedMode(Param: string): string;
begin
  Result := IntToStr(Target.Mode);
end;

function SelectedMajor(Param: string): string;
begin
  Result := IntToStr(Target.Major);
end;

function NextButtonClick(PageID: Integer): Boolean;
var
  Error: string;
begin
  Result := True;
  if PageID <> TargetPage.ID then Exit;
  Target := TargetFromPage;
  Error := '';
  if Target.Root = '' then Error := 'Select an x64 OBS Studio folder containing bin\64bit\obs64.exe.'
  else if Target.Major < 32 then Error := 'This version requires OBS Studio 32 or newer.'
  else if Target.Mode = UnknownMode then Error := 'Choose Standard or Portable. For silent setup use /MODE.';
  if Error <> '' then begin
    SuppressibleMsgBox(Error, mbError, MB_OK, IDOK);
    Result := False;
  end
  else WizardForm.DirEdit.Text :=
    ExpandConstant('{commonappdata}\obs-studio\FaderSyncPlugin-installs\') + InstallKey('');
end;

function UpdateReadyMemo(Space, NewLine, UserInfo, DirInfo, TypeInfo, ComponentsInfo, GroupInfo, TasksInfo: string): string;
begin
  Result := 'OBS Studio ' + Target.Version + ' (' + ModeName(Target.Mode) + ')' + NewLine +
    Space + Target.Root + NewLine + NewLine + 'Plugin location:' + NewLine +
    Space + ModuleDir(Target) + '\' + ModuleFile;
end;
