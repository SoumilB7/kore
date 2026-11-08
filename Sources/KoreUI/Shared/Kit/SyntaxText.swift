import AppKit
import KoreCore
import SwiftUI

/// Code in the editor's colours as an `AttributedString`, for read-only code: chat code blocks
/// and notebook cells. One pass of the editor's line scanner per block, kept by text and
/// language, so a block redrawn (a scroll, a reply growing above it) isn't coloured again.
/// Past `maxLines` or `maxLength` the text stays plain: a block that big is read, not scanned.
/// Runs of one colour merge, so plain stretches (punctuation included) are one run each.
@MainActor
enum SyntaxText {
    static let maxLines = 2_000
    static let maxLength = 64 * 1024

    private final class Entry {
        let text: String
        let value: AttributedString
        init(_ text: String, _ value: AttributedString) {
            self.text = text
            self.value = value
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        return cache
    }()

    private static func key(_ text: String, _ language: Language) -> NSString {
        "\(language.id):\(text.utf16.count):\(text.hashValue)" as NSString
    }

    /// Already coloured (for tests: the second ask is a lookup).
    static func isCached(_ text: String, _ language: Language) -> Bool {
        cache.object(forKey: key(text, language))?.text == text
    }

    /// Whether `text` is small enough to colour.
    static func fits(_ text: String) -> Bool {
        let length = text.utf16.count
        guard length <= maxLength else { return false }
        var lines = 1
        for unit in text.utf8 where unit == 0x0A {
            lines += 1
            if lines > maxLines { return false }
        }
        return true
    }

    static func attributed(_ text: String, _ language: Language) -> AttributedString {
        guard language.family != .plain, fits(text) else { return plain(text) }
        let key = key(text, language)
        if let entry = cache.object(forKey: key), entry.text == text { return entry.value }
        let value = color(text, language)
        cache.setObject(Entry(text, value), forKey: key)
        return value
    }

    private static func plain(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = Theme.Syntax.plain
        return result
    }

    private static func color(_ text: String, _ language: Language) -> AttributedString {
        var result = AttributedString()
        var state = Language.State.normal
        var tokens: [Language.Token] = []
        var colors: [TokenKind: Color] = [:]
        func color(_ kind: TokenKind?) -> Color {
            // Punctuation stays plain here: it's half a block's colour runs, and each run costs
            // the row's layout on every build, for a shade few read in a block.
            guard let kind, kind != .punctuation else { return Theme.Syntax.plain }
            if let known = colors[kind] { return known }
            let made = Theme.Syntax.color(kind).map(Color.init(nsColor:)) ?? Theme.Syntax.plain
            colors[kind] = made
            return made
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let units = Array(line.utf16)
            tokens.removeAll(keepingCapacity: true)
            state = language.scan(units, from: state, into: &tokens)
            var position = 0
            func append(_ range: Range<Int>, _ kind: TokenKind?) {
                guard !range.isEmpty else { return }
                var piece = AttributedString(String(decoding: units[range], as: UTF16.self))
                piece.foregroundColor = color(kind)
                result.append(piece)
            }
            for token in tokens where token.range.lowerBound >= position {
                append(position..<min(token.range.lowerBound, units.count), nil)
                append(token.range.clamped(to: position..<max(position, units.count)), token.kind)
                position = min(token.range.upperBound, units.count)
            }
            append(position..<units.count, nil)
            if index < lines.count - 1 { result.append(AttributedString("\n")) }
        }
        return result
    }
}
