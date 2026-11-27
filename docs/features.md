# Features

Everything Nearside does, in detail. Each section describes the Mac; the Windows app has the same
features, with its differences noted under each. For installing and setting up, see
[Getting started](getting-started.md).

## Phone apps on your computer

Any app on your phone opens in its own window on your computer, or you can open a whole second
phone with its own home screen.

- **Real windows.** They work with the Dock, ⌘-Tab, Mission Control and Spotlight, plus a
  launcher (⌥⌘P) with your recent and favourite apps. Optionally each phone app also becomes a
  small Mac app, so Raycast, Alfred and Launchpad find it.
- **The phone window.**
  - Nearside's own home screen with a dock.
  - Recents built from snapshots of your apps.
  - A notification panel (⌘3): open, reply, use a notification's buttons, or dismiss it.
- **Phone, foldable and tablet sizes.** Apps lay themselves out for each, exactly as they would
  on that device.
- **Input that feels native.** Trackpad scrolling with real flings, pinch, right-click and
  hover. Your Mac keyboard works in its own layout, and ⌘C / ⌘V copy and paste across devices.
  Return sends a message in chat apps, and Shift-Return starts a new line (Settings → Phone apps).
- **Sound** plays on the Mac, per window, or on the phone if you prefer. Apps that record (a
  WhatsApp call, a voice message) hear the Mac's microphone, only while they record.
- **Works with the phone locked** and its screen off. Your Mac asks for Touch ID or your
  password first: after it wakes, every time, or never.
- **Leaves the phone alone.** Windows never take the phone's focus, so you can keep using the
  phone and its keyboard while apps are open on the Mac.
- **Smart about resources.** Windows you aren't looking at slow down or pause. Quality adapts to
  your connection and to how warm the phone is. Windows left hidden can go back to the phone
  after a while.
- **Smooth or responsive.** Smooth evens out Wi-Fi hiccups with a small, adaptive buffer;
  Responsive shows every frame the moment it arrives.
- **Seamless hand-off.** Open the app on the phone and it moves back there. Close the window
  and it's on your phone, where you left it.
- **Up to 120 frames a second** on a fast screen, if your phone runs Android 14 or later and the
  Wi-Fi keeps up (Settings → Frame rate).

**On Windows:** each window has its own taskbar button and shows in Alt+Tab. Phone apps can go in
the Start menu, each with a small Nearside badge. The launcher is Ctrl+Alt+N, and Windows Hello
(or your PIN) stands in for Touch ID. The PC decodes on its graphics card (H.264), with Direct3D.

## Clipboard, both ways

Copy on the phone and paste on the Mac, or the other way round. It happens automatically,
without opening anything on the phone.

- The panel has two tabs: **Notifications**, what's on your phone right now, and **Clipboard**, a
  searchable history that puts any earlier clip back on both clipboards.
- A small card tells you when something arrives.
- Items that password managers mark as concealed are never recorded.
- You can also hide Android's "pasted from your clipboard" message from the Mac.
- While the phone is away, the panel shows nothing of it: only where it is, Settings, and
  **Connect** when another computer has it. Nothing is recorded meanwhile.

## Photos and screenshots

The panel shows your phone's newest photos and screenshots while it's open. Drag one into any
app or folder to get the full file, click to open it, or right-click to save it to the Desktop
or Downloads. You can also have each new phone screenshot land in Downloads, and each computer
screenshot go to the phone's gallery.

## Calls

Incoming calls ring on the Mac with Answer, Decline, or decline with a text, for phone calls and
app calls (WhatsApp, Messenger, Signal) alike. Answered or placed on the Mac, a call talks
through the Mac: its sound and the Mac's microphone, the phone's own microphone off. During a
call a small card under the menu-bar icon shows the time, Mute and End, and moves the call to the
phone and back in one click. Call a number from Messages or from clipboard history.

**On Windows:** calls ring as a Windows notification, and the in-call card sits above the
notification area.

## Phone camera as a webcam

Pick "Nearside Camera" in FaceTime, Zoom, a browser or Photo Booth: the phone's back or front
camera, upright however you hold it. The phone's camera is on only while an app uses it, and the
phone says so, with a Stop button. Turn it on in Settings → Phone camera (macOS asks you to allow
the camera extension once).

**On Windows:** it's in Teams, Zoom, the Camera app and browsers, installed with the app.

## Phone status

The menu bar shows your phone's battery, signal and network (5G, LTE) while it's connected,
and tells you once when its battery runs low.

## Notifications

