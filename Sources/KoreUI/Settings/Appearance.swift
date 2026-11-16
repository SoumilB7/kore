import AppKit
import Observation
import SwiftUI

/// Theme's base colours, live: Kore's own, or made from a Ghostty theme. `Theme` holds dynamic
/// NSColors that read `Appearance.live` when drawn, so every colour derived from them follows a
/// switch without each view knowing.
struct ThemePalette: Equatable, @unchecked Sendable {
    var background, surface, surfaceHover, surfaceRaised, line, text, secondary, tertiary, danger, accent: NSColor
    var isLight: Bool
    /// The 16 terminal colours; empty: SwiftTerm's own.
    var ansi: [NSColor] = []
    /// The rest of Kore's colours, each from the theme's terminal palette (Kore's own for Kore).
    var roles = Roles.kore

    struct Roles: Equatable {
        var success, warning, comment, variable, keyword, type, string, number: NSColor
        /// The accent's lighter and deeper steps (logo, mode outlines, board lines).
        var blue200, blue400, blue500, blue600: NSColor
        var boardGround, clusterLine: NSColor
        var groups: [TabGroupColor: NSColor]

        static let kore = Roles(
            success: .hex(0x74C991), warning: .hex(0xE1C08D), comment: .hex(0x6F7A83), variable: .hex(0x8CC4B4),
            keyword: .hex(0x6AB1E7), type: .hex(0xA3C3DC), string: .hex(0xE1C08D), number: .hex(0xE1C08D),
            blue200: .hex(0xA3C3DC), blue400: .hex(0x3C97DD), blue500: .hex(0x257DC1), blue600: .hex(0x1B6298),
            boardGround: .hex(0x212326), clusterLine: .hex(0x2A3338),
            groups: [
                .grey: .hex(0x9AA4AD), .blue: .hex(0x6FA8DC), .teal: .hex(0x5FB5AE), .green: .hex(0x7DBE8B),
                .sand: .hex(0xCDB173), .orange: .hex(0xDE9467), .rose: .hex(0xDC7F92), .violet: .hex(0xA390D8),
            ])
    }

    func group(_ color: TabGroupColor) -> NSColor { roles.groups[color] ?? Roles.kore.groups[color] ?? text }

    static let kore = ThemePalette(
        background: .hex(0x111113), surface: .hex(0x171D21), surfaceHover: .hex(0x1D252A), surfaceRaised: .hex(0x263036),
        line: .hex(0xBED7EB), text: .hex(0xEDEDED), secondary: .hex(0x89959F), tertiary: .hex(0x77828B),
        danger: .hex(0xF0736B), accent: .hex(0x6AB1E7), isLight: false)

    init(
        background: NSColor, surface: NSColor, surfaceHover: NSColor, surfaceRaised: NSColor, line: NSColor, text: NSColor,
        secondary: NSColor, tertiary: NSColor, danger: NSColor, accent: NSColor, isLight: Bool
    ) {
        (self.background, self.surface, self.surfaceHover, self.surfaceRaised) = (background, surface, surfaceHover, surfaceRaised)
        (self.line, self.text, self.secondary, self.tertiary) = (line, text, secondary, tertiary)
        (self.danger, self.accent, self.isLight) = (danger, accent, isLight)
    }

    /// Grounds step from the theme's background toward its foreground; danger and accent are its
    /// red and blue.
    init?(_ theme: GhosttyTheme) {
        guard let bg = theme.background, let fg = theme.foreground else { return nil }
        func mix(_ f: CGFloat) -> NSColor { bg.blended(withFraction: f, of: fg) ?? bg }
        self.init(
            background: bg, surface: mix(0.05), surfaceHover: mix(0.09), surfaceRaised: mix(0.14), line: fg, text: fg,
            secondary: Self.readable(bg, fg, from: 0.62, contrast: 4.5), tertiary: Self.readable(bg, fg, from: 0.5, contrast: 4.0), danger: theme.ansi[1] ?? ThemePalette.kore.danger,
            accent: theme.ansi[12] ?? theme.ansi[4] ?? ThemePalette.kore.accent, isLight: bg.luminance > 0.5)
        let ansi = (0..<16).compactMap { theme.ansi[$0] }
        if ansi.count == 16 { self.ansi = ansi }
        // Each role from its terminal colour, as editors themed by the same palette do: green
        // strings and success, yellow warnings and numbers, magenta keywords, cyan types. Groups
        // take the bright colours on a dark ground, the plain ones on a light ground.
        let k = Roles.kore
        func a(_ n: Int, _ fallback: NSColor) -> NSColor { theme.ansi[n] ?? fallback }
        func lit(_ n: Int, _ fallback: NSColor) -> NSColor { theme.ansi[isLight ? n : n + 8] ?? theme.ansi[n] ?? fallback }
        let accent = self.accent
        roles = Roles(
            success: a(2, k.success), warning: a(3, k.warning),
            comment: Self.readable(bg, fg, from: 0.42, contrast: 3.0),
            variable: a(6, k.variable), keyword: a(5, k.keyword), type: a(6, k.type), string: a(2, k.string), number: a(3, k.number),
            blue200: accent.blended(withFraction: 0.35, of: fg) ?? accent,
            blue400: accent.blended(withFraction: 0.15, of: bg) ?? accent,
            blue500: accent.blended(withFraction: 0.3, of: bg) ?? accent,
            blue600: accent.blended(withFraction: 0.45, of: bg) ?? accent,
            boardGround: mix(0.07), clusterLine: mix(0.12),
            groups: [
                .grey: secondary, .blue: lit(4, k.groups[.blue]!), .teal: lit(6, k.groups[.teal]!), .green: lit(2, k.groups[.green]!),
                .sand: lit(3, k.groups[.sand]!),
                .orange: lit(1, k.groups[.rose]!).blended(withFraction: 0.5, of: lit(3, k.groups[.sand]!)) ?? k.groups[.orange]!,
                .rose: lit(1, k.groups[.rose]!), .violet: lit(5, k.groups[.violet]!),
            ])
    }
}

