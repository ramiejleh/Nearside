import NearsideCore
import NearsideMac
import AppKit
import CoreServices
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// The phone's apps as tiny Mac apps in ~/Applications/Nearside Phone Apps, so launchers that
/// only list real applications (Raycast, Alfred, Launchpad, Spotlight's app results) find them.
/// Each is a script that opens `nearside://open?package=<package>`; Nearside opens the window.
/// Kept in step with the phone's app list; only bundles carrying our marker are ever removed.
@MainActor
enum PhoneAppLaunchers {
    static let enabledKey = "PhoneApps.launchers"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true)
        .appendingPathComponent("Nearside Phone Apps", isDirectory: true)

    /// Info.plist key holding the package: marks a bundle as ours.
    private static let marker = "NearsidePhoneApp"
    private static let signatureKey = "PhoneApps.launchersSignature"

    /// Writes a launcher per app and removes those for apps no longer on the phone.
    /// `hasIcon` is cheap (the signature); `icon` draws a PNG, so it's only asked when writing.
    static func sync(_ apps: [PhoneApp], hasIcon: (PhoneApp) -> Bool, icon: (PhoneApp) -> Data?) {
        guard enabled else { return }
        // "badged": icons carry the Nearside badge (launchers from before it are redrawn).
        let signature = "badged\n" + apps.map { "\($0.package)|\($0.label)|\($0.version)|\(hasIcon($0))" }.sorted().joined(separator: "\n")
        let hash = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        guard UserDefaults.standard.string(forKey: signatureKey) != hash || !FileManager.default.fileExists(atPath: folder.path) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var wanted: Set<String> = []
        var used: Set<String> = []
        for app in apps.sorted(by: { $0.package < $1.package }) where isSafePackage(app.package) {
            var name = "\(fileName(app.label)) (Phone)"
            if used.contains(name.lowercased()) { name = "\(fileName(app.label)) (\(app.package)) (Phone)" } // two apps, one label
            used.insert(name.lowercased())
            let bundle = folder.appendingPathComponent("\(name).app", isDirectory: true)
            wanted.insert(bundle.lastPathComponent)
            write(app, to: bundle, icon: icon(app))
        }
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where item.pathExtension == "app" && !wanted.contains(item.lastPathComponent) && isOurs(item) {
            try? fm.removeItem(at: item)
        }
        UserDefaults.standard.set(hash, forKey: signatureKey)
        NSLog("Nearside: \(wanted.count) phone app launchers in \(folder.path)")
    }

    /// Removes every launcher (the setting turned off); the folder goes too if nothing else is in it.
    static func removeAll() {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where isOurs(item) {
            try? fm.removeItem(at: item)
        }
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
            try? fm.removeItem(at: folder)
        }
        UserDefaults.standard.removeObject(forKey: signatureKey)
    }

    /// The package from a launcher's link, if it's one (nearside://open?package=…).
    static func package(from url: URL) -> String? {
        guard url.scheme == "nearside", url.host == "open",
              let package = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "package" })?.value,
              isSafePackage(package) else { return nil }
        return package
    }

    // MARK: -

    private static func write(_ app: PhoneApp, to bundle: URL, icon: Data?) {
        let fm = FileManager.default
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try? fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.nearside.mac.phone-app.\(app.package)",
            "CFBundleName": app.label,
            "CFBundleDisplayName": app.label,
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true, // no Dock icon: it only hands over to Nearside
            "LSMinimumSystemVersion": "14.0",
            marker: app.package,
        ]
        if let plist = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
            try? plist.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        }
        // The package is checked to be letters, digits, dots and underscores: nothing to quote.
        let script = "#!/bin/sh\nexec /usr/bin/open \"nearside://open?package=\(app.package)\"\n"
        let launch = macOS.appendingPathComponent("launch")
        try? Data(script.utf8).write(to: launch, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launch.path)
        if let icon, let icns = icns(fromPNG: icon) {
            try? icns.write(to: resources.appendingPathComponent("AppIcon.icns"), options: .atomic)
        }
        LSRegisterURL(bundle as CFURL, true) // Launch Services (and so Raycast, Spotlight) see it now
    }

    /// Nearside's own icon, small in the corner of each launcher's: tells them from real Mac apps.
    private static let badge: CGImage? = {
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        return NSApp.applicationIconImage?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }()

    /// An .icns with the usual sizes, from the phone's icon, with Nearside's badge.
    private static func icns(fromPNG png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        let sizes = [16, 32, 64, 128, 256, 512]
        guard let destination = CGImageDestinationCreateWithData(out, UTType.icns.identifier as CFString, sizes.count, nil) else { return nil }
        for size in sizes {
            guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.interpolationQuality = .high
            // A little margin, as Mac app icons have.
            let inset = CGFloat(size) * 0.08
            context.draw(image, in: CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset))
            if let badge, size >= 32 { // bottom right (Core Graphics counts up from the bottom)
                let side = CGFloat(size) * 0.4
                context.setShadow(offset: CGSize(width: 0, height: -CGFloat(size) * 0.01), blur: CGFloat(size) * 0.03,
                                  color: CGColor(gray: 0, alpha: 0.35))
                context.draw(badge, in: CGRect(x: CGFloat(size) - side, y: 0, width: side, height: side))
            }
            if let scaled = context.makeImage() { CGImageDestinationAddImage(destination, scaled, nil) }
        }
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    private static func isOurs(_ bundle: URL) -> Bool {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return info[marker] is String
    }

    static func isSafePackage(_ package: String) -> Bool {
        !package.isEmpty && package.count <= 255 && package.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }
    }

    /// A label as a file name: no slashes or colons, no leading dot, not too long.
    private static func fileName(_ label: String) -> String {
        var name = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return String((name.isEmpty ? "App" : name).prefix(80))
    }
}
