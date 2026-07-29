#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${TMPDIR:-/tmp}/ccbar-manual-build"
APP_BUNDLE="$BUILD_ROOT/CCBar.app"
INSTALL_PATH="/Applications/CCBar.app"
BACKUP_PATH="$BUILD_ROOT/CCBar.previous.app"

SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macos14.0"

rm -rf "$BUILD_ROOT"
mkdir -p \
  "$BUILD_ROOT/Generated" \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Resources" \
  "$APP_BUNDLE/Contents/Helpers"

cat > "$BUILD_ROOT/Generated/AssetFallbacks.swift" <<'SWIFT'
import SwiftUI
import AppKit

extension Color {
    static let codexAccent = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(
            calibratedRed: (isDark ? 152 : 108) / 255,
            green: (isDark ? 152 : 108) / 255,
            blue: (isDark ? 157 : 112) / 255,
            alpha: 1
        )
    })

    static let claudeAccent = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(
            calibratedRed: (isDark ? 230 : 217) / 255,
            green: (isDark ? 138 : 119) / 255,
            blue: (isDark ? 110 : 87) / 255,
            alpha: 1
        )
    })
}
SWIFT

sources=()
while IFS= read -r source; do
  sources+=("$source")
done < <(find "$ROOT" -name '*.swift' ! -path "$ROOT/Helpers/*" -print | sort)

xcrun swiftc -O -sdk "$SDK" -target "$TARGET" -parse-as-library \
  "${sources[@]}" "$BUILD_ROOT/Generated/AssetFallbacks.swift" \
  -o "$APP_BUNDLE/Contents/MacOS/CCBar"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>CCBar</string>
    <key>CFBundleExecutable</key>
    <string>CCBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.nanvon.ccbar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CCBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.9.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string></string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

cp "$ROOT/Resources/Logos/codex.svg" "$APP_BUNDLE/Contents/Resources/codex.svg"
cp "$ROOT/Resources/Logos/claude.svg" "$APP_BUNDLE/Contents/Resources/claude.svg"
cp "$ROOT/Resources/MenuBarIcon/menubar-22.png" "$APP_BUNDLE/Contents/Resources/menubar-22.png"
cp "$ROOT/Resources/MenuBarIcon/menubar-44.png" "$APP_BUNDLE/Contents/Resources/menubar-44.png"

ICONSET="$BUILD_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_16.png" "$ICONSET/icon_16x16.png"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_32.png" "$ICONSET/icon_16x16@2x.png"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_32.png" "$ICONSET/icon_32x32.png"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_128.png" "$ICONSET/icon_128x128.png"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" "$ICONSET/icon_256x256.png"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_512.png" "$ICONSET/icon_512x512.png"
cp "$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

xcrun swiftc -O -sdk "$SDK" -target "$TARGET" \
  "$ROOT/Helpers/CCBarClaudeWatchdog/main.swift" \
  -o "$APP_BUNDLE/Contents/Helpers/CCBarClaudeWatchdog"

codesign --force --sign - --options runtime --timestamp=none \
  "$APP_BUNDLE/Contents/Helpers/CCBarClaudeWatchdog"
codesign --force --deep --sign - --options runtime --timestamp=none \
  --entitlements "$ROOT/CCBar.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

if pgrep -x CCBar >/dev/null 2>&1; then
  pkill -x CCBar
  for _ in $(seq 1 20); do
    if ! pgrep -x CCBar >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
fi

if [ -d "$INSTALL_PATH" ]; then
  rm -rf "$BACKUP_PATH"
  ditto "$INSTALL_PATH" "$BACKUP_PATH"
  rm -rf "$INSTALL_PATH"
fi

ditto "$APP_BUNDLE" "$INSTALL_PATH"
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
codesign --verify --deep --strict "$INSTALL_PATH"
open "$INSTALL_PATH"

for _ in $(seq 1 30); do
  if pgrep -x CCBar >/dev/null 2>&1; then
    pgrep -fl CCBar
    exit 0
  fi
  sleep 0.5
done

echo "CCBar did not appear in the process list after launch." >&2
exit 1
