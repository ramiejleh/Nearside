// swift-tools-version: 6.0
import PackageDescription

// The Windows app's Swift side: the engine (core/) with this PC's platform, as a DLL the C# app
// loads (NearsideBridge, a C API in include/nearside.h). See docs/architecture.md.
let package = Package(
    name: "windows",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WindowsPlatform", targets: ["WindowsPlatform"]),
        .library(name: "NearsideBridge", type: .dynamic, targets: ["NearsideBridge"]),
    ],
    dependencies: [.package(path: "../core")],
    targets: [
        // The clipboard, Mark of the Web, and hooks for notifications and video.
        .target(name: "WindowsPlatform", dependencies: [.product(name: "NearsideCore", package: "core")]),
        .target(name: "NearsideBridge", dependencies: [.product(name: "NearsideCore", package: "core"), "WindowsPlatform"]),
    ]
)
