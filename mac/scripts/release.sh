#!/usr/bin/env bash
# Builds a signed, notarised Nearside release for GitHub.
#
#   mac/scripts/release.sh <version> [--no-notarize]
#     → mac/build/release/Nearside-<version>.zip (+ .sha256)
#
# Nothing personal lives in the repo; everything comes from your environment:
#   NEARSIDE_KEYSTORE        path to the Android release keystore (required)
#   NEARSIDE_KEYSTORE_PASS   its password (required)
#   NEARSIDE_KEY_ALIAS       key alias (default: nearside)
#   NEARSIDE_KEY_PASS        key password (default: the keystore password)
#   NEARSIDE_SIGN_ID         codesign identity (default: the only "Developer ID Application" one)
#   NEARSIDE_NOTARY_PROFILE  notarytool keychain profile (default: nearside)
#
# One-time setup:
#   keytool -genkeypair -v -keystore ~/nearside-release.jks -alias nearside \
#     -keyalg RSA -keysize 4096 -validity 10000          (keep it and its password safe)
#   xcrun notarytool store-credentials nearside --apple-id <id> --team-id <team> --password <app-specific>
#
# --no-notarize signs only (for trying the script before notarisation is set up).
# This doesn't touch the normal development loop (debug APK + bundle.sh).
set -euo pipefail

VERSION="${1:-}"
NOTARIZE=1
[[ "${2:-}" == "--no-notarize" ]] && NOTARIZE=0
if [[ -z "$VERSION" || "$VERSION" == -* ]]; then
  echo "usage: $0 <version> [--no-notarize]   e.g. $0 0.1.0" >&2
  exit 2
fi

fail() { echo "error: $*" >&2; exit 1; }

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(dirname "$MAC_DIR")"
ANDROID_DIR="$REPO_DIR/android"
APP="$MAC_DIR/build/Nearside.app"
OUT="$MAC_DIR/build/release"
ZIP="$OUT/Nearside-$VERSION.zip"
PROFILE="${NEARSIDE_NOTARY_PROFILE:-nearside}"

# --- Checks first, so a release never half-builds. -----------------------------------
[[ -n "${NEARSIDE_KEYSTORE:-}" && -f "$NEARSIDE_KEYSTORE" ]] \
  || fail "set NEARSIDE_KEYSTORE to your Android release keystore (see the top of this script)"
[[ -n "${NEARSIDE_KEYSTORE_PASS:-}" ]] || fail "set NEARSIDE_KEYSTORE_PASS"
# Gradle resolves relative paths from the app module, so hand it an absolute one.
NEARSIDE_KEYSTORE="$(cd "$(dirname "$NEARSIDE_KEYSTORE")" && pwd)/$(basename "$NEARSIDE_KEYSTORE")"
export NEARSIDE_KEYSTORE

SIGN_ID="${NEARSIDE_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  ids="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p')"
  [[ -n "$ids" ]] || fail "no \"Developer ID Application\" identity in your keychain"
  [[ "$(wc -l <<<"$ids")" -eq 1 ]] || fail "several Developer ID identities; pick one with NEARSIDE_SIGN_ID"
  SIGN_ID="$ids"
fi

if [[ $NOTARIZE -eq 1 ]]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "notarytool profile \"$PROFILE\" not found or not working (see the top of this script, or use --no-notarize)"
fi

if [[ -z "${JAVA_HOME:-}" && -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi

# --- Phone app: release build, signed with the release key. ---------------------------
echo "==> Building the phone app (release)"
(cd "$ANDROID_DIR" && ./gradlew --quiet assembleRelease)
APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"
[[ -f "$APK" ]] || fail "release APK missing (was the keystore accepted?)"

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
APKSIGNER="$(ls -d "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
[[ -x "$APKSIGNER" ]] || fail "apksigner not found in $SDK/build-tools"
"$APKSIGNER" verify "$APK" || fail "the release APK isn't properly signed"

# --- Mac app: bundle, then sign with Developer ID and the hardened runtime. ------------
echo "==> Bundling the Mac app $VERSION"
APK="$APK" VERSION="$VERSION" "$MAC_DIR/scripts/bundle.sh"

echo "==> Signing with $SIGN_ID"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

mkdir -p "$OUT"
rm -f "$ZIP" "$ZIP.sha256"

if [[ $NOTARIZE -eq 1 ]]; then
  echo "==> Notarising (usually a few minutes)"
  SUBMIT="$OUT/notarize-upload.zip"
  ditto -c -k --keepParent "$APP" "$SUBMIT"
  if ! xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait | tee "$OUT/notarize.log" \
      | grep -q "status: Accepted"; then
    id="$(sed -n 's/^ *id: //p' "$OUT/notarize.log" | head -1)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
    fail "notarisation was not accepted (log above)"
  fi
  rm -f "$SUBMIT"
  xcrun stapler staple "$APP"
  spctl --assess --type exec -vv "$APP"
else
  echo "==> Skipping notarisation (--no-notarize): Gatekeeper will warn on other Macs"
fi

# --- The download: the stapled app, zipped, with its checksum. ------------------------
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "==> Done: $ZIP"
cat "$ZIP.sha256"
