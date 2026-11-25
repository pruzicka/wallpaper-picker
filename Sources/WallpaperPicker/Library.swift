import AppKit
import CoreServices
import CryptoKit
import Observation

struct Wallpaper: Identifiable, Hashable, Sendable {
    let url: URL
    let fileName: String
    // From the wallpaper folder, e.g. "Nature/lake.jpg"; names it in the
    // favourites, fit modes and rotation history.
    let relativePath: String
    let fileSize: Int64
    let modified: Date
    // Names this version of the file in the caches.
    let key: String

    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var format: String { url.pathExtension.uppercased() }
    // The subfolder it's in (the first one below the wallpaper folder).
    var collection: String? { Library.collection(of: relativePath) }
}

struct WallpaperInfo: Codable, Sendable {
    var width: Int
    var height: Int
    var scheme: Scheme
    var hue: Double?
    var lightness: Double
    // The colour round the picture's edge (nil in caches from before it).
    var edge: String?
    // The file it was read from (nil in caches from before it).
    var path: String?
}

// How a wallpaper meets the screen, as in System Settings. (Its "Tile"
// has no public API, so it isn't offered.)
enum FitMode: String, Codable, CaseIterable, Sendable {
    case fill, fit, stretch, center

    var label: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        case .center: "Center"
        }
    }

    var symbol: String {
        switch self {
        case .fill: "rectangle.inset.filled"
        case .fit: "rectangle.center.inset.filled"
        case .stretch: "arrow.left.and.right.square"
        case .center: "square.dashed.inset.filled"
        }
    }

    // Leaves screen showing round the picture (filled with its edge colour).
    var showsEdge: Bool { self == .fit || self == .center }
}

// The wallpaper folder and its subfolders: what's in them (kept up to
// date as files come and go), each wallpaper's size and colours, and the
// favourites and fit modes, which are kept for each folder.
@MainActor @Observable
final class Library {
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Wallpapers", isDirectory: true)
    nonisolated static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"]

    private(set) var folder: URL
    private(set) var items: [Wallpaper] = []
    // The subfolders that have wallpapers in them.
    private(set) var collections: [String] = []
    private(set) var info: [String: WallpaperInfo] = [:]
    private(set) var favourites: Set<String> = []
    private(set) var fitModes: [String: FitMode] = [:]
    // What each display shows.
    private(set) var currentPaths: Set<String> = []

    @ObservationIgnored var onItemsChanged: (() -> Void)?
    @ObservationIgnored var onAnalysisFinished: (() -> Void)?
    @ObservationIgnored private var allFavourites: [String: [String]] = [:]
    @ObservationIgnored private var allFitModes: [String: [String: FitMode]] = [:]
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var analyzeTask: Task<Void, Never>?
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var pruned = false

    init() {
        Store.prepare()
        if let saved = UserDefaults.standard.string(forKey: "folder") {
            folder = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            folder = Self.defaultFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        loadSettings()
        info = Store.read([String: WallpaperInfo].self, from: Store.index) ?? [:]
        refreshCurrent()
        scan()
    }

    func choose(folder url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: "folder")
        favourites = Set(allFavourites[folderKey] ?? [])
        fitModes = allFitModes[folderKey] ?? [:]
        stopWatching()
        scan()
    }

    private var folderKey: String { folder.standardizedFileURL.path }

    // MARK: Current wallpaper

    func refreshCurrent() {
        currentPaths = Set(NSScreen.screens.compactMap {
            NSWorkspace.shared.desktopImageURL(for: $0)?.resolvingSymlinksInPath().path
        })
    }

    func markCurrent(_ wp: Wallpaper) {
        currentPaths = [wp.url.path]
    }

    func isCurrent(_ wp: Wallpaper) -> Bool {
        currentPaths.contains(wp.url.path)
    }

