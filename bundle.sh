#!/bin/bash
# Builds WallpaperPicker.app into ./build (no Xcode needed).
#   ./bundle.sh            build
#   ./bundle.sh --install  build, copy to ~/Applications, add the
#                          `wallpaper-picker` command, restart the app
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
    "" | --install) ;;
    *) echo "Unknown option: $1 (use --install or nothing)" >&2; exit 2 ;;
esac

VERSION=0.3.0
BUNDLE_ID=io.github.pruzicka.WallpaperPicker # must match AppInfo.bundleID

# SwiftPM points the linker at two Command Line Tools folders that don't
# exist; the "search path not found" warnings about them are harmless.
# (pipefail still stops the script if the build itself fails.)
# SWIFT_BUILD_FLAGS: extra flags, e.g. --disable-sandbox under Homebrew.
swift build -c release ${SWIFT_BUILD_FLAGS:-} 2>&1 | { grep -v "ld: warning: search path '/Library/Developer/CommandLineTools/Developer" || true; }

APP=build/WallpaperPicker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release ${SWIFT_BUILD_FLAGS:-} --show-bin-path)/WallpaperPicker" "$APP/Contents/MacOS/"

# The icon: every size macOS asks for, from the 1024 px master
# (redraw it with `swift scripts/make-icon.swift Resources/AppIcon.png`).
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
    sips -z $px $px Resources/AppIcon.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wallpaper Picker</string>
    <key>CFBundleDisplayName</key><string>Wallpaper Picker</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>WallpaperPicker</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
