import AppKit
import CryptoKit
import Observation

struct Wallpaper: Identifiable, Hashable, Sendable {
    let url: URL
    let fileName: String
    let fileSize: Int64
    let modified: Date
    // Names this version of the file in the caches.
    let key: String

    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var format: String { url.pathExtension.uppercased() }
}

struct WallpaperInfo: Codable, Sendable {
    var width: Int
    var height: Int
    var scheme: Scheme
    var hue: Double?
    var lightness: Double
}

// The wallpaper folder: what's in it (kept up to date as files come and
// go), each wallpaper's size and colours, and the favourites.
@MainActor @Observable
final class Library {
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Wallpapers", isDirectory: true)
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"]

    private(set) var folder: URL
    private(set) var items: [Wallpaper] = []
    private(set) var info: [String: WallpaperInfo] = [:]
    private(set) var favourites: Set<String> = []
    private(set) var currentPath: String?

    @ObservationIgnored var onItemsChanged: (() -> Void)?
    @ObservationIgnored var onAnalysisFinished: (() -> Void)?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var analyzeTask: Task<Void, Never>?
    @ObservationIgnored private var rescanPending = false

    init() {
        Store.prepare()
        if let saved = UserDefaults.standard.string(forKey: "folder") {
            folder = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            folder = Self.defaultFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        favourites = Set(Store.read([String].self, from: Store.favourites) ?? [])
        info = Store.read([String: WallpaperInfo].self, from: Store.index) ?? [:]
        refreshCurrent()
        scan()
        watch()
    }

    func choose(folder url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: "folder")
        scan()
        watch()
    }

    // MARK: Current wallpaper

    func refreshCurrent() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        currentPath = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }?
            .resolvingSymlinksInPath().path
    }

    func markCurrent(_ wp: Wallpaper) {
        currentPath = wp.url.path
    }

    func isCurrent(_ wp: Wallpaper) -> Bool {
        wp.url.path == currentPath
    }

    // MARK: Favourites

    func isFavourite(_ wp: Wallpaper) -> Bool {
        favourites.contains(wp.fileName)
    }

    func toggleFavourite(_ wp: Wallpaper) {
        if favourites.contains(wp.fileName) {
            favourites.remove(wp.fileName)
        } else {
            favourites.insert(wp.fileName)
        }
        Store.write(favourites.sorted(), to: Store.favourites)
    }

    // MARK: Scanning

    func scan() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var found: [Wallpaper] = []
        for url in urls where Self.extensions.contains(url.pathExtension.lowercased()) {
            let resolved = url.resolvingSymlinksInPath()
            guard let values = try? resolved.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)
            found.append(Wallpaper(url: resolved, fileName: url.lastPathComponent, fileSize: size,
                                   modified: modified, key: Self.key(resolved.path, modified, size)))
        }
        found.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        guard found != items else { return }
        items = found
        onItemsChanged?()
        analyze()
    }

    private static func key(_ path: String, _ modified: Date, _ size: Int64) -> String {
        let digest = SHA256.hash(data: Data("\(path)|\(modified.timeIntervalSince1970)|\(size)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // New, removed or renamed files show up without a restart.
    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleRescan() {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.rescanPending = false
                self?.scan()
            }
        }
    }

    // MARK: Analysis

    // Thumbnails and colours for every wallpaper not read yet, the one on
    // the desktop first, four at a time.
    private func analyze() {
        analyzeTask?.cancel()
        var todo = items.filter { info[$0.key] == nil }
        guard !todo.isEmpty else { return }
        if let i = todo.firstIndex(where: isCurrent) {
            todo.insert(todo.remove(at: i), at: 0)
        }
        analyzeTask = Task { [weak self] in
            await withTaskGroup(of: (String, WallpaperInfo?).self) { group in
                var queue = todo[...]
                for _ in 0..<min(4, queue.count) {
                    let wp = queue.removeFirst()
                    group.addTask { (wp.key, await Analyzer.analyze(wp)) }
                }
                var done = 0
                while let (key, result) = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if let result { self?.info[key] = result }
                    done += 1
                    if done % 25 == 0 { self?.saveIndex() }
                    if !queue.isEmpty {
                        let wp = queue.removeFirst()
                        group.addTask { (wp.key, await Analyzer.analyze(wp)) }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self?.saveIndex()
            self?.onAnalysisFinished?()
        }
    }

    private func saveIndex() {
        Store.write(info, to: Store.index)
    }
}
