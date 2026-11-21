# Architecture

How Nearside is put together, and the Android behaviour that shaped it. For the security
design see [security.md](security.md); for the phone-app stream format see
[display-protocol.md](display-protocol.md).

## The three pieces

```
Mac app ──(adb over TLS, wireless debugging)──> helper (shell user) <──(Binder)──> phone app
```

- **Mac app** (`mac/`, Swift): a menu-bar app. `NearsideCore` holds the sync engine,
  protocols and the video/audio pipeline; `NativeAdb` is a complete adb client (TLS, pairing,
  streams, file sync, install) so nothing else needs installing; `Nearside` is the UI.
- **Helper** (`android/.../helper/`, Kotlin): a process the Mac starts with
  `app_process` from the phone app's own APK, over adb, so it runs as the **shell user** — the
  rights `adb shell` has. It reads the clipboard in the background, starts activities, creates
  virtual displays, injects input and captures app audio. It listens on the abstract socket
  `nearside-helper`; the Mac reaches it through an adb stream (nothing listens on the
  network).
- **Phone app** (`android/.../`, Kotlin): notifications, SMS, the share target, the phone
  window's home screen, and the "apps open on your Mac" notification. It talks to the Mac
  through the helper.

### Why a shell helper

Android lets no ordinary app read the clipboard in the background (since Android 10), nor show
other apps' screens without asking every session (MediaProjection). The shell user can do
both. This is the technique scrcpy and Shizuku use; Nearside bundles its own helper rather
than depending on either.

### Staying connected

- **Pairing** is wireless debugging's QR code (or its pairing code), handled natively on the
  Mac (TLS 1.3, SPAKE2, AES-GCM, as in AOSP's adb).
- After a reboot or Wi-Fi change Android turns wireless debugging back on by itself (on a
  trusted network); the Mac finds the phone over mDNS (`_adb-tls-connect._tcp`) and restarts
  the helper if needed. It reconnects every 6 h so Android's 7-day adb authorisation never
  lapses.
- The Mac updates the phone app when its bundled copy is newer (versionCode = commit count).

### App ⇄ helper link

Apps can't open sockets to the shell user (SELinux denies it), but Binder calls work. The
helper calls the app's ContentProvider (`dev.nearside.link`) through
`ActivityManager.getContentProviderExternal` and hands it an `IHelper` Binder; the app answers
with its `IAppCallback` (as Shizuku does). Messages the Mac sends that the helper doesn't
handle itself go to the app, and the app's messages go to the Mac (types the helper reserves
are refused).

Android 17 freezes the app even while it's a bound notification listener, which queues every
Binder call to it. The helper unfreezes it (`cmd activity unfreeze --sticky`) on every link,
and wakes it with a broadcast after each message.

## Features

### Clipboard
The helper listens to the phone's clipboard (deduplicated: Android fires twice per copy) and
sets it from the Mac. On the Mac, a pasteboard watcher sends copies (concealed and transient
types, used by password managers, are skipped) and keeps a searchable history
(`~/Library/Application Support/Nearside/history.json`, mode 0600).

Android shows "Shell pasted from your clipboard" on each phone copy. The only way to hide it is
the phone-wide "Show clipboard access" setting, so it's an explicit choice in setup.

