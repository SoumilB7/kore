import AppKit
import SwiftUI
import Testing

@testable import KoreUI

/// The transcript's selection: a text laid out again with TextKit 2 lands where SwiftUI drew it,
/// and a clipped selection copies back as markdown with its structure.
@MainActor
@Suite("Transcript selection")
struct TranscriptSelectionTests {
    // MARK: Laid out again where SwiftUI drew it

    /// Each style's text in SwiftUI and in TextKit, at a width that wraps: the same lines, the
    /// same baselines, the same first glyph on each line (within a point: a small heading with
    /// larger inline code in it lands half a point apart).
    @Test(arguments: [
        SelectionStyle.body, .running, .heading(1), .heading(2), .heading(3), .heading(4), .heading(5), .code, .codeSmall, .cell(header: true),
        .cell(header: false),
    ])
    func layoutMatchesSwiftUI(_ style: SelectionStyle) throws {
        let text = Self.text(style)
        let width: CGFloat = 300
        let drawn = try Self.swiftUILines(text, style, width: width)
        let again = SlotLayout(style.attributed(text, zoom: Zoom.shared.scale), size: drawn.size).lineOrigins()
        #expect(drawn.lines.count == again.count, "\(style): \(drawn.lines.count) lines drawn, \(again.count) laid out")
        for (a, b) in zip(drawn.lines, again) {
            #expect(abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 1, "\(style): drawn \(a), laid out \(b)")
        }
    }

    private static func text(_ style: SelectionStyle) -> AttributedString {
        switch style {
        case .heading:
            // Headings as answers write them: words, maybe inline code. (An emoji in a large
            // heading makes SwiftUI's line a point taller than TextKit's.)
            let heading = AttributedString("Plan for one selection across the rows and the turns of a chat, ")
            var code = AttributedString("Text.Layout")
            code.inlinePresentationIntent = .code
            code.font = TextStyle.code
            return heading + code + AttributedString(" and more words to wrap")
        case .code, .codeSmall:
            return AttributedString("func hit(_ point: CGPoint) -> Int? {\n    rows.first { $0.frame.contains(point) }.map { $0.offset(at: point.x) }\n}")
        default:
            let markdown = "The **transcript** keeps one selection across rows, so a drag from one answer into the next selects `everything` between, the way a *browser* does, with emoji 😀 and “quotes”."
            var parsed = try! AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true { parsed[run.range].font = TextStyle.code }
            return parsed
        }
    }

    /// SwiftUI's own layout of the text as the transcript sets it.
    private static func swiftUILines(_ text: AttributedString, _ style: SelectionStyle, width: CGFloat) throws -> (lines: [CGPoint], size: CGSize) {
        let box = LayoutBox()
        let view = styled(Text(text), style)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { geometry in
                    let _ = box.take(layouts, geometry)
                    Color.clear
                }
            }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let result = try #require(box.result)
        window.contentView = nil
        return result
    }

    private static func styled(_ text: Text, _ style: SelectionStyle) -> some View {
        switch style {
        case .body: AnyView(text.font(TextStyle.body))
        case .running: AnyView(text.font(TextStyle.body).lineSpacing(TextStyle.leading))
        case .heading(let level): AnyView(text.font(TextStyle.heading(level)))
        case .code: AnyView(text.font(TextStyle.code))
        case .codeSmall: AnyView(text.font(TextStyle.codeSmall))
        case .cell(let header): AnyView(text.font(TextStyle.body).bold(header))
        }
    }

    private final class LayoutBox {
        var result: (lines: [CGPoint], size: CGSize)?

        func take(_ layouts: Text.LayoutKey.Value, _ geometry: GeometryProxy) {
            guard let anchored = layouts.first else { return }
            let origin = geometry[anchored.origin]
            var lines: [CGPoint] = []
            var width: CGFloat = 0
            for line in anchored.layout where !line.isEmpty {
                let first = line.first?.first?.typographicBounds.origin.x ?? 0
                lines.append(CGPoint(x: origin.x + line.origin.x + first, y: origin.y + line.origin.y))
                width = max(width, line.typographicBounds.width)
            }
            result = (lines, CGSize(width: width, height: geometry.size.height))
        }
    }

    // MARK: Copy

    private static let reply = """
        # Title

        A paragraph with **bold**, `code` and a [link](https://example.com).

        - first item
        - second item
          - nested one
        - third item

        > a quoted line
        > and another

        | Name | Kind |
        |---|---|
        | alpha | one |
        | beta | two |

        ```swift
        let fence = "```"
        ```
        """

    private func copy(from lo: TextPoint?, to hi: TextPoint?) -> String {
        let blocks = MarkdownParser.parse(Self.reply[...], base: 0, zoom: 1)
        let clip = Clip(lo: lo, hi: hi)
        return blocks.enumerated().compactMap { i, block in clip.block(block, [i]) }.joined(separator: "\n\n")
    }

    private let id = UUID()
    private func at(_ path: [Int], _ offset: Int) -> TextPoint { TextPoint(entry: id, path: path, offset: offset) }

    @Test func partOfAParagraphKeepsItsInlineMarkup() {
        // "with bold, code and a link."
        #expect(copy(from: at([1], 12), to: at([1], 33)) == "with **bold**, `code` and a")
        #expect(copy(from: at([1], 34), to: nil).hasPrefix("[link](https://example.com)."))
    }

    @Test func partOfAListKeepsItsMarkersAndNesting() {
        #expect(copy(from: at([2, 1, 0], 7), to: at([2, 2, 0], 5)) == "- item\n\n  - nested one\n- third")
    }

    @Test func partOfAHeadingKeepsItsLevel() {
        #expect(copy(from: at([0], 2), to: at([1], 1)) == "# tle\n\nA")
    }

    @Test func partOfAQuoteStaysQuoted() {
        #expect(copy(from: at([3, 0], 2), to: at([3, 0], 13)) == "> quoted line")
    }

    @Test func partOfATableKeepsItsHeaderRow() {
        #expect(copy(from: at([4, 2, 0], 0), to: at([4, 2, 1], 3)) == "| Name | Kind |\n|---|---|\n| beta | two |")
    }

    @Test func aCodeBlockFenceOutgrowsTheBackticksInside() {
        let code = copy(from: at([5], 4), to: nil)
        #expect(code == "````swift\nfence = \"```\"\n````")
    }

    @Test func blocksSelectedWholeAreTheirSource() {
        let clip = Clip(lo: at([1], 0), hi: at([3, 0], 1))
        #expect(clip.covers([1]) && clip.covers([2]))
        #expect(!clip.covers([3]) && !clip.covers([0]) && !clip.covers([4]))
    }

    /// What floats over the rows (a pinned message) takes presses from the text under it.
    @Test func aPinnedMessageBlocksPressesUnderIt() {
        let selection = TranscriptSelection(store: nil)
        selection.blocker("message", CGRect(x: 0, y: 100, width: 400, height: 60))
        #expect(selection.isBlocked(CGPoint(x: 10, y: 120)))
        #expect(!selection.isBlocked(CGPoint(x: 10, y: 200)))
        selection.blocker("message", nil)
        #expect(!selection.isBlocked(CGPoint(x: 10, y: 120)))
    }

    @Test func messagesQuoteEveryLine() {
        #expect(SelectionCopy.quote("one\n\ntwo") == "> one\n>\n> two")
    }
}
