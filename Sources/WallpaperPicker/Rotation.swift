import AppKit

enum RotationInterval: String, CaseIterable, Sendable {
    case off
    case m15 = "15m"
    case h1 = "1h"
    case h3 = "3h"
    case d1 = "1d"

    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .m15: 15 * 60
        case .h1: 60 * 60
        case .h3: 3 * 60 * 60
        case .d1: 24 * 60 * 60
        }
    }

    var label: String {
        switch self {
        case .off: "Never"
        case .m15: "Every 15 Minutes"
        case .h1: "Every Hour"
        case .h3: "Every 3 Hours"
        case .d1: "Every Day"
        }
    }
}

struct RotationError: LocalizedError {
    let errorDescription: String?
}

// Changes the wallpaper now and then, or when asked for the next one: a
// random pick that isn't one of the last few shown.
@MainActor
final class Rotation {
    private let library: Library
    // Nothing changes while the picker is open.
    var isPaused: () -> Bool = { false }
    private var timer: Timer?

    private let defaults = UserDefaults.standard

    var interval: RotationInterval {
        get { RotationInterval(rawValue: defaults.string(forKey: "rotation") ?? "") ?? .off }
        set {
            defaults.set(newValue.rawValue, forKey: "rotation")
            // The first change comes a whole interval from now.
            lastChange = Date()
        }
    }

    var favouritesOnly: Bool {
        get { defaults.bool(forKey: "rotationFavourites") }
        set { defaults.set(newValue, forKey: "rotationFavourites") }
    }

    private(set) var lastChange: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: "rotationLastChange")) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "rotationLastChange") }
    }

    private var history: [String] {
        get { defaults.stringArray(forKey: "rotationHistory") ?? [] }
        set { defaults.set(newValue, forKey: "rotationHistory") }
    }

    init(library: Library) {
        self.library = library
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard let seconds = interval.seconds, !isPaused(),
              Date().timeIntervalSince(lastChange) >= seconds
        else { return }
        do {
            try next()
        } catch {
            // Try again in an interval rather than every minute.
            lastChange = Date()
        }
    }

    // Sets a random wallpaper (from the favourites if asked, or as the
    // rotation is set up) that hasn't been on the desktop lately.
    @discardableResult
    func next(favouritesOnly only: Bool? = nil) throws -> Wallpaper {
        let favourites = only ?? favouritesOnly
        let pool = favourites ? library.items.filter(library.isFavourite) : library.items
        guard !pool.isEmpty else {
            throw RotationError(errorDescription: favourites ? "There are no favourites to choose from"
                                                             : "There are no wallpapers in the folder")
        }
        let avoiding = history + pool.filter(library.isCurrent).map(\.relativePath)
        guard let path = Self.candidates(from: pool.map(\.relativePath), avoiding: avoiding).randomElement(),
              let wp = pool.first(where: { $0.relativePath == path })
        else { throw RotationError(errorDescription: "Nothing to choose from") }
        try library.apply(wp)
        record(wp)
        return wp
    }

    // A wallpaper was set (here or in the picker).
    func record(_ wp: Wallpaper) {
        lastChange = Date()
        let keep = max(1, min(10, library.items.count / 2))
        history = Array((history.filter { $0 != wp.relativePath } + [wp.relativePath]).suffix(keep))
    }

    // What to choose from: everything not shown lately; failing that,
    // everything but the last one shown.
    nonisolated static func candidates(from all: [String], avoiding recent: [String]) -> [String] {
        let fresh = all.filter { !recent.contains($0) }
        if !fresh.isEmpty { return fresh }
        let notLast = all.filter { $0 != recent.last }
        return notLast.isEmpty ? all : notLast
    }
}
