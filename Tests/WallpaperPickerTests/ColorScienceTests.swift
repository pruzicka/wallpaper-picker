import Testing
@testable import WallpaperPicker

@Suite struct ColorScienceTests {
    @Test func hexRoundTrip() {
        for hex in ["#000000", "#FFFFFF", "#12AB9F", "#FF5C7A"] {
            #expect(RGB(hex: hex).hex == hex)
        }
        #expect(RGB(hex: "12ab9f").hex == "#12AB9F")
    }

    @Test func labOfWhiteAndBlack() {
        let white = ColorMath.lab(RGB(r: 1, g: 1, b: 1))
        #expect(abs(white.l - 100) < 0.5)
        #expect(white.chroma < 0.5)
        let black = ColorMath.lab(RGB(r: 0, g: 0, b: 0))
        #expect(abs(black.l) < 0.5)
    }

    @Test(arguments: [0.0, 40, 120, 210, 300])
    func schemesAreValidAndReadable(hue: Double) {
        let s = Scheme.make(hue: hue, vividness: 1, source: RGB(r: 0.5, g: 0.2, b: 0.1))
        let all = [s.source, s.primary, s.onPrimary, s.primaryContainer, s.secondary, s.tertiary,
                   s.surfaceContainerLow, s.surfaceContainer, s.surfaceContainerHigh, s.surfaceContainerHighest,
                   s.onSurface, s.onSurfaceVariant, s.outlineVariant]
        for hex in all {
            #expect(hex.count == 7 && hex.hasPrefix("#") && UInt32(hex.dropFirst(), radix: 16) != nil)
        }
        // Text on a card stands well apart from the card.
        let ink = ColorMath.lab(RGB(hex: s.onSurface)).l
        let card = ColorMath.lab(RGB(hex: s.surfaceContainer)).l
        #expect(ink - card > 60)
    }
}