extension ThemePalette {
    /// The text colour `from` of the way from background to foreground, moved toward the
    /// foreground until it reads at `contrast` : 1 (Kore's own: secondary 6.2, tertiary 4.3). A
    /// low-contrast theme made tertiary hints near-invisible at a fixed mix.
    static func readable(_ bg: NSColor, _ fg: NSColor, from start: CGFloat, contrast: CGFloat) -> NSColor {
        var f = start
        while f < 1 {
            let c = bg.blended(withFraction: f, of: fg) ?? fg
            if ratio(c, bg) >= contrast { return c }
            f += 0.04
        }
        return fg
    }

    static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (a.relativeLuminance, b.relativeLuminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// A Ghostty theme file: `background = #…`, `foreground = …`, `palette = N=#…`.
struct GhosttyTheme {
    var background: NSColor?
    var foreground: NSColor?
    var ansi: [Int: NSColor] = [:]

    init(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "background": background = NSColor.hex(string: pair[1])
            case "foreground": foreground = NSColor.hex(string: pair[1])
            case "palette":
                let entry = pair[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let n = Int(entry[0]), let color = NSColor.hex(string: entry[1]) { ansi[n] = color }
            default: break
            }
        }
    }

    init?(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(text)
    }
}

/// The chosen theme. Ghostty's themes are read where Ghostty keeps them; none are bundled.
@MainActor @Observable
final class Appearance {
    static let shared = Appearance()
    static let key = "kore.theme"
    static let kore = "Kore"
    /// Read by the dynamic colours when drawn, on any thread; written only on the main thread.
    nonisolated(unsafe) static var live = ThemePalette.kore

    /// The theme on screen: a preview until saved.
    private(set) var name = Appearance.kore
    /// The theme kept across launches.
    private(set) var saved = Appearance.kore
    var unsaved: Bool { name != saved }
    private(set) var isLight = false
    /// Flipped for one frame on a switch: the scheme change makes every view resolve its colours again.
    private var flip = false
    var scheme: ColorScheme { isLight != flip ? .light : .dark }

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.key), load(stored) { (name, saved) = (stored, stored) }
    }

    /// The user's own themes win over Ghostty's of the same name.
    static let folders: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/themes"),
        URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"),
    ]

    /// Kore's own first, then every theme found, by name.
    static func names() -> [String] {
        let found = Set(folders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }.filter { !$0.hasPrefix(".") })
        return [kore] + found.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func file(_ name: String) -> URL? {
        folders.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Shows `name` everywhere at once, without keeping it: `save()` keeps it, `revert()` goes back.
    func preview(_ name: String) {
        guard name != self.name, load(name) else { return }
        self.name = name
        TerminalShell.restyleAll()
        flip = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            flip = false
        }
    }

    func save() {
        saved = name
        UserDefaults.standard.set(name, forKey: Self.key)
    }

    func revert() { preview(saved) }

    /// Every view draws its colours and fonts again (a code font change), without a theme switch.
    func refresh() {
        TerminalShell.restyleAll()
        flip = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            flip = false
        }
    }

    private func load(_ name: String) -> Bool {
        let palette: ThemePalette
        if name == Self.kore {
            palette = .kore
        } else if let url = Self.file(name), let theme = GhosttyTheme(contentsOf: url), let made = ThemePalette(theme) {
            palette = made
        } else {
            return false
        }
        Self.live = palette
        isLight = palette.isLight
        return true
    }

    @ObservationIgnored private var parsed: [String: GhosttyTheme] = [:]

    /// A theme's file, read once.
    func theme(_ name: String) -> GhosttyTheme? {
        if name == Self.kore { return nil }
        if let hit = parsed[name] { return hit }
        let theme = Self.file(name).flatMap(GhosttyTheme.init(contentsOf:))
        parsed[name] = theme
        return theme
    }

    func palette(_ name: String) -> ThemePalette { theme(name).flatMap(ThemePalette.init) ?? .kore }

    /// A Theme colour that follows the live palette.
    nonisolated static func role(_ pick: @escaping @Sendable (ThemePalette.Roles) -> NSColor) -> Color { color { pick($0.roles) } }

    nonisolated static func color(_ pick: @escaping @Sendable (ThemePalette) -> NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { _ in pick(Appearance.live) })
    }
}

/// The window's light or dark, from the theme (system controls, menus, text fields).
struct ThemeScheme: ViewModifier {
    func body(content: Content) -> some View { content.preferredColorScheme(Appearance.shared.scheme) }
}

extension NSColor {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// `#rrggbb` or `rrggbb`.
    static func hex(string: String) -> NSColor? {
        let digits = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return hex(value)
    }

    /// WCAG relative luminance (linear sRGB).
    var relativeLuminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}
