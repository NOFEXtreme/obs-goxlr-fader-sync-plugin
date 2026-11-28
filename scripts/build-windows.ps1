param(
    [switch]$Install,
    [string]$InnoCompiler,
    [string]$ReleaseVersion = $env:FADERSYNC_VERSION
)

$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'FaderSyncPlugin/FaderSyncPlugin.csproj'
$installer = Join-Path $PSScriptRoot 'installer/FaderSyncPlugin.iss'
$pluginOutput = Join-Path $root 'FaderSyncPlugin/bin/Release/net10.0/win-x64'
$package = Join-Path $pluginOutput 'package'
$setup = Join-Path $package 'FaderSyncPlugin-win-x64-installer.exe'

if (-not $InnoCompiler) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $InnoCompiler = $command.Source }
    else {
        $InnoCompiler = @($env:ProgramFiles, (Join-Path $env:LOCALAPPDATA 'Programs')) |
            ForEach-Object { Join-Path $_ 'Inno Setup 7/ISCC.exe' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
}
if (-not $InnoCompiler -or -not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) {
    throw 'Install Inno Setup 7 or pass its ISCC executable with -InnoCompiler.'
}
Write-Host "Inno Setup compiler is $InnoCompiler"

$versionArgument = @()
if ($ReleaseVersion) { $versionArgument += "-p:Version=$ReleaseVersion" }
$properties = & dotnet msbuild $project -nologo -target:GetAssemblyVersion -getProperty:Version,FileVersion @versionArgument
if ($LASTEXITCODE -ne 0) { throw 'Could not read the plugin version.' }
$version = ($properties -join "`n" | ConvertFrom-Json).Properties
if (-not $version.Version -or -not $version.FileVersion) { throw 'Plugin version metadata is incomplete.' }

& dotnet publish $project -c Release -r win-x64 --self-contained @versionArgument
if ($LASTEXITCODE -ne 0) { throw 'Plugin build failed.' }

$binary = Join-Path $pluginOutput 'publish/FaderSyncPlugin.dll'
$license = Join-Path $pluginOutput 'publish/LICENSE'
$licensePage = Join-Path $pluginOutput 'setup-license.txt'
$originalLicense = Get-Content -Raw -LiteralPath (Join-Path $root 'LICENSE')
$setupNotices = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'installer/SetupNotices.txt')
Set-Content -LiteralPath $licensePage -Value ($originalLicense + "`n`n" + $setupNotices) -Encoding utf8BOM
if (Test-Path -LiteralPath $setup) { Remove-Item -LiteralPath $setup }
& $InnoCompiler /Qp "/DVersion=$($version.Version)" "/DFileVersion=$($version.FileVersion)" `
    "/DPluginBinary=$binary" "/DLicensePath=$license" "/DLicensePagePath=$licensePage" "/O$package" $installer
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed.' }

& (Join-Path $PSScriptRoot 'verify-packages.ps1') -WindowsDirectory $package -WindowsBinary $binary
Write-Host "Packages are in $package"
if ($Install) {
    $process = Start-Process $setup -Wait -PassThru
    if ($process.ExitCode -ne 0) { exit $process.ExitCode }
}