### Notifications
`NotificationMirror` (a NotificationListenerService; the Mac grants access with
`cmd notification allow_listener`, so there's no settings screen) sends each notification with
its app icon and up to three actions. The Mac shows one `UNNotificationRequest` per phone key,
so updates replace and removals clear; dismissing on either side clears both. Inline replies
fill the action's RemoteInput. Opening a notification fires its PendingIntent through the
helper (apps can't start activities from the background) — on the phone, or into a Mac window.
On connect the phone catches the Mac up: the newest three as banners, older ones quietly.

### SMS
`SmsBridge` reads the Telephony provider and sends with `SmsManager`; the Mac grants the
permissions over adb. RCS chats live in Google Messages' private store and stay with
notification replies. Google Messages ignores the provider's read flag, so marking a
conversation read also presses that conversation notification's "Mark as read" action.

### Files
- **Phone → Mac:** the "Send to Mac" share target passes each file's descriptor to the helper,
  which stages it in a shell-only folder; the Mac pulls it into Downloads (quarantined) and the
  staged copy is deleted.
- **Mac → phone:** files dropped on the menu-bar icon or panel are pushed into
  `Download/Nearside`, with fresh timestamps and a media scan.
- **Into a phone app:** files dropped on an app's window are pushed into the phone app's own
  folder and shared into the app on that display (`ACTION_SEND`) through a non-exported
  provider with a per-share read grant.

## Phone apps on the Mac

Each window is an Android **virtual display** the helper creates; the app is launched on it (or
its task moved there) and the display is encoded and streamed to the Mac.

- **Displays live on a VirtualDevice** (Android's virtual device manager, through a
  shell-owned companion association): the device's own clipboard works while the phone is
  locked, its virtual keyboard and touchscreen give the display real input devices, and its
  virtual audio device captures only that display's sound (one per device, so one device per
  window). Plain displays with a UHID keyboard remain the fallback.
- **Video:** HEVC from the phone's hardware encoder; the Mac decodes with VideoToolbox and draws
  with Metal (vsync-paced by default, or one frame per refresh for the lowest latency). The
  phone measures how far behind the Mac is from per-frame acks and lowers the bitrate when
  Wi-Fi can't keep up. Windows you aren't looking at drop to a lower rate or pause; a shared
  budget keeps the encoder within what it can do; quality drops when the phone is warm.
- **Audio:** captured per window (48 kHz), encoded to Opus on the phone, decoded with
  AudioToolbox on the Mac behind an adaptive jitter buffer. The phone stays silent.
- **Input:** clicks and drags are touches; trackpad scrolling is a finger drag (so Android's own
  flings feel right); pinch is two fingers; right-click and hover are a mouse pointer. The Mac
  decides what's typed (its layout, dead keys, input methods) and the phone types it on the
  display's own keyboard with the matching Android layout; shortcuts map ⌘ to Ctrl.
- **Sizes:** phone, foldable and tablet presets at the phone's own density, so an app moving
  between the phone and a window only ever changes size.
- **System bars:** an invisible window per display provides the phone's status and navigation
  bar insets, so apps lay out exactly as on the phone (the Mac hides the status-bar strip).
  Adding it needs shell permissions *and* a real app process, so it's an instrumentation in
  the app's `:bars` process, started by the helper.
- **Moving back:** closing a window, or opening the app on the phone, moves the task to the
  phone (first resized to the phone's size, so apps restore their phone layout).
- **Phone window:** a whole second phone with Nearside's own home screen (Android 17
  doesn't start the Pixel launcher on such displays), Recents built from task snapshots, and a
  dock.
- **Locked phone:** displays are always-unlocked and keep a wake lock of their own, so apps work
  with the phone locked in a pocket; the Mac asks for Touch ID first.

## Android behaviour worth knowing

Measured on a Pixel 9 Pro with Android 17; earlier versions may differ.

- App ↔ shell unix sockets are denied by SELinux in both directions; Binder works.
- A bare `app_process` can't add windows ("Unknown pid"); that's why the system-bars window
  lives in an instrumentation.
- Injected key events are relabelled as the virtual US keyboard, so text is pressed on a real
  (virtual or UHID) keyboard device instead.
- Android refuses all reads of the phone's own clipboard while locked; a VirtualDevice's
  clipboard isn't affected.
- One virtual audio device per virtual device, tied to one display.
- The Exynos HEVC encoder ignores a runtime frame-rate cap: a new cap means a new encoder.
- `VirtualDisplay.setSurface(null)` stops the app; suspending the encoder keeps it running.
- Starting an instrumentation force-stops its package (the app restarts once per helper start).
