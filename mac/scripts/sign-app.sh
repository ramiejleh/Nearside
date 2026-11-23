#!/usr/bin/env bash
# Signs Nearside.app inside out (never --deep) with a Developer ID and the hardened runtime:
# Sparkle's helpers, the framework, the camera extension, then the app.
#   sign-app.sh <Nearside.app> <identity> [--timestamp]
# With the camera extension inside, its Developer ID provisioning profiles are embedded from
# $NEARSIDE_PROFILES (default ~/nearside-profiles: app.provisionprofile, camera.provisionprofile).
set -euo pipefail

APP="$1"
SIGN_ID="$2"
TIMESTAMP="${3:-}"
MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES="${NEARSIDE_PROFILES:-$HOME/nearside-profiles}"

sign() { codesign --force --options runtime $TIMESTAMP --sign "$SIGN_ID" "$@"; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"

EXT="$APP/Contents/Library/SystemExtensions/dev.nearside.mac.camera.systemextension"
ENTITLEMENTS="$MAC_DIR/Nearside.entitlements"
if [[ -d "$EXT" ]]; then
  cp "$PROFILES/camera.provisionprofile" "$EXT/Contents/embedded.provisionprofile"
  sign --entitlements "$MAC_DIR/NearsideCamera.entitlements" "$EXT"
  cp "$PROFILES/app.provisionprofile" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="$MAC_DIR/NearsideWebcam.entitlements"
fi
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=2 "$APP"
