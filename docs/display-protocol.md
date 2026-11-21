# Phone-app stream protocol

The binary protocol between the Mac and the helper for phone-app windows. Mac side:
`mac/Sources/NearsideCore/Display/DisplayProtocol.swift` (encoders, decoder, tests);
helper side: `android/.../helper/display/DisplayServer.kt` and `DisplaySession.kt`.

## Connection

1. On the authenticated control link (JSON), the Mac asks for a **ticket**: 32 random bytes,
   single use, valid 10 s.
2. It opens up to three adb streams to the abstract socket `nearside-display` (the helper
   only accepts the shell uid): **control** (role 1), **video** (2), **audio** (3).
3. Each stream starts with HELLO: `"ATD1"`, u16 version (1), u8 role, 16-byte session id,
   32-byte ticket, then HMAC-SHA256 with the Mac's token over
   `nearside-display:<role>:<session hex>:<ticket hex>`. The helper answers HELLO with
   HMAC over `nearside-display-server:…` (same values); the Mac drops the stream otherwise.
4. A dropped session can be resumed for 30 s (RESUME) without relaunching the app.

## Framing

Every packet: `u8 type, u8 flags, u32 big-endian length, payload`. All integers are big-endian;
coordinates are floats (IEEE 754 bits) normalised to the video, 0…1. Packets over 16 MiB end the
stream; control packets are read up to 1 MiB. Unknown or short packets are ignored.

## Mac → phone (control stream)

| Type | Name | Payload |
|---|---|---|
| 0x10 | OPEN | u16 w, u16 h, u16 dpi, u8 fps, u32 kbps, utf8 target (`pkg`, `pkg/activity`, `home`, `notification:<key hex>`) |
| 0x11 | RESUME | (empty) reattach to the session named in HELLO |
| 0x12 | TOUCH | u8 action (down/up/move/cancel), u8 pointer, u32 gen, f32 x, f32 y, u64 event µs |
| 0x13 | RESIZE | u16 w, u16 h, u16 dpi |
| 0x14 | NAV | u8 1 = Back, 2 = Home (phone window) |
| 0x15 | PING | u64 t0 (answered by PONG; gives the clock offset) |
| 0x16 | VISIBILITY | 0 focused, 1 hidden, 2 visible |
| 0x17 | CLOSE | the app goes back to the phone; u8 1 = to the front of the phone's screen (Open on Phone) |
| 0x18 | SYNC | request a keyframe |
| 0x19 | SCROLL | u32 gen, f32 x, f32 y, f32 h, f32 v (wheel notches) |
| 0x1A | MOUSE | u8 action (hover/exit/secondary down/up), u32 gen, f32 x, f32 y |
| 0x1B | KEY | u16 Android key code, u32 meta state |
| 0x1C | TEXT | utf8 text to type |
| 0x1D | LAYOUT | utf8 keyboard-layout hint |
| 0x1E | PASTE | utf8 text to paste |
| 0x1F | ACK | u64 pts µs of a frame that arrived (flow control) |
| 0x40 | BLACK | u8 1 = the picture went all black, 0 = no longer |
| 0x41 | RECENTS | phone window: list its apps (TASKS + SNAPSHOTs) |
| 0x42 | TASK_FRONT | i32 task |
| 0x43 | TASK_REMOVE | i32 task |
| 0x44 | DOCK | utf8 packages, one per line, for the home screen's dock |
| 0x45 | NOTIFICATION | utf8 notification key to open in this window |
| 0x46 | SHARE | utf8 names (one per line) of files already pushed, to share into the app |
| 0x47 | SOUND | u8 0 = the window's sound stays on the phone (sent right after OPEN) |
| 0x48 | TOUCHES | u32 gen, u64 event µs, u8 n, n × (u8 action, u8 pointer, f32 x, f32 y): fingers that changed together (pinch, rotate) |

## Phone → Mac

| Type | Name | Stream | Payload |
|---|---|---|---|
| 0x01 | HELLO | all | 32-byte server proof |
| 0x20 | TASK | control | i32 task id, utf8 package |
| 0x21 | TASK_GONE | control | u8 0 exited, 1 moved to the phone |
| 0x22 | PONG | control | u64 t0, u64 phone µs |
| 0x23 | ERROR | control | u8 code, utf8 message |
| 0x24 | THERMAL | control | u8 1 = quality reduced (phone warm) |
| 0x25 | SECURE | control | u8 1 = an app on the display blocks capture |
| 0x26 | TASKS | control | JSON `[{"id":…,"pkg":…}]`, top first |
| 0x27 | SNAPSHOT | control | i32 task, JPEG |
| 0x28 | INSETS | control | u16 top, u16 bottom (px); the Mac hides the top bar |
| 0x30 | CONFIG | video | u32 gen, u16 w, u16 h, HEVC parameter sets |
| 0x31 | FRAME | video | u32 gen, u64 pts µs, u64 encode µs, u8 keyframe, HEVC data |
| 0x32 | AUDIO_CONFIG | audio | u32 sample rate, u8 channels |
| 0x33 | AUDIO | audio | u64 pts µs, one 20 ms Opus packet; no packet: silence follows (nothing is sent until there's sound) |

`gen` increases with every resize; input carrying an old `gen` is dropped, so a touch meant for
the previous size never lands in the wrong place.
