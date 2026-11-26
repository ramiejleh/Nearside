# Nearside for Windows

The Windows app: the engine (`core/`) as a DLL, a C# WinUI 3 app on top, the webcam's media
source (C++) and the installer.

- `Package.swift`, `Sources/`: `WindowsPlatform` (the engine's Windows parts) and `NearsideBridge`
  (the engine as `NearsideBridge.dll`, with a JSON C API).
- `App/`: the app (WinUI 3, Windows App SDK, unpackaged).
- `Camera/`: `NearsideCamera.dll`, the virtual camera.
- `installer/`, `scripts/release.ps1`: the installer and the release script.
- `Spike/`: console tools from the port's first steps (not shipped).

Building, the camera, USB, test switches and how the app runs the engine:
[docs/development-windows.md](../docs/development-windows.md). Releasing:
[docs/releasing.md](../docs/releasing.md).
