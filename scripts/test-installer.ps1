#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$PluginBinary,
    [switch]$IncludeStandard,
    [string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$fixture = New-Item -ItemType Directory (Join-Path ([IO.Path]::GetTempPath()) ('FaderSync-test-' + [guid]::NewGuid()))
$repo = 'https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/releases/download'
$obsReleases = 'https://github.com/obsproject/obs-studio/releases/download'
$binaryName = 'FaderSyncPlugin.dll'
$expectedHash = (Get-FileHash $PluginBinary).Hash
$packagedLicense = Join-Path (Split-Path -Parent $PluginBinary) 'LICENSE'
$testRoots = [Collections.Generic.List[string]]::new()

function Get-TestDownload($Url, $Hash) {
    $path = Join-Path $fixture.FullName ($Hash.Substring(0, 8) + '-' + [IO.Path]::GetFileName($Url))
    Invoke-WebRequest $Url -OutFile $path
    if ((Get-FileHash $path).Hash -ne $Hash) { throw "Test fixture checksum mismatch: $Url" }
    return $path
}

function Invoke-Setup($Program, $Case, $Root = '', $Mode = '') {
    $log = Join-Path $fixture.FullName "$Case.log"
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$log`"")
    if ($Root) { $arguments += "/OBS=`"$Root`"" }
    if ($Mode) { $arguments += "/MODE=$Mode" }
    $process = Start-Process $Program -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0 -and (Test-Path -LiteralPath $log)) {
        Get-Content -LiteralPath $log | Write-Host
    }
    return $process.ExitCode
}

function Assert-Hash($Path, $Hash) {
    if ((Get-FileHash -LiteralPath $Path).Hash -ne $Hash) { throw "Unexpected contents: $Path" }
}

function Assert-Hashes($Hashes) {
    foreach ($file in $Hashes.GetEnumerator()) { Assert-Hash $file.Key $file.Value }
}

function Get-InstallId($Root) {
    if (-not $Root) { return 'standard' }
    $bytes = [Text.Encoding]::Unicode.GetBytes($Root.ToLowerInvariant())
    'portable-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-InstallDirectory($Root) {
    Join-Path $env:ProgramData ('obs-studio\FaderSyncPlugin-installs\' + (Get-InstallId $Root))
}

function Get-InstallRecord($Root) {
    $expected = Get-InstallDirectory $Root
    Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' |
        Get-ItemProperty | Where-Object {
            $_.InstallLocation -and $_.InstallLocation.TrimEnd('\') -eq $expected -and
            $_.PSChildName -like 'FaderSyncPlugin-*_is1'
        }
}

function Get-Uninstaller($Root) {
    $record = @(Get-InstallRecord $Root)
    if ($record.Count -ne 1) { throw "Expected one registered installation for $Root" }
    $uninstaller = ([string]$record[0].UninstallString).Trim('"')
    if ((Split-Path -Parent $uninstaller) -ne (Get-InstallDirectory $Root) -or
        -not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
        throw "Invalid uninstaller location: $uninstaller"
    }
    return $uninstaller
}

function Get-SetupProcessIds([uint32]$ProcessId) {
    $ids = [Collections.Generic.HashSet[uint32]]::new()
    $null = $ids.Add($ProcessId)
    $processes = Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId
    do {
        $count = $ids.Count
        foreach ($candidate in $processes) {
            if ($ids.Contains($candidate.ParentProcessId)) { $null = $ids.Add($candidate.ProcessId) }
        }
    } while ($count -ne $ids.Count)
    [uint32[]]@($ids)
}

function Test-InstallerIcon {
    Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class InstallerIconTest
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll")]
    private static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", EntryPoint = "FindResourceW", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr FindResource(IntPtr module, string name, IntPtr type);
    [DllImport("kernel32.dll", EntryPoint = "FindResourceW", ExactSpelling = true)]
    private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll")]
    private static extern int SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("user32.dll")]
    private static extern int LookupIconIdFromDirectoryEx(IntPtr group, bool icon, int width, int height, uint flags);
    [DllImport("user32.dll")]
    private static extern IntPtr CreateIconFromResourceEx(byte[] data, int bytes, bool icon, uint version,
        int width, int height, uint flags);
    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);

    public static void Verify(string executable, string icon)
    {
        byte[] ico = File.ReadAllBytes(icon);
        int count = BitConverter.ToUInt16(ico, 4);
        IntPtr module = LoadLibraryEx(executable, IntPtr.Zero, 2); // LOAD_LIBRARY_AS_DATAFILE
        if (module == IntPtr.Zero) throw new InvalidOperationException("Cannot read setup icon resources.");
        try
        {
            IntPtr group = FindResource(module, "MAINICON", new IntPtr(14)); // RT_GROUP_ICON
            IntPtr directory = LockResource(LoadResource(module, group));
            if (directory == IntPtr.Zero || Marshal.ReadInt16(directory, 4) != count)
                throw new InvalidOperationException("Setup icon frame count does not match the ICO.");

            for (int index = 0; index < count; index++)
            {
                int entry = 6 + 16 * index;
                int size = ico[entry] == 0 ? 256 : ico[entry];
                int length = BitConverter.ToInt32(ico, entry + 8);
                int offset = BitConverter.ToInt32(ico, entry + 12);
                int id = LookupIconIdFromDirectoryEx(directory, true, size, size, 0);
                IntPtr frame = FindResource(module, new IntPtr(id), new IntPtr(3)); // RT_ICON
                if (frame == IntPtr.Zero || SizeofResource(module, frame) != length)
                    throw new InvalidOperationException($"Windows selected the wrong setup frame for {size} px.");
                IntPtr data = LockResource(LoadResource(module, frame));
                if (data == IntPtr.Zero) throw new InvalidOperationException($"Cannot read setup frame {size} px.");
                byte[] image = new byte[length];
                Marshal.Copy(data, image, 0, length);
                if (!ico.AsSpan(offset, length).SequenceEqual(image))
                    throw new InvalidOperationException($"Setup changed the {size} px icon frame.");
                IntPtr handle = CreateIconFromResourceEx(image, length, true, 0x00030000, size, size, 0);
                if (handle == IntPtr.Zero) throw new InvalidOperationException($"Cannot decode setup frame {size} px.");
                DestroyIcon(handle);
                Console.WriteLine($"PASS Windows selected and decoded the exact {size} px setup icon frame.");
            }
        }
        finally { FreeLibrary(module); }
    }
}
'@
    [InstallerIconTest]::Verify((Resolve-Path -LiteralPath $Installer).Path,
        (Join-Path $PSScriptRoot 'installer/FaderSyncPlugin.ico'))
}

