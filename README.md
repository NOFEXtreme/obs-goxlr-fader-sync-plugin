# GoXLR Fader Sync

Use a GoXLR channel to control the volume and mute of an audio source in OBS Studio. This independently maintained fork by **NOFEXtreme** builds on Malte Linke's [original Fader Sync](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin). It follows the measured GoXLR gain curve, reconnects when GoXLR Utility restarts, and includes a Windows installer for both standard and portable OBS.

![Gain by GoXLR fader position for this fork and the original plugin](docs/volume-curve.svg)

The measured model differed by at most **0.002294 dB** in the recorded sweeps. The original line shows its calculated target gain. [Measurements and test conditions](docs/volume-measurements.md)

## Requirements

- [OBS Studio](https://obsproject.com/) 32 or newer, Windows or native Linux x86-64. Linux requires a compatible libobs and glibc 2.34 or newer.
- [GoXLR Utility](https://github.com/GoXLR-on-Linux/goxlr-utility) 1.0 or newer on the OBS computer, with its HTTP server enabled and a GoXLR Full or Mini connected.

## Install or update

Close OBS and download the matching package from [Releases](https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/releases).

| Package | Installation |
| --- | --- |
| `FaderSyncPlugin-win-x64-installer.exe` | Recommended on Windows. Choose the OBS folder and **Installation type**. Select **Portable** if you start OBS with `--portable` without a marker file. |
| `FaderSyncPlugin-win-x64.zip` | OBS 33+ Standard or Steam. Extract to `%ProgramData%\obs-studio\plugins`. |
| `FaderSyncPlugin-win-x64-obs32.zip` | OBS 32 Standard or Steam. Extract to `%ProgramData%\obs-studio\plugins`. |
| `FaderSyncPlugin-win-x64-portable.zip` | Extract to a Portable OBS 32 folder. For Portable OBS 33+, use Setup. |
| `FaderSyncPlugin-linux-x64.zip` | Extract to `obs-studio/plugins` under `$XDG_CONFIG_HOME` (default `~/.config`). |

Existing filters and settings carry over from the original plugin. Windows Setup backs up recognized copies and replaces them with one module for the chosen OBS. Its `FaderSyncPlugin-backups` folder contains `Restore.txt`. For manual updates, remove the previous module if it is in a different location, then extract the new package. Keep one copy per OBS instance. Verify downloads with `SHA256SUMS.txt`.

To remove the plugin, close OBS and use **Installed apps** for a Setup installation. For a ZIP installation, remove the plugin files from the path where you extracted them.

## Use the filter

Open **Filters** for an audio source and add **Sync volume with GoXLR Channel**. Select the **Device** and **Channel**. You can use the same GoXLR channel on several OBS sources. Enable one sync filter per source.

- **Submix** chooses A or B when available and uses the common level for shared outputs or when Submix is off.
- **Volume Offset (dB)** adjusts the level by up to ±60 dB. A silent fader position stays silent.
- **Mute Behavior** controls the OBS mute button in **Sync OBS mute button**. In **Manual OBS mute button**, GoXLR mutes through volume and you can still use the OBS mute button directly or through Stream Deck. Mute to All, Stream Mix and Stream Mix + VOD silence the source. VOD-only mute leaves it active.
- **Verbose Logging** records volume and mute changes in the OBS log.

Volume and mute stay at their current OBS values while Utility is disconnected. Capture audio before GoXLR fader attenuation so the gain is applied once. Chat can apply additional dynamics in the capture path. [Chat measurements](docs/volume-measurements.md#chat-channel-dynamics)

## Build and credits

Use the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) pinned in `global.json` and its [Native AOT prerequisites](https://learn.microsoft.com/dotnet/core/deploying/native-aot/#prerequisites). Run `bash scripts/build-linux.sh` on Linux or `./scripts/build-windows.ps1` with PowerShell 7 and [Inno Setup 7](https://jrsoftware.org/isdl.php) on Windows. Use `--install` or `-Install` to install the local build. Rider provides **Build** and **Build & Install** for both platforms.

Malte Linke (Parzival) wrote the original plugin under the [MIT License](LICENSE), building on Craig McLure's (FrostyCoolSlug) [GoXLR OBS Fader Sync](https://github.com/FrostyCoolSlug/goxlr-obs-fader-sync). The plugin uses [NetObsBindings](https://github.com/kostya9/NetObsBindings). Report plugin issues in the [fork's issue tracker](https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/issues).
