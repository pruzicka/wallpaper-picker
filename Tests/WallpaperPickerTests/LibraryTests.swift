import Foundation
import Testing
@testable import WallpaperPicker

@Suite struct LibraryTests {
    @Test func relativePaths() {
        #expect(Library.relativePath(of: "/w/lake.jpg", in: "/w") == "lake.jpg")
        #expect(Library.relativePath(of: "/w/Nature/lake.jpg", in: "/w/") == "Nature/lake.jpg")
        // Not under the folder: just the name.
        #expect(Library.relativePath(of: "/wx/lake.jpg", in: "/w") == "lake.jpg")
    }

    @Test func collections() {
        #expect(Library.collection(of: "lake.jpg") == nil)
        #expect(Library.collection(of: "Nature/lake.jpg") == "Nature")
        #expect(Library.collection(of: "Nature/Lakes/one.jpg") == "Nature")
    }

    @Test func migration() {
        // The old list becomes the current folder's.
        #expect(Library.migrated(nil, legacy: ["a.jpg"], folder: "/w") == ["/w": ["a.jpg"]])
        // Once migrated, the old one is ignored.
        #expect(Library.migrated(["/x": ["b.jpg"]], legacy: ["a.jpg"], folder: "/w") == ["/x": ["b.jpg"]])
        #expect(Library.migrated(nil as [String: [String]]?, legacy: nil, folder: "/w").isEmpty)
    }

    @Test func staleCacheEntries() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wp-\(UUID().uuidString).jpg")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let good = Library.key(file.path, values.contentModificationDate!, Int64(values.fileSize!))
        let scheme = Scheme.neutral
        func entry(_ path: String?) -> WallpaperInfo {
            WallpaperInfo(width: 1, height: 1, scheme: scheme, hue: nil, lightness: 0, edge: nil, path: path)
        }
        let info = [
            good: entry(file.path),        // still there, unchanged
            "edited": entry(file.path),    // same file, older version
            "gone": entry("/no/such/file.jpg"),
            "old": entry(nil),             // from before paths were kept
            "inUse": entry(nil),           // ...but in the folder now
        ]
        let stale = Set(Library.staleKeys(info, current: ["inUse"]))
        #expect(stale == ["edited", "gone", "old"])
    }
}
