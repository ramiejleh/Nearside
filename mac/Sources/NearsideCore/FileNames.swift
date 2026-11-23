import Foundation

/// File-name hygiene for files crossing between the devices.
public enum FileNames {
    /// A plain name: no directories, no control characters, not hidden, not empty.
    public static func safe(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
            .unicodeScalars.filter { $0.value >= 0x20 && $0 != "/" && $0 != ":" }
        var cleaned = String(String.UnicodeScalarView(base)).trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
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
