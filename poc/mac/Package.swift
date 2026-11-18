// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nearside-poc",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "nearside-poc"),
    ],
    // Throwaway PoC: all mutable state lives on the main queue; skip strict concurrency.
    swiftLanguageModes: [.v5]
)
