#!/usr/bin/env bash
# Builds Nearside.app (menu-bar only) with the Android APK embedded.
#   mac/scripts/bundle.sh            → mac/build/Nearside.app
# Requires the APK to be built first: (cd android && ./gradlew assembleDebug)
# release.sh sets APK (the release APK) and VERSION; normal builds use the defaults.
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(dirname "$MAC_DIR")"
APK="${APK:-$REPO_DIR/android/app/build/outputs/apk/debug/app-debug.apk}"
APP="$MAC_DIR/build/Nearside.app"
VERSION="${VERSION:-0.1.0}"

if [[ ! -f "$APK" ]]; then
  echo "error: APK not found at $APK" >&2
  echo "       build it with: (cd android && ./gradlew assembleDebug)" >&2
  exit 1
fi

# The APK's versionCode, from Gradle's output-metadata.json beside it: the Mac updates a phone
# whose installed app is older than this.
APK_VERSION="$(plutil -extract elements.0.versionCode raw "$(dirname "$APK")/output-metadata.json" 2>/dev/null || echo 0)"

cd "$MAC_DIR"
swift build -c release --product Nearside
BIN="$(swift build -c release --product Nearside --show-bin-path)/Nearside"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nearside"
cp "$APK" "$APP/Contents/Resources/nearside.apk"
# Made by scripts/make-icon.swift (re-run it to change the icon).
cp "$MAC_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nearside</string>
  <key>CFBundleDisplayName</key><string>Nearside</string>
  <key>CFBundleIdentifier</key><string>dev.nearside.mac</string>
  <key>CFBundleExecutable</key><string>Nearside</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NearsidePhoneAppVersion</key><integer>$APK_VERSION</integer>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu-bar app: no Dock icon or menus until a phone-app window opens. -->
  <key>LSUIElement</key><true/>
  <!-- nearside://open?package=… : the phone-app launchers in ~/Applications (PhoneAppLaunchers). -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>dev.nearside.mac.phone-app</string>
      <key>CFBundleURLSchemes</key><array><string>nearside</string></array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>AGPL-3.0-or-later</string>
  <!-- Wireless debugging: find the phone over Bonjour and connect to it on this network. -->
  <key>NSLocalNetworkUsageDescription</key><string>Nearside connects to your Android phone over this Wi-Fi network (Wireless debugging).</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_adb-tls-connect._tcp</string>
    <string>_adb-tls-pairing._tcp</string>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will run it locally. Release builds need a Developer ID + notarization.
codesign --force --sign - "$APP"
echo "Built $APP"
