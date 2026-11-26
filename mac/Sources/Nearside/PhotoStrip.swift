import NearsideCore
import NearsideMac
import SwiftUI
import UniformTypeIdentifiers

/// The phone's newest photos and screenshots in the panel. Drag one anywhere to get the full
/// file (pulled from the phone when it's dropped); click to open it in Preview.
struct PhotoStrip: View {
    let engine: SyncEngine
    @State private var opening: Int64?

    var body: some View {
        let photos = engine.photos
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent photos").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Drag out, or click to open").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(photos.items) { photo in
                        Thumbnail(photo: photo, data: photos.thumbnails[photo.id], busy: opening == photo.id)
                            .onTapGesture { open(photo) }
                            .onDrag { provider(for: photo) }
                            .contextMenu {
                                Button("Open") { open(photo) }
                                Button("Save to Desktop") { save(photo, to: .desktopDirectory) }
                                Button("Save to Downloads") { save(photo, to: .downloadsDirectory) }
                            }
                            .help("\(photo.name)\(photo.isScreenshot ? " (screenshot)" : "") · \(photo.date.formatted(.relative(presentation: .named)))")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func open(_ photo: PhonePhoto) {
        guard opening == nil else { return }
        opening = photo.id
        Task {
            if let url = await engine.fetchPhoto(photo) {
                // Always in Preview, never whatever app claims the file type.
                let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
                _ = try? await NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
            }
            opening = nil
        }
    }

    /// A copy in that folder (quarantined, as pulled), under a free name; Downloads shows it in Finder.
    private func save(_ photo: PhonePhoto, to directory: FileManager.SearchPathDirectory) {
        Task {
            guard let url = await engine.fetchPhoto(photo),
                  let folder = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return }
            let name = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            var target = folder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(name) (\(n))").appendingPathExtension(ext)
                n += 1
            }
            guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
            if directory == .downloadsDirectory { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        }
    }

    /// A promise of the file: Finder (or any app) asks for it on drop, and only then is it pulled.
    private func provider(for photo: PhonePhoto) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = photo.name
        let type = UTType(filenameExtension: (photo.name as NSString).pathExtension) ?? .image
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                if let url = await engine.fetchPhoto(photo) {
                    done(url, false, nil)
                } else {
                    done(nil, false, CocoaError(.fileReadUnknown))
                }
            }
            return nil
        }
        return provider
    }
}

private struct Thumbnail: View {
    let photo: PhonePhoto
    let data: Data?
    let busy: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            }
            if busy { ProgressView().controlSize(.small) }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
