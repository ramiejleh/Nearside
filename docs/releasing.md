# Releasing

A release is one version number for everything: the Mac app, the Windows installers and the phone
app inside both. It's a GitHub release with every file, plus the update feeds on the website.
Nothing secret lives in the repo. Keys, certificates and passwords stay with the maintainer, and
the scripts read them from the environment or the keychain.

## One-time setup

### Phone app

- **Android release key**: `keytool -genkeypair -v -keystore ~/nearside-release.jks -alias
  nearside -keyalg RSA -keysize 4096 -validity 10000`. Every future phone-app update must be
  signed with it. Lose it and users have to reinstall, so back it up. `mac/scripts/release.sh`
  uses it (see the top of that script) and builds the release APK that both platforms ship.

### Mac

- A **Developer ID Application** certificate, and a notarytool profile:
  `xcrun notarytool store-credentials nearside --apple-id <id> --team-id <team>`.
- The team ID in `mac/scripts/team-id`. For the webcam, the provisioning profiles in
  `~/nearside-profiles/` (see [development-mac.md](development-mac.md#signed-builds-the-webcam)).
- The **Sparkle update key**: `mac/.build/artifacts/sparkle/Sparkle/bin/generate_keys`. The
  private key stays in the login keychain (back it up); the public key goes in
  `SPARKLE_PUBLIC_KEY` in `mac/scripts/bundle.sh`.
- A **Homebrew tap** (`<owner>/homebrew-tap`) for `brew install --cask`.

### Windows

- A **code-signing certificate**. Without one, SmartScreen warns about every installer. It goes in
  the certificate store (a USB token's or a cloud signing service's driver puts it there), and its
  SHA-1 thumbprint in `NEARSIDE_SIGN_CERT`. `NEARSIDE_TIMESTAMP_URL` sets the timestamp server.
- The **WinSparkle update key**: after one build of the app, run `winsparkle-tool generate-key
  --file %USERPROFILE%\nearside-winsparkle.key` (it's in
  `%USERPROFILE%\.nuget\packages\winsparkle\0.9.4\tools`). Keep the file safe. Put the public key
  it prints in `PublicKey` in `windows/App/Updates.cs`; until then the app doesn't check for updates.
- On the PC that builds: Inno Setup 7, the Swift toolchain, the Visual Studio Build Tools (C++
  for x64 and ARM64), the .NET 10 SDK, and FFmpeg's shared LGPL builds for both architectures (see
  the top of `windows/scripts/release.ps1`).
- A fork of `microsoft/winget-pkgs`, for the winget manifests.

### Website

- GitHub Pages on (Settings → Pages → Source: GitHub Actions). It serves the website and both
  update feeds (`site/appcast.xml`, `site/appcast-windows.xml`).

## Each release

1. **Version.** Set `versionName` in `android/app/build.gradle.kts`, and commit everything. The
   phone app's `versionCode` is the number of commits, so build both platforms from the same
   commit.
2. **Mac** (on a Mac): `mac/scripts/release.sh <version>`. It builds the release APK, then the
   app, signs, notarises and zips it. Out come `mac/build/release/Nearside-<version>.zip` (and
   `.sha256`), the Homebrew cask, and a new entry at the top of `site/appcast.xml`.
3. **Windows** (on a PC): copy the release APK from step 2 with Gradle's
   `output-metadata.json` beside it (it has the `versionCode`). Then:
   `windows\scripts\release.ps1 -Version <version> -Apk <app-release.apk>`.
   Out come `Nearside-<version>-x64.exe` and `-arm64.exe` (signed, with `.sha256`), a new entry
   at the top of `site/appcast-windows.xml`, and winget manifests.
4. **Try them.** Install each on a clean account, check that it connects, and check that the
   phone app updates.
5. **Tag and publish.** Tag `v<version>`, push the tag, and make a GitHub release with the zip,
   both installers and their checksums, plus the copies under fixed names the scripts make
   (`Nearside-mac.zip`, `Nearside-windows-x64.exe`, `Nearside-windows-arm64.exe`). The website's
   and README's download buttons link to `releases/latest/download/<that name>`, so they always
   get the newest release.
6. **Then the feeds.** Commit both appcast entries and push to `main`; Pages publishes them.
   Never before the release exists, or computers fetch a missing file.
7. **Package managers.** Copy the cask into the tap's `Casks/`, and open a pull request to
   `microsoft/winget-pkgs` with the manifests.

`release.ps1 -NoSign -NoFeed -Build <n>` and `release.sh <version> --no-notarize` try the scripts
without the certificates or the feeds.

## What users see

- Each app checks its feed by itself (Sparkle on the Mac, WinSparkle on Windows) and shows what's
  new; **Check for Updates** checks at once.
- A new computer app updates the phone app the next time it connects, if the phone's is older
  (never a downgrade).
- A phone app installed from another build (built from source, or a debug build) can't be
  updated in place, because Android requires the same signing key. The panel then says "Nearside
  on ‹phone› needs updating" with **Reinstall**, which swaps it and grants its permissions again.
