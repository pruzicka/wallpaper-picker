#!/bin/bash
# Builds WallpaperPicker.app into ./build (no Xcode needed).
#   ./bundle.sh            build
#   ./bundle.sh --install  build, copy to ~/Applications, add the
#                          `wallpaper-picker` command, restart the app
set -euo pipefail
cd "$(dirname "$0")"

VERSION=0.2
BUNDLE_ID=io.github.pruzicka.WallpaperPicker # must match AppInfo.bundleID

# The macOS 27 SDK's SwiftUI needs a macro plugin that only ships with
# Xcode; with just the Command Line Tools, build against the newest SDK
# that doesn't (the app still runs on the current macOS).
if [[ -z "${SDKROOT:-}" ]] && ! xcode-select -p | grep -q Xcode.app; then
    for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
        if [[ -d "$sdk" ]]; then export SDKROOT="$sdk"; break; fi
    done
fi

swift build -c release

APP=build/WallpaperPicker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/WallpaperPicker" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wallpaper Picker</string>
    <key>CFBundleDisplayName</key><string>Wallpaper Picker</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>WallpaperPicker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    TARGET=~/Applications/WallpaperPicker.app
    pkill -x WallpaperPicker 2>/dev/null && sleep 0.5 || true
    mkdir -p ~/Applications
    rm -rf "$TARGET"
    cp -R "$APP" ~/Applications/
    echo "Installed $TARGET"

    # A command for the terminal. It execs the binary inside the app, so
    # the app finds its bundle (a symlink wouldn't).
    BIN=~/.local/bin
    mkdir -p "$BIN"
    printf '#!/bin/sh\nexec "%s/Contents/MacOS/WallpaperPicker" "$@"\n' "$TARGET" > "$BIN/wallpaper-picker"
    chmod +x "$BIN/wallpaper-picker"
    echo "Installed $BIN/wallpaper-picker"

    open "$TARGET"
fi
