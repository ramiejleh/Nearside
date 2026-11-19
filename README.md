# Nearside

Apple-style Continuity between an Android phone and a Mac: a shared clipboard both ways,
notifications, files, SMS and screen mirroring. It runs quietly in the background, with no
per-use triggering and no cloud account.

> **Status: proof of concept.** Right now this repo only tests the riskiest part: automatic
> phone → Mac clipboard sync that survives reboots. See [`vault/README.md`](vault/README.md)
> for the design, research and PoC results.

## How it works (short version)

Android blocks normal apps from reading the clipboard in the background. Nearside ships a
small helper that the Mac starts over **wireless debugging**, so it runs with shell-level
access (the technique scrcpy and Shizuku use). That helper may read the clipboard. After a
reboot, the phone app turns wireless debugging back on and the Mac restarts the helper, so you
do nothing.

## The Mac app

A menu-bar app with:
- **Arrival toasts:** a card slides in when a clip arrives from the phone.
- **Unseen count:** the menu-bar icon shows how many phone clips you haven't looked at.
- **Searchable history:** click an item to put it back on both clipboards.

```sh
(cd android && ./gradlew assembleDebug)   # the phone app, embedded in the Mac app
mac/scripts/bundle.sh                          # → mac/build/Nearside.app
open mac/build/Nearside.app
```

The first launch walks you through pairing (Wireless debugging → "Pair device with pairing
code"). It needs Android's adb: `brew install --cask android-platform-tools`.

## Trying the PoC CLI

Requirements: a Mac with Xcode and the Android SDK, and an Android 11+ phone on the same Wi-Fi.

```sh
# 1. Build the Android app
cd android && ./gradlew assembleDebug

# 2. Build the Mac CLI
cd ../mac && swift build

# 3. On the phone: Settings → About phone → tap "Build number" 7 times,
#    then Developer options → Wireless debugging → on → "Pair device with pairing code".
.build/debug/nearside-poc setup <ip:port shown on phone> <6-digit code>

# 4. Sync clipboards
.build/debug/nearside-poc run
```

The PoC has **no encryption or pairing** between the app and the Mac. Only use it on a network
you trust.

## License

Apache-2.0. The helper's context workarounds are adapted from
[scrcpy](https://github.com/Genymobile/scrcpy) (Apache-2.0, Genymobile).
