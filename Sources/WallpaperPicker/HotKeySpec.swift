import AppKit
import Carbon.HIToolbox

// The shortcut that opens the picker: a key and Carbon modifiers, written
// "ctrl+opt+w" on the command line and shown as ⌃⌥W.
struct HotKeySpec: Equatable, Hashable, Sendable {
    let keyCode: Int
    let modifiers: Int

    static let standard = HotKeySpec(keyCode: kVK_ANSI_W, modifiers: controlKey | optionKey)
    static let presets: [HotKeySpec] = [
        standard,
        HotKeySpec(keyCode: kVK_ANSI_W, modifiers: controlKey | optionKey | cmdKey),
        HotKeySpec(keyCode: kVK_Space, modifiers: controlKey | optionKey),
        HotKeySpec(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey),
    ]

    // In the order macOS shows them.
    private static let modifierNames: [(mask: Int, name: String, symbol: String, flag: NSEvent.ModifierFlags)] = [
        (controlKey, "ctrl", "⌃", .control),
        (optionKey, "opt", "⌥", .option),
        (shiftKey, "shift", "⇧", .shift),
        (cmdKey, "cmd", "⌘", .command),
    ]

    private static let modifierAliases: [String: Int] = [
        "ctrl": controlKey, "control": controlKey, "⌃": controlKey,
        "opt": optionKey, "option": optionKey, "alt": optionKey, "⌥": optionKey,
        "shift": shiftKey, "⇧": shiftKey,
        "cmd": cmdKey, "command": cmdKey, "⌘": cmdKey,
    ]

    // name, Carbon key code, what a menu shows as its key equivalent
    private static let keys: [(name: String, code: Int, equivalent: String)] = {
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
            ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ]
        let functions: [Int] = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                                kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        return letters.map { ($0.0, $0.1, $0.0) }
            + [("space", kVK_Space, " ")]
            + functions.enumerated().map { i, code in
                ("f\(i + 1)", code, String(UnicodeScalar(NSF1FunctionKey + i)!))
            }
    }()

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // "ctrl+opt+w", "cmd+shift+space", "f5", or as a menu shows it, "⌃⌥W".
    // A letter, digit or space needs a modifier; a function key doesn't.
    init?(_ text: String) {
        var spelled = text.lowercased()
        for symbol in ["⌃", "⌥", "⇧", "⌘"] {
            spelled = spelled.replacingOccurrences(of: symbol, with: symbol + "+")
        }
        let parts = spelled.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = parts.last, let key = Self.keys.first(where: { $0.name == last }) else { return nil }
        var mods = 0
        for part in parts.dropLast() {
            guard let mask = Self.modifierAliases[part] else { return nil }
            mods |= mask
        }
        guard mods != 0 || key.name.hasPrefix("f") && key.name.count > 1 else { return nil }
        self.init(keyCode: key.code, modifiers: mods)
    }

    private var key: (name: String, code: Int, equivalent: String)? {
        Self.keys.first { $0.code == keyCode }
    }

    // As typed on the command line and kept in the settings.
    var text: String {
        (Self.modifierNames.filter { modifiers & $0.mask != 0 }.map(\.name) + [key?.name ?? "?"])
            .joined(separator: "+")
    }

    // As a menu shows it, e.g. ⌃⌥W.
    var display: String {
        let mods = Self.modifierNames.filter { modifiers & $0.mask != 0 }.map(\.symbol).joined()
        let name = key?.name ?? "?"
        return mods + (name == "space" ? "Space" : name.uppercased())
    }

    var keyEquivalent: String { key?.equivalent ?? "" }

    var modifierFlags: NSEvent.ModifierFlags {
        Self.modifierNames.filter { modifiers & $0.mask != 0 }.reduce(into: []) { $0.insert($1.flag) }
    }

    static var saved: HotKeySpec {
        UserDefaults.standard.string(forKey: "hotkey").flatMap(HotKeySpec.init) ?? .standard
    }

    func save() {
        UserDefaults.standard.set(text, forKey: "hotkey")
    }
}
