// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nearside",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Only for its bundled BoringSSL (the crypto adb itself uses: TLS 1.3, SPAKE2).
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.6"),
    ],
    targets: [
        // A native adb client: wireless-debugging TLS, the adb wire protocol, shell, streams.
        .target(name: "NativeAdb", dependencies: [.product(name: "NIOSSL", package: "swift-nio-ssl")]),
        // Logic with no UI: adb, the helper tunnel, clipboard watching, history, sync state.
        .target(name: "NearsideCore", dependencies: ["NativeAdb"]),
        // The menu-bar app. Bundle it with scripts/bundle.sh.
        .executableTarget(name: "Nearside", dependencies: ["NearsideCore"]),
        // Gate B viewer (dev tool): streams a phone app into a Metal window and measures latency.
        .executableTarget(name: "atview", dependencies: ["NativeAdb"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NearsideCoreTests", dependencies: ["NearsideCore", "NativeAdb"]),
    ]
)
