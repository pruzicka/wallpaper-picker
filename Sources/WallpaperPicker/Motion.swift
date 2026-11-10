import AppKit
import Observation
import os
import QuartzCore

enum Ease {
    static func outCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func inCubic(_ t: Double) -> Double { t * t * t }
    static func inQuad(_ t: Double) -> Double { t * t }
}

// The picker's moving numbers, driven frame by frame from the display:
// the deck's position (fractional while it turns), the dealing of the
// cards, the fade of the whole picker and the peek. Everything on screen
// is worked out from these, as in the original, so the cards follow the
// arc of the hand instead of cutting straight across.
@MainActor @Observable
final class Motion {
    enum Key: Hashable {
        case pos, deal, shown, peek
    }

    private(set) var pos = 0.0
    private(set) var deal = 0.0
    private(set) var shown = 0.0
    private(set) var peek = 0.0

    private struct Tween {
        var from: Double
        var to: Double
        var start: CFTimeInterval
        var duration: Double
        var ease: (Double) -> Double
        var done: (() -> Void)?
    }

    @ObservationIgnored private var tweens: [Key: Tween] = [:]
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private lazy var proxy = LinkProxy(motion: self)
    // Timer beats since the display last sent a frame.
    @ObservationIgnored private var missed = 0
    @ObservationIgnored private var linkFailed = false
    @ObservationIgnored private let log = Logger(subsystem: AppInfo.bundleID, category: "motion")
    // The view whose screen paces the frames. Setting it (again) starts
    // a fresh display link.
    @ObservationIgnored weak var view: NSView? {
        didSet {
            link?.invalidate()
            link = nil
            linkFailed = false
            timer?.invalidate()
            timer = nil
        }
    }

    func value(_ key: Key) -> Double {
        switch key {
        case .pos: pos
        case .deal: deal
        case .shown: shown
        case .peek: peek
        }
    }

    private func write(_ key: Key, _ v: Double) {
        switch key {
        case .pos: if pos != v { pos = v }
        case .deal: if deal != v { deal = v }
        case .shown: if shown != v { shown = v }
        case .peek: if peek != v { peek = v }
        }
    }

    func isAnimating(_ key: Key) -> Bool { tweens[key] != nil }

    // Jumps there, stopping any animation of it.
    func set(_ key: Key, _ v: Double) {
        tweens[key] = nil
        write(key, v)
    }

    // Animates from wherever it is now; replaces a running animation.
    func animate(_ key: Key, to target: Double, duration: Double,
                 ease: @escaping (Double) -> Double, done: (() -> Void)? = nil) {
        tweens[key] = Tween(from: value(key), to: target, start: CACurrentMediaTime(),
                            duration: duration, ease: ease, done: done)
        run()
    }

    private func run() {
        if let view, link == nil, !linkFailed {
            let l = view.displayLink(target: proxy, selector: #selector(LinkProxy.tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
        if let link, link.isPaused {
            link.isPaused = false
            missed = 0
        }
        // The display paces the frames; a timer does when there is no
        // display link, and watches over the link when there is one.
        if timer == nil {
            let t = Timer(timeInterval: link == nil ? 1.0 / 120 : 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func beat() {
        guard link != nil else { return tick() }
        missed += 1
        guard missed >= 3 else { return }
        // A display link can go quiet for good after the screens sleep or
        // change, which left the picker open but invisible. Carry on by
        // timer; the next opening tries a new link.
        log.error("Display link sent no frames; animating by timer")
        link?.invalidate()
        link = nil
        linkFailed = true
        timer?.invalidate()
        timer = nil
        tick()
        if !tweens.isEmpty { run() }
    }

    fileprivate func linkTick() {
        missed = 0
        tick()
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        var finished: [() -> Void] = []
        for (key, t) in tweens {
            let p = t.duration > 0 ? min(1, max(0, (now - t.start) / t.duration)) : 1
            write(key, t.from + (t.to - t.from) * t.ease(p))
            if p >= 1 {
                tweens[key] = nil
                if let done = t.done { finished.append(done) }
            }
        }
        if tweens.isEmpty {
            link?.isPaused = true
            timer?.invalidate()
            timer = nil
        }
        finished.forEach { $0() }
    }
}

private final class LinkProxy: NSObject {
    weak var motion: Motion?

    init(motion: Motion) {
        self.motion = motion
    }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { motion?.linkTick() }
    }
}
