# GoXLR Fader Sync Plugin

Control the volume of an OBS audio source with any GoXLR channel. Add the plugin as a filter to each source you want to control. This fork uses a measured GoXLR gain curve, reconnects when GoXLR Utility restarts, and includes a Windows installer that backs up previous copies of the plugin before replacing them.

## Requirements

- [OBS Studio](https://obsproject.com/) 32 or newer with a compatible plugin API, on Windows or Linux x86-64.
- [GoXLR Utility](https://github.com/GoXLR-on-Linux/goxlr-utility) 1.0 or newer, running on the OBS computer with a GoXLR Full or Mini connected.

## Install or update

Close OBS and download a package from [Releases](https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/releases).

| Package | Where to install |
| --- | --- |
| `FaderSyncPlugin-win-x64-installer.exe` | Recommended on Windows. Setup detects standard, Steam and Portable installations and chooses the layout for your OBS version. Use **Installed apps** to uninstall. |
| `FaderSyncPlugin-win-x64.zip` | OBS 33+ standard or Steam. Extract to `%ProgramData%\obs-studio\plugins`. |
| `FaderSyncPlugin-win-x64-obs32.zip` | OBS 32 standard or Steam. Extract to `%ProgramData%\obs-studio\plugins`. |
| `FaderSyncPlugin-win-x64-portable.zip` | Portable legacy layout. Extract to the OBS installation folder. Use Setup for the new OBS 33+ Portable layout. |
| `FaderSyncPlugin-linux-x64.zip` | Extract to `${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins` for a native OBS installation. |

When updating manually, remove older copies of this plugin from OBS's other plugin locations. Setup saves the previous files and `Restore.txt` in `FaderSyncPlugin-backups` under `%ProgramData%\obs-studio` or the Portable OBS folder. Your OBS filters, scenes and profiles are kept. The release includes `SHA256SUMS.txt` for the downloads. [OBS plugin locations](https://obsproject.com/kb/legacy-plugin-developer-info)

## Use the filter

Right-click an OBS audio source, open **Filters**, and add **Sync volume with GoXLR Channel** to **Audio/Video Filters**. Select the GoXLR under **Device** and the fader channel under **Channel**. You can control any OBS audio source with any of the supported GoXLR channels.

- **Submix** selects A or B when available. With Submix off or a shared output level, the filter uses the common volume and remembers your selection.
- **Volume Offset (dB)** adjusts the level by up to 60 dB in either direction. A fader position with zero gain stays silent at any offset.
- **Mute Behavior** defaults to **Sync OBS mute button**, which follows GoXLR on the OBS mute button. **Manual OBS mute button** silences the source with its volume and leaves the OBS mute button available for manual or Stream Deck control. Mute to All, Stream Mix, and Stream Mix + VOD silence the source. A VOD-only mute leaves the source active.
- **Verbose Logging** adds volume and mute changes to the standard OBS log.

OBS keeps its current volume and mute during a disconnect. Capture the source before GoXLR fader gain so the fader's attenuation is applied once. Chat can apply its own dynamic processing, so the result depends on the capture path. The same gain curve is used across models and channels. Measurements covered Game, System, Music, Chat, and Sample on GoXLR Full firmware `1.5.1.901`.

## Development and credits

Use [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) and the [Native AOT prerequisites](https://learn.microsoft.com/dotnet/core/deploying/native-aot/#prerequisites). Run `scripts/build-linux.sh` on Linux or `scripts/build-windows.ps1` with PowerShell 7 and [Inno Setup 7](https://jrsoftware.org/isdl.php) on Windows. Use `--install` or `-Install` to install the local build.

The [original OBS plugin](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin) was written by Malte Linke (Parzival) and is licensed under the [MIT License](LICENSE). It builds on [goxlr-obs-fader-sync](https://github.com/FrostyCoolSlug/goxlr-obs-fader-sync) by Craig McLure (FrostyCoolSlug), who created GoXLR Utility and helped with the port. Thanks to [NetObsBindings](https://github.com/kostya9/NetObsBindings) for the OBS API bindings. This fork is developed by NOFEXtreme.

Report plugin issues in the [fork's issue tracker](https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/issues). For GoXLR Utility help, see the [GoXLR Utility project](https://github.com/GoXLR-on-Linux/goxlr-utility) or its [Discord](https://discord.gg/QtHQBwnfyW).
