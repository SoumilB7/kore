import AppKit
import SwiftUI

/// How a selectable transcript text is set, so it can be laid out again exactly as SwiftUI drew
/// it: SwiftUI lays `Text` out with TextKit 2 too, and with the same fonts the lines, baselines
/// and glyphs land in the same places (research/transcript-selection.md §4).
enum SelectionStyle: Equatable {
    /// `TextStyle.body`.
    case body
    /// `TextStyle.body` with `TextStyle.leading` between lines (paragraphs, plans, thinking).
    case running
    case heading(Int)
    /// `TextStyle.code`.
    case code
    /// `TextStyle.codeSmall` (a tool's IN / OUT).
    case codeSmall
    case cell(header: Bool)

    /// The text with AppKit fonts and paragraph style for this style at `zoom`; inline code,
    /// bold and italic runs keep their own faces.
    @MainActor func attributed(_ text: AttributedString, zoom: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        if self == .running { paragraph.lineSpacing = TextStyle.leading }
        let base = font(zoom)
        let out = NSMutableAttributedString()
        for run in text.runs {
            var font = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { font = Self.mono(12 * zoom) }
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return out
    }

    private func font(_ zoom: CGFloat) -> NSFont {
        switch self {
        case .body, .running: .systemFont(ofSize: 13 * zoom)
        case .heading(let level): .systemFont(ofSize: Self.headings[min(max(level, 1), 6) - 1] * zoom, weight: .bold)
        case .code: Self.mono(12 * zoom)
        case .codeSmall: Self.mono(11 * zoom)
        case .cell(let header): .systemFont(ofSize: 13 * zoom, weight: header ? .bold : .regular)
        }
    }

    /// `TextStyle.h1`…`h6` (Markdown.swift).
    private static let headings: [CGFloat] = [26, 20, 15, 13, 11, 11]

    private static func mono(_ size: CGFloat) -> NSFont {
        NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// One text laid out with TextKit 2 at the width its `Text` has: a point to an offset, a range
/// to the rects a selection fills, a word or paragraph around an offset.
@MainActor
final class SlotLayout {
    private let storage = NSTextContentStorage()
    private let manager = NSTextLayoutManager()
    private(set) var text: NSAttributedString
    var length: Int { text.length }

    /// `size` is the `Text`'s frame. At some sizes of the system font (11, 15, 20 points…)
    /// SwiftUI's lines are a point taller than TextKit's; laid out to a different height than
    /// the frame, the difference goes between the lines, as SwiftUI puts it.
    init(_ text: NSAttributedString, size: CGSize) {
        self.text = text
        storage.addTextLayoutManager(manager)
        // A hair over the measured width: the widest line fits as it did.
        let container = NSTextContainer(size: CGSize(width: size.width + 0.5, height: 1e7))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        storage.attributedString = text
        manager.ensureLayout(for: manager.documentRange)
        let lines = lineOrigins(empty: true).count
        let extra = size.height - manager.usageBoundsForTextContainer.height
        if lines > 1, abs(extra) > 0.5 {
            let spaced = NSMutableAttributedString(attributedString: text)
            spaced.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: spaced.length)) { value, range, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.lineSpacing += extra / CGFloat(lines)
                spaced.addAttribute(.paragraphStyle, value: style, range: range)
            }
            storage.attributedString = spaced
            manager.ensureLayout(for: manager.documentRange)
            self.text = spaced
        }
    }

    private func offset(_ location: NSTextLocation) -> Int { storage.offset(from: storage.documentRange.location, to: location) }

    private func location(_ offset: Int) -> NSTextLocation? {
        storage.location(storage.documentRange.location, offsetBy: min(max(offset, 0), length))
    }

    /// The offset nearest a point (the text's own coordinates): on the nearest line, the side of
    /// the glyph the point is nearer; past a line's end, its end.
    func offset(at p: CGPoint) -> Int {
        var best: (start: Int, line: NSTextLineFragment, origin: CGPoint, score: CGFloat)?
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            let start = offset(fragment.rangeInElement.location)
            let o = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments {
                let r = line.typographicBounds.offsetBy(dx: o.x, dy: o.y)
                let dy = p.y < r.minY ? r.minY - p.y : p.y > r.maxY ? p.y - r.maxY : 0
                if best == nil || dy < best!.score { best = (start, line, o, dy) }
            }
            return true
        }
        guard let (start, line, o, _) = best else { return 0 }
        let local = CGPoint(x: p.x - o.x, y: p.y - o.y)
        let range = line.characterRange
        var index = line.characterIndex(for: local)
        if index < range.upperBound, line.fractionOfDistanceThroughGlyph(for: local) > 0.5 { index += 1 }
        // Not past the line's own end: its line break starts the next line.
        var end = range.upperBound
        let units = line.attributedString.string.utf16
        if end > range.location, end <= units.count, units[units.index(units.startIndex, offsetBy: end - 1)] == 0x0A { end -= 1 }
        return min(start + min(max(index, range.location), end), length)
    }

