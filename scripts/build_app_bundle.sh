#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GPTransfer"
LEGACY_APP_NAME="Camera Transfer"
LEGACY_SPACED_APP_NAME="GP Transfer"
EXECUTABLE_NAME="GoProUsbTransferTestApp"
HELPER_BUILD_NAME="CameraTransferAutoLauncher"
HELPER_EXECUTABLE_NAME="GPTransfer AutoLauncher"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$DIST_DIR/$LEGACY_APP_NAME.app"
rm -rf "$DIST_DIR/$LEGACY_SPACED_APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$ROOT_DIR/.build/release/$HELPER_BUILD_NAME" "$MACOS_DIR/$HELPER_EXECUTABLE_NAME"
cp "$ROOT_DIR/Resources/GPTransferAppIcon.icns" "$RESOURCES_DIR/GPTransferAppIcon.icns"
cp "$ROOT_DIR/Resources/GPTransferHeaderLogo.png" "$RESOURCES_DIR/GPTransferHeaderLogo.png"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>local.gp-transfer.gp-transfer-4gb</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>GPTransferAppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Connect to your camera on the local network to copy files to this Mac.</string>
</dict>
</plist>
PLIST

echo "$APP_DIR"
