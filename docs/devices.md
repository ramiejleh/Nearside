# Phones Nearside is tested on

Nearside depends on parts of Android that phone makers can change: wireless debugging, virtual
displays, the in-call audio paths and the camera. So it can work fully on one phone and only
partly on another. This page lists every phone someone has tried, and how each feature did.

**Tried Nearside on your phone?**
[Send a device report](https://github.com/ramiejleh/Nearside/issues/new?template=device_report.yml),
whether it worked or not. Each report becomes a row here, with your name if you'd like.

## The matrix

| Phone | Android | Computer | Clipboard | Notifications | Text messages | Files | Phone apps in windows | Computer's mic in apps | Calls | Webcam | USB | Reported by |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Google Pixel 9 Pro | 17 beta (API 37) | Mac (macOS 27), Windows 11 | Works | Works | Works | Works | Works | Works | Works | Works | Works | Maintainer |

**Works**: everything in that feature did what the [feature list](features.md) says.
**Partly**: some of it worked; the notes below say what didn't. **No**: it didn't work.
**Not tried**: the reporter didn't get to it.

## Notes per phone

### Google Pixel 9 Pro (Android 17 beta)

The phone Nearside is built on, used every day with a MacBook Air (Apple M5) and a Windows 11 PC.
Every feature works, over Wi-Fi and over USB. Phone-app windows at 90 or 120 frames a second
haven't been checked yet.

## What tends to differ between phones

- **Calls through the computer** use the in-call audio paths that Pixel's Call Screen uses. Phones
  that don't offer them keep the call's sound on the phone: Nearside then leaves calls there.
- **Phone apps in windows** use Android's virtual displays. Makers can limit them, or how many
  apps can run on them at once; these reports will show which do.

## Adding a row

Maintainers add a row from each device report: the phone and Android version as reported, each
feature's result, and a note for anything that was Partly or No (with a link to its issue). A
second report for the same phone and Android version updates its row; a different Android version
gets a row of its own.
