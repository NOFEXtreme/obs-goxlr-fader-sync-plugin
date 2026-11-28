param(
    [string]$WindowsDirectory,
    [string]$LinuxDirectory,
    [string]$WindowsBinary,
    [string]$LinuxBinary,
    [string]$WindowsLicense,
    [string]$LinuxLicense,
    [string]$Manifest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$licensePrefix = (Get-Content -Raw -LiteralPath (Join-Path $root 'LICENSE')).Replace("`r`n", "`n") +
    "`n`nThird-party notices for GoXLR Fader Sync Plugin`n"
$files = [ordered]@{}

function Get-EntryHash($Entry) {
    $stream = $Entry.Open()
    try { (Get-FileHash -InputStream $stream).Hash }
    finally { $stream.Dispose() }
}

function Test-Package($Directory, $Name, $Module, $License, $Data, $ExpectedHash, $ExpectedLicenseHash) {
    $path = Join-Path $Directory $Name
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $expected = @($Module, $License)
        if ($Data) { $expected += $Data }
        $names = @($archive.Entries.FullName)
        if ($names.Count -ne $expected.Count -or (Compare-Object $expected $names -CaseSensitive)) {
            throw "Unexpected contents in $Name."
        }
        $licenseEntry = $archive.GetEntry($License)
        $reader = [IO.StreamReader]::new($licenseEntry.Open())
        try {
            $text = $reader.ReadToEnd().Replace("`r`n", "`n")
            if (-not $text.StartsWith($licensePrefix, [StringComparison]::Ordinal) -or
                $text -notmatch '(?m)^\.NET NativeAOT runtime \d+\.\d+\.\d+') { throw "Incorrect license in $Name." }
        }
        finally { $reader.Dispose() }
        $licenseHash = Get-EntryHash $licenseEntry
        if ($ExpectedLicenseHash -and $licenseHash -ne $ExpectedLicenseHash) { throw "License mismatch in $Name." }
        $moduleEntry = $archive.GetEntry($Module)
        if ($moduleEntry.Length -eq 0) { throw "Empty module in $Name." }
        $moduleHash = Get-EntryHash $moduleEntry
        if ($ExpectedHash -and $moduleHash -ne $ExpectedHash) { throw "Incorrect module in $Name." }
        $files[$Name] = $path
        [pscustomobject]@{ Module = $moduleHash; License = $licenseHash }
    }
    finally { $archive.Dispose() }
}

if ($WindowsDirectory) {
    $dll = 'FaderSyncPlugin.dll'
    $dllHash = if ($WindowsBinary) { (Get-FileHash $WindowsBinary).Hash }
    if ($WindowsBinary -and -not $WindowsLicense) { $WindowsLicense = Join-Path (Split-Path -Parent $WindowsBinary) 'LICENSE' }
    $licenseHash = if ($WindowsLicense) { (Get-FileHash -LiteralPath $WindowsLicense).Hash }
    $windows = Test-Package $WindowsDirectory 'FaderSyncPlugin-win-x64.zip' "FaderSyncPlugin/$dll" 'FaderSyncPlugin/LICENSE' 'FaderSyncPlugin/data/' $dllHash $licenseHash
    $null = Test-Package $WindowsDirectory 'FaderSyncPlugin-win-x64-obs32.zip' "FaderSyncPlugin/bin/64bit/$dll" 'FaderSyncPlugin/LICENSE' 'FaderSyncPlugin/data/' $windows.Module $windows.License
    $null = Test-Package $WindowsDirectory 'FaderSyncPlugin-win-x64-portable.zip' "obs-plugins/64bit/$dll" 'data/obs-plugins/FaderSyncPlugin/LICENSE' '' $windows.Module $windows.License

    $name = 'FaderSyncPlugin-win-x64-installer.exe'
    $setup = Join-Path $WindowsDirectory $name
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($setup))
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Invalid installer executable: $setup" }
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw "The installer must be a Windows x64 executable: $setup"
        }
    }
    finally { $reader.Dispose() }
    # .NET reads native PE version resources through Windows APIs.
    if ($WindowsBinary -and $IsWindows) {
        $setupInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($setup)
        $pluginInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($WindowsBinary)
        $setupVersion = ([string]$setupInfo.ProductVersion).TrimEnd()
        $pluginVersion = ([string]$pluginInfo.ProductVersion).TrimEnd()
        if ($setupVersion -ne $pluginVersion -or -not $setupVersion) { throw 'Installer and plugin versions differ.' }
        if (($setupInfo.FileMajorPart, $setupInfo.FileMinorPart, $setupInfo.FileBuildPart, $setupInfo.FilePrivatePart -join '.') -ne $pluginInfo.FileVersion) {
            throw 'Installer and plugin numeric versions differ.'
        }
    }
    $files[$name] = $setup
}

if ($LinuxDirectory) {
    $hash = if ($LinuxBinary) { (Get-FileHash $LinuxBinary).Hash }
    if ($LinuxBinary -and -not $LinuxLicense) { $LinuxLicense = Join-Path (Split-Path -Parent $LinuxBinary) 'LICENSE' }
    $licenseHash = if ($LinuxLicense) { (Get-FileHash -LiteralPath $LinuxLicense).Hash }
    $null = Test-Package $LinuxDirectory 'FaderSyncPlugin-linux-x64.zip' 'FaderSyncPlugin/bin/64bit/FaderSyncPlugin.so' 'FaderSyncPlugin/LICENSE' 'FaderSyncPlugin/data/' $hash $licenseHash
}

if ($files.Count -eq 0) { throw 'Specify the package directory to verify.' }
if ($Manifest) {
    if ($files.Count -ne 5) { throw 'A release manifest requires all five packages.' }
    $files.Keys | Sort-Object | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash $files[$_]).Hash.ToLowerInvariant(), $_
    } | Set-Content -LiteralPath $Manifest -Encoding ascii
}
Write-Host "Verified $($files.Count) release packages."
