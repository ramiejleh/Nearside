# Frequently asked questions

Short answers to what people ask most. For everything Nearside does, see
[features.md](features.md); to install it, see [Getting started](getting-started.md).

## Does my phone need root?

No. The computer starts a small helper on the phone over Android's wireless debugging (or a USB
cable), the same approach as scrcpy and Shizuku. You pair once by scanning a QR code; after that
the computer turns the connection back on by itself after a reboot or a Wi-Fi change.

## Isn't wireless debugging a security risk?

Left on with any computer allowed, it can be. Nearside narrows it down:

- At pairing, the computer pins your phone's TLS key, so it only ever talks to your phone.
- The computer and the phone's helper prove to each other that they share a per-computer secret
  before doing anything.
- Phone apps open on the computer only after Touch ID, Windows Hello or your password, and the
  phone always shows that apps are open, with a Stop button.

The full design and threat model are in [security.md](security.md).

## Does anything go through a server?

No. There is no server, account or telemetry: the phone and the computer talk directly over
your Wi-Fi or a USB cable.

## How is this different from scrcpy?

scrcpy is the better tool for mirroring and controlling a phone now and then, on any OS.
Nearside runs all day in the background and adds the continuity layer: notifications, SMS,
calls, clipboard history, photos, and phone apps that behave like computer apps (a launcher, the
Dock or taskbar, Spotlight or the Start menu). It builds on scrcpy's techniques and credits them.

## Why not KDE Connect or Phone Link?

Both are good. KDE Connect has no app windows on macOS; Phone Link is Windows-only, and which
apps it can show depends on the phone. Nearside works on both computers and opens any app in its
own window.

## Does it work on Samsung, OnePlus, Xiaomi...?

It should on any phone with Android 11 or later, but so far it's tested on a Pixel. Please try it
and send a
[device report](https://github.com/ramiejleh/Nearside/issues/new?template=device_report.yml)
either way; each one becomes a row in the [device matrix](devices.md). Calls through the
computer use in-call audio paths that Pixels have; on other phones a call may stay on the phone.

## Do I have to unlock the phone?

No. Phone apps open on the computer while the phone stays locked with its screen off, and the
phone stays free for you to use at the same time.

## Why isn't the phone app on Google Play?

It needs SMS and notification access that Google restricts for apps like this. The computer
installs and updates the phone app itself.

## Windows says the installer is unsafe.

The Windows installer isn't code-signed yet, because a certificate costs money every year.
Compare the download's SHA-256 checksum with the `.sha256` file on the release page, then choose
**More info**, **Run anyway**. Sponsorship goes toward the certificate first. The Mac app is
signed and notarised by Apple.

## What about battery?

Windows you aren't looking at slow down or pause, and the helper idles when nothing is open.
If you see a difference in battery life, please open an issue with your phone model.

## Some apps show black in a window.

Apps that block screen capture (many banking apps) can't be shown on the computer. The window
says so and offers to open the app on the phone.

## Linux?

The engine already builds on Linux; [adding-a-platform.md](adding-a-platform.md) describes what
the rest would take. Help is very welcome.

## I have a question that isn't here.

Ask in [GitHub Discussions](https://github.com/ramiejleh/Nearside/discussions). Found a
vulnerability? Please report it privately; see [SECURITY.md](../SECURITY.md).
