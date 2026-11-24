// swift-tools-version: 6.0
import PackageDescription

// Phase 3 test tool for Windows: pairs with the phone and talks adb to it, through core/'s adb
// client (Winsock + BoringSSL). Not shipped.
let package = Package(
    name: "NearsideSpike",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../core")],
    targets: [
        .executableTarget(name: "nearside-spike", dependencies: [.product(name: "NativeAdb", package: "core")]),
    ]
)
