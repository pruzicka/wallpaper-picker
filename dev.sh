#!/bin/bash
# Builds a debug copy and runs it from here, without installing.
#   ./dev.sh                     open the picker
#   ./dev.sh --dir=~/some/folder use another folder (remembered for dev runs)
# Quit the installed app first, or both will want ⌃⌥W.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -z "${SDKROOT:-}" ]] && ! xcode-select -p | grep -q Xcode.app; then
    for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
        if [[ -d "$sdk" ]]; then export SDKROOT="$sdk"; break; fi
    done
fi
swift build
exec .build/debug/WallpaperPicker --show "$@"