Your phone's notifications appear as native macOS or Windows notifications, with their buttons
and inline replies. Dismiss one on either device and it's gone on both. **Open on Mac** (**Open
on PC**) opens a notification's app in a window, right where the notification points. The
panel's Notifications tab lists what's on the phone now.

- **Mute** them from the bell in the panel, for 1 to 24 hours or until you turn them back on.
  When it ends, what's still on the phone appears.
- **Choose the apps.** Settings → Notifications → Apps has a switch per phone app, or use **Mute
  notifications from…** on a notification. A muted app's notifications never leave the phone for
  that computer (each computer has its own list); its calls still ring.
- **While the phone is away** they're cleared from the computer, and come back quietly when it
  reconnects. After a minute away, its apps also leave Spotlight, Applications or the Start
  menu until it's back.

## Text messages

Read and send SMS in a Messages window on the Mac: conversations, threads and new messages.
Return sends, Shift-Return starts a new line. RCS chats stay in Google Messages.

## Files

- **To the phone:** drag files onto the menu-bar icon, or onto the drop shelf that slides out
  while you drag toward the top of the screen. On Windows, drop them on the panel. A transfers
  list shows progress.
- **To the computer:** use **Send to computer** in Android's share sheet. Files land in your
  Downloads.
- **Into an app:** drop files onto a phone app's window to share them straight into that app.

## Wi-Fi, USB and more than one computer

- **Plug in a USB cable** and the computer switches to it, then goes back to Wi-Fi when you
  unplug. Windows needs no driver.
- **After a reboot or a Wi-Fi change**, the phone turns wireless debugging back on and the
  computer restarts the helper. You do nothing.
- **One computer at a time.** If your Mac has the phone, the PC shows where it is, with
  **Connect** to take it over, and the other way round.

## Keyboard shortcuts

| Mac | Windows | What it does |
|---|---|---|
| ⌥⌘P | Ctrl+Alt+N | Open the launcher (change it in Settings on the Mac) |
| ⌥⇧⌘P | | Open the phone window |
| ⌘[ | Esc | Back |
| ⌘1, ⌘2, ⌘3 | | Home, Recents, Notifications (phone window) |
| ⌃⌘1, ⌃⌘2, ⌃⌘3 | | Phone, foldable, tablet size |
| ⌘+, ⌘-, ⌘0 | Drag the window's edge | Larger, smaller (⌘0: actual size) |
| ⌃⌘F | | Full screen |
| ⌥⌘I | | Show statistics (frame rate, bitrate, delay) |
| ⌘C, ⌘V | Ctrl+C, Ctrl+V | Copy and paste between the computer and the app |

On Windows the phone window's toolbar has Back, Home, Recents, Notifications and the sizes.

## Privacy and security

- **Nothing leaves your devices.** There is no server, account or telemetry.
- **Pinned to your phone.** During pairing, the computer pins your phone's TLS key (the pairing
  code authenticates it), so a look-alike device on the network is refused. Over USB, the phone
  must first prove it holds this computer's secret.
- **Mutual authentication.** The computer and the helper prove to each other that they share a
  per-computer secret, without ever sending it. The helper only trusts the shell user and the
  Nearside app, and phone-app streams need single-use tickets.
- **Touch ID, Windows Hello or your password** before phone apps are shown, because they work
  while the phone is locked. The phone always shows that apps are open on your computer, with a
  Stop button.
- **Your data stays yours.** Clipboard history lives in your user account only, readable by you
  alone. Concealed clipboard items are never stored.

The full design and threat model are in [security.md](security.md). Found a vulnerability?
Please report it privately; see [SECURITY.md](../SECURITY.md).

## Known limitations

- Apps that block screen capture (many banking apps) show black in a window. The window says so
  and offers to open the app on the phone.
- Calls on the computer use Android's in-call audio paths (the ones Pixel's Call Screen uses);
  other phones may not offer them, and then a call talks on the phone.
- The Mac webcam needs Nearside from the releases (or your own Apple developer signing, see
  [development-mac.md](development-mac.md)): macOS loads camera extensions only when signed,
  provisioned and notarised.
- The phone's own on-screen keyboard can't show in a window; you type with the computer's.
- The phone works with one computer at a time; **Connect** moves it from one to the other.
- Windows: the PC asks the phone for H.264, as Windows' own HEVC decoder is a paid extension.
- The Android app isn't on Google Play, because it needs SMS and notification access that
  Google restricts.

How it all works underneath is in [architecture.md](architecture.md).
