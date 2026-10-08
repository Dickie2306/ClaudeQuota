#!/bin/zsh
# Build ClaudeQuota.app from Sources/main.swift and install it to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeQuota"
BUNDLE_ID="com.michaeldickerson.claudequota"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compiling…"
swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.2.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
echo "APPL????" > "$APP/Contents/PkgInfo"

mkdir -p "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"

# Prefer the stable "ClaudeQuota Dev" identity (keeps Keychain "Always Allow"
# valid across rebuilds); fall back to ad-hoc if it doesn't exist.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ClaudeQuota Dev"; then
    SIGN_ID="ClaudeQuota Dev"
else
    SIGN_ID="-"
    echo "note: signing ad-hoc (no 'ClaudeQuota Dev' certificate found) — Keychain will re-prompt after each rebuild"
fi
codesign --force --sign "$SIGN_ID" "$APP"

DEST="/Applications/$APP_NAME.app"
if [[ -w /Applications ]]; then
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
else
    DEST="$HOME/Applications/$APP_NAME.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
fi
echo "Installed to $DEST"
echo "Run with: open \"$DEST\""
