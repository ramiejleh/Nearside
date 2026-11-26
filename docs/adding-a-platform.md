# Adding a platform

Nearside runs on the Mac and on Windows. This page is for bringing it to another computer, with
Linux as the running example. Most of the work is already shared: the phone app and its helper
don't change, and the engine (`core/`) already builds and passes its tests on Linux (CI checks
this). What a new platform adds is the parts that touch the system, and an interface.

A new platform joins the [feature parity](development.md#feature-parity) rule: it ships with
the same features as the others, or the docs list what it's missing and why.

Read [architecture.md](architecture.md) first, then how the two existing apps do it:
[development-mac.md](development-mac.md) and [development-windows.md](development-windows.md).

## What's shared, and what isn't

| Part | Where | On a new platform |
|---|---|---|
| Phone app and helper | `android/` | Unchanged (see [the phone's wording](#the-phones-wording)) |
| Sync engine, protocols, streams | `core/Sources/NearsideCore` | Unchanged |
| adb client: TLS, pairing, streams, sync | `core/Sources/NativeAdb` | Unchanged |
| Sockets, mDNS discovery, USB | `core/Sources/NativeAdb` | **New**, one file each |
| Clipboard, notifications, sound, video... | `Platform` protocols | **New** |
| Interface | `mac/`, `windows/App` | **New** |
| Webcam | `mac/Sources/NearsideCamera`, `windows/Camera` | **New** (optional) |
| Installer and updates | per platform | **New** |

## 1. The adb transport

`NativeAdb` needs three things from the system. On the Mac they're in `TCPSocket.swift`,
`Discovery.swift` and `USB.swift`; Windows has `*+Windows.swift`; everything else gets the
placeholders in `Unsupported.swift`, which fail or find nothing. A port replaces each placeholder
(guard it with `#if os(Linux)` and narrow the placeholder's condition):

- **`TCPSocket`**: a TCP connection with timeouts and non-blocking reads, handed to BoringSSL
  by its descriptor. Linux's sockets are POSIX like the Mac's, so `TCPSocket.swift` is mostly
  reusable with `Glibc` in place of `Darwin`.
- **`Discovery`**: browses mDNS for the phone's `_adb-tls-connect._tcp` and
  `_adb-tls-pairing._tcp` services. On Linux, Avahi (its D-Bus API, or `libavahi-compat-libdnssd`,
  which offers the same `dns_sd` calls the Mac uses).
- **`USB`**: lists phones on a cable and opens adb's bulk endpoints. On Linux, `libusb` or usbfs
  directly. The interface is class `0xFF`, subclass `0x42`, protocol `0x01`. The serial must match
  the one adb reports (see `WindowsUSBInstance` for the checks).

Do mDNS early: pairing can take a typed address and code (`SyncEngine.pair(hostPort:code:)`),
but every reconnection finds the phone's current port through it (wireless debugging changes
port each time it starts). USB can come last; Wi-Fi alone is enough.

## 2. The platform

`core/Sources/NearsideCore/Platform.swift` lists what the engine asks of the computer. Implement
`Platform` and set `Platforms.current` at launch, before anything else in the engine runs:

| Protocol | Does | Mac | Windows | Linux, for example |
|---|---|---|---|---|
| `Clipboard` | Watches and writes text | NSPasteboard | Win32 clipboard | Wayland or X11, via GTK or `wl-clipboard` |
| `SystemNotifications` | The phone's notifications, with buttons and replies | UserNotifications | App notifications (C#) | `org.freedesktop.Notifications` over D-Bus (inline reply is KDE only) |
| `ScreenshotWatcher` | New screenshots to the phone | The screenshot folder | `Pictures\Screenshots` | `~/Pictures/Screenshots` (GNOME and KDE) |
| `markDownloaded` | Marks files from the phone | Quarantine | Mark of the Web | `user.xdg.origin.url` extended attribute |
| `VideoDecoding` | HEVC or H.264 to frames | VideoToolbox | FFmpeg, Direct3D 11 | FFmpeg with VA-API, or GStreamer |
| `AudioOutput` | Plays a window's or call's sound (Opus) | AVAudioEngine | WASAPI | PipeWire or PulseAudio, Opus via libopus or FFmpeg |
| `Microphone` | 48 kHz mono 16-bit, 20 ms chunks | AVAudioEngine | WASAPI | PipeWire or PulseAudio |
| `computerName`, `osName` | Shown on the phone ("in use on…") | | | The host name; `osName` (see below) |
| `preferredCodec` | The codec the phone encodes | HEVC | H.264 (HEVC needs a paid extension) | H.264 is the safe choice |

`Paths.support` is Foundation's application-support folder (`~/.local/share/Nearside` on Linux).
It holds the history and the secret the computer shares with the helper (`token`), written owner-only.
The adb key goes there too.

## 3. The interface

Two ways, both already in use:

- **All Swift**, like the Mac. The interface uses the engine directly. It's natural if the
  toolkit has good Swift bindings. On Linux that means GTK through C, which is workable but thin.
- **A bridge and another language**, like Windows. `NearsideBridge` exports the engine as a C
  library. The interface sends JSON commands, reads a JSON snapshot of everything it shows, and
  gets events and media through a few C functions. `Snapshot.swift`, `Commands.swift` and
  `Sessions.swift` hardly mention Windows. Move them next to `core/` (as a shared
  `NearsideBridgeCore`, say) and a Linux app in C#, Rust, Python or C++ can reuse them, along with
  the Windows app's structure.

Either way, the engine's main actor is the interface's main thread. Pump it from the toolkit's
main loop (see `nearside_pump` and the wake handle in `windows/Sources/NearsideBridge/Bridge.swift`).

What the interface shows is the same on every platform: the panel (status, transfers, photos,
Notifications and Clipboard tabs), setup with pairing, settings, Messages, calls, the launcher,
and phone and app windows. Those windows need a toolbar, a video view, input (touch, scroll,
keys with a key map, see `KeyMap` and `WindowsKeyMap` in `core/`), recents and the notification
list. Use the Windows app as the checklist: it's the most recent full port.

## 4. The webcam (optional)

The phone's camera arrives as a stream (`CameraSession`). The platform turns it into a camera
other apps can pick: a system extension on the Mac, a Media Foundation source on Windows, and
`v4l2loopback` on Linux. Keep the same rules: only Nearside may feed it, and the phone's camera is
on only while an app uses it.

## The phone's wording

The phone names the computer it's connected to ("Camera in use by your Mac", "in use on another
PC"). The computer says what it is in its hello (`osName`, sent as `"os"`; Windows sends
`"windows"`). The helper (`android/.../helper/Main.kt`, `desktopKind`) and the phone app's text
only know the Mac and the PC so far. A new platform adds its name there, or falls back to "your
computer".

## 5. Packaging and updates

Each platform ships its own way. The Mac has a notarised zip with Sparkle and Homebrew; Windows
has an Inno Setup installer with WinSparkle and winget. On Linux, Flatpak or an AppImage would
suit; Flatpak needs portals for the clipboard, notifications and the camera. Every release
bundles the same phone APK (signed with the release key) and its `versionCode`, so any computer
can install or update the phone app. See [releasing.md](releasing.md).

## Checklist

1. `core/` builds and `swift test` passes on the new system (it already does on Linux).
2. Sockets, then mDNS and USB, in `NativeAdb`; a console tool can pair and run `shell` (as
   `windows/Spike` did on Windows).
3. A `Platform` with the clipboard and notifications: the clipboard syncs.
4. A window showing the phone's home screen, decoded and drawn, with input; measure latency.
5. The interface, feature by feature, with the Windows app as the checklist.
6. The webcam, the installer, updates, and docs (a `development-<platform>.md`, the README's
   support matrix and requirements).
7. Add the platform to CI (`.github/workflows/ci.yml`).