    // Puts the wallpaper on every display, the way its fit mode says.
    func apply(_ wp: Wallpaper) throws {
        let mode = fitMode(wp)
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        switch mode {
        case .fill:
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = true
        case .fit:
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = false
        case .stretch:
            options[.imageScaling] = NSImageScaling.scaleAxesIndependently.rawValue
            options[.allowClipping] = true
        case .center:
            options[.imageScaling] = NSImageScaling.scaleNone.rawValue
            options[.allowClipping] = true
        }
        if mode.showsEdge {
            let edge = edgeColor(wp)
            options[.fillColor] = NSColor(srgbRed: edge.r, green: edge.g, blue: edge.b, alpha: 1)
        }
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(wp.url, for: screen, options: options)
        }
        markCurrent(wp)
    }

    // A file given by path (from the command line): the wallpaper in the
    // folder if it's one, or a stand-in that is filled to the screen.
    func wallpaper(at url: URL) -> Wallpaper? {
        let resolved = url.resolvingSymlinksInPath()
        if let wp = items.first(where: { $0.url == resolved }) { return wp }
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true
        else { return nil }
        let modified = values.contentModificationDate ?? .distantPast
        let size = Int64(values.fileSize ?? 0)
        return Wallpaper(url: resolved, fileName: url.lastPathComponent, relativePath: resolved.path,
                         fileSize: size, modified: modified, key: Self.key(resolved.path, modified, size))
    }

    // MARK: Favourites and fit modes

    func isFavourite(_ wp: Wallpaper) -> Bool {
        favourites.contains(wp.relativePath)
    }

    func toggleFavourite(_ wp: Wallpaper) {
        if favourites.contains(wp.relativePath) {
            favourites.remove(wp.relativePath)
        } else {
            favourites.insert(wp.relativePath)
        }
        allFavourites[folderKey] = favourites.isEmpty ? nil : favourites.sorted()
        Store.write(allFavourites, to: Store.favourites)
    }

    func fitMode(_ wp: Wallpaper) -> FitMode {
        fitModes[wp.relativePath] ?? .fill
    }

    func setFitMode(_ mode: FitMode, for wp: Wallpaper) {
        fitModes[wp.relativePath] = mode == .fill ? nil : mode
        allFitModes[folderKey] = fitModes.isEmpty ? nil : fitModes
        Store.write(allFitModes, to: Store.fitModes)
    }

    // The colour to show round a wallpaper that doesn't cover the screen.
    func edgeColor(_ wp: Wallpaper) -> RGB {
        info[wp.key]?.edge.map { RGB(hex: $0) } ?? RGB(r: 0, g: 0, b: 0)
    }

    // Kept per folder since 0.4; before, one list for whichever folder
    // was in use, which becomes that folder's.
    private func loadSettings() {
        allFavourites = Self.migrated(Store.read([String: [String]].self, from: Store.favourites),
                                      legacy: Store.read([String].self, from: Store.legacyFavourites),
                                      folder: folderKey)
        allFitModes = Self.migrated(Store.read([String: [String: FitMode]].self, from: Store.fitModes),
                                    legacy: Store.read([String: FitMode].self, from: Store.legacyFitModes),
                                    folder: folderKey)
        for (legacy, current, write) in [
            (Store.legacyFavourites, Store.favourites, { Store.write(self.allFavourites, to: Store.favourites) }),
            (Store.legacyFitModes, Store.fitModes, { Store.write(self.allFitModes, to: Store.fitModes) }),
        ] where FileManager.default.fileExists(atPath: legacy.path) {
            if !FileManager.default.fileExists(atPath: current.path) { write() }
            try? FileManager.default.removeItem(at: legacy)
        }
        favourites = Set(allFavourites[folderKey] ?? [])
        fitModes = allFitModes[folderKey] ?? [:]
    }

    nonisolated static func migrated<V>(_ current: [String: V]?, legacy: V?, folder: String) -> [String: V] {
        if let current { return current }
        guard let legacy else { return [:] }
        return [folder: legacy]
    }

    // MARK: Scanning

    func scan() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let root = folderKey
        var found: [Wallpaper] = []
        let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = walker?.nextObject() as? URL {
            guard Self.extensions.contains(url.pathExtension.lowercased()) else { continue }
            let resolved = url.resolvingSymlinksInPath()
            guard let values = try? resolved.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)
            found.append(Wallpaper(url: resolved, fileName: url.lastPathComponent,
                                   relativePath: Self.relativePath(of: url.standardizedFileURL.path, in: root),
                                   fileSize: size, modified: modified, key: Self.key(resolved.path, modified, size)))
        }
        found.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        // A folder missing until now gets watched once it's there.
        if stream == nil { watch() }
        guard found != items else {
            pruneOnce()
            return
        }
        items = found
        collections = Set(found.compactMap(\.collection)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        onItemsChanged?()
        analyze()
    }

    nonisolated static func relativePath(of path: String, in root: String) -> String {
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : (path as NSString).lastPathComponent
    }

    nonisolated static func collection(of relativePath: String) -> String? {
        let parts = relativePath.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : nil
    }

    nonisolated static func key(_ path: String, _ modified: Date, _ size: Int64) -> String {
        let digest = SHA256.hash(data: Data("\(path)|\(modified.timeIntervalSince1970)|\(size)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // New, removed or renamed files, in the folder or below it, show up
    // without a restart.
    private func watch() {
        stopWatching()
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let library = Unmanaged<Library>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { library.scheduleRescan() }
        }
        guard let s = FSEventStreamCreate(
            nil, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot))
        else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopWatching() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
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
        // Unread, or read before edge colours (or paths) were kept (the
        // thumbnails are cached, so that's quick).
        var todo = items.filter { info[$0.key]?.edge == nil || info[$0.key]?.path == nil }
        guard !todo.isEmpty else {
            pruneOnce()
            return
        }
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
            self?.prune()
            self?.onAnalysisFinished?()
        }
    }

    private func saveIndex() {
        Store.write(info, to: Store.index)
    }

    // MARK: Cache upkeep

    private func pruneOnce() {
        guard !pruned else { return }
        prune()
    }

    // Forgets what was read from files that are gone or have changed since
    // (in any folder), with their thumbnails.
    private func prune() {
        pruned = true
        let snapshot = info
        let current = Set(items.map(\.key))
        Task.detached(priority: .utility) { [weak self] in
            let stale = Self.staleKeys(snapshot, current: current)
            let keep = Set(snapshot.keys).subtracting(stale).union(current)
            let thumbs = (try? FileManager.default.contentsOfDirectory(
                at: Store.thumbs, includingPropertiesForKeys: nil)) ?? []
            for url in thumbs where url.pathExtension == "jpg"
                && !keep.contains(url.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
            guard !stale.isEmpty else { return }
            await self?.forget(stale)
        }
    }

    private func forget(_ keys: [String]) {
        let now = Set(items.map(\.key))
        for key in keys where !now.contains(key) { info[key] = nil }
        saveIndex()
    }

    nonisolated static func staleKeys(_ info: [String: WallpaperInfo], current: Set<String>) -> [String] {
        info.compactMap { key, entry in
            if current.contains(key) { return nil }
            guard let path = entry.path else { return key }
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return key }
            let now = Self.key(path, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0))
            return now == key ? nil : key
        }
    }
}
