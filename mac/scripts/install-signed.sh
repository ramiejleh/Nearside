#!/usr/bin/env bash
# For trying the camera extension (or anything that needs real signing) on this Mac: builds,
# signs with the Developer ID (no notarisation) and installs to /Applications/Nearside.app,
# replacing what's there. macOS only loads camera extensions from /Applications.
#   mac/scripts/install-signed.sh
set -euo pipefail
MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_ID="${NEARSIDE_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$SIGN_ID" ]] || { echo "error: no Developer ID Application identity" >&2; exit 1; }

"$MAC_DIR/scripts/bundle.sh"
"$MAC_DIR/scripts/sign-app.sh" "$MAC_DIR/build/Nearside.app" "$SIGN_ID"
pkill -x Nearside 2>/dev/null || true
rm -rf /Applications/Nearside.app
ditto "$MAC_DIR/build/Nearside.app" /Applications/Nearside.app
echo "Installed /Applications/Nearside.app"
