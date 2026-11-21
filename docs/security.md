# Security design

Nearside runs a helper with `adb shell` rights on the phone and can show and control the
phone's apps from the Mac, so it is designed so that only *your* Mac, talking to *your* phone,
can use any of it. To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## What's protected, from whom

- **Other devices on the network** must not read or inject anything, nor pose as the phone or
  the Mac.
- **Other apps on the phone** must not reach the helper's rights, read what's synced, or forge
  messages.
- **Other users and processes on the Mac** must not read the history or the secrets.

Out of scope: an attacker who has already unlocked the Mac as you, or who has root on the phone.

## Transport: adb over TLS, pinned

- The Mac's own adb client speaks wireless debugging's TLS 1.3. Stock adb accepts any phone
  certificate; Nearside **pins the phone's TLS key**. It's learned seconds after the
  code-checked pairing, only from the address the pairing reached and only if exactly one key
  answers there (several stop setup with a warning). Any other key is refused before adb data.
- Every adb operation is tied to the phone pinned during pairing; nothing is adopted
  automatically.
- Residual risk, stated plainly: an attacker on your network during those seconds of setup who
  also takes over the phone's address, and is the only one answering, could be pinned. Android
  gives no way to show the key on the phone to compare.
- The Mac's adb key is `~/.android/adbkey` if stock adb made one, else its own (RSA 2048,
  mode 0600).
- **USB cable.** When the paired phone is plugged in, the Mac uses the cable instead of Wi-Fi.
  A cable has no TLS key to pin (the phone checks the Mac's RSA key, as stock adb does; if it
  doesn't know it yet it asks "Allow USB debugging?"), and a USB serial number is easy to fake.
  So before anything else is sent, the device must prove it's the paired phone: it must hold this
  Mac's token, which was written over the pinned Wi-Fi connection into a folder only the shell
  user can read. The Mac reads it back and compares locally; the token is never sent to an
  unproven device. A device that fails is not tried again until it's plugged in again.
- Residual risk on the cable, stated plainly: adb's USB auth signs whatever challenge the device
  sends before it can be proven (stock adb does the same). Someone with your phone plugged into
  their own computer and a device in your Mac's USB port could relay one challenge and get adb
  on your phone over their cable. The signature can't be reused on Wi-Fi (TLS 1.3 signs
  differently), and nothing of yours is sent to their device.

## Mac ⇄ helper

- Each Mac has a 256-bit token (`~/Library/Application Support/Nearside/token`, mode 0600)
  that never crosses the network: it reaches the phone inside the encrypted adb connection, as
  the helper's environment (readable only by the shell user) or a file in a shell-only folder
  (`/data/local/tmp/nearside-macs`, 0700/0600, one per Mac).
- **Mutual challenge-response:** the helper sends a nonce, the Mac answers with
  HMAC(token, "nearside-mac:" + nonce) plus its own nonce, and the helper must answer
  HMAC(token, "nearside-phone:" + macNonce). Neither side sends anything until the other has
  proven itself; one challenge per connection, a 5 s deadline, bounded sizes.
- The Mac only trusts a process named exactly `nearside-helper` owned by `shell` (no app can
  run as shell).
- **More than one Mac:** each has its own token; the newest takes over and the other is told so.

## Helper ⇄ phone app

- The helper only accepts Binder calls from the Nearside app's uid, and only hands its
  Binder to the provider belonging to `dev.nearside`.
- The link provider is guarded by `INTERACT_ACROSS_USERS_FULL` (shell has it, third-party apps
  can't) and only accepts calls from the shell uid.
- Message types the helper produces itself (files ready, display control) are reserved: the
  app can't forge them. Messages are capped at 1 MB.
- `sendIntentOnDisplay` (used to open notifications and share files into windows) is callable
  only by the app's uid and only targets Nearside's own displays.

## Phone apps on the Mac

- Each window's streams need a **single-use ticket** (10 s, bound to the session) issued over
  the authenticated control link, and every stream starts with an HMAC proof in both
  directions. The display socket only accepts the shell uid, and no tickets are issued if
  another process holds the socket name.
- Phone apps work while the phone is locked, so the Mac asks for **Touch ID or your password**
  (by default after the Mac wakes or unlocks; configurable) and covers open windows when the
  Mac sleeps or locks.
- The phone always shows a notification while apps are open on a Mac, with a **Stop** button.
- Apps that block screen capture (FLAG_SECURE) stay black; the window says so.
- Files dropped into a window are shared with that one app through a non-exported provider with
  a per-share read grant.

## Files and data

- Received files are quarantined (`com.apple.quarantine`), so Gatekeeper checks anything
  executable, and always announced with a notification.
- The share target only accepts `content://` URIs from other apps' providers (never
  `file://`, never our own files). File names are sanitised on both sides.
- Clipboard history stays in your Mac account (mode 0600); concealed clipboard items are never
  recorded. Nothing is sent anywhere but between your two devices: no server, no telemetry.

## Known limitations

- Any foreground phone app can invoke "Send to Mac" with a file of its choosing (Android's share
  sheet doesn't tell the target who started it). The notification and quarantine contain this.
- Android's own "Wireless debugging connected" notification stays while the Mac is attached.
- One-time codes may arrive redacted in mirrored notifications (Android 17 hides them from
  listeners it doesn't trust).
