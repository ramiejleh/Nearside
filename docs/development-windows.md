# Developing on Windows

The Windows app is three parts on top of the engine (`core/`); what every platform shares (the
phone app, the engine and its tests) is in [development.md](development.md).

- `windows/Sources/` (Swift, `windows/Package.swift`):
  - `WindowsPlatform`: what the engine needs from Windows (the clipboard, Mark of the Web, the
    computer's name), with hooks the app fills in for notifications, video, sound and the
    microphone.
  - `NearsideBridge`: the engine as `NearsideBridge.dll`, with a small C API.
- `windows/App/` (C#, WinUI 3 with the Windows App SDK, unpackaged, self-contained): the app. It
  lives in the notification area; its panel has the phone, transfers, recent photos and the
  Notifications and Clipboard tabs. Also setup, settings, notifications, Messages, calls, phone
  and app windows (FFmpeg with Direct3D 11 hardware decoding, WASAPI sound and microphone), the
  launcher (Ctrl+Alt+N), Start-menu shortcuts and Windows Hello before phone apps show.
- `windows/Camera/` (C++): `NearsideCamera.dll`, the virtual camera, a Media Foundation media
  source that Windows' camera service loads.
- `windows/installer/Nearside.iss`: the Inno Setup 7 installer, made by `windows/scripts/release.ps1`.
- `windows/Spike/`: console tools from the port's first steps (not shipped; see its README).
- `windows/scripts/make-icons.swift`: draws the app and tray icons (run on a Mac).

## Toolchain

Windows 11, x64 or ARM64, with:

- the [Swift toolchain](https://www.swift.org/install/windows/) (6.3 or later);
- the Visual Studio 2022 or 2026 Build Tools, with the C++ tools for your architecture (and for the
  other one to build both);
- the .NET 10 SDK;
- FFmpeg's shared LGPL build ([BtbN's FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds),
  `ffmpeg-n8.1-latest-winarm64-lgpl-shared-8.1` or `-win64-`), unpacked in `%USERPROFILE%\deps`
  (or pass `-p:FFmpegDir=<folder>`).

With Visual Studio 2026's C++ library, Swift's clang needs to be told the versions are fine:
add `-Xcxx -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH -Xcc -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH`
to `swift build` and `swift test` (CI does).

## Build and run

```
cd windows
swift build
Camera\build.cmd                      (optional: the webcam; arm64 or x64, default this PC's)
cd App
dotnet build -p:Platform=ARM64 -r win-arm64      (or -p:Platform=x64 -r win-x64)
bin\ARM64\Debug\net10.0-windows10.0.22621.0\win-arm64\Nearside.exe
```

The build copies `NearsideBridge.dll`, FFmpeg's DLLs and `NearsideCamera.dll` (if built) next to
`Nearside.exe`. The Swift runtime comes from the toolchain on `PATH` in a development build; a
release bundles it. To let a development build install the phone app, copy the APK next to
`Nearside.exe` as `phone-app.apk`, with its `versionCode` in `phone-app.version` (a release does
this).

- The log is `%LOCALAPPDATA%\Nearside\nearside.log` (no phone content goes in it).
- The engine's settings are Foundation's, in `%LOCALAPPDATA%\Nearside.exe.plist`; the app's own
  (window sizes, the panel's tab, Start-menu shortcuts) are in the registry under
  `HKEY_CURRENT_USER\Software\Nearside`.

### Tests

- `cd core && swift test` (with the flags above): the engine, including the Windows parts of the
  adb client (USB serials, sockets).
- `cd windows && swift build`: the bridge. The app has no unit tests; check it with the demo mode
  below and on a phone.

## How the app runs the engine

The engine runs on the app's UI thread, which is the process's main thread and so the engine's
main actor. The app pumps it (`nearside_pump`) when the engine's wake handle is signalled and on a
100 ms tick for run-loop timers. The engine reports changes as events; the app then reads a JSON
snapshot of everything the interface shows (`Sources/NearsideBridge/Snapshot.swift`, read by
`App/Engine/Snapshot.cs`) and sends commands as JSON (`Commands.swift`). Video, sound and the
microphone go through their own C functions, not JSON. See `Sources/NearsideBridge/Bridge.swift`.

## The camera

Windows' camera service (Frame Server) only loads a camera registered machine-wide, so it needs
installing. By hand, for a development build:

```
copy the app's output folder to C:\Program Files\Nearside
regsvr32 "C:\Program Files\Nearside\NearsideCamera.dll"      (as an administrator)
```

The installer does this. The DLL only takes pictures from `Nearside.exe` in its own folder (it
checks the process on its named pipe), and the app only sends them to the camera service. The DLL
writes a short log (no pictures) to
`C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp\NearsideCamera.log`. Frame Server keeps
the DLL loaded: stop it (`sc stop FrameServer`) before replacing or deleting it.

## A USB cable

A phone on a cable is used instead of Wi-Fi as soon as it's plugged in, as on the Mac. No driver
is needed: the phone's adb tells Windows to use WinUSB for it (phones with their maker's adb
driver installed work too). Only one program can have the phone's USB connection at a time, so
quit Android Studio or run `adb kill-server` first. The first time, the phone asks to allow this
PC's key. `nearside-spike usb` (in `Spike/`) lists phones on a cable, and
`nearside-spike usb <serial> <command>` runs a command on one.

## Phone apps in the Start menu

With **Settings → Phone apps in the Start menu** on, each phone app gets a shortcut in the Start
menu's "Nearside Phone Apps" folder, with its icon and a small Nearside badge. They're removed
while the phone has been away for a minute or more and come back when it reconnects. Each opens
`nearside://open?package=<package>` with Nearside (as `Nearside.exe --link <link>`, which takes
no other switches), which opens the app in a window (only apps on the phone; Windows Hello first
if it's asked for). The installer registers `nearside:` links, so other launchers can use them
too; a second start hands its link to the running Nearside.

## Test switches

- `Nearside.exe --demo` shows made-up content instead of connecting (for screenshots);
  `--setup <page>`, `--settings`, `--messages`, `--call` or `--arrival` show those instead of the
  panel; `--muted` and `--away` show the panel with notifications muted or the phone in use
  elsewhere; `--shot <file.png>` saves the window as drawn, then quits.
- `--open-phone` opens the phone window once connected (`--launcher`: the launcher instead).
  With it, `NEARSIDE_TEST_PHONE=recents` or `size:<phone|foldable|tablet>` opens Recents or
  changes the size once the window shows, and logs what came back (counts and sizes only).
- `--camera-test` feeds the camera a generated picture instead of the phone's camera.
- `NEARSIDE_SOFTWARE_DECODE=1` decodes video on the processor instead of the graphics card.
- Updates: builds made with `release.ps1 -UpdateTest` (never published) read
  `NEARSIDE_UPDATE_FEED=<url>` instead of the real feed (updates must still be signed with the
  app's key), and `--install-update` checks and installs at once.

## Working in a virtual machine

A Windows 11 ARM virtual machine (UTM on a Mac, with OpenSSH) is enough for everything but the
graphics card, Windows Hello biometrics and USB. Two things to know:

- OpenSSH ends every process a session started when the command ends. Start the app, an
  uninstaller or anything that must outlive the command with a scheduled task
  (`schtasks /create /tn … /tr … /sc once /st 00:00 /it`, then `schtasks /run /tn …`); `/it` runs
  it in the signed-in desktop, which windows need.
- When copying the sources over with `tar`, don't exclude `obj`: BoringSSL has a `crypto/obj`
  folder.

## Code map

```
windows/Sources/WindowsPlatform/  the engine's Windows platform
windows/Sources/NearsideBridge/   Bridge (start, pump, events), Snapshot, Commands, Sessions
                                  (phone windows), Media (video, sound, microphone), Camera
windows/App/                      App.xaml.cs (start, tray, single instance), PanelWindow,
                                  SetupWindow, SettingsWindow, MessagesWindow, PhoneWindow,
                                  LauncherWindow, NotificationList, Notifications (toasts),
                                  CallCard, ArrivalCard, PhoneAppShortcuts, AuthGate (Hello),
                                  Updates (WinSparkle), Video/ (decoder, Direct3D view, camera
                                  feed), Audio/ (WASAPI)
windows/Camera/                   NearsideCamera.cpp, build.cmd
windows/installer/, scripts/      the installer and release.ps1
```

Releasing is in [releasing.md](releasing.md).