function Wait-InstallerWindow($Description, [scriptblock]$Find) {
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $window = & $Find
        if ($window -ne [IntPtr]::Zero) { return $window }
        Start-Sleep -Milliseconds 150
    }
    throw "Installer window not found: $Description"
}

function Test-Cancel($Root) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class InstallerTestWindow
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr previous, string className, string caption);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    public static IntPtr Find(string className, string caption, uint[] ids)
    {
        var window = IntPtr.Zero;
        if (string.IsNullOrEmpty(className)) className = null;
        if (string.IsNullOrEmpty(caption)) caption = null;
        while ((window = FindWindowEx(IntPtr.Zero, window, className, caption)) != IntPtr.Zero)
        {
            GetWindowThreadProcessId(window, out var id);
            if (Array.IndexOf(ids, id) >= 0) return window;
        }
        return IntPtr.Zero;
    }
    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr dialog, int control);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr parameter, IntPtr control);
}
'@
    $log = Join-Path $fixture.FullName 'cancel32.log'
    $process = Start-Process $Installer -ArgumentList "/LOG=`"$log`"", "/OBS=`"$Root`"" -PassThru
    try {
        $window = Wait-InstallerWindow 'the Inno Setup wizard' {
            [InstallerTestWindow]::Find('TWizardForm', $null, (Get-SetupProcessIds $process.Id))
        }
        if (-not [InstallerTestWindow]::PostMessage($window, 0x0010, 0, 0)) { throw 'Cannot close test wizard.' }
        $confirm = Wait-InstallerWindow 'Exit Setup' {
            $ids = Get-SetupProcessIds $process.Id
            $window = [InstallerTestWindow]::Find($null, 'Exit Setup', $ids)
            if ($window -eq [IntPtr]::Zero) { $window = [InstallerTestWindow]::Find('#32770', 'Setup', $ids) }
            $window
        }
        $answer = 6
        $button = [InstallerTestWindow]::GetDlgItem($confirm, $answer)
        if ($button -eq [IntPtr]::Zero) {
            $answer = 1
            $button = [InstallerTestWindow]::GetDlgItem($confirm, $answer)
        }
        if ($button -eq [IntPtr]::Zero -or
            -not [InstallerTestWindow]::PostMessage($confirm, 0x0111, $answer, $button) -or
            -not $process.WaitForExit(20000) -or $process.ExitCode -ne 2) {
            throw 'Cancellation did not return the Inno Setup exit code 2.'
        }
        if ((Get-Content $log -Raw) -match 'Installed plugin file') { throw 'Cancel reached the file write stage.' }
    }
    catch {
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Write-Host }
        Write-Host "Runner desktop interactive: $([Environment]::UserInteractive)."
        throw
    }
    finally { if (-not $process.HasExited) { $process.Kill($true) } }
}

