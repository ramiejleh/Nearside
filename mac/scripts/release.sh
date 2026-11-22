#!/usr/bin/env bash
# Builds a signed, notarised Nearside release for GitHub.
#
#   mac/scripts/release.sh <version> [--no-notarize]
#     → mac/build/release/Nearside-<version>.zip (+ .sha256), the Homebrew cask (nearside.rb),
#       and a new entry at the top of site/appcast.xml (the update feed, served by Pages)
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
#   mac/.build/artifacts/sparkle/Sparkle/bin/generate_keys   (Sparkle's update-signing key: the
#     private half stays in your login keychain; put the public half in bundle.sh)
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

SPARKLE_BIN="$MAC_DIR/.build/artifacts/sparkle/Sparkle/bin"
grep -q '^SPARKLE_PUBLIC_KEY="."' "$MAC_DIR/scripts/bundle.sh" \
  || fail "no Sparkle public key in bundle.sh (run $SPARKLE_BIN/generate_keys once; see the top of this script)"
[[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]] && fail "commit everything first: the build number is the commit count"

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
APK="$APK" VERSION="$VERSION" UPDATES=1 "$MAC_DIR/scripts/bundle.sh"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"

echo "==> Signing with $SIGN_ID"
# Inside out, never --deep: Sparkle's helpers, then the framework, then the app.
sign() { codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
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
SHA="$(cut -d' ' -f1 "$ZIP.sha256")"
URL="https://github.com/ramiejleh/Nearside/releases/download/v$VERSION/$(basename "$ZIP")"

# --- The update feed: a signed entry for this release at the top of site/appcast.xml. -----
echo "==> Adding $VERSION to the update feed"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ZIP")"   # sparkle:edSignature="…" length="…"
PREVIOUS="$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
NOTES="$(git -C "$REPO_DIR" log -n 40 --format='%s' ${PREVIOUS:+"$PREVIOUS..HEAD"} --no-merges \
  | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s#.*#<li>&</li>#')"
ITEM="    <item>
      <title>Nearside $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>
$NOTES
</ul>]]></description>
      <enclosure url=\"$URL\" type=\"application/octet-stream\" $SIGNATURE/>
    </item>"
FEED="$REPO_DIR/site/appcast.xml"
ITEM="$ITEM" python3 - "$FEED" <<'PY'
import os, sys
path = sys.argv[1]
feed = open(path).read()
marker = "<!-- releases: newest first -->"
assert marker in feed, "appcast marker missing"
open(path, "w").write(feed.replace(marker, marker + "\n" + os.environ["ITEM"], 1))
PY

# --- Homebrew: the cask for the ramiejleh/homebrew-tap repository. ---------------------
cat > "$OUT/nearside.rb" <<CASK
cask "nearside" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/ramiejleh/Nearside/releases/download/v#{version}/Nearside-#{version}.zip"
  name "Nearside"
  desc "Your Android phone on your Mac: clipboard, notifications, messages, files and apps"
  homepage "https://ramiejleh.github.io/Nearside/"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Nearside.app"

  zap trash: [
    "~/Library/Application Support/Nearside",
    "~/Library/Preferences/dev.nearside.mac.plist",
    "~/Library/Caches/dev.nearside.mac",
  ]
end
CASK

echo "==> Done: $ZIP (build $BUILD)"
cat "$ZIP.sha256"
cat <<NEXT

Next:
  1. Try the zip: unzip it somewhere, open it, check it connects.
  2. git tag v$VERSION && git push --tags
  3. Make a GitHub release for v$VERSION with the zip and its .sha256.
  4. Commit and push site/appcast.xml (Pages serves it; Macs then see the update).
  5. Copy $OUT/nearside.rb to Casks/ in ramiejleh/homebrew-tap and push.
NEXT
