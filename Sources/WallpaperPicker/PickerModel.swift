import AppKit
import Observation

enum SortMode: String, CaseIterable {
    case name, colour, newest

    var label: String {
        switch self {
        case .name: "Name"
        case .colour: "Colour"
        case .newest: "Newest"
        }
    }

    var symbol: String {
        switch self {
        case .name: "textformat"
        case .colour: "paintpalette"
        case .newest: "clock"
        }
    }
}

enum Source {
    case all, favourites
}

// The hand of cards: its geometry, in the original's design pixels
// (1920×1200 is u = 1), scaled to the screen.
struct Fan: Equatable {
    static let side = 7
    let frontScale = 1.22

    let width: Double
    let height: Double
    let u: Double
    let pivotX: Double
    let pivotY: Double
    let handR: Double
    let lift: Double
    let step1: Double
    let stepN: Double
    let cardW: Double
    let cardH: Double

    init(size: CGSize) {
        width = size.width
        height = size.height
        u = max(0.6, min(width / 1920, height / 1200))
        // The cards turn round a pivot far below the screen, like a hand.
        pivotX = width / 2
        pivotY = height + 1650 * u
        handR = pivotY - (height - 196 * u)
        lift = 66 * u
        // Angles between the front card and its neighbours, and the rest.
        step1 = 204 * u / handR
        stepN = 132 * u / handR
        cardW = 212 * u
        cardH = 299 * u
    }

    // Top of the card in front, at rest.
    var frontTop: Double { pivotY - handR - lift - cardH * frontScale / 2 }

    // How far a drag moves to turn the deck by one card.
    var pxPerCard: Double { stepN * handR }

    struct Placement {
        var x: Double
        var y: Double
        var rotation: Double
        var scale: Double
        var z: Double
        var opacity: Double
        // 1 for the card in front.
        var near: Double
        var dim: Double
    }

    func place(index: Int, pos: Double, deal: Double, peek: Double) -> Placement {
        let d = Double(index) - pos
        let ad = abs(d)
        let near = max(0, 1 - ad)
        // Dealt from below, the middle first.
        let t = min(1, max(0, deal * (1 + 0.09 * Double(Fan.side)) - 0.09 * ad))
        let dealt = Ease.outCubic(t)
        let theta = (d < 0 ? -1.0 : 1.0) * (min(ad, 1) * step1 + max(0, ad - 1) * stepN)
        let r = handR + lift * near
        let lower = (1 - dealt) * (cardH * 1.35 + 140 * u) + peek * (cardH * 1.25 + 120 * u)
        return Placement(
            x: pivotX + r * sin(theta),
            y: pivotY - r * cos(theta) + lower,
            rotation: theta + (1 - dealt) * (d < 0 ? -0.1 : 0.1),
            scale: 1 + (frontScale - 1) * near,
            z: 100 - ad,
            opacity: min(1, max(0, Double(Fan.side) + 1 - ad)),
            near: near,
            dim: min(0.3, max(0, ad - 0.6) * 0.065)
        )
    }
}

// A card's colours, from its wallpaper's scheme.
struct Dress: Equatable {
    var surface: RGB
    var raised: RGB
    var low: RGB
    var ink: RGB
    var muted: RGB
    var line: RGB
    var accent: RGB
    var accentInk: RGB

    init(_ scheme: Scheme?) {
        let s = scheme ?? .neutral
        surface = RGB(hex: s.surfaceContainer)
        raised = RGB(hex: s.surfaceContainerHigh)
        low = RGB(hex: s.surfaceContainerLow)
        ink = RGB(hex: s.onSurface)
        muted = RGB(hex: s.onSurfaceVariant)
        line = RGB(hex: s.outlineVariant)
        accent = RGB(hex: s.primary)
        accentInk = RGB(hex: s.onPrimary)
    }
}

@MainActor @Observable
final class PickerModel {
    let library: Library
    let motion = Motion()

    private(set) var displayed: [Wallpaper] = []
    private(set) var currentIndex = 0
    private(set) var source: Source = .all
    private(set) var sort: SortMode
    private(set) var isOpen = false
    private(set) var fan = Fan(size: CGSize(width: 1920, height: 1200))
    private(set) var backingScale = 2.0
    var message: String?

    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onChooseFolder: (() -> Void)?