function Get-ObsStartupResult($Log, $Version) {
    if ($Log -match '\[FaderSyncPlugin\].*Plugin load failed:' -or
        $Log -match '(?:Failed to (?:initialize module|load module file)|Skipping module)[^\r\n]*\bFaderSyncPlugin\b') {
        return 'PluginError'
    }
    if ($Log -match '==== Startup complete') {
        $versionPattern = [regex]::Escape($Version)
        if ($Log -match "(?m)Loading FaderSyncPlugin v$versionPattern\r?$" -and
            $Log -match '(?m)^\S+:[ \t]+FaderSyncPlugin\.dll[ \t]*\r?$') {
            return 'Loaded'
        }
        return 'PluginMissing'
    }
    if ($Log -match 'Failed to initialize video[:.]') { return 'GraphicsUnavailable' }
    return 'Pending'
}

function Test-ObsStartup($Root) {
    $bin = Join-Path $Root 'bin/64bit'
    $process = Start-Process (Join-Path $bin 'obs64.exe') -WorkingDirectory $bin `
        -ArgumentList '--portable', '--disable-shutdown-check', '--multi' -PassThru
    try {
        $logs = Join-Path $Root 'config/obs-studio/logs'
        $expected = (Get-Item $PluginBinary).VersionInfo.ProductVersion.TrimEnd()
        $result = 'Pending'
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $latest = Get-ChildItem $logs -Filter '*.txt' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                $log = Get-Content $latest.FullName -Raw
                $result = Get-ObsStartupResult $log $expected
                if ($result -eq 'Loaded' -and -not $process.HasExited) {
                    $log -split '\r?\n' | Where-Object {
                        $_ -match 'Loading FaderSyncPlugin|[ \t]FaderSyncPlugin\.dll\s*$|==== Startup complete'
                    } | Write-Host
                    $obsVersion = (Get-Item (Join-Path $bin 'obs64.exe')).VersionInfo.ProductVersion
                    Write-Host "PASS full OBS $obsVersion started on Windows and loaded the release DLL."
                    return
                }
            }
            if ($result -ne 'Pending' -or $process.HasExited) { break }
            Start-Sleep -Seconds 1
        }
        if ($latest) { Get-Content $latest.FullName -Tail 50 | Write-Host }
        switch ($result) {
            'PluginError' { throw 'OBS logged a FaderSyncPlugin load error.' }
            'PluginMissing' { throw "OBS started without the expected FaderSyncPlugin v$expected." }
            'GraphicsUnavailable' { throw 'OBS video initialization failed before the plugin check could run.' }
            default { throw 'OBS exited or timed out without a successful startup check.' }
        }
    }
    finally {
        if (-not $process.HasExited -and (-not $process.CloseMainWindow() -or -not $process.WaitForExit(8000))) {
            $process.Kill($true)
            $process.WaitForExit()
        }
    }
}

function New-InterruptedSetup {
    $source = Join-Path $fixture.FullName 'diagnostic/scripts/installer'
    $null = New-Item -ItemType Directory -Force $source
    Copy-Item (Join-Path $PSScriptRoot 'installer/*') $source
    Copy-Item (Join-Path $PSScriptRoot '../LICENSE') (Join-Path $source '../../LICENSE')
    $files = Join-Path $source 'PluginFiles.iss'
    $pascal = Get-Content $files -Raw
    $hook = @'
procedure Checkpoint(Name: string);
begin
  if (ExpandConstant('{param:CHECKPOINT|}') = Name) or
    ((Name = 'uninstall') and FileExists(ExpandConstant('{app}\hold-uninstall'))) then begin
    Log('TEST CHECKPOINT: ' + Name);
    Sleep(30000);
  end;
end;

function NeedRestart: Boolean;
begin
  Checkpoint('before-uninstall-registration');
  Result := False;
end;

'@
    $pascal = $pascal.Replace('procedure InstallPayload;', $hook + 'procedure InstallPayload;')
    $pascal = $pascal.Replace('Files[I].Changed := True;', "Files[I].Changed := True;`n    if I = 0 then Checkpoint('first-file');")
    $pascal = $pascal.Replace('if Step <> usUninstall then Exit;', "if Step <> usUninstall then Exit;`n  Checkpoint('uninstall');")
    Set-Content $files $pascal -Encoding utf8
    $output = Join-Path $fixture.FullName 'diagnostic'
    $version = (Get-Item $PluginBinary).VersionInfo.ProductVersion
    $fileVersion = (Get-Item $PluginBinary).VersionInfo.FileVersion
    $licensePage = (Resolve-Path (Join-Path (Split-Path -Parent $PluginBinary) '../setup-license.txt')).Path
    & $env:ISCC /Qp "/O$output" "/DVersion=$version" "/DFileVersion=$fileVersion" `
        "/DPluginBinary=$((Resolve-Path $PluginBinary).Path)" "/DLicensePath=$((Resolve-Path $packagedLicense).Path)" `
        "/DLicensePagePath=$licensePage" (Join-Path $source 'FaderSyncPlugin.iss') | Write-Host
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the diagnostic Setup.' }
    Join-Path $output 'FaderSyncPlugin-win-x64-installer.exe'
}

