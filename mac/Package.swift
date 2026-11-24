// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nearside",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The engine shared with the Windows app.
        .package(path: "../core"),
        // App updates for release builds (see Sources/Nearside/Updates.swift).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
    ],
    targets: [
        // The engine's Mac parts (see NearsideCore's Platform): video decoding, audio, the
        // microphone, the pasteboard, notifications, screenshots.
        .target(name: "NearsideMac", dependencies: [.product(name: "NearsideCore", package: "core")]),
        // The menu-bar app. Bundle it with scripts/bundle.sh.
        .executableTarget(
            name: "Nearside",
            dependencies: [
                "NearsideMac",
                .product(name: "NearsideCore", package: "core"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // bundle.sh puts Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // The camera extension ("Nearside Camera"); bundle.sh makes it a .systemextension.
        .executableTarget(name: "NearsideCamera"),
        .testTarget(name: "NearsideMacTests", dependencies: ["NearsideMac", .product(name: "NearsideCore", package: "core")]),
    ]
)
