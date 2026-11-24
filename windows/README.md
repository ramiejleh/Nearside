# Nearside for Windows

Work in progress, on the `windows` branch. The plan is in the project notes; the architecture is
in [docs/architecture.md](../docs/architecture.md).

- `Package.swift`: the Swift side.
  - `WindowsPlatform`: what the engine needs from Windows (the clipboard, Mark of the Web), with
    hooks for notifications and video.
  - `NearsideBridge`: the engine (`core/`) as a DLL with a small C API, for the app.
- `App/`: the app, in C# with WinUI 3 (Windows App SDK, unpackaged). It lives in the
  notification area; its panel shows the phone, transfers and the clipboard history.
- `Spike/`: the Phase 3 test tools (not shipped).
- `scripts/make-icons.swift`: draws the app and tray icons (run on a Mac).

## Building (Windows 11, x64 or ARM64)

Needs the Swift toolchain (6.3 or later), the Visual Studio Build Tools and the .NET 10 SDK.

```
cd windows
swift build
cd App
dotnet build -p:Platform=ARM64 -r win-arm64   (or x64 / win-x64)
```

The build copies `NearsideBridge.dll` next to `Nearside.exe`. The Swift runtime DLLs come from the
toolchain on `PATH` for now; the installer will bundle them.

## How the app runs the engine

The engine runs on the app's UI thread, which is the process's main thread and so the engine's
main actor. The app pumps it (`nearside_pump`) when the engine's wake handle is signalled and on a
100 ms tick for run-loop timers. The engine reports changes as events; the app then reads a JSON
snapshot of everything the interface shows, and sends commands as JSON. See
`Sources/NearsideBridge/Bridge.swift`.

## Testing

- `Nearside.exe --demo` shows made-up content instead of connecting (for screenshots), and
  `--demo --shot <file.png>` saves the panel as drawn, then quits.
- The log is `%LOCALAPPDATA%\Nearside\nearside.log` (no phone content goes in it).
- Settings are Foundation's, in `%LOCALAPPDATA%\Nearside.exe.plist`.
