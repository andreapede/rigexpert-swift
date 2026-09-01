#!/bin/bash
# Builds RigXSwift.app.
#
# There is no .xcodeproj on purpose: the package is the source of truth, and the bundle
# is assembled around the executable SwiftPM produces. Xcode can still open Package.swift
# directly for previews and debugging.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="build/RigXSwift.app"

if [ -d /Applications/Xcode.app ] && [ "$(xcode-select -p)" != "/Applications/Xcode.app/Contents/Developer" ]; then
  # SwiftUI needs Xcode's toolchain; use it without changing the system-wide selection.
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product RigXSwiftApp

# --show-bin-path also writes progress lines to stdout, so keep only the last one:
# an unfiltered command substitution yields a path with build chatter glued to the front.
BIN="$(swift build -c "$CONFIG" --product RigXSwiftApp --show-bin-path 2>/dev/null | tail -1)"
test -x "$BIN/RigXSwiftApp" || { echo "executable not found in $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/RigXSwiftApp" "$APP/Contents/MacOS/RigXSwift"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>RigXSwift</string>
    <key>CFBundleDisplayName</key><string>RigXSwift</string>
    <key>CFBundleIdentifier</key><string>com.andreapede.RigXSwift</string>
    <key>CFBundleExecutable</key><string>RigXSwift</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. A Developer ID and notarization are only
# needed to hand the app to someone else.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Done: $APP"
