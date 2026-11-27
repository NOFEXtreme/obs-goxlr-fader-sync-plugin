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
$legacyLicense = Join-Path (Split-Path -Parent $PSScriptRoot) 'LICENSE'
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

function Test-ObsStartup($Root) {
    $bin = Join-Path $Root 'bin/64bit'
    $process = Start-Process (Join-Path $bin 'obs64.exe') -WorkingDirectory $bin `
        -ArgumentList '--portable', '--disable-shutdown-check', '--multi' -PassThru
    try {
        $logs = Join-Path $Root 'config/obs-studio/logs'
        $expected = (Get-Item $PluginBinary).VersionInfo.ProductVersion.TrimEnd()
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $latest = Get-ChildItem $logs -Filter '*.txt' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                $log = Get-Content $latest.FullName -Raw
                if ($log.Contains("Loading FaderSyncPlugin v$expected") -and $log -match 'Startup complete') {
                    Write-Host 'PASS full OBS 32.2.2 started on Windows and loaded the release DLL.'
                    return
                }
            }
            if ($process.HasExited) { break }
            Start-Sleep -Seconds 1
        }
        Write-Warning 'Full OBS did not reach a confirmed plugin startup on the Windows runner.'
        if ($latest) { Get-Content $latest.FullName -Tail 25 | Write-Host }
    }
    finally {
        if (-not $process.HasExited -and (-not $process.CloseMainWindow() -or -not $process.WaitForExit(8000))) {
            $process.Kill($true)
            $process.WaitForExit()
        }
    }
}

try {
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
    $installed33 = Join-Path $obs33 "plugins/FaderSyncPlugin/$binaryName"
    $null = New-Item -ItemType Directory -Force (Split-Path $old33)
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
    $oldCopy = Get-ChildItem (Join-Path $obs33 'FaderSyncPlugin-backups') -Recurse -File -Filter 'obs-root.dll'
    if (@($oldCopy).Count -ne 1) { throw 'The installer did not write exactly one backup of the old module.' }
    Assert-Hash $oldCopy.FullName $oldHash
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
    $scene = Join-Path $obs32 'config/obs-studio/scene-test.json'
    $null = New-Item -ItemType Directory -Force (Split-Path $scene)
    Set-Content $scene '{"scene":"keep this file"}'
    $sceneHash = (Get-FileHash $scene).Hash

    $beta2 = Get-TestDownload "$repo/v1.4.0-beta.2/FaderSyncPlugin-win-x64-installer.exe" `
        'dc3fc9b3d4b70919f8abdc3ec770221327798692beff34c1ea3a3d092ac2b324'
    if ((Invoke-Setup $beta2 'seed32' $obs32) -ne 0) { throw 'Failed to install the published beta.2.' }
    $beta2Hash = 'b95962a67c582a6c872baae6a8973a84743af31d7e688f0a4ac7d867095495d6'
    Assert-Hash $plugin32 $beta2Hash
    $licenseHash = (Get-FileHash $legacyLicense).Hash
    Assert-Hash $license32 $licenseHash
    $oldUninstaller = Get-Uninstaller $obs32
    $uninstallHash = (Get-FileHash $oldUninstaller).Hash

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
    Assert-Hash $plugin32 $beta2Hash
    Assert-Hash $license32 $licenseHash
    Assert-Hash $scene $sceneHash
    Assert-Hash $oldUninstaller $uninstallHash
    Write-Host "PASS late write failure restored the published beta.2 DLL (SHA-256 $beta2Hash)."

    Test-Cancel $obs32
    Assert-Hash $plugin32 $beta2Hash
    Assert-Hash $license32 $licenseHash
    Assert-Hash $scene $sceneHash
    Assert-Hash $oldUninstaller $uninstallHash
    Write-Host 'PASS wizard cancellation preserved the DLL, license, registration, and scene.'

    if ((Invoke-Setup $Installer 'upgrade32' $obs32) -ne 0) { throw 'OBS 32 installation after rollback failed.' }
    Assert-Hash $plugin32 $expectedHash
    Assert-Hash $installed33 $expectedHash
    Assert-Hash $license32 (Get-FileHash $packagedLicense).Hash
    Assert-Hash (Join-Path (Split-Path $installed33) 'LICENSE') (Get-FileHash $packagedLicense).Hash
    Test-ObsStartup $obs32
    if ((Invoke-Setup (Get-Uninstaller $obs33) 'uninstall33') -ne 0 -or (Test-Path -LiteralPath $installed33)) {
        throw 'Could not uninstall the registered OBS 33 copy.'
    }
    if ((Get-Content -LiteralPath $old33) -ne 'a different file with the same name') {
        throw 'Uninstall changed an unregistered legacy file.'
    }
    Assert-Hash $plugin32 $expectedHash
    if ((Invoke-Setup (Get-Uninstaller $obs32) 'uninstall32') -ne 0 -or (Test-Path -LiteralPath $plugin32)) {
        throw 'Could not uninstall the registered OBS 32 copy.'
    }
    Assert-Hash $scene $sceneHash
    Write-Host 'PASS independent Portable OBS 32/33 updates, uninstall, and preservation of unrelated files.'
}
finally { Remove-Item -LiteralPath $fixture.FullName -Recurse -Force }
