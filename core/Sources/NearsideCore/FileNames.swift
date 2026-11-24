import Foundation

/// File-name hygiene for files crossing between the devices.
public enum FileNames {
    /// A plain name: no directories, no control characters, not hidden, not empty. On Windows
    /// also none of its reserved characters or device names (CON, NUL, COM1…), and no trailing
    /// dots or spaces (Windows drops them, so "x.exe." would land as "x.exe").
    public static func safe(_ name: String) -> String {
        #if os(Windows)
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let banned: Set<Unicode.Scalar> = ["/", "\\", ":", "<", ">", "\"", "|", "?", "*"]
        #else
        let last = (name as NSString).lastPathComponent
        let banned: Set<Unicode.Scalar> = ["/", ":"]
        #endif
        let base = last.unicodeScalars.filter { $0.value >= 0x20 && !banned.contains($0) }
        var cleaned = String(String.UnicodeScalarView(base)).trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        #if os(Windows)
        while cleaned.hasSuffix(".") || cleaned.hasSuffix(" ") { cleaned.removeLast() }
        let device = (cleaned.split(separator: ".").first.map(String.init) ?? "").uppercased()
        if ["CON", "PRN", "AUX", "NUL"].contains(device) || ((device.hasPrefix("COM") || device.hasPrefix("LPT"))
            && device.count == 4 && device.last!.isNumber) {
            cleaned = "_" + cleaned
        }
        #endif
        guard !cleaned.isEmpty else { return "file" }
        guard cleaned.count > 200 else { return cleaned }
        // Too long: shorten the stem, never the extension (cutting "x.command.jpg" in the
        // middle could leave a different, runnable type).
        let ext = (cleaned as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 16 else { return String(cleaned.prefix(200)) }
        let stem = (cleaned as NSString).deletingPathExtension
        return String(stem.prefix(200 - ext.count - 1)) + "." + ext
    }

    /// "photo.jpg", 2 → "photo (2).jpg"
    public static func numbered(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
    }

    /// A path in `directory` for `name` that doesn't exist yet.
    public static func unique(_ name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var url = directory.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(numbered(name, n))
            n += 1
        }
        return url
    }
}
