// swift-tools-version: 6.0
import PackageDescription

// The engine shared by the Mac and Windows apps: adb, the helper link, the display protocol,
// clipboard and notification sync, calls, photos. Platform-specific parts are behind `Platform`
// (Sources/NearsideCore/Platform.swift), implemented by each app.
let package = Package(
    name: "NearsideCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NativeAdb", targets: ["NativeAdb"]),
        .library(name: "NearsideCore", targets: ["NearsideCore"]),
    ],
    dependencies: [
        // Only for its bundled BoringSSL (the crypto adb itself uses: TLS 1.3, SPAKE2).
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.6"),
        // CryptoKit's API where there's no CryptoKit (Windows).
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.2"),
    ],
    targets: [
        // A native adb client: wireless-debugging TLS, the adb wire protocol, shell, streams.
        .target(name: "NativeAdb", dependencies: [.product(name: "NIOSSL", package: "swift-nio-ssl")]),
        // Logic with no UI: adb, the helper tunnel, clipboard history, sync state, display streams.
        .target(name: "NearsideCore", dependencies: [
            "NativeAdb",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.windows, .linux])),
        ]),
        .testTarget(name: "NearsideCoreTests", dependencies: ["NearsideCore", "NativeAdb"]),
    ]
)
