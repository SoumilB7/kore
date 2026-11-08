import AppKit
import KoreCore

/// A `.env` file's values as bullets, as a password field shows them: the glyphs are swapped
/// while laid out (`shouldGenerateGlyphs`, beside folding's), the text itself never changes, so
/// copy, find, save and undo see the real values. Menlo's bullet has the same advance as every
/// other glyph, so nothing moves when a line is shown. The caret's line (while the editor has
/// the keys) and the line under the pointer show their values.
extension CodeEditorController {
    var masksSecrets: Bool { colorer.language.family == .dotenv }

    /// The secret values on lines touching `span` that aren't shown, as character ranges.
    func secretRanges(in span: NSRange) -> [NSRange] {
        guard masksSecrets, span.length > 0 else { return [] }
        let string = document.storage.string as NSString
        let first = lines.line(at: span.location)
        let last = lines.line(at: max(span.location, NSMaxRange(span) - 1))
        var ranges: [NSRange] = []
        var tokens: [Language.Token] = []
        var state = colorer.state(at: first, string: string, lines: lines)
        for line in first...last {
            let range = lines.range(of: line, in: string)
            var units = [UInt16](repeating: 0, count: range.length)
            string.getCharacters(&units, range: range)
            tokens.removeAll(keepingCapacity: true)
            state = colorer.language.scan(units, from: state, into: &tokens)
            guard line != secretCaretLine, line != secretHoverLine else { continue }
            for token in tokens where token.kind == .secret {
                ranges.append(NSRange(location: range.location + token.range.lowerBound, length: token.range.count))
            }
        }
        return ranges
    }

    /// The caret's line shows its value while the editor has the keys.
    func revealSecrets() {
        guard masksSecrets else { return }
        let focused = textView.window?.firstResponder === textView
        let line = focused ? lines.line(at: textView.selectedRange().location) : nil
        guard line != secretCaretLine else { return }
        let old = secretCaretLine
        secretCaretLine = line
        remask(lines: [old, line])
    }

    func hoverSecrets(line: Int?) {
        guard masksSecrets, line != secretHoverLine else { return }
        let old = secretHoverLine
        secretHoverLine = line
        remask(lines: [old, line])
    }

    private func remask(lines changed: [Int?]) {
        let string = document.storage.string as NSString
        for line in changed.compactMap({ $0 }) where line < lines.count {
            remask(lines.range(of: line, in: string))
        }
    }

    /// Lays out `range`'s glyphs again: bullets on or off.
    func remask(_ range: NSRange) {
        guard let layout = textView.layoutManager else { return }
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: document.storage.length))
        guard safe.length > 0 else { return }
        layout.invalidateGlyphs(forCharacterRange: safe, changeInLength: 0, actualCharacterRange: nil)
        layout.invalidateLayout(forCharacterRange: safe, actualCharacterRange: nil)
        textView.needsDisplay = true
        textView.updateTrackingAreas()
    }

    /// The bullet glyph in `font`, or nil when it has none.
    static func bullet(in font: NSFont) -> CGGlyph? {
        var character: UniChar = 0x2022
        var glyph: CGGlyph = 0
        return CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1) && glyph != 0 ? glyph : nil
    }
}
