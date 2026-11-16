import AppKit
import Testing

@testable import KoreUI

@MainActor
struct ThemePaletteTests {
    @Test func ghosttyThemeParsesColoursAndPalette() {
        let theme = GhosttyTheme("background = #282a36\nforeground = f8f8f2\npalette = 1=#ff5555\npalette = 12=#bd93f9\n# comment\n")
        #expect(theme.background != nil)
        #expect(theme.foreground != nil)
        #expect(theme.ansi[1] != nil && theme.ansi[12] != nil)
        let palette = ThemePalette(theme)
        #expect(palette?.isLight == false)
        #expect(palette?.ansi.isEmpty == true)  // not all 16: SwiftTerm keeps its own
    }

    @Test func tertiaryStaysReadableOnALowContrastTheme() {
        let theme = GhosttyTheme("background = #3a3a3a\nforeground = #6a6a6a\n")
        let palette = ThemePalette(theme)!
        #expect(ThemePalette.ratio(palette.tertiary, palette.background) >= 2.0)
        #expect(ThemePalette.ratio(palette.secondary, palette.background) >= ThemePalette.ratio(palette.tertiary, palette.background) - 0.01)
    }

    @Test func tertiaryMeetsItsContrastWhenTheForegroundAllows() {
        let palette = ThemePalette(GhosttyTheme("background = #1e1e2e\nforeground = #cdd6f4\n"))!
        #expect(ThemePalette.ratio(palette.tertiary, palette.background) >= 4.0)
        #expect(ThemePalette.ratio(palette.secondary, palette.background) >= 4.5)
    }
}
