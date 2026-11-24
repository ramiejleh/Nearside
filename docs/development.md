# Development

## Build and run

Needs Xcode 26 or later and Android Studio (its bundled JDK; a newer system JDK is too new for Gradle).

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
(cd android && ./gradlew assembleDebug)   # phone app + helper (one APK)
mac/scripts/bundle.sh                     # → mac/build/Nearside.app, APK inside
open mac/build/Nearside.app
```

The Mac app installs and updates the phone app itself. While iterating on the phone side:

```sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell 'kill $(pidof nearside-helper)'     # the Mac starts the new helper within seconds
```

Logs:

- Helper: `adb shell cat /data/local/tmp/nearside-helper.log`
- Mac: `/usr/bin/log show --last 10m --predicate 'subsystem == "dev.nearside.mac"'`
  (in zsh, plain `log` is a shell builtin)

### Signed builds (the webcam)

macOS only loads the camera extension ("Nearside Camera") from a build that is signed with a
Developer ID, carries provisioning profiles allowing a system extension, is notarised, and sits
in /Applications. Plain builds leave the extension out and work otherwise.

To build it yourself you need your own Apple developer account:

1. Identifiers: App IDs `dev.nearside.mac` (with the System Extension capability) and
   `dev.nearside.mac.camera` (or your own IDs, changed throughout).
2. Profiles: a Developer ID profile for each, saved as `~/nearside-profiles/app.provisionprofile`
   and `~/nearside-profiles/camera.provisionprofile`.
3. Your team ID in `mac/scripts/team-id`, and a notarytool profile (`xcrun notarytool
   store-credentials nearside`).
4. `mac/scripts/install-signed.sh`: builds, signs, notarises (a few minutes) and installs to
   /Applications. Then Settings › Phone camera, and allow it in System Settings › General ›
   Login Items & Extensions.

Its logs: `/usr/bin/log show --last 5m --predicate 'category == "webcam" OR (process ==
"dev.nearside.mac.camera" AND category == "camera")'`. Info-level lines only show live
(`log stream --level info`).

## Tests

- `cd core && swift test`: protocol encoding and decoding, input mapping, key map, sizes, the
  audio jitter buffer, clipboard history, adb key format and more.
- `cd mac && swift test`: the Mac parts (a real Opus round trip, quarantine).
- Live tests against a phone are opt-in: `cd core && NEARSIDE_DEVICE=<ip:port> swift test`
  (`NEARSIDE_INSTALL_APK=<apk>` adds the install test).

## Test hooks

The Mac app reads these environment variables when started directly
(`mac/build/Nearside.app/Contents/MacOS/Nearside`), so phone-app windows can be tested
without clicking:

