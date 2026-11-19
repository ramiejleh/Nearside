# Nearside

Apple-style Continuity between an Android phone and a Mac: a shared clipboard both ways,
notifications, files, SMS and screen mirroring. It runs quietly in the background, with no
per-use triggering and no cloud account.

> **Status: early.** Two-way clipboard sync and notification mirroring work today: proven on a
> Pixel 9 Pro running Android 17, surviving reboots and Wi-Fi drops. Files and SMS work too.
> See [`vault/README.md`](vault/README.md) for the design, research and test results.

## How it works (short version)

Android blocks normal apps from reading the clipboard in the background. Nearside ships a
small helper that the Mac starts over **wireless debugging**, so it runs with shell-level
access (the technique scrcpy and Shizuku use). That helper may read the clipboard.

The Mac talks to the helper through adb's encrypted connection, never over your open
network. After a reboot or Wi-Fi drop, Android turns wireless debugging back on and the Mac
restarts the helper, so you do nothing.

## The Mac app

A menu-bar app with:
- **Arrival toasts:** a card slides in when a clip arrives from the phone.
- **Unseen count:** the menu-bar icon shows how many phone clips you haven't looked at.
- **Searchable history:** click an item to put it back on both clipboards.
- **Files both ways:** drag files onto the menu-bar icon to send them to the phone; "Send to
  Mac" in Android's share sheet puts files in your Mac's Downloads.
- **Text messages:** read and send SMS in a Messages window (RCS chats stay in Google
  Messages; reply to those from their notifications).
- **Phone notifications** as native macOS notifications; dismiss on either device and it's
  gone on both.

```sh
(cd android && ./gradlew assembleDebug)   # the phone app, embedded in the Mac app
mac/scripts/bundle.sh                          # → mac/build/Nearside.app
open mac/build/Nearside.app
```

Requirements: macOS 14+ and an Android 11+ phone on the same Wi-Fi. Nothing else: Nearside
has its own adb client. The first launch opens a setup wizard, and you pair by scanning a QR
code from Developer options → Wireless debugging.

## Security

- The Mac only works with the phone it paired with: its TLS key is pinned during pairing,
  where the pairing code authenticates it, so a look-alike device on the network is refused.
- The Mac only trusts a helper running as the shell user.
- Mac and helper prove to each other that they share a secret, without ever sending it.
- Clipboard history is stored on the Mac, readable only by your user. Items that password
  managers mark as concealed are never recorded.

## License

Apache-2.0. The helper's context workarounds are adapted from
[scrcpy](https://github.com/Genymobile/scrcpy) (Apache-2.0, Genymobile).
