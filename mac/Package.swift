// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nearside",
    platforms: [.macOS(.v14)],
    targets: [
        // Logic with no UI: adb, the helper tunnel, clipboard watching, history, sync state.
        .target(name: "NearsideCore"),
        // The SwiftUI menu-bar app. Bundle it with scripts/bundle.sh.
        .executableTarget(name: "Nearside", dependencies: ["NearsideCore"]),
        .testTarget(name: "NearsideCoreTests", dependencies: ["NearsideCore"]),
    ]
)
