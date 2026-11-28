#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
package="$root/FaderSyncPlugin/bin/Release/net10.0/linux-x64/package"
if [[ $# -gt 1 || ($# -eq 1 && $1 != --install) ]]; then
    echo "Usage: $0 [--install]" >&2
    exit 2
fi

export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
version=()
if [[ -n ${FADERSYNC_VERSION:-} ]]; then version=(-p:Version="$FADERSYNC_VERSION"); fi
dotnet publish "$root/FaderSyncPlugin/FaderSyncPlugin.csproj" -c Release -r linux-x64 --self-contained "${version[@]}"
test -s "$package/FaderSyncPlugin-linux-x64.zip"
echo "Package is in $package"

if [[ $# -eq 1 ]]; then
    if pgrep -x obs >/dev/null; then
        echo "Close OBS Studio before installing the plugin." >&2
        exit 1
    fi
    source_dir="$package/FaderSyncPlugin-linux-x64/FaderSyncPlugin"
    target_dir="${XDG_CONFIG_HOME:-$HOME/.config}/obs-studio/plugins/FaderSyncPlugin"
    install -d "$target_dir/bin/64bit" "$target_dir/data"
    license_stage=$(mktemp -d "$target_dir/.fadersync-XXXXXX")
    binary_stage=''
    trap 'rm -rf -- "$license_stage" "${binary_stage:-$license_stage}"' EXIT
    binary_stage=$(mktemp -d "$target_dir/bin/64bit/.fadersync-XXXXXX")
    install -m 644 "$source_dir/LICENSE" "$license_stage/LICENSE"
    install -m 755 "$source_dir/bin/64bit/FaderSyncPlugin.so" "$binary_stage/FaderSyncPlugin.so"
    if [[ -e "$target_dir/LICENSE" || -L "$target_dir/LICENSE" ]]; then
        cp -P --preserve=mode,timestamps -- "$target_dir/LICENSE" "$license_stage/previous-license"
    fi
    mv -fT -- "$license_stage/LICENSE" "$target_dir/LICENSE"
    if ! mv -fT -- "$binary_stage/FaderSyncPlugin.so" "$target_dir/bin/64bit/FaderSyncPlugin.so"; then
        if [[ -e "$license_stage/previous-license" || -L "$license_stage/previous-license" ]]; then
            mv -fT -- "$license_stage/previous-license" "$target_dir/LICENSE"
        else
            rm -f -- "$target_dir/LICENSE"
        fi
        exit 1
    fi
    echo "Plugin installed in $target_dir"
fi