| Variable | Effect |
|---|---|
| `NEARSIDE_OPEN_APP` | Open windows on launch: comma-separated `pkg`, `pkg/activity` or `phone` (the phone window) |
| `NEARSIDE_OPEN_APP_DELAY` | Seconds to wait before opening |
| `NEARSIDE_TEST_WINDOW` | An app window saves its chrome (toolbar, corners) to this PNG once showing |
| `NEARSIDE_OPEN_APP_GAP` | Seconds between the windows in `NEARSIDE_OPEN_APP` (default 4) |
| `NEARSIDE_OPEN_NOTIFICATION` | Open a notification key in a window |
| `NEARSIDE_TRACE` | Write a trace (frames, delays, audio, stats) to this file, and the shown picture to `<file>.png` once a second |
| `NEARSIDE_TEST_INPUT` | Drive a window: `tap`, `click`, `scroll`, `wheel`, `pinch`, `mouse`, `type`, `keys`, `copy`, `paste`, `resize`, `size`, `hide`, `close`, `drop` |
| `NEARSIDE_TEST_TAP` | `x,y` (0…1 of the window) for `tap` |
| `NEARSIDE_TEST_TEXT` | Text for `type` |
| `NEARSIDE_TEST_SIZE`, `NEARSIDE_TEST_SIZE2` | `WxH` in points, or `phone`, `foldable`, `tablet`, for `size` (the second 8 s later) |
| `NEARSIDE_TEST_CLOSE_AFTER` | Seconds before `close` / how long `hide` lasts |
| `NEARSIDE_TEST_HIDE_AFTER` | Seconds before `hide` minimises the window (default 0) |
| `NEARSIDE_TEST_FILE` | File for `drop` |
| `NEARSIDE_TEST_PHONE` | Phone window: `recents`, `notifications`, `close`, `bar`, `drag` |
| `NEARSIDE_TEST_DISMISS` | With `NEARSIDE_TEST_PHONE=notifications`: dismiss the first notification from this app |
| `NEARSIDE_TEST_WAIT` | Seconds before the phone-window test runs |
| `NEARSIDE_TEST_DEMO_NOTIFICATIONS` | `1`: with `NEARSIDE_TEST_PHONE=notifications`, the panel shows made-up notifications (for pictures) |
| `NEARSIDE_TEST_DOCK` | The phone window's dock: comma-separated packages instead of your favourites |
| `NEARSIDE_TEST_OVERLAY` | Output PNG for the overlay, phone-window and `NEARSIDE_TEST_VIEW` snapshots |
| `NEARSIDE_TEST_SHOT` | Save the whole window as it looks (toolbar, panels and the app's picture) to this PNG, `NEARSIDE_TEST_SHOT_AFTER` seconds (default 4) after it shows; for the phone window, counted from opening |
| `NEARSIDE_TEST_VIEW` | Save `panel`, `settings` or `messages` to `NEARSIDE_TEST_OVERLAY` after `NEARSIDE_TEST_WAIT` s (default 8); `NEARSIDE_TEST_DARK=1` for dark mode |
| `NEARSIDE_TEST_LAUNCHER` | Save the launcher to this PNG (with `NEARSIDE_TEST_QUERY`, `NEARSIDE_TEST_MOVES=down,right`) |
| `NEARSIDE_TEST_SETUP` | Save a setup page to this PNG (`NEARSIDE_TEST_SETUP_PAGE`: `welcome`, `permissions`, `phone`; `NEARSIDE_TEST_DARK=1` for dark mode; after `NEARSIDE_TEST_WAIT` s, default 3) |
| `NEARSIDE_TEST_DOCK_ICON` | Save the Dock icon to this PNG |
| `NEARSIDE_TEST_LAYOUTS` | Log the phone's keyboard layouts |
| `NEARSIDE_TEST_VIDEO_KBPS` | Read video at most this fast (tests the adaptive bitrate) |

Notes:

- An app started from a shell can't become the key window, so ⌘ shortcuts in tests go through
  `performKeyEquivalent`.
- Hidden windows pause their encoder, so trace pictures go stale while a window is covered.
- Phone-side debug properties (set with `adb shell setprop`): `debug.nearside.sleep_after_s`
  (seconds of silence before a hidden window's display sleeps) and `debug.nearside.bars_idle_s`
  (how long the system-bars host stays after the last window).
- README and website pictures: `NEARSIDE_TEST_SHOT` and `NEARSIDE_TEST_VIEW` make the raw
  captures; blur anything personal before using them. The "How it works" picture is
  [`assets/src/architecture.html`](assets/src/architecture.html), rendered to PNG with a
  headless browser (the command is in the file).
- Phone apps ask for Touch ID by default; for unattended tests set
  `defaults write dev.nearside.mac PhoneApps.authentication never` and delete it afterwards.

## Code map

```
core/Sources/NearsideCore/  SyncEngine, helper link, clipboard history, Display/ streams;
                            Platform.swift: what each app provides (the Mac's: NearsideMac)
core/Sources/NativeAdb/     adb client: TLS, pairing, mDNS discovery, streams, sync, install
mac/Sources/Nearside/       UI: menu-bar panel, setup, settings, Messages, phone-app windows
mac/Sources/NearsideMac/    the engine's Mac parts: VideoToolbox decoding, audio, microphone,
                            pasteboard, notifications, screenshots, quarantine
mac/Sources/NearsideCamera/ the camera extension
android/app/src/main/java/dev/nearside/
  helper/                   the shell-user helper (Main.kt) and display/ (virtual displays,
                            encoder, input, audio, system bars, app catalog)
  link/                     app side of the helper Binder link
  phone/                    home screen, system-bars host, dropped files, in-use notification
```

See [architecture.md](architecture.md) for how the pieces fit together.
