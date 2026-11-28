#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$PluginBinary
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$fixture = New-Item -ItemType Directory (Join-Path ([IO.Path]::GetTempPath()) ('FaderSync-test-' + [guid]::NewGuid()))
$releases = 'https://github.com/obsproject/obs-studio/releases/download'
$fixtures = [ordered]@{
    '32.2.2' = '4d6e40e3ab155f56b30de517380566a206d74b63cdf5ad49aa596924768f97e1'
    '33.0.0' = '3369a3ecd67b5669a8a08d77357f87cc786d1fba42fbbd1054d841a69f6271a7'
}
$version = (Get-Item -LiteralPath $PluginBinary).VersionInfo.ProductVersion.TrimEnd()
$pluginHash = (Get-FileHash -LiteralPath $PluginBinary).Hash
$licenseHash = (Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $PluginBinary) 'LICENSE')).Hash

function Invoke-Setup($Program, $Case, $Target = '') {
    $log = Join-Path $fixture.FullName "$Case.log"
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$log`"")
    if ($Target) { $arguments += "/OBS=`"$Target`"", '/MODE=portable' }
    $process = Start-Process $Program -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Write-Host
        throw "Setup returned exit code $($process.ExitCode) for $Case."
    }
}

function Get-FixtureRegistration($Directory) {
    Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' |
        Get-ItemProperty | Where-Object {
            $_.PSChildName -like 'FaderSyncPlugin-portable-*_is1' -and
            $_.InstallLocation -and $_.InstallLocation.TrimEnd('\') -eq $Directory
        }
}

function Test-ObsStartup($Root, $ObsVersion) {
    $bin = Join-Path $Root 'bin/64bit'
    $process = Start-Process (Join-Path $bin 'obs64.exe') -WorkingDirectory $bin `
        -ArgumentList '--portable', '--disable-shutdown-check', '--multi' -PassThru
    try {
        $logDirectory = Join-Path $Root 'config/obs-studio/logs'
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $latest = Get-ChildItem $logDirectory -Filter '*.txt' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                $log = Get-Content -LiteralPath $latest.FullName -Raw
                if ($log -match 'Plugin load failed:|Failed to initialize video[:.]') { break }
                if ($log -match '==== Startup complete') {
                    $target = [regex]::Escape($version)
                    if ($log -match "(?m)Loading FaderSyncPlugin v$target\r?$" -and
                        $log -match '(?m)^\S+:[ \t]+FaderSyncPlugin\.dll[ \t]*\r?$' -and -not $process.HasExited) {
                        Write-Host "OBS $ObsVersion loaded Fader Sync v$version and completed startup."
                        return
                    }
                    break
                }
            }
            if ($process.HasExited) { break }
            Start-Sleep -Seconds 1
        }
        if ($latest) { Get-Content -LiteralPath $latest.FullName -Tail 50 | Write-Host }
        throw "OBS $ObsVersion did not complete startup with Fader Sync v$version."
    }
    finally {
        if (-not $process.HasExited -and (-not $process.CloseMainWindow() -or -not $process.WaitForExit(8000))) {
            $process.Kill($true)
            $process.WaitForExit()
        }
    }
}

try {
    foreach ($obsVersion in $fixtures.Keys) {
        $archive = Join-Path $fixture.FullName "OBS-$obsVersion.zip"
        Invoke-WebRequest "$releases/$obsVersion/OBS-Studio-$obsVersion-Windows-x64.zip" -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive).Hash -ne $fixtures[$obsVersion]) { throw 'OBS archive checksum mismatch.' }
        $target = Join-Path $fixture.FullName "Portable OBS $obsVersion"
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $target)
        $marker = Join-Path $target 'portable_mode.txt'
        $null = New-Item -ItemType File -Path $marker -Force
        $keyBytes = [Text.Encoding]::Unicode.GetBytes($target.ToLowerInvariant())
        $id = 'portable-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($keyBytes)).ToLowerInvariant()
        $directory = Join-Path $env:ProgramData "obs-studio\FaderSyncPlugin-installs\$id"
        if ((Test-Path -LiteralPath $directory) -or @(Get-FixtureRegistration $directory).Count -ne 0) {
            throw "Expected a new fixture directory: $directory"
        }
        try {
            Invoke-Setup $Installer "install-$obsVersion" $target
            $records = @(Get-FixtureRegistration $directory)
            if ($records.Count -ne 1) { throw "Expected a single registration for $target." }
            $registration = $records[0]
            $uninstaller = $registration.UninstallString.Trim('"')
            if ((Split-Path -Parent $uninstaller) -ne $directory) { throw 'Unexpected fixture uninstaller path.' }
            $legacy = $obsVersion.StartsWith('32.')
            $dll = Join-Path $target $(if ($legacy) { 'obs-plugins/64bit/FaderSyncPlugin.dll' } else { 'plugins/FaderSyncPlugin/FaderSyncPlugin.dll' })
            $license = Join-Path $target $(if ($legacy) { 'data/obs-plugins/FaderSyncPlugin/LICENSE' } else { 'plugins/FaderSyncPlugin/LICENSE' })
            if ((Get-FileHash -LiteralPath $dll).Hash -ne $pluginHash -or (Get-FileHash -LiteralPath $license).Hash -ne $licenseHash) {
                throw "Setup did not install the expected DLL and LICENSE for OBS $obsVersion."
            }
            Test-ObsStartup $target $obsVersion
            Invoke-Setup $uninstaller "uninstall-$obsVersion"
            if ((Test-Path -LiteralPath $dll) -or (Test-Path -LiteralPath $license) -or (Test-Path -LiteralPath $registration.PSPath)) {
                throw "Setup did not remove the test installation for OBS $obsVersion."
            }
        }
        finally {
            $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
            try {
                foreach ($item in (Get-FixtureRegistration $directory)) {
                    $hive.DeleteSubKeyTree("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($item.PSChildName)", $false)
                }
                $hive.DeleteSubKeyTree("SOFTWARE\FaderSyncPlugin\Installations\$id", $false)
            }
            finally { $hive.Dispose() }
            if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        }
    }
}
finally { Remove-Item -LiteralPath $fixture.FullName -Recurse -Force }
