# GoXLR Fader Sync Plugin
An OBS Studio Plugin that enables synchronizing the volume slider of an audio source with an audio channel from your GoXLR. 
This allows you to manage the volume of audio sources using the GoXLR's faders.

This plugin is essentially a port of the [goxlr-obs-fader-sync](https://github.com/FrostyCoolSlug/goxlr-obs-fader-sync) 
project developed by [FrostyCoolSlug](https://github.com/FrostyCoolSlug) into an OBS plugin.

If you need help or encounter any problems, feel free to join the [GoXLR Utility Discord](https://discord.gg/QtHQBwnfyW) 
or create a [new Issue](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin/issues/new) in the Issues section.

> [!NOTE]  
> Version [1.3.1](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin/releases/tag/v1.3.1) is currently the last update containing new features. 
> I consider this plugin feature complete and since I don't own a GoXLR anymore I don't have any reason to continue working on it.
> If there are any new breaking changes in OBS, I will patch this plugin to continue working but for now this project is in maintenance only mode.
>
> Thank you all for using my plugin.

## Requirements
* [OBS Studio](https://obsproject.com/) v32.0 or a newer version with a compatible plugin API
* [GoXLR Utility](https://github.com/GoXLR-on-Linux/goxlr-utility) v1.0.0+

Note: The plugin reports the OBS API version it was built against.

### Additional Requirements for Development
If you plan on contributing to this project, you will also need a working [.Net SDK](https://dotnet.microsoft.com/en-us/download/dotnet/9.0) 9.0+ installation as well as all
other .NET Native AOT requirements. 
You can find a detailed list and installation instructions [here](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/?tabs=net8plus%2Cwindows#prerequisites).

The build scripts in the scripts directory create the release packages. Windows also requires [Inno Setup 7](https://jrsoftware.org/isdl.php). Use `-Install` on Windows or `--install` on Linux to install a local build.

## Installation

Detailed Installation Instructions can be found in the [Wiki Pages](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin/wiki/Installation).

Pre-built binaries are available in the Releases section.

| File | Installation |
| --- | --- |
| `FaderSyncPlugin-win-x64-installer.exe` | The setup wizard detects OBS Studio and selects the matching layout. It backs up the plugin before replacing previous copies. Use Windows Installed apps to uninstall. |
| `FaderSyncPlugin-win-x64.zip` | OBS 33+. Extract to `%ProgramData%\obs-studio\plugins`. |
| `FaderSyncPlugin-win-x64-obs32.zip` | OBS 32. Extract to `%ProgramData%\obs-studio\plugins`. |
| `FaderSyncPlugin-win-x64-portable.zip` | Portable legacy layout. Extract to the OBS installation root. For the new OBS 33+ Portable layout, use the installer. |
| `FaderSyncPlugin-linux-x64.zip` | Extract to `~/.config/obs-studio/plugins`. |

Close OBS before installing. When upgrading manually, remove previous copies of this plugin from the installation's other plugin locations.
[OBS plugin paths](https://obsproject.com/kb/legacy-plugin-developer-info)

## Usage-Guide
Please refer to the [Wiki Pages](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin/wiki/Usage-Guide).

The same measured gain curve is used for all GoXLR models and channels. Hardware measurements covered Game, Music, System, Sample and Chat on GoXLR Full firmware 1.5.1.901.
OBS keeps its current volume and mute state while GoXLR status is unavailable.
Chat may apply additional dynamic processing, so the result depends on the audio capture path. Capture the OBS source before the GoXLR fader so its gain is applied once.

## Contributing
Contributions to this project are welcome. 
Use the build scripts above to build and install the plugin for local testing.

To contribute, follow these steps:
1. [Fork](https://github.com/parzival-space/obs-goxlr-fader-sync-plugin/fork) this repository.
2. Create a new feature branch.
3. Make your changes.
4. Create a pull request.

## Special Thanks
Special thanks to the following individuals who made this project possible:
* <b>[FrostyCoolSlug](https://github.com/FrostyCoolSlug)</b>: For creating the GoXLR Utility and assisting in the creation of this plugin.
* <b>[NetObsBindings Project](https://github.com/kostya9/NetObsBindings)</b>: For creating the .NET bindings for the OBS API.



