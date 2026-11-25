#!/bin/bash
# Runs the tests (swift test), with or without Xcode.
#   ./test.sh                 everything
#   ./test.sh --filter Rotation
set -euo pipefail
cd "$(dirname "$0")"

# With only the Command Line Tools, SwiftPM sometimes doesn't hand the
# compiler Swift Testing's macro plugin ("plugin for module 'TestingMacros'
# not found"); point it there.
FLAGS=()
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ $(xcode-select -p) == /Library/Developer/CommandLineTools && -d $PLUGINS ]]; then
    FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
fi

swift test "${FLAGS[@]}" "$@" 2>&1 | { grep -v "ld: warning: search path '/Library/Developer/CommandLineTools/Developer" || true; }
