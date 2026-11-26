#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
package="$root/FaderSyncPlugin/bin/Release/net9.0/linux-x64/package"
if [[ $# -gt 1 || ($# -eq 1 && $1 != --install) ]]; then
    echo "Usage: $0 [--install]" >&2
    exit 2
fi

export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
dotnet publish "$root/FaderSyncPlugin/FaderSyncPlugin.csproj" -c Release -r linux-x64 --self-contained
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
    install -m 644 "$source_dir/LICENSE" "$target_dir/LICENSE"
    install -m 755 "$source_dir/bin/64bit/FaderSyncPlugin.so" "$target_dir/bin/64bit/FaderSyncPlugin.so"
    echo "Plugin installed in $target_dir"
fi