    @ObservationIgnored private var peekHeld = false
    @ObservationIgnored private var peekKept = false
    @ObservationIgnored private var peekPressedAt: CFTimeInterval = 0
    @ObservationIgnored private var dragFrom = 0.0
    @ObservationIgnored private var lastScroll = 0.0
    @ObservationIgnored private var scrollAccumulator = 0.0
    @ObservationIgnored private var lastViewed: String?

    init(library: Library) {
        self.library = library
        sort = SortMode(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .name
        library.onItemsChanged = { [weak self] in self?.libraryChanged() }
        library.onAnalysisFinished = { [weak self] in self?.analysisFinished() }
    }

    var front: Wallpaper? {
        displayed.indices.contains(currentIndex) ? displayed[currentIndex] : nil
    }

    var dress: Dress {
        Dress(front.flatMap { library.info[$0.key]?.scheme })
    }

    var peeking: Bool { peekHeld || peekKept }

    // MARK: Opening and closing

    func configure(size: CGSize, scale: Double) {
        let f = Fan(size: size)
        if f != fan { fan = f }
        backingScale = scale
    }

    func open() {
        library.refreshCurrent()
        library.scan()
        rebuild(keep: nil)
        let target = displayed.firstIndex(where: library.isCurrent)
            ?? displayed.firstIndex(where: { $0.id == lastViewed })
            ?? 0
        currentIndex = displayed.isEmpty ? 0 : target
        message = nil
        peekHeld = false
        peekKept = false
        motion.set(.peek, 0)
        motion.set(.pos, Double(currentIndex))
        motion.set(.deal, 0)
        if !isOpen { motion.set(.shown, 0) }
        isOpen = true
        motion.animate(.shown, to: 1, duration: 0.38, ease: Ease.outCubic)
        motion.animate(.deal, to: 1, duration: 0.76, ease: Ease.outCubic)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        lastViewed = front?.id
        motion.animate(.deal, to: 0, duration: 0.22, ease: Ease.inCubic)
        motion.animate(.shown, to: 0, duration: 0.24, ease: Ease.inCubic) { [weak self] in
            self?.onClose?()
        }
    }

    // Gone at once (before another window needs the screen).
    func closeNow() {
        guard isOpen else { return }
        isOpen = false
        lastViewed = front?.id
        motion.set(.deal, 0)
        motion.set(.shown, 0)
        onClose?()
    }

    // MARK: The deck

    private func ordered() -> [Wallpaper] {
        var list = library.items
        if source == .favourites {
            list = list.filter(library.isFavourite)
        }
        switch sort {
        case .name:
            break // the library keeps them by name
        case .newest:
            list.sort { $0.modified > $1.modified }
        case .colour:
            // Round the hue wheel, so the deck becomes a spectrum; greys
            // after, dark to light; unread ones last.
            func rank(_ wp: Wallpaper) -> Double {
                guard let info = library.info[wp.key] else { return 2000 }
                if let hue = info.hue { return hue }
                return 1000 + info.lightness
            }
            list = list.map { ($0, rank($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
        }
        return list
    }

    private func rebuild(keep: Wallpaper?) {
        displayed = ordered()
        if let keep, let i = displayed.firstIndex(where: { $0.id == keep.id }) {
            currentIndex = i
        } else {
            currentIndex = min(max(0, currentIndex), max(0, displayed.count - 1))
        }
        motion.set(.pos, Double(currentIndex))
    }

    private func libraryChanged() {
        guard isOpen else { return }
        rebuild(keep: front)
    }

    private func analysisFinished() {
        guard isOpen, sort == .colour else { return }
        let keep = front
        reshuffle { $0.rebuild(keep: keep) }
    }

    // The cards drop, change, and are dealt again.
    private func reshuffle(_ change: @escaping (PickerModel) -> Void) {
        motion.animate(.deal, to: 0.1, duration: 0.17, ease: Ease.inQuad) { [weak self] in
            guard let self else { return }
            change(self)
            self.motion.animate(.deal, to: 1, duration: 0.56, ease: Ease.outCubic)
        }
    }

    func go(_ index: Int) {
        guard !displayed.isEmpty else { return }
        currentIndex = min(max(index, 0), displayed.count - 1)
        motion.animate(.pos, to: Double(currentIndex), duration: 0.38, ease: Ease.outCubic)
    }

    func step(_ n: Int) {
        go(currentIndex + n)
    }

    // Moves the deck by hand (drags, trackpad, the ribbon).
    func setPos(_ p: Double) {
        guard !displayed.isEmpty else { return }
        let clamped = min(max(p, -0.45), Double(displayed.count) - 0.55)
        motion.set(.pos, clamped)
        let i = min(max(Int(clamped.rounded()), 0), displayed.count - 1)
        if i != currentIndex { currentIndex = i }
    }

    func beginDrag() {
        dragFrom = motion.pos
        motion.set(.pos, motion.pos)
    }

    func drag(by translation: Double) {
        setPos(dragFrom - translation / fan.pxPerCard)
    }

    // A flick carries on a little.
    func endDrag(velocity: Double) {
        go(Int((motion.pos - velocity / fan.pxPerCard * 0.2).rounded()))
    }

    // MARK: Actions

    func applyFront() {
        guard let wp = front else { return }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        do {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(wp.url, for: screen, options: options)
            }
            library.markCurrent(wp)
            message = nil
        } catch {
            message = "Couldn't set the wallpaper: \(error.localizedDescription)"
        }
    }

    func toggleFavourite() {
        guard let wp = front else { return }
        library.toggleFavourite(wp)
        if source == .favourites {
            rebuild(keep: displayed.indices.contains(currentIndex + 1) ? displayed[currentIndex + 1] : nil)
        }
    }

    func setSort(_ mode: SortMode) {
        guard mode != sort else { return }
        let keep = front
        reshuffle { model in
            model.sort = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "sort")
            model.rebuild(keep: keep)
        }
    }

    func cycleSort() {
        let all = SortMode.allCases
        setSort(all[(all.firstIndex(of: sort)! + 1) % all.count])
    }

    func setSource(_ s: Source) {
        guard s != source else { return }
        let keep = front
        reshuffle { model in
            model.source = s
            model.rebuild(keep: keep)
        }
    }

    func random() {
        guard displayed.count > 1 else { return }
        var i = currentIndex
        while i == currentIndex { i = Int.random(in: 0..<displayed.count) }
        go(i)
    }

    func togglePeek() {
        peekKept.toggle()
        updatePeek()
    }

    private func updatePeek() {
        motion.animate(.peek, to: peeking ? 1 : 0, duration: 0.3, ease: Ease.outCubic)
    }

    func chooseFolder() {
        onChooseFolder?()
    }

    func revealFolder() {
        NSWorkspace.shared.open(library.folder)
    }

    // MARK: Input

    func keyDown(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) { return false }
        switch Int(e.keyCode) {
        case 53: // esc
            if peekKept { togglePeek() } else { close() }
        case 123, 126: step(-1) // left, up
        case 124, 125: step(1) // right, down
        case 115: go(0) // home
        case 119: go(displayed.count - 1) // end
        case 116: step(-Fan.side) // page up
        case 121: step(Fan.side) // page down
        case 36, 76: applyFront() // return, enter
        case 49: // space: hold to peek, tap to keep peeking
            if !e.isARepeat {
                peekPressedAt = CACurrentMediaTime()
                peekHeld = true
                updatePeek()
            }
        case 48: setSource(source == .all ? .favourites : .all) // tab
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFavourite()
            case "s": cycleSort()
            case "r": random()
            default: return false
            }
        }
        return true
    }

