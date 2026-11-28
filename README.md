# GoXLR Fader Sync

Control the volume and mute of an OBS audio source with a GoXLR fader. This fork by **NOFEXtreme** continues Malte Linke’s [original Fader Sync](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin) and works with GoXLR Full and Mini.

[Download a release](https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/releases) · [Install](#installation) · [Set up a filter](#using-the-filter)

## What this fork adds

- **Measured volume tracking.** OBS follows the GoXLR gain curve, including full silence at the bottom of the fader.
- **Automatic reconnection.** OBS keeps its current volume and mute state while GoXLR Utility is offline. Sync resumes when Utility reconnects.
- **Windows Setup.** The installer supports Standard and Portable OBS and backs up recognized plugin files during an upgrade.

## Volume comparison

![GoXLR fader gain at zero offset. The NOFEXtreme fork reaches −∞ at the lowest positions. Original Fader Sync shows its calculated target.](docs/volume-curve.svg)

The model matched the recorded GoXLR Full sweeps within **0.002294 dB** on firmware `1.5.1.901`. The dashed line is the original plugin’s calculated target. [Measurement data, method and limits](docs/volume-measurements.md)

## Requirements

- [OBS Studio](https://obsproject.com/) 32 or newer on Windows or native Linux x86-64. Linux needs a compatible `libobs` and glibc 2.34 or newer.
- [GoXLR Utility](https://github.com/GoXLR-on-Linux/goxlr-utility) 1.0 or newer on the OBS computer, with its HTTP server enabled and a GoXLR connected.

## Installation

**Close OBS** before installing or updating. Choose the package from the [release](https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/releases) you want to install.

- **Windows.** Run `FaderSyncPlugin-win-x64-installer.exe`, select your OBS folder, and check **Installation type**. Choose **Portable** if you launch OBS with `--portable` without a marker file.
- **Linux.** Extract `FaderSyncPlugin-linux-x64.zip` into `${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins`.

<details>
<summary>Manual ZIP installation on Windows</summary>

| OBS installation | Package | Extract to |
| --- | --- | --- |
| OBS 33+ Standard or Steam | `FaderSyncPlugin-win-x64.zip` | `%ProgramData%\obs-studio\plugins` |
| OBS 32 Standard or Steam | `FaderSyncPlugin-win-x64-obs32.zip` | `%ProgramData%\obs-studio\plugins` |
| OBS 32 Portable | `FaderSyncPlugin-win-x64-portable.zip` | The Portable OBS folder |

Use Windows Setup for OBS 33+ Portable. For a manual update, remove an older copy if it is installed in a different plugin location. Keep one copy per OBS instance.

</details>

### Updating from the original

Existing filters carry over with their settings. Windows Setup backs up recognized files to `FaderSyncPlugin-backups`, where `Restore.txt` describes the saved files. Use `SHA256SUMS.txt` to verify release downloads.

To uninstall, close OBS and use **Installed apps** for Windows Setup, or remove the plugin files from the folder where you extracted the ZIP.

## Using the filter

1. Start GoXLR Utility and open OBS.
2. Open **Filters** on an audio source and add **Sync volume with GoXLR Channel**.
3. Select the **Device** and **Channel**. Use one active sync filter per source. Several sources can follow the same channel.

| Setting | What it does |
| --- | --- |
| **Submix** | Chooses A or B when available. Shared outputs and channels with Submix off use their common level. |
| **Volume Offset (dB)** | Adjusts the level by up to ±60 dB while preserving silence. |
| **Mute Behavior** | **Sync OBS mute button** controls the button. With **Manual OBS mute button**, GoXLR mutes through volume and the OBS button remains available for manual or Stream Deck control. |
| **Verbose Logging** | Records volume and mute changes in the OBS log. |

GoXLR mute to **All**, **Stream Mix** and **Stream Mix + VOD** silences the source. VOD-only mute leaves it active. Capture audio before GoXLR fader attenuation so the gain is applied once. See the [Chat measurements](docs/volume-measurements.md#chat-channel-dynamics) for details of additional processing in that capture path.

## Development

<details>
<summary>Build from source</summary>

Use the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) pinned in `global.json` and its [Native AOT prerequisites](https://learn.microsoft.com/dotnet/core/deploying/native-aot/#prerequisites).

- **Windows.** Run `./scripts/build-windows.ps1` with PowerShell 7 and [Inno Setup 7](https://jrsoftware.org/isdl.php). Pass `-Install` to install the local build.
- **Linux.** Run `bash scripts/build-linux.sh`. Pass `--install` to install the local build.

Rider provides **Build** and **Build & Install** for both platforms.

</details>

Report plugin issues in the [fork’s issue tracker](https://github.com/NOFEXtreme/obs-goxlr-fader-sync-plugin/issues).

## Credits

Malte Linke (Parzival) wrote the [original plugin](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin) under the [MIT License](LICENSE), building on Craig McLure’s (FrostyCoolSlug) [GoXLR OBS Fader Sync](https://github.com/FrostyCoolSlug/goxlr-obs-fader-sync). This fork is maintained by NOFEXtreme and uses [NetObsBindings](https://github.com/kostya9/NetObsBindings).
