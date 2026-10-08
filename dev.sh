#!/bin/bash
# Builds a debug copy and runs it from here, without installing.
#   ./dev.sh                     open the picker
#   ./dev.sh --dir=~/some/folder use another folder (remembered for dev runs)
# Quit the installed app first, or both will want ⌃⌥W.
set -euo pipefail
cd "$(dirname "$0")"
swift build
exec .build/debug/WallpaperPicker --show "$@"
