#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$PluginBinary
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$fixture = New-Item -ItemType Directory (Join-Path ([IO.Path]::GetTempPath()) ('FaderSync-test-' + [guid]::NewGuid()))
$repo = 'https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/releases/download'
$obsReleases = 'https://github.com/obsproject/obs-studio/releases/download'
$binaryName = 'FaderSyncPlugin.dll'
$expectedHash = (Get-FileHash $PluginBinary).Hash
$packagedLicense = Join-Path (Split-Path -Parent $PluginBinary) 'LICENSE'

function Get-TestDownload($Url, $Hash) {
    $path = Join-Path $fixture.FullName ([IO.Path]::GetFileName($Url))
    Invoke-WebRequest $Url -OutFile $path
    if ((Get-FileHash $path).Hash -ne $Hash) { throw "Test fixture checksum mismatch: $Url" }
    return $path
}

function Invoke-Setup($Program, $Case, $Root = '') {
    $log = Join-Path $fixture.FullName "$Case.log"
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$log`"")
    if ($Root) { $arguments += "/OBS=`"$Root`"" }
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

function Get-Uninstaller($Root) {
    $displayName = 'GoXLR Fader Sync Plugin (Portable: ' + (Split-Path -Leaf $Root) + ')'
    $programData = Join-Path $env:ProgramData 'obs-studio/FaderSyncPlugin-installs'
    $record = Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' |
        Get-ItemProperty | Where-Object { $_.DisplayName -eq $displayName }
    if (@($record).Count -ne 1) { throw "Expected one registered installation for $Root" }
    $uninstaller = ([string]$record.UninstallString).Trim('"')
    if (-not $uninstaller.StartsWith($programData, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
        throw "Invalid uninstaller location: $uninstaller"
    }
    return $uninstaller
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
    private static extern IntPtr FindWindow(string className, string caption);
    public static IntPtr Wizard() => FindWindow("TWizardForm", null);
    public static IntPtr CancelConfirmation()
    {
        var window = FindWindow(null, "Exit Setup");
        return window != IntPtr.Zero ? window : FindWindow("#32770", "Setup");
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
        $window = Wait-InstallerWindow 'the Inno Setup wizard' { [InstallerTestWindow]::Wizard() }
        if (-not [InstallerTestWindow]::PostMessage($window, 0x0010, 0, 0)) { throw 'Cannot close test wizard.' }
        $confirm = Wait-InstallerWindow 'Exit Setup' { [InstallerTestWindow]::CancelConfirmation() }
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
                    Write-Host 'PASS full OBS 32.2.2 started on Windows and loaded the release DLL.'
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

try {
    Test-InstallerIcon
    $obs33 = Join-Path $fixture.FullName 'Portable OBS 33'
    $exe33 = New-Item -ItemType Directory -Force (Join-Path $obs33 'bin/64bit')
    $archive = Get-TestDownload "$obsReleases/33.0.0/OBS-Studio-33.0.0-Windows-x64.zip" `
        '3369a3ecd67b5669a8a08d77357f87cc786d1fba42fbbd1054d841a69f6271a7'
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry('bin/64bit/obs64.exe'),
            (Join-Path $exe33.FullName 'obs64.exe'))
    }
    finally { $zip.Dispose() }

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

    Set-Content -LiteralPath $old33 'a different file with the same name'
    if ((Invoke-Setup $Installer 'foreign33' $obs33) -eq 0) { throw 'Setup accepted a foreign module.' }
    if ((Get-Content -LiteralPath $old33) -ne 'a different file with the same name') {
        throw 'Setup changed a foreign file.'
    }
    Assert-Hash $installed33 $expectedHash

    $obs32 = Join-Path $fixture.FullName 'Portable OBS 32'
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
}
finally { Remove-Item -LiteralPath $fixture.FullName -Recurse -Force }
