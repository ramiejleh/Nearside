#!/usr/bin/env bash
# For trying the camera extension (or anything that needs real signing) on this Mac: builds,
# signs with the Developer ID, notarises (macOS won't load a system extension that isn't, even
# here; a few minutes) and installs to /Applications/Nearside.app, replacing what's there. macOS
# only loads camera extensions from /Applications. Uses release.sh's notary profile.
#   mac/scripts/install-signed.sh
set -euo pipefail
MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_ID="${NEARSIDE_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$SIGN_ID" ]] || { echo "error: no Developer ID Application identity" >&2; exit 1; }

"$MAC_DIR/scripts/bundle.sh"
APP="$MAC_DIR/build/Nearside.app"
"$MAC_DIR/scripts/sign-app.sh" "$APP" "$SIGN_ID" --timestamp

echo "==> Notarising (usually a few minutes)"
SUBMIT="$MAC_DIR/build/notarize-test.zip"
LOG="$MAC_DIR/build/notarize-test.log"
rm -f "$SUBMIT"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "${NEARSIDE_NOTARY_PROFILE:-nearside}" --wait | tee "$LOG" || true
rm -f "$SUBMIT"
grep -q "status: Accepted" "$LOG" || { echo "error: notarisation failed (see $LOG; notarytool log <id> for why)" >&2; exit 1; }
xcrun stapler staple "$APP"
pkill -x Nearside 2>/dev/null || true
rm -rf /Applications/Nearside.app
ditto "$MAC_DIR/build/Nearside.app" /Applications/Nearside.app
echo "Installed /Applications/Nearside.app"
