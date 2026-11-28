# GoXLR Fader Sync Plugin

Control the volume of an OBS audio source with any GoXLR channel. Add the plugin as a filter to each source you want to control. This fork uses a measured GoXLR gain curve, reconnects when GoXLR Utility restarts, and includes a Windows installer that backs up previous copies of the plugin before replacing them.

## Volume matching

![Relative gain by GoXLR fader position for the measured device, this fork and the original plugin](docs/volume-curve.svg)

The measured signal and this fork overlap at the scale of the chart. The original 1.4.0 line shows its calculated target gain. To use the interactive chart, download the raw HTML file from GitHub and open it in a browser. [Measurement method](docs/volume-measurements.md) · [Interactive chart](docs/volume-curve.html)

## Requirements

- [OBS Studio](https://obsproject.com/) 32 or newer with a compatible plugin API, on Windows or Linux x86-64.
- Native Linux builds of OBS need a compatible libobs runtime and glibc 2.34 or newer to load this plugin. The package is built on Ubuntu 22.04.
- [GoXLR Utility](https://github.com/GoXLR-on-Linux/goxlr-utility) 1.0 or newer, running on the OBS computer with a GoXLR Full or Mini connected and the HTTP/WebSocket API enabled.

## Install or update

Close OBS and download a package from [Releases](https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/releases).

| Package | Where to install |
| --- | --- |
| `FaderSyncPlugin-win-x64-installer.exe` | Recommended on Windows. Setup suggests a detected OBS installation and the matching layout. Choose a different folder or mode when needed. |
| `FaderSyncPlugin-win-x64.zip` | OBS 33+ standard or Steam. Extract to `%ProgramData%\obs-studio\plugins`. |
| `FaderSyncPlugin-win-x64-obs32.zip` | OBS 32 standard or Steam. Extract to `%ProgramData%\obs-studio\plugins`. |
| `FaderSyncPlugin-win-x64-portable.zip` | Portable legacy layout. Extract to the OBS installation folder. Use Setup for the new OBS 33+ Portable layout. |
| `FaderSyncPlugin-linux-x64.zip` | Extract to `${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins` for a native OBS installation. |

Use **Browse** to select a custom OBS folder. Choose **Portable** if you start OBS with `--portable` without a marker file. Separate Portable installations can have their own copy.

When updating manually, remove older copies of this plugin from OBS's other plugin locations. Setup saves the previous files and `Restore.txt` in `FaderSyncPlugin-backups` under `%ProgramData%\obs-studio` or the Portable OBS folder. To restore a previous installer-managed version, run its installer. Your OBS filters, scenes and profiles are kept. The release includes `SHA256SUMS.txt` for the downloads. [OBS plugin locations](https://obsproject.com/kb/legacy-plugin-developer-info)

To uninstall, close OBS and use **Installed apps** for a Setup installation. For a ZIP installation, remove the plugin files listed in the archive from the folder where you extracted them.

## Use the filter

Right-click an OBS audio source, open **Filters**, and add **Sync volume with GoXLR Channel** to **Audio/Video Filters**. Select the GoXLR under **Device** and the fader channel under **Channel**. Keep one sync filter enabled per source because both filters could change the same volume and mute. Multiple sources can follow the same GoXLR channel.

- **Submix** selects A or B when available. With Submix off or a shared output level, the filter uses the common volume and remembers your selection.
- **Volume Offset (dB)** adjusts the level by up to 60 dB in either direction. A fader position with zero gain stays silent at any offset.
- **Mute Behavior** defaults to **Sync OBS mute button**, which follows GoXLR on the OBS mute button. **Manual OBS mute button** silences the source with its volume and leaves the OBS mute button available for manual or Stream Deck control. Mute to All, Stream Mix, and Stream Mix + VOD silence the source. A VOD-only mute leaves the source active.
- **Verbose Logging** adds volume and mute changes to the standard OBS log.

OBS keeps its current volume and mute during a disconnect. Capture the source before GoXLR fader gain so the fader's attenuation is applied once. Chat can apply its own dynamic processing depending on the capture path. The same gain curve is used across models and channels. Measurements covered Game, System, Music, Chat and Sample on GoXLR Full firmware `1.5.1.901`. [Chat measurements](docs/volume-measurements.md#chat-channel-dynamics)

## Development and credits

Use the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) specified in `global.json` and the [Native AOT prerequisites](https://learn.microsoft.com/dotnet/core/deploying/native-aot/#prerequisites). Run `bash scripts/build-linux.sh` on Linux or `./scripts/build-windows.ps1` with PowerShell 7 and [Inno Setup 7](https://jrsoftware.org/isdl.php) on Windows. Use `--install` or `-Install` to install the local build. On Windows, use `-InnoCompiler` if ISCC is installed in a custom location and run the script under your existing PowerShell execution policy.

In Rider, open the solution and choose **Build** or **Build & Install** for your OS. The Windows configurations use `pwsh.exe` from `PATH`.

The [original OBS plugin](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin) was written by Malte Linke (Parzival) and is licensed under the [MIT License](LICENSE). It builds on [goxlr-obs-fader-sync](https://github.com/FrostyCoolSlug/goxlr-obs-fader-sync) by Craig McLure (FrostyCoolSlug), who created GoXLR Utility and helped with the port. Thanks to [NetObsBindings](https://github.com/kostya9/NetObsBindings) for the OBS API bindings. This fork is developed by NOFEXtreme.

Report plugin issues in the [fork's issue tracker](https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/issues). For GoXLR Utility help, see the [GoXLR Utility project](https://github.com/GoXLR-on-Linux/goxlr-utility) or its [Discord](https://discord.gg/QtHQBwnfyW).
