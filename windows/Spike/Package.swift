// swift-tools-version: 6.0
import PackageDescription

// Phase 3 test tools for Windows (not shipped), on core/'s engine. See README.md.
let package = Package(
    name: "NearsideSpike",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../core")],
    targets: [
        // Pairs and runs adb commands with the adb client alone.
        .executableTarget(name: "nearside-spike", dependencies: [.product(name: "NativeAdb", package: "core")]),
        // The engine's Windows platform for these tools: the clipboard, Mark of the Web.
        .target(name: "SpikePlatform", dependencies: [.product(name: "NearsideCore", package: "core")]),
        // The whole engine (SyncEngine) in a console.
        .executableTarget(name: "nearside-engine", dependencies: [.product(name: "NearsideCore", package: "core"), "SpikePlatform"]),
        // FFmpeg's C API.
        .systemLibrary(name: "CFFmpeg"),
        // The phone window: H.264 decoded with FFmpeg, drawn with GDI, clicks sent back as touches.
        .executableTarget(name: "nearside-window", dependencies: [
            .product(name: "NearsideCore", package: "core"), "SpikePlatform",
            .target(name: "CFFmpeg", condition: .when(platforms: [.windows])),
        ]),
    ]
)
