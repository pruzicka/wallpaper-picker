import Foundation
import Testing
@testable import WallpaperPicker

@Suite struct LibraryTests {
    @Test func relativePaths() {
        #expect(Library.relativePath(URL(fileURLWithPath: "/w/lake.jpg"), level: 1) == "lake.jpg")
        #expect(Library.relativePath(URL(fileURLWithPath: "/w/Nature/lake.jpg"), level: 2) == "Nature/lake.jpg")
        #expect(Library.relativePath(URL(fileURLWithPath: "/w/Nature/Lakes/one.jpg"), level: 3) == "Nature/Lakes/one.jpg")
    }

    // The bug: the folder chosen as ~/Pictures/Wallpapers, on disk
    // ~/Pictures/wallpapers, lost its subfolders.
    @Test func scanFindsSubfoldersWhateverTheCase() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wp-\(UUID().uuidString)")
        let real = base.appendingPathComponent("walls/Nature", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        FileManager.default.createFile(atPath: real.appendingPathComponent("lake.jpg").path, contents: Data([1]))
        let spelt = base.appendingPathComponent("WALLS", isDirectory: true)
        let walker = FileManager.default.enumerator(at: spelt, includingPropertiesForKeys: nil)!
        var found: [String] = []
        while let url = walker.nextObject() as? URL {
            if url.pathExtension == "jpg" { found.append(Library.relativePath(url, level: walker.level)) }
        }
        #expect(found == ["Nature/lake.jpg"])
        #expect(Library.collection(of: found[0]) == "Nature")
        #expect(Library.canonicalPath(spelt).hasSuffix("/walls"))
    }

    @Test func sameFolderSpeltTwiceMerges() {
        let lower = { (p: String) in p.lowercased() }
        let merged = Library.rekeyed(["/P/Walls": ["a.jpg"], "/p/walls": ["b.jpg", "a.jpg"], "/x": ["c.jpg"]],
                                     by: lower) { Array(Set($0).union($1)).sorted() }
        #expect(merged == ["/p/walls": ["a.jpg", "b.jpg"], "/x": ["c.jpg"]])
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
