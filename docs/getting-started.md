# Getting started

## Requirements

| | |
|---|---|
| **Mac** | macOS 14 Sonoma or later |
| **PC** | Windows 11 (x64 or Arm) |
| **Phone** | Android 11 or later, on the same Wi-Fi network (or plugged in by USB once paired) |

## Install

### Mac

Download `Nearside-<version>.zip` from the
[latest release](https://github.com/ramiejleh/Nearside/releases/latest), unzip it and move
Nearside to Applications. Or, with [Homebrew](https://brew.sh):

```sh
brew install --cask ramiejleh/tap/nearside
```

Releases are signed and notarised by Apple. Nearside checks for updates by itself, and
**Settings → General → Check for Updates…** checks now.

### Windows

Download `Nearside-<version>-x64.exe` (or `-arm64.exe` for Arm PCs) from the same release and run
it, or use winget:

```
winget install Nearside.Nearside
```

It installs for everyone on the PC (it asks for an administrator once, for the webcam). Nearside
checks for updates by itself; **Check for updates** in its notification-area menu checks now.

When either app updates, it updates the phone app too.

## Set up

The first launch opens a setup assistant. On the phone, turn on **Developer options →
Wireless debugging** and scan the pairing QR code your computer shows. That's the only time you
touch the phone: the computer installs the phone app and does the rest.

## Build it yourself

To build the Mac app from source you need Xcode 26 or later and Android Studio (Gradle uses its
bundled JDK).

```sh
git clone https://github.com/ramiejleh/Nearside.git
cd Nearside
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
(cd android && ./gradlew assembleDebug)   # the phone app, bundled into the Mac app
mac/scripts/bundle.sh                     # builds mac/build/Nearside.app
open mac/build/Nearside.app
```

On Windows you need the Swift toolchain, the Visual Studio Build Tools and the .NET 10 SDK; see
[Developing on Windows](development-windows.md). To work on Nearside, start with
[development.md](development.md).

## What's tested, and where

Everything below is tested with **one phone**: a **Google Pixel 9 Pro on Android 17 beta
(API 37)**, with a **MacBook Air (Apple M5) on macOS 27.0.1** and a **Windows 11 PC (x64)**, over
Wi-Fi and over USB. Nothing else has been tested yet: other phones, Android 11 to 16, macOS 14 to
26, Intel Macs and Arm PCs may work, or may not.

**Phones:** the [device matrix](devices.md) lists every phone tried so far, feature by feature;
for now that's the Pixel 9 Pro. Tried another?
[Send a device report](https://github.com/ramiejleh/Nearside/issues/new?template=device_report.yml),
whether it worked or not, and it becomes a row there.

| Feature | Mac (macOS 27) | Windows 11 | Notes |
|---|---|---|---|
| Clipboard, both ways, with history | Tested | Tested | |
| Notifications, with buttons and replies | Tested | Tested | |
| Text messages (SMS) | Tested | Tested | RCS stays in Google Messages |
| Files, both ways | Tested | Tested | |
| Phone apps in computer windows, with sound | Tested | Tested | Uses Android's virtual devices |
| The computer's microphone in app windows | Tested | Tested | WhatsApp and Messenger calls |
| Phone status (battery, signal, network) | Tested | Tested | |
| Photos and screenshots | Tested | Tested | |
| Incoming calls: answer, decline, reply | Tested | Tested | Phone, WhatsApp and Messenger calls |
| Phone calls through the computer (sound and microphone) | Tested | Tested | Uses the in-call audio paths Pixel's Call Screen uses |
| Phone camera as a webcam, back and front | Tested | Tested | Mac: release builds only (needs Apple signing) |
| USB cable | Tested | Tested | |
| Wi-Fi (wireless debugging) | Tested | Tested | |
| Phone-app windows at 90 or 120 frames a second | Not yet | Not yet | Android 14 or later |
| Muting notifications, the Notifications tab | Not yet | Not yet | New |

## Status

Nearside is **alpha** software. It's built and used daily on a Pixel 9 Pro (Android 17 beta)
with a MacBook Air (macOS 27) and a Windows 11 PC. Its known limitations are listed in
[Features](features.md#known-limitations).
