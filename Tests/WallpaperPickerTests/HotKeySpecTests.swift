import Carbon.HIToolbox
import Testing
@testable import WallpaperPicker

@Suite struct HotKeySpecTests {
    @Test func standard() {
        #expect(HotKeySpec("ctrl+opt+w") == .standard)
        #expect(HotKeySpec.standard.text == "ctrl+opt+w")
        #expect(HotKeySpec.standard.display == "⌃⌥W")
    }

    @Test func aliasesAndOrder() {
        let spec = HotKeySpec("Command + Shift + Alt + Space")
        #expect(spec == HotKeySpec(keyCode: kVK_Space, modifiers: cmdKey | shiftKey | optionKey))
        #expect(spec?.text == "opt+shift+cmd+space")
        #expect(spec?.display == "⌥⇧⌘Space")
        #expect(HotKeySpec("⌃⌥p") == HotKeySpec(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey))
    }

    @Test func functionKeysNeedNoModifier() {
        #expect(HotKeySpec("f5")?.keyCode == kVK_F5)
        #expect(HotKeySpec("f12")?.display == "F12")
        #expect(HotKeySpec("f") == nil)
        #expect(HotKeySpec("w") == nil)
        #expect(HotKeySpec("space") == nil)
    }

    @Test func rejectsNonsense() {
        #expect(HotKeySpec("") == nil)
        #expect(HotKeySpec("ctrl+") == nil)
        #expect(HotKeySpec("hyper+w") == nil)
        #expect(HotKeySpec("ctrl+f13") == nil)
    }

    @Test func roundTripsThePresets() {
        for spec in HotKeySpec.presets {
            #expect(HotKeySpec(spec.text) == spec)
        }
    }
}
