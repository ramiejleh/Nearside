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
        // CryptoKit's API where there's no CryptoKit (Windows).
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.2"),
    ],
    targets: [
        // BoringSSL (the crypto adb itself uses: TLS 1.3, SPAKE2), vendored from swift-nio-ssl
        // 2.37.6: see Sources/CNIOBoringSSL/README.md. Settings as in its Package.swift.
        .target(
            name: "CNIOBoringSSL",
            exclude: ["README.md", "LICENSE.txt", "NOTICE.txt", "hash.txt"],
            cSettings: [
                .define("_GNU_SOURCE"),
                .define("_POSIX_C_SOURCE", to: "200112L"),
                .define("_DARWIN_C_SOURCE"),
                // Recent Windows SDKs make <windows.h> pull in headers whose symbols collide
                // with BoringSSL's (swift-nio-ssl's note): suppress just those.
                .define("_WINSOCKAPI_", .when(platforms: [.windows])),
                .define("NOMINMAX", .when(platforms: [.windows])),
                .define("NOCRYPT", .when(platforms: [.windows])),
            ],
            cxxSettings: [
                .define("_WINSOCKAPI_", .when(platforms: [.windows])),
                .define("NOMINMAX", .when(platforms: [.windows])),
                .define("NOCRYPT", .when(platforms: [.windows])),
            ]
        ),
        // Windows' device list (cfgmgr32.h), for finding a plugged-in phone. Empty elsewhere.
        .target(name: "CWinDevices"),
        // A native adb client: wireless-debugging TLS, the adb wire protocol, shell, streams.
        .target(name: "NativeAdb", dependencies: [
            "CNIOBoringSSL",
            .target(name: "CWinDevices", condition: .when(platforms: [.windows])),
        ], linkerSettings: [
            .linkedLibrary("ws2_32", .when(platforms: [.windows])), // Winsock
            .linkedLibrary("dnsapi", .when(platforms: [.windows])), // mDNS (DnsServiceBrowse)
            .linkedLibrary("cfgmgr32", .when(platforms: [.windows])), // the device list (USB)
        ]),
        // Logic with no UI: adb, the helper tunnel, clipboard history, sync state, display streams.
        .target(name: "NearsideCore", dependencies: [
            "NativeAdb",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.windows, .linux])),
        ]),
        .testTarget(name: "NearsideCoreTests", dependencies: ["NearsideCore", "NativeAdb", "CNIOBoringSSL"]),
    ],
    cxxLanguageStandard: .cxx17 // BoringSSL's C++ parts (as swift-nio-ssl builds them)
)