    func keyUp(_ e: NSEvent) -> Bool {
        guard e.keyCode == 49 else { return false }
        peekHeld = false
        if CACurrentMediaTime() - peekPressedAt < 0.25 { peekKept.toggle() }
        updatePeek()
        return true
    }

    func scroll(_ e: NSEvent) {
        guard !displayed.isEmpty else { return }
        let dx = Double(e.scrollingDeltaX), dy = Double(e.scrollingDeltaY)
        if e.hasPreciseScrollingDeltas {
            // Trackpad: the deck follows the fingers, then settles.
            if !e.momentumPhase.isEmpty { return }
            let raw = abs(dx) > abs(dy) ? dx : dy
            if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
                lastScroll = 0
                motion.set(.pos, motion.pos)
            } else if e.phase.contains(.changed) {
                let d = -raw / fan.pxPerCard
                lastScroll = d
                setPos(motion.pos + d)
            } else if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
                go(Int((motion.pos + lastScroll * 4).rounded()))
                lastScroll = 0
            } else {
                // Precise deltas without phases (some mice).
                scrollAccumulator += raw
                while scrollAccumulator >= 40 { step(-1); scrollAccumulator -= 40 }
                while scrollAccumulator <= -40 { step(1); scrollAccumulator += 40 }
            }
        } else {
            // Wheel: a card a notch.
            let d = dy != 0 ? dy : -dx
            if d != 0 { step(d > 0 ? -1 : 1) }
        }
    }
}
