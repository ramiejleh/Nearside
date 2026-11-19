import Foundation
import Security

/// Gets adb without Homebrew: downloads Google's official platform-tools into Application
/// Support and only keeps it if adb carries Google's Developer ID signature. Downloading
/// (rather than shipping it in the app) keeps us clear of the Android SDK licence's
/// redistribution terms.
public enum AdbInstaller {
    static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
    /// Google LLC's Apple Developer ID team.
    static let googleTeam = "EQHXZ8M8AV"

    public static var installDirectory: URL { Paths.support.appendingPathComponent("platform-tools", isDirectory: true) }
    public static var installedAdb: URL { installDirectory.appendingPathComponent("adb") }

    public enum Failure: Error, Sendable, Equatable {
        case download(String)
        case unpack
        case notGoogleSigned
        case missingAdb

        public var message: String {
            switch self {
            case .download(let reason): "The download didn't work (\(reason)). Check your internet connection and try again."
            case .unpack: "The download couldn't be unpacked. Try again."
            case .notGoogleSigned: "The downloaded adb isn't signed by Google, so it wasn't installed."
            case .missingAdb: "The download didn't contain adb."
            }
        }
    }

    /// Downloads, unpacks, verifies and installs. `progress` gets 0…1 during the download.
    public static func install(progress: @escaping @Sendable (Double) -> Void) async -> Result<URL, Failure> {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("nearside-adb-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return .failure(.unpack)
        }

        // 1. Download.
        let zip = work.appendingPathComponent("platform-tools.zip")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failure(.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            }
            let expected = max(response.expectedContentLength, 1)
            fm.createFile(atPath: zip.path, contents: nil)
            let handle = try FileHandle(forWritingTo: zip)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            var received: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(min(Double(received) / Double(expected), 1))
                }
            }
            try handle.write(contentsOf: buffer)
            progress(1)
        } catch {
            return .failure(.download(error.localizedDescription))
        }

        // 2. Unpack (ditto keeps permissions and the code signatures intact).
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            return .failure(.unpack)
        }
        guard ditto.terminationStatus == 0 else { return .failure(.unpack) }
        let tools = unpacked.appendingPathComponent("platform-tools", isDirectory: true)
        let adb = tools.appendingPathComponent("adb")
        guard fm.isExecutableFile(atPath: adb.path) else { return .failure(.missingAdb) }

        // 3. Only Google's adb.
        guard isGoogleSigned(adb) else { return .failure(.notGoogleSigned) }

        // 4. Install (replacing an older copy).
        do {
            try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installDirectory.path) { try fm.removeItem(at: installDirectory) }
            try fm.moveItem(at: tools, to: installDirectory)
        } catch {
            return .failure(.unpack)
        }
        return .success(installedAdb)
    }

    /// Valid signature, Apple-issued Developer ID chain, Google's team, identifier "adb".
    public static func isGoogleSigned(_ file: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"adb\" and certificate leaf[subject.OU] = \"\(googleTeam)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
