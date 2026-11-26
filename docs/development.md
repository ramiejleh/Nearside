# Development

Nearside is three programs that work together:

- the **phone app** and its **helper** (`android/`, Kotlin): one APK, the same for every computer;
- the **engine** (`core/`, Swift): adb, the helper link, sync, and the window, call and camera
  streams, shared by every computer app;
- a **computer app** for each system: the Mac's (`mac/`, Swift) and Windows' (`windows/`, Swift
  engine bridge plus a C# WinUI 3 app).

This page covers what they share. Each computer has its own page:

- [Developing on the Mac](development-mac.md): building, signed builds (the webcam), test hooks.
- [Developing on Windows](development-windows.md): toolchain, building, the camera, the installer.
- [Adding a platform](adding-a-platform.md): what a new computer app (Linux, say) needs.
- [Releasing](releasing.md): making a release for both.

## The phone app

Build it with Android Studio's bundled JDK (a newer system JDK is too new for Gradle):

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"   # macOS
(cd android && ./gradlew assembleDebug)
```

Each computer app bundles the APK it was built with and installs or updates the phone app
itself; `versionCode` is the number of commits, so a newer build always replaces an older one.
While working on the phone side:

```sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell 'kill $(pidof nearside-helper)'     # the computer starts the new helper within seconds
```

The helper's log: `adb shell cat /data/local/tmp/nearside-helper.log`.

A phone whose app was installed from a release can't be updated in place by a debug build (Android
requires the same signing key): the panel then offers **Reinstall**, which swaps it.

## The engine

`core/` is a Swift package with no UI. It builds on macOS, Windows and Linux:

```sh
cd core && swift test
```

The tests cover protocol encoding and decoding, input mapping, key maps, sizes, the audio jitter
buffer, clipboard history, the adb key format, notification muting and more. Live tests against a
phone are opt-in: `NEARSIDE_DEVICE=<ip:port> swift test` (`NEARSIDE_INSTALL_APK=<apk>` adds the
install test).

On Linux it builds and tests too, which catches Apple-only code creeping in (CI does this):

```sh
docker run --rm -v "$PWD/core":/src:ro swift:6.4.3 bash -c 'cp -r /src /w && rm -rf /w/.build && cd /w && swift test'
```

Sockets, mDNS and USB are placeholders there (`core/Sources/NativeAdb/Unsupported.swift`), so the
network tests are left out.

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request: the engine on Linux, the Mac app's
tests on macOS, the Windows engine tests, bridge, camera and app on Windows, and the phone app's
debug build. `.github/workflows/pages.yml` publishes `site/` to GitHub Pages from `main`.

## Code map

```
core/Sources/NearsideCore/   SyncEngine (connection, clipboard, notifications, calls, photos, SMS),
                             the helper link, Display/ (window, call and camera streams);
                             Platform.swift: what each computer app provides
core/Sources/NativeAdb/      adb client: TLS, pairing, mDNS discovery, USB, streams, sync, install;
                             *+Windows.swift: the Windows sockets, mDNS and USB
mac/Sources/Nearside/        the Mac UI: menu-bar panel, setup, settings, Messages, phone windows
mac/Sources/NearsideMac/     the engine's Mac platform: VideoToolbox, audio, microphone,
                             pasteboard, notifications, screenshots, quarantine
mac/Sources/NearsideCamera/  the Mac camera extension
windows/Sources/             WindowsPlatform (the engine's Windows platform) and NearsideBridge
                             (the engine as a DLL with a JSON C API)
windows/App/                 the Windows UI (C#, WinUI 3): tray panel, setup, settings, Messages,
                             phone windows (FFmpeg, Direct3D 11), WASAPI sound and microphone
windows/Camera/              the Windows virtual camera (a C++ Media Foundation source)
windows/installer/           the Inno Setup installer
android/app/src/main/java/dev/nearside/
  helper/                    the shell-user helper (Main.kt) and display/ (virtual displays,
                             encoder, input, audio, system bars, app catalog, camera)
  link/                      app side of the helper Binder link
  phone/                     home screen, system-bars host, dropped files, in-use notification
site/                        the website and the update feeds (appcast.xml, appcast-windows.xml)
```

See [architecture.md](architecture.md) for how the pieces fit together,
[security.md](security.md) for the security design and
[display-protocol.md](display-protocol.md) for the stream format.
