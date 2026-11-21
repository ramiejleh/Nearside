# Development

## Build and run

Needs Xcode 16+ and Android Studio (its bundled JDK; a newer system JDK is too new for Gradle).

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

## Tests

- `cd mac && swift test`: protocol encoding and decoding, input mapping, key map, sizes, audio
  (a real Opus round trip), clipboard history, adb key format and more.
- Live tests against a phone are opt-in: `NEARSIDE_DEVICE=<ip:port> swift test`
  (`NEARSIDE_INSTALL_APK=<apk>` adds the install test).

## Test hooks

The Mac app reads these environment variables when started directly
(`mac/build/Nearside.app/Contents/MacOS/Nearside`), so phone-app windows can be tested
without clicking:

| Variable | Effect |
|---|---|
| `NEARSIDE_OPEN_APP` | Open windows on launch: comma-separated `pkg`, `pkg/activity` or `phone` |
| `NEARSIDE_OPEN_APP_DELAY` | Seconds to wait before opening |
| `NEARSIDE_OPEN_NOTIFICATION` | Open a notification key in a window |
| `NEARSIDE_TRACE` | Write a trace (frames, delays, audio, stats) to this file, and the shown picture to `<file>.png` once a second |
| `NEARSIDE_TEST_INPUT` | Drive a window: `tap`, `click`, `scroll`, `wheel`, `pinch`, `mouse`, `type`, `keys`, `copy`, `paste`, `resize`, `size`, `hide`, `close`, `drop` |
| `NEARSIDE_TEST_TAP` | `x,y` (0…1 of the window) for `tap` |
| `NEARSIDE_TEST_TEXT` | Text for `type` |
| `NEARSIDE_TEST_SIZE`, `NEARSIDE_TEST_SIZE2` | `WxH` in points for `size` (the second 8 s later) |
| `NEARSIDE_TEST_CLOSE_AFTER` | Seconds before `close` / how long `hide` lasts |
| `NEARSIDE_TEST_HIDE_AFTER` | Seconds before `hide` minimises the window (default 0) |
| `NEARSIDE_TEST_FILE` | File for `drop` |
| `NEARSIDE_TEST_PHONE` | Phone window: `recents`, `close`, `bar` |
| `NEARSIDE_TEST_WAIT` | Seconds before the phone-window test runs |
| `NEARSIDE_TEST_OVERLAY` | Save a window's overlay to this PNG |
| `NEARSIDE_TEST_LAUNCHER` | Save the launcher to this PNG (with `NEARSIDE_TEST_QUERY`, `NEARSIDE_TEST_MOVES=down,right`) |
| `NEARSIDE_TEST_SETUP` | Save a setup page to this PNG (`NEARSIDE_TEST_SETUP_PAGE`: `welcome`, `permissions`, `phone`; `NEARSIDE_TEST_DARK=1` for dark mode; after `NEARSIDE_TEST_WAIT` s, default 3) |
| `NEARSIDE_TEST_DOCK_ICON` | Save the Dock icon to this PNG |
| `NEARSIDE_TEST_LAYOUTS` | Log the phone's keyboard layouts |
| `NEARSIDE_TEST_VIDEO_KBPS` | Read video at most this fast (tests the adaptive bitrate) |

Notes:

- An app started from a shell can't become the key window, so ⌘ shortcuts in tests go through
  `performKeyEquivalent`.
- Hidden windows pause their encoder, so trace pictures go stale while a window is covered.
- Phone apps ask for Touch ID by default; for unattended tests set
  `defaults write dev.nearside.mac PhoneApps.authentication never` and delete it afterwards.

## Code map

```
mac/Sources/Nearside/       UI: menu-bar panel, setup, settings, Messages, phone-app windows
mac/Sources/NearsideCore/   SyncEngine, helper link, notifications, clipboard, Display/ pipeline
mac/Sources/NativeAdb/      adb client: TLS, pairing, mDNS discovery, streams, sync, install
android/app/src/main/java/dev/nearside/
  helper/                   the shell-user helper (Main.kt) and display/ (virtual displays,
                            encoder, input, audio, system bars, app catalog)
  link/                     app side of the helper Binder link
  phone/                    home screen, system-bars host, dropped files, in-use notification
```

See [architecture.md](architecture.md) for how the pieces fit together.