    /// Where the glyph at `offset` starts, at its line's middle (the text's coordinates).
    func point(at offset: Int) -> CGPoint? {
        guard let location = location(offset), let fragment = manager.textLayoutFragment(for: location) else { return nil }
        let inParagraph = offset - self.offset(fragment.rangeInElement.location)
        let o = fragment.layoutFragmentFrame.origin
        for line in fragment.textLineFragments
        where line.characterRange.contains(inParagraph) || line.characterRange.upperBound == inParagraph {
            return CGPoint(x: o.x + line.locationForCharacter(at: inParagraph).x, y: o.y + line.typographicBounds.midY)
        }
        return nil
    }

    /// The rects a selection of `range` fills, as TextKit draws a text view's selection.
    func rects(_ range: Range<Int>) -> [CGRect] {
        let a = max(0, range.lowerBound), b = min(length, range.upperBound)
        guard a < b, let start = location(a), let end = location(b), let text = NSTextRange(location: start, end: end) else { return [] }
        var out: [CGRect] = []
        manager.enumerateTextSegments(in: text, type: .selection, options: [.rangeNotRequired]) { _, rect, _, _ in
            if rect.width > 0 { out.append(rect) }
            return true
        }
        return out
    }

    /// The word (or run of punctuation or space) around `offset`, as a double-click takes it.
    func word(at offset: Int) -> Range<Int> {
        guard length > 0 else { return 0..<0 }
        let range = text.doubleClick(at: min(max(offset, 0), length - 1))
        return range.location..<(range.location + range.length)
    }

    /// The paragraph around `offset`, without its line break, as a triple-click takes it.
    func paragraph(at offset: Int) -> Range<Int> {
        let string = text.string as NSString
        guard string.length > 0 else { return 0..<0 }
        var range = string.paragraphRange(for: NSRange(location: min(max(offset, 0), string.length - 1), length: 0))
        while range.length > 0, [0x0A, 0x0D].contains(string.character(at: range.location + range.length - 1)) { range.length -= 1 }
        return range.location..<(range.location + range.length)
    }

    /// Each laid-out line's first glyph on its baseline (the text's coordinates).
    func lineOrigins(empty: Bool = false) -> [CGPoint] {
        var out: [CGPoint] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            let o = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments where empty || line.characterRange.length > 0 {
                let x = line.locationForCharacter(at: line.characterRange.location).x
                out.append(CGPoint(x: o.x + x, y: o.y + line.typographicBounds.minY + line.glyphOrigin.y))
            }
            return true
        }
        return out
    }

    /// The link under `offset`, if any.
    func link(at offset: Int) -> URL? {
        guard offset >= 0, offset < length else { return nil }
        let value = text.attribute(.link, at: offset, effectiveRange: nil)
        return value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }
}
