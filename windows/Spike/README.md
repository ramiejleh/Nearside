# Windows test tools (Phase 3)

Not shipped: they check core/'s engine on Windows before the real app (C# WinUI, Phase 4).

- `nearside-spike`: adb alone. `find` (mDNS), `pair <ip> <pairing port> <code> <debugging port>`,
  `shell <ip> <port> <command>`.
- `nearside-engine`: the whole SyncEngine in a console. `pair <ip:port> <code> <apk>` sets up
  (pairing, the phone app, the helper); without arguments it reconnects and syncs the clipboard.
  `engine-test.ps1` runs setup, a copy and a restart in one go.
- `nearside-window`: the phone's home screen in a window. FFmpeg decodes H.264 (software), GDI
  draws it, the left mouse button is a finger. Prints frame rate, bitrate, latency and decode time.

Building (in the VM): `swift build`, and for the window FFmpeg's LGPL shared build (BtbN
FFmpeg-Builds, winarm64 8.1) unpacked somewhere, with its DLLs next to the exe:

    swift build --product nearside-window -Xcc -I<ffmpeg>\include -Xlinker -L<ffmpeg>\lib

A window must run in the logged-in desktop session (not over SSH): start it with a one-off
scheduled task (`schtasks /create ... /it`, then `schtasks /run`). Each tool keeps its settings
under its own exe name (Foundation on Windows), so copy `%LOCALAPPDATA%\nearside-engine.exe.plist`
to `nearside-window.exe.plist` to reuse the engine's pairing. Each SSH session has its own clipboard.
