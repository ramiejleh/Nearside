import Foundation
import Testing
@testable import NearsideCore

@Suite struct RecentPhotosTests {
    private func json(_ id: Int, path: String = "/sdcard/Pictures/Screenshots/Screenshot_1.png",
                      name: String = "Screenshot_1.png", screenshot: Bool = true, date: Date = Date()) -> [String: Any] {
        ["id": id, "name": name, "path": path, "date": date.timeIntervalSince1970 * 1000, "screenshot": screenshot,
         "w": 1080, "h": 2400, "size": 123_456]
    }

    @Test func parsesAPhoto() throws {
        let photo = try #require(PhonePhoto(json: json(7)))
        #expect(photo.id == 7 && photo.isScreenshot && photo.width == 1080 && photo.size == 123_456)
    }

    @Test func refusesPathsOutsideSharedStorage() {
        #expect(PhonePhoto(json: json(1, path: "/data/local/tmp/Screenshot_1.png")) == nil)
        #expect(PhonePhoto(json: json(1, path: "/sdcard/../data/Screenshot_1.png")) == nil)
        #expect(PhonePhoto(json: json(1, path: "/sdcard/DCIM/other.png")) == nil) // path must end in the name
        #expect(PhonePhoto(json: json(1, path: "/sdcard/DCIM/a/b.png", name: "a/b.png")) == nil)
    }

    @Test func onlyScreenshotsTakenWhileWatchingAreNew() throws {
        let old = try #require(PhonePhoto(json: json(1)))
        let fresh = try #require(PhonePhoto(json: json(2)))
        let photo = try #require(PhonePhoto(json: json(3, path: "/sdcard/DCIM/Camera/IMG.jpg", name: "IMG.jpg", screenshot: false)))
        let restored = try #require(PhonePhoto(json: json(4, date: Date().addingTimeInterval(-3600))))
        #expect(RecentPhotos.newScreenshots(seen: nil, in: [old]).isEmpty) // the first list
        #expect(RecentPhotos.newScreenshots(seen: [1], in: [fresh, photo, restored, old]) == [fresh])
    }
}

@MainActor @Suite struct RecentPhotosFlowTests {
    @Test func listThenThumbnailsEachAskedOnce() {
        let photos = RecentPhotos()
        var sent: [[String: Any]] = []
        photos.send = { sent.append($0) }
        let item: [String: Any] = ["id": 5, "name": "a.jpg", "path": "/sdcard/DCIM/Camera/a.jpg", "date": 1_700_000_000_000.0]
        photos.handle(["t": "photos", "items": [item]])
        photos.handle(["t": "photos", "items": [item]]) // a burst: not asked again
        #expect(sent.filter { $0["t"] as? String == "photos-thumbs" }.count == 1)
        photos.handle(["t": "photo-thumb", "id": 5, "jpeg": Data([1, 2, 3]).base64EncodedString()])
        photos.handle(["t": "photo-thumb", "id": 9, "jpeg": Data([1]).base64EncodedString()]) // not listed
        #expect(photos.items.map(\.id) == [5])
        #expect(photos.thumbnails[5] == Data([1, 2, 3]) && photos.thumbnails[9] == nil)
    }
}