function Wait-Checkpoint($Process, $Log, $Checkpoint) {
    for ($attempt = 0; $attempt -lt 125; $attempt++) {
        if ($Process.HasExited) { break }
        if ((Test-Path -LiteralPath $Log) -and (Get-Content $Log -Raw) -match "TEST CHECKPOINT: $Checkpoint") {
            return
        }
        Start-Sleep -Milliseconds 120
    }
    Get-Content $Log -ErrorAction SilentlyContinue | Write-Host
    throw "The test process did not reach $Checkpoint."
}

function Test-InterruptedSetup($Root, $Binary, $License, $Settings, $PreviousInstaller) {
    $diagnostic = New-InterruptedSetup
    foreach ($stage in @('first-file', 'before-uninstall-registration')) {
        if ($stage -eq 'before-uninstall-registration') {
            if ((Invoke-Setup $PreviousInstaller 'interrupted-update-seed' $Root) -ne 0) {
                throw 'Could not seed the previous installation for the interruption test.'
            }
            $previousRecord = Get-InstallRecord $Root
            $previousLog = [IO.Path]::ChangeExtension((Get-Uninstaller $Root), '.dat')
            $previousLogHash = (Get-FileHash -LiteralPath $previousLog).Hash
        }
        $log = Join-Path $fixture.FullName "interrupted-$stage.log"
        $process = Start-Process $diagnostic -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', `
            '/NORESTART', "/LOG=`"$log`"", "/OBS=`"$Root`"", "/CHECKPOINT=$stage"
        try {
            Wait-Checkpoint $process $log $stage
            Assert-Hash $Binary $expectedHash
            if ($stage -eq 'first-file' -and (Test-Path -LiteralPath $License)) {
                throw 'The first-file checkpoint ran after replacing the license.'
            }
            if ($stage -eq 'before-uninstall-registration') {
                Assert-Hash $License (Get-FileHash $packagedLicense).Hash
                $record = Get-InstallRecord $Root
                if ($record.DisplayVersion -ne $previousRecord.DisplayVersion) {
                    throw 'The registration checkpoint ran after Inno replaced Installed apps.'
                }
                Assert-Hash $previousLog $previousLogHash
            }
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        }
        if ((Invoke-Setup $Installer "recover-$stage" $Root) -ne 0) { throw "Setup did not recover from $stage." }
        Assert-Hash $Binary $expectedHash
        Assert-Hash $License (Get-FileHash $packagedLicense).Hash
        Assert-Hashes $Settings
        if ((Invoke-Setup (Get-Uninstaller $Root) "remove-recovered-$stage") -ne 0 -or
            (Test-Path -LiteralPath $Binary) -or (Test-Path -LiteralPath $License) -or
            @(Get-InstallRecord $Root).Count -ne 0) {
            throw "Could not remove the installation recovered from $stage."
        }
        Write-Host "PASS process tree killed at $stage; unmodified Setup recovered and uninstall succeeded."
    }
    if ((Invoke-Setup $diagnostic 'locked-uninstall-seed' $Root) -ne 0) { throw 'Diagnostic Setup failed.' }
    $uninstaller = Get-Uninstaller $Root
    $dat = [IO.Path]::ChangeExtension($uninstaller, '.dat')
    $baseline = @{ $Binary = $expectedHash; $License = (Get-FileHash $packagedLicense).Hash;
        $uninstaller = (Get-FileHash $uninstaller).Hash; $dat = (Get-FileHash $dat).Hash }
    $sentinel = Join-Path (Get-InstallDirectory $Root) 'hold-uninstall'
    $null = New-Item -ItemType File $sentinel
    $log = Join-Path $fixture.FullName 'locked-uninstall.log'
    $process = Start-Process $uninstaller -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', `
        '/NORESTART', "/LOG=`"$log`""
    $lock = $null
    try {
        Wait-Checkpoint $process $log 'uninstall'
        $lock = [IO.File]::Open($Binary, 'Open', 'Read', 'Read')
        if (-not $process.WaitForExit(40000)) { throw 'Locked uninstaller timed out.' }
        if ($process.ExitCode -eq 0 -or (Get-Content $log -Raw) -notmatch 'locked or cannot be replaced') {
            Get-Content $log | Write-Host
            throw 'Uninstall did not report the locked DLL.'
        }
        Assert-Hashes $baseline
        if ((Get-Uninstaller $Root) -ne $uninstaller) { throw 'Late uninstall failure lost Installed apps.' }
    }
    finally {
        if ($lock) { $lock.Dispose() }
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        Remove-Item -LiteralPath $sentinel -Force
    }
    if ((Invoke-Setup $uninstaller 'retry-locked-uninstall') -ne 0 -or (Test-Path -LiteralPath $Binary) -or
        @(Get-InstallRecord $Root).Count -ne 0) { throw 'Uninstall could not be retried after unlocking the DLL.' }
    Assert-Hashes $Settings
    Write-Host 'PASS locking the DLL after InitializeUninstall preserved the registration and allowed retry.'
}

try {
    Test-InstallerIcon
    $obs33 = Join-Path $fixture.FullName 'Portable OBS 33'
    $testRoots.Add($obs33)
    $archive = Get-TestDownload "$obsReleases/33.0.0/OBS-Studio-33.0.0-Windows-x64.zip" `
        '3369a3ecd67b5669a8a08d77357f87cc786d1fba42fbbd1054d841a69f6271a7'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $obs33)

    $old33 = Join-Path $obs33 "obs-plugins/64bit/$binaryName"
    $legacyLicense = Join-Path $obs33 'data/obs-plugins/FaderSyncPlugin/LICENSE'
    $installed33 = Join-Path $obs33 "plugins/FaderSyncPlugin/$binaryName"
    $null = New-Item -ItemType Directory -Force (Split-Path $old33)
    $null = New-Item -ItemType Directory -Force (Split-Path $legacyLicense)
    $originalLicense = Join-Path (Split-Path -Parent $PSScriptRoot) 'LICENSE'
    Copy-Item -LiteralPath $originalLicense -Destination $legacyLicense
    $null = New-Item -ItemType File (Join-Path $obs33 'portable_mode.txt')
    $stable = Get-TestDownload "$repo/v1.3.1.2/FaderSyncPlugin-win-x64-1.3.1.2.zip" `
        '76247a0d1170c2890dd08c9fc7bd77db6ba41676e0c3414da34e89fed6b72192'
    $zip = [IO.Compression.ZipFile]::OpenRead($stable)
    try {
        $entry = $zip.Entries | Where-Object Name -eq $binaryName
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $old33)
    }
    finally { $zip.Dispose() }
    $oldHash = (Get-FileHash $old33).Hash
    if ((Invoke-Setup $Installer 'upgrade33' $obs33) -ne 0 -or (Test-Path -LiteralPath $old33)) {
        throw 'OBS 33 migration from the published stable DLL failed.'
    }
    Assert-Hash $installed33 $expectedHash
    $backups33 = Join-Path $obs33 'FaderSyncPlugin-backups'
    $oldCopy = Get-ChildItem $backups33 -Recurse -File -Filter 'obs-root.dll'
    $oldLicenseCopy = Get-ChildItem $backups33 -Recurse -File -Filter 'obs-root-LICENSE'
    if (@($oldCopy).Count -ne 1 -or @($oldLicenseCopy).Count -ne 1 -or (Test-Path -LiteralPath $legacyLicense)) {
        throw 'The installer did not migrate and back up the old DLL and LICENSE.'
    }
    Assert-Hash $oldCopy.FullName $oldHash
    Assert-Hash $oldLicenseCopy.FullName (Get-FileHash $originalLicense).Hash
    Write-Host "PASS OBS 33 migrated the published 1.3.1.2 binary (SHA-256 $oldHash)."
    Test-ObsStartup $obs33

    Set-Content -LiteralPath $old33 'a different file with the same name'
    if ((Invoke-Setup $Installer 'foreign33' $obs33) -eq 0) { throw 'Setup accepted a foreign module.' }
    if ((Get-Content -LiteralPath $old33) -ne 'a different file with the same name') {
        throw 'Setup changed a foreign file.'
    }
    Assert-Hash $installed33 $expectedHash

    $obs32 = Join-Path $fixture.FullName 'Portable OBS 32'
    $testRoots.Add($obs32)
    $archive = Get-TestDownload "$obsReleases/32.2.2/OBS-Studio-32.2.2-Windows-x64.zip" `
        '4d6e40e3ab155f56b30de517380566a206d74b63cdf5ad49aa596924768f97e1'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $obs32)
    $null = New-Item -ItemType File (Join-Path $obs32 'portable_mode.txt')
    $plugin32 = Join-Path $obs32 "obs-plugins/64bit/$binaryName"
    $licenseDir32 = Join-Path $obs32 'data/obs-plugins/FaderSyncPlugin'
    $license32 = Join-Path $licenseDir32 'LICENSE'
    $settings = @{
        'basic/scenes/Preserved.json' = '{"name":"Preserved","sources":[],"scene_order":[]}'
        'basic/profiles/Preserved/basic.ini' = "[General]`nName=Preserved"
        'user.ini' = "[BasicWindow]`nWarnBeforeStartingStream=true"
    }
    $settingsHashes = @{}
    foreach ($setting in $settings.GetEnumerator()) {
        $path = Join-Path $obs32 ('config/obs-studio/' + $setting.Key)
        $null = New-Item -ItemType Directory -Force (Split-Path $path)
        Set-Content -LiteralPath $path -Value $setting.Value
        $settingsHashes[$path] = (Get-FileHash -LiteralPath $path).Hash
    }

    $beta3 = Get-TestDownload "$repo/v1.4.0-beta.3/FaderSyncPlugin-win-x64-installer.exe" `
        '72a002980667aa65ccfcbc96751991282bca046f1a64eaace510c25cf4f811b8'
    if ((Invoke-Setup $beta3 'seed32' $obs32) -ne 0) { throw 'Failed to install the published beta.3.' }
    $previous = $settingsHashes.Clone()
    $previous[$plugin32] = '4d8c0dee28bd106db9a05ab4bac19072315a1ff1b658a5a853c29ed27c8c1494'
    $previous[$license32] = '0fe6dabfff2c5b2243446f31cb9eae798c62e5d0324febd2c5af7490d5be20ef'
    $oldUninstaller = Get-Uninstaller $obs32
    $previous[$oldUninstaller] = (Get-FileHash $oldUninstaller).Hash
    Assert-Hashes $previous

    $acl = Get-Acl -LiteralPath $licenseDir32
    $restricted = Get-Acl -LiteralPath $licenseDir32
    $account = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($account, 'CreateFiles', 'Deny')
    $restricted.AddAccessRule($rule)
    Set-Acl -LiteralPath $licenseDir32 -AclObject $restricted
    try {
        $exitCode = Invoke-Setup $Installer 'late-failure32' $obs32
        $log = Get-Content (Join-Path $fixture.FullName 'late-failure32.log') -Raw
        if ($exitCode -eq 0 -or $log -notmatch 'Installed plugin file [^\r\n]*FaderSyncPlugin[.]dll' -or
            $log -notmatch 'Could not stage or verify the plugin file: [^\r\n]*LICENSE' -or
            -not $log.Contains('Previous plugin files restored.')) {
            throw 'The write error did not exercise rollback after the DLL was replaced.'
        }
    }
    finally { Set-Acl -LiteralPath $licenseDir32 -AclObject $acl }
    Assert-Hashes $previous
    if ((Get-Uninstaller $obs32) -ne $oldUninstaller) { throw 'Rollback changed the uninstaller registration.' }
    Write-Host "PASS late write failure restored beta.3 DLL and bundled LICENSE (SHA-256 $($previous[$plugin32]))."

    Test-Cancel $obs32
    Assert-Hashes $previous
    if ((Get-Uninstaller $obs32) -ne $oldUninstaller) { throw 'Cancel changed the uninstaller registration.' }
    Write-Host 'PASS wizard cancellation preserved the DLL, LICENSE, uninstaller, and OBS settings.'

    if ((Invoke-Setup $Installer 'upgrade32' $obs32) -ne 0) { throw 'OBS 32 installation after rollback failed.' }
    Assert-Hash $plugin32 $expectedHash
    Assert-Hash $installed33 $expectedHash
    Assert-Hash $license32 (Get-FileHash $packagedLicense).Hash
    $license33 = Join-Path (Split-Path $installed33) 'LICENSE'
    Assert-Hash $license33 (Get-FileHash $packagedLicense).Hash
    Assert-Hashes $settingsHashes
    $backups32 = @(Get-ChildItem (Join-Path $obs32 'FaderSyncPlugin-backups') -Directory)
    if ($backups32.Count -ne 2) { throw 'Expected a beta.3 backup for both upgrade attempts.' }
    foreach ($backup in $backups32) {
        Assert-Hash (Join-Path $backup.FullName 'previous.dll') $previous[$plugin32]
        Assert-Hash (Join-Path $backup.FullName 'previous-LICENSE') $previous[$license32]
    }
    Write-Host 'PASS upgraded the published beta.3 and preserved the contents of the bundled LICENSE backup.'

    $beta4 = Get-TestDownload "$repo/v1.4.0-beta.4/FaderSyncPlugin-win-x64-installer.exe" `
        'ce728abd0b350ec596fa302fb4da5732cf7f916d9c0ce2dbc2c76ec4d3aa5c33'
    if ((Invoke-Setup $beta4 'seed-beta4' $obs32) -ne 0) { throw 'Could not seed the published beta.4.' }
    $oldUninstaller = Get-Uninstaller $obs32
    $oldLog = [IO.Path]::ChangeExtension($oldUninstaller, '.dat')
    $registered = Get-InstallRecord $obs32
    $previous = $settingsHashes.Clone()
    foreach ($file in @($plugin32, $license32, $oldUninstaller, $oldLog)) { $previous[$file] = (Get-FileHash $file).Hash }
    $lock = [IO.File]::Open($oldLog, 'Open', 'Read', 'Read')
    try { $exitCode = Invoke-Setup $Installer 'registration-failure' $obs32 }
    finally { $lock.Dispose() }
    $log = Get-Content -Raw (Join-Path $fixture.FullName 'registration-failure.log')
    if ($exitCode -eq 0 -or $log -notmatch 'Installed plugin file' -or
        $log -notmatch 'Saving uninstall information' -or $log -notmatch 'Rolling back changes') {
        throw 'The registration failure did not reach native Inno rollback after installing the payload.'
    }
    Assert-Hashes $previous
    $after = Get-InstallRecord $obs32
    if ($after.PSPath -ne $registered.PSPath -or $after.UninstallString -ne $registered.UninstallString -or
        $after.DisplayVersion -ne $registered.DisplayVersion) { throw 'Native rollback did not restore Installed apps.' }
    Write-Host 'PASS native registration failure restored the beta.4 payload, uninstall EXE, log and Installed apps entry.'
    $key = 'SOFTWARE\FaderSyncPlugin\Installations\' + (Get-InstallId $obs32)
    $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    $rights = [Security.AccessControl.RegistryRights]::ReadKey -bor [Security.AccessControl.RegistryRights]::ChangePermissions
    $recordKey = $hive.OpenSubKey($key, 'ReadWriteSubTree', $rights)
    if (-not $recordKey) { throw 'Late rollback did not restore the mandatory target registry key.' }
    $denied = [Microsoft.Win32.RegistryAclExtensions]::GetAccessControl($recordKey)
    $rule = [Security.AccessControl.RegistryAccessRule]::new($account, 'SetValue', 'Deny')
    $denied.AddAccessRule($rule)
    [Microsoft.Win32.RegistryAclExtensions]::SetAccessControl($recordKey, $denied)
    try {
        $exit = Invoke-Setup $Installer 'target-registration-denied' $obs32
        $log = Get-Content -Raw (Join-Path $fixture.FullName 'target-registration-denied.log')
        if ($exit -eq 0 -or $log -notmatch 'Installed plugin file' -or
            $log -notmatch 'Could not register the selected OBS installation' -or
            $log -notmatch 'Previous plugin files restored') {
            throw 'Mandatory target registration did not fail and roll back as expected.'
        }
        Assert-Hashes $previous
        if ((Get-Uninstaller $obs32) -ne $oldUninstaller) { throw 'Denied registration changed Installed apps.' }
    }
    finally {
        $denied.RemoveAccessRuleSpecific($rule)
        [Microsoft.Win32.RegistryAclExtensions]::SetAccessControl($recordKey, $denied)
        $recordKey.Dispose()
        $hive.Dispose()
    }
    Write-Host 'PASS Windows ACL denied mandatory registry writes; Setup returned an error and rolled back.'
    if ((Invoke-Setup $Installer 'upgrade-beta4' $obs32) -ne 0) { throw 'Upgrade from beta.4 after native rollback failed.' }
    Assert-Hash $plugin32 $expectedHash
    Assert-Hashes $settingsHashes
    Test-ObsStartup $obs32
    foreach ($path in @($settingsHashes.Keys)) {
        $settingsHashes[$path] = (Get-FileHash -LiteralPath $path).Hash
    }
    if ((Invoke-Setup (Get-Uninstaller $obs33) 'uninstall33') -ne 0 -or
        (Test-Path -LiteralPath $installed33) -or (Test-Path -LiteralPath $license33)) {
        throw 'Could not uninstall the registered OBS 33 copy.'
    }
    if ((Get-Content -LiteralPath $old33) -ne 'a different file with the same name') {
        throw 'Uninstall changed an unregistered legacy file.'
    }
    Assert-Hash $plugin32 $expectedHash
    if ((Invoke-Setup (Get-Uninstaller $obs32) 'uninstall32') -ne 0 -or
        (Test-Path -LiteralPath $plugin32) -or (Test-Path -LiteralPath $license32)) {
        throw 'Could not uninstall the registered OBS 32 copy.'
    }
    Assert-Hashes $settingsHashes
    Write-Host 'PASS independent Portable OBS 32/33 updates and uninstall preserved scenes, profiles, and settings.'
    Test-InterruptedSetup $obs32 $plugin32 $license32 $settingsHashes $beta4

    if ($IncludeStandard) {
        $shared = Join-Path $env:ProgramData 'obs-studio/plugins/FaderSyncPlugin'
        if (@(Get-InstallRecord '').Count -gt 0 -or (Test-Path -LiteralPath $shared)) {
            throw 'Run the Standard scenarios in a clean Windows environment.'
        }
        $testRoots.Add('')
        foreach ($major in @(32, 33)) {
            $source = if ($major -eq 32) { $obs32 } else { $obs33 }
            $target = Join-Path $fixture.FullName "Standard OBS $major"
            $bin = New-Item -ItemType Directory -Force (Join-Path $target 'bin/64bit')
            Copy-Item -LiteralPath (Join-Path $source 'bin/64bit/obs64.exe') -Destination $bin.FullName
            if ((Invoke-Setup $Installer "standard-$major" $target 'standard') -ne 0) { throw "OBS $major Standard setup failed." }
            $binary = if ($major -eq 32) { Join-Path $shared "bin/64bit/$binaryName" } else { Join-Path $shared $binaryName }
            Assert-Hash $binary $expectedHash
            Assert-Hash (Join-Path $shared 'LICENSE') (Get-FileHash $packagedLicense).Hash
            if ((Invoke-Setup (Get-Uninstaller '') "uninstall-standard-$major") -ne 0 -or (Test-Path -LiteralPath $binary)) {
                throw "OBS $major Standard removal failed."
            }
            Write-Host "PASS OBS $major Standard layout and uninstallation."
        }
    }
}
finally {
    if ($EvidenceDirectory) {
        $null = New-Item -ItemType Directory -Force $EvidenceDirectory
        Copy-Item -Path (Join-Path $fixture.FullName '*.log') -Destination $EvidenceDirectory
    }
    $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    try {
        foreach ($root in $testRoots) {
            $record = @(Get-InstallRecord $root)
            if ($record.Count -gt 0) {
                try { $null = Invoke-Setup (Get-Uninstaller $root) 'cleanup' }
                catch { Write-Warning $_ }
            }
            foreach ($remaining in @(Get-InstallRecord $root)) {
                $hive.DeleteSubKeyTree("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($remaining.PSChildName)", $false)
            }
            $hive.DeleteSubKeyTree(('SOFTWARE\FaderSyncPlugin\Installations\' + (Get-InstallId $root)), $false)
            $directory = Get-InstallDirectory $root
            if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        }
    }
    finally { $hive.Dispose() }
    Remove-Item -LiteralPath $fixture.FullName -Recurse -Force
}
