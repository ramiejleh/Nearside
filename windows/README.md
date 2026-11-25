# Nearside for Windows

Work in progress, on the `windows` branch. The plan is in the project notes; the architecture is
in [docs/architecture.md](../docs/architecture.md).

- `Package.swift`: the Swift side.
  - `WindowsPlatform`: what the engine needs from Windows (the clipboard, Mark of the Web), with
    hooks for notifications and video.
  - `NearsideBridge`: the engine (`core/`) as a DLL with a small C API, for the app.
- `App/`: the app, in C# with WinUI 3 (Windows App SDK, unpackaged). It lives in the
  notification area. Its panel has the phone, transfers, recent photos and the clipboard
  history; it also has setup, settings, notifications, Messages, calls, phone and app windows
  (FFmpeg and Direct3D 11, WASAPI sound and microphone), the launcher (Ctrl+Alt+N) and Windows
  Hello before phone apps show.
- `Camera/`: `NearsideCamera.dll`, the virtual camera (a Media Foundation media source that
  Windows' camera service loads). Build it with `Camera\build.cmd`.
- `installer/Nearside.iss`: the installer (Inno Setup 7), made by `scripts/release.ps1`.
- `Spike/`: the Phase 3 test tools (not shipped).
- `scripts/make-icons.swift`: draws the app and tray icons (run on a Mac).

## Building (Windows 11, x64 or ARM64)

Needs the Swift toolchain (6.3 or later), the Visual Studio Build Tools and the .NET 10 SDK.

```
cd windows
swift build
cd App
dotnet build -p:Platform=ARM64 -r win-arm64   (or x64 / win-x64)
```

The build copies `NearsideBridge.dll`, FFmpeg's DLLs (`-p:FFmpegDir=` its shared LGPL build) and
`NearsideCamera.dll` (if built) next to `Nearside.exe`. The Swift runtime DLLs come from the
toolchain on `PATH` in a development build; a release bundles them.

## How the app runs the engine

The engine runs on the app's UI thread, which is the process's main thread and so the engine's
main actor. The app pumps it (`nearside_pump`) when the engine's wake handle is signalled and on a
100 ms tick for run-loop timers. The engine reports changes as events; the app then reads a JSON
snapshot of everything the interface shows, and sends commands as JSON. See
`Sources/NearsideBridge/Bridge.swift`.

## The camera

Windows' camera service only loads a camera registered machine-wide, so it needs installing.
By hand (a development build):

```
copy the app's output folder to C:\Program Files\Nearside
regsvr32 "C:\Program Files\Nearside\NearsideCamera.dll"      (as an administrator)
```

The installer does this. The DLL only takes pictures from `Nearside.exe` in its own folder, and
the app only sends them to the camera service (LocalService). The DLL writes a short log (no pictures) to
`C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp\NearsideCamera.log`.

## Releasing

`scripts\release.ps1 -Version <x.y.z> -Apk <the release APK>` builds the installers for x64 and
ARM64 (on either kind of PC), signs them, adds the release to `site/appcast-windows.xml` (the
update feed WinSparkle reads) and writes the winget manifests. The top of the script lists what
it needs: Inno Setup 7, FFmpeg's shared LGPL builds for both architectures, the code-signing
certificate (`NEARSIDE_SIGN_CERT`) and the update-signing key (`NEARSIDE_UPDATE_KEY`, whose public
half goes in `App/Updates.cs`). `-NoSign -NoFeed -Build <n>` tries it without any of those.

What an installer does: everything goes in `C:\Program Files\Nearside` (for everyone on the PC;
the camera needs a folder only administrators can change), the camera is registered, and a
Start-menu shortcut is added. Uninstalling removes all of that, and the start-at-sign-in entry of
whoever uninstalls; settings and history in `%LOCALAPPDATA%\Nearside` stay.

## Phone apps in the Start menu

With **Settings → Phone apps in the Start menu** on, each phone app gets a shortcut in the Start
menu's "Nearside Phone Apps" folder, with its own icon. Each opens
`nearside://open?package=<package>` with Nearside, which opens the app in a window (only apps on
the phone; Windows Hello first if it's asked for). The installer registers `nearside:` links, so
other launchers can use them too; a second start hands its link to the running Nearside.

## A USB cable

A phone on a cable is used instead of Wi-Fi as soon as it's plugged in, as on the Mac. No driver
is needed: the phone's adb tells Windows to use WinUSB for it (phones with their maker's adb
driver installed work too). Only one program can have the phone's USB connection at a time, so
quit Android Studio or run `adb kill-server` first. The first time, the phone asks to allow this
PC's key. `nearside-spike usb` (in `Spike/`) lists phones on a cable, and
`nearside-spike usb <serial> <command>` runs a command on one.

## Testing

- `Nearside.exe --demo` shows made-up content instead of connecting (for screenshots);
  `--setup <page>`, `--settings`, `--messages` or `--call` show those instead of the panel, and
  `--shot <file.png>` saves the window as drawn, then quits.
- `--open-phone` opens the phone window once connected (`--launcher`: the launcher instead).
- `--camera-test` feeds the camera a generated picture instead of the phone's camera.
- `--demo --arrival` shows the clip-arrival card. `NEARSIDE_TEST_PHONE=recents` or
  `size:<phone|foldable|tablet>` (with `--open-phone`) opens Recents or changes the size once the
  window shows, and logs what came back (counts and sizes only).
- Updates (release builds): `NEARSIDE_UPDATE_FEED=<url>` reads another feed (updates must still
  be signed with the app's key), and `--install-update` checks and installs at once.
- The log is `%LOCALAPPDATA%\Nearside\nearside.log` (no phone content goes in it).
- Settings are Foundation's, in `%LOCALAPPDATA%\Nearside.exe.plist`.
