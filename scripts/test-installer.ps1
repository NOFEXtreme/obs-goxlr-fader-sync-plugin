#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$PluginBinary
)

$ErrorActionPreference = 'Stop'
$fixture = New-Item -ItemType Directory (Join-Path ([IO.Path]::GetTempPath()) ('FaderSync-test-' + [guid]::NewGuid()))
$obs = Join-Path $fixture.FullName 'Portable OBS'
$binaryName = 'FaderSyncPlugin.dll'
$previous = Join-Path $obs "obs-plugins/64bit/$binaryName"
$installed = Join-Path $obs "plugins/FaderSyncPlugin/$binaryName"
$settings = Join-Path $obs 'config/obs-studio/scene-test.json'
$expectedHash = (Get-FileHash $PluginBinary).Hash

function Invoke-Setup($Program, $Log, $Selection) {
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$Log`"") + $Selection
    $process = Start-Process $Program -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0 -and (Test-Path -LiteralPath $Log)) {
        Get-Content -LiteralPath $Log | Write-Host
    }
    return $process.ExitCode
}

try {
    $archive = Join-Path $fixture.FullName 'obs.zip'
    Invoke-WebRequest 'https://github.com/obsproject/obs-studio/releases/download/33.0.0/OBS-Studio-33.0.0-Windows-x64.zip' -OutFile $archive
    if ((Get-FileHash $archive).Hash -ne '3369a3ecd67b5669a8a08d77357f87cc786d1fba42fbbd1054d841a69f6271a7') {
        throw 'OBS test fixture checksum mismatch.'
    }
    $exeDirectory = New-Item -ItemType Directory -Force (Join-Path $obs 'bin/64bit')
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $exe = $zip.GetEntry('bin/64bit/obs64.exe')
        [IO.Compression.ZipFileExtensions]::ExtractToFile($exe, (Join-Path $exeDirectory.FullName 'obs64.exe'))
    }
    finally { $zip.Dispose() }

    $null = New-Item -ItemType Directory -Force (Split-Path $previous), (Split-Path $settings)
    $null = New-Item -ItemType File (Join-Path $obs 'portable_mode.txt')
    Set-Content -LiteralPath $settings 'keep this scene'
    Copy-Item -LiteralPath $PluginBinary -Destination $previous

    $select = @("/OBS=`"$obs`"")
    if ((Invoke-Setup $Installer (Join-Path $fixture.FullName 'install.log') $select) -ne 0) {
        throw 'Portable OBS 33 installation failed.'
    }
    if ((Test-Path -LiteralPath $previous) -or (Get-FileHash $installed).Hash -ne $expectedHash) {
        throw 'Setup did not replace the legacy root copy with the built module.'
    }
    $backup = Get-ChildItem -LiteralPath (Join-Path $obs 'FaderSyncPlugin-backups') -Recurse -File -Filter 'obs-root.dll'
    if (@($backup).Count -ne 1 -or (Get-FileHash $backup.FullName).Hash -ne $expectedHash) {
        throw 'The legacy module was not backed up correctly.'
    }

    Set-Content -LiteralPath $previous 'a different file with the same name'
    if ((Invoke-Setup $Installer (Join-Path $fixture.FullName 'foreign-file.log') $select) -eq 0 -or
        (Get-Content -LiteralPath $previous) -ne 'a different file with the same name' -or
        (Get-FileHash $installed).Hash -ne $expectedHash) {
        throw 'Setup changed files while the installation had a conflicting module.'
    }

    $record = Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' |
        Get-ItemProperty | Where-Object { $_.DisplayName -eq 'GoXLR Fader Sync Plugin (Portable: Portable OBS)' -and $_.InstallLocation -like '*FaderSyncPlugin-installs*' }
    $uninstaller = ([string]$record.UninstallString).Trim('"')
    if (@($record).Count -ne 1 -or -not (Test-Path -LiteralPath $uninstaller -PathType Leaf) -or
        (Invoke-Setup $uninstaller (Join-Path $fixture.FullName 'uninstall.log') @()) -ne 0 -or
        (Test-Path -LiteralPath $installed) -or (Get-Content -LiteralPath $settings) -ne 'keep this scene' -or
        (Get-Content -LiteralPath $previous) -ne 'a different file with the same name') {
        throw 'Uninstall did not remove only the registered plugin files.'
    }
    Write-Host 'Installer verified on Windows: legacy migration, backup, file ownership, and uninstall.'
}
finally { Remove-Item -LiteralPath $fixture.FullName -Recurse -Force }
