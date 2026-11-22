import AppKit
@testable import src
import SwiftUI
import Testing

@testable import KoreUI

/// The transcript's selection: a text laid out again with TextKit 2 lands where SwiftUI drew it,
/// and a selection copies what it shows inside one text, Markdown across blocks, tagged by who said
/// it when it spans messages.
@MainActor
@Suite("Transcript selection")
struct TranscriptSelectionTests {
    // MARK: Laid out again where SwiftUI drew it

    /// Each style's text in SwiftUI and in TextKit, at a width that wraps: the same lines, the
    /// same baselines, the same first glyph on each line (within a point: a small heading with
    /// larger inline code in it lands half a point apart).
    @Test(arguments: [
        SelectionStyle.body, .running, .toolHeader, .heading(1), .heading(2), .heading(3), .heading(4), .heading(5), .code, .codeSmall, .cell(header: true),
        .cell(header: false),
    ])
    func layoutMatchesSwiftUI(_ style: SelectionStyle) throws {
        let text = Self.text(style)
        let width: CGFloat = 300
        let drawn = try Self.swiftUILines(text, style, width: width)
        let again = SlotLayout(style.attributed(text, zoom: Zoom.shared.scale), size: drawn.size, maximumLines: style == .toolHeader ? 2 : 0).lineOrigins()
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
        case .toolHeader:
            var name = AttributedString("Run")
            name.font = TextStyle.toolName
            name.inlinePresentationIntent = .stronglyEmphasized
            var command = AttributedString(" python3 -c \"a command long enough to wrap across several lines in a narrow transcript\"")
            command.font = TextStyle.codeSmall
            command.inlinePresentationIntent = .code
            return name + command
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
        try swiftUILines(styled(Text(text), style), width: width)
    }

    private static func swiftUILines(_ text: some View, width: CGFloat) throws -> (lines: [CGPoint], size: CGSize) {
        let box = LayoutBox()
        let view = text
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
        case .toolHeader: AnyView(text.font(TextStyle.toolName).lineLimit(2))
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

    /// A bullet whose second line, after a break, is a long file path in inline code, at zooms
    /// where Menlo's size isn't a whole point: the code wraps as SwiftUI drew it, and selecting
    /// the path fills its glyphs on its lines and nothing past them (a stray rect once sat on an
    /// empty line under it).
    @Test(arguments: [0.8, 0.9, 1.1, 1.2])
    func codeLineInABulletSelectsOnItsGlyphs(_ zoom: Double) throws {
        let zoom = CGFloat(zoom)
        let path = "file:///Users/soumil/Code/Projects/kore/z-docs/design/chat-handoff.html"
        for (lead, end) in [("  \n", "hard break"), ("\n", "soft break")] {
            let md = "- The design doc is here: [chat-handoff.html](\(path))\(lead)  `\(path)`"
            let blocks = MarkdownParser.parse(md[...], base: 0, zoom: zoom)
            guard case .list(let list) = blocks.first?.kind, case .paragraph(let text) = list.items.first?.blocks.first?.kind else {
                Issue.record("not a bullet paragraph")
                return
            }
            let start = (String(text.characters) as NSString).range(of: "file:").location
            for width in [360, 480, 600, 760, 1000] as [CGFloat] {
                let drawn = try Self.swiftUILines(Text(text).font(.system(size: 13 * zoom)).lineSpacing(TextStyle.leading), width: width)
                let layout = SlotLayout(SelectionStyle.running.attributed(text, zoom: zoom), size: drawn.size)
                let again = layout.lineOrigins()
                let shape = "zoom \(zoom), \(end), \(Int(width)) pt"
                #expect(drawn.lines.count == again.count, "\(shape): \(drawn.lines.count) lines drawn, \(again.count) laid out")
                let rects = layout.rects(start..<layout.length)
                #expect(rects.allSatisfy { $0.maxY <= drawn.size.height + 1 }, "\(shape): \(rects) past \(drawn.size.height) pt")
                let right = rects.map(\.maxX).max() ?? 0
                #expect(abs(right - drawn.size.width) < 1, "\(shape): the selection ends at \(right), the text at \(drawn.size.width)")
            }
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

    private func copy(_ source: String = reply, from lo: TextPoint?, to hi: TextPoint?) -> String {
        SelectionCopy.markdownText(source[...], Clip(lo: lo, hi: hi))
    }

    private let id = UUID()
    private func at(_ path: [Int], _ offset: Int) -> TextPoint { TextPoint(entry: id, path: path, offset: offset) }

    /// The owner's case: a numbered point that starts in bold, with a command in inline code.
    private static let steps = """
        1. **Install the CLI**: run `curl -fsSL https://example.com/install.sh | bash` once.
        2. Then sign in.
        """
    private static let command = "curl -fsSL https://example.com/install.sh | bash"
    private static let point = "Install the CLI: run \(command) once."

    @Test func inlineCodeInsideAListPointIsTheBareCode() {
        let from = Self.point.utf16.count - " once.".utf16.count - Self.command.utf16.count
        let copied = copy(Self.steps, from: at([0, 0, 0], from), to: at([0, 0, 0], from + Self.command.utf16.count))
        #expect(copied == Self.command)
    }

    @Test func aWholeListPointIsItsTextWithNoMarker() {
        #expect(copy(Self.steps, from: at([0, 0, 0], 0), to: at([0, 0, 0], Self.point.utf16.count)) == Self.point)
        #expect(copy(Self.steps, from: at([0, 0, 0], 0), to: at([0, 0, 0], .max)) == Self.point)
    }

    @Test func partsOfTwoPointsAreNumberedLines() {
        #expect(copy(Self.steps, from: at([0, 0, 0], 8), to: at([0, 1, 0], 4))
            == "1. **the CLI**: run `\(Self.command)` once.\n2. Then")
        #expect(copy(from: at([2, 1, 0], 7), to: at([2, 2, 0], 5)) == "- item\n  - nested one\n- third")
    }

    @Test func partOfABoldPhraseIsTheBareText() {
        // "A paragraph with bold, code and a link."
        #expect(copy(from: at([1], 18), to: at([1], 20)) == "ol")
        #expect(copy(from: at([1], 12), to: at([1], 33)) == "with bold, code and a")
        #expect(copy(from: at([1], 0), to: at([1], .max)) == "A paragraph with bold, code and a link.")
    }

    @Test func twoParagraphsAreMarkdownWithLinksAsText() {
        let source = "Some **bold** words.\n\nA [second](https://example.com/x) `para`."
        #expect(copy(source, from: at([0], 5), to: at([1], .max)) == "**bold** words.\n\nA second `para`.")
        #expect(copy(source, from: at([0], 0), to: nil) == "Some **bold** words.\n\nA second `para`.")
        #expect(copy(source, from: nil, to: nil) == "Some **bold** words.\n\nA second `para`.")
        #expect(copy(from: at([1], 34), to: nil).hasPrefix("link.\n\n- first item\n"))
    }

    @Test func aHeadingKeepsItsMarkInMarkdown() {
        #expect(copy(from: at([0], 2), to: at([1], 1)) == "# tle\n\nA")
        #expect(copy(from: at([0], 0), to: at([0], .max)) == "Title")
    }

    @Test func aQuoteLineIsItsText() {
        #expect(copy(from: at([3, 0], 2), to: at([3, 0], 13)) == "quoted line")
    }

    @Test func partOfACodeBlockIsTheBareCode() {
        #expect(copy(from: at([5], 4), to: at([5], 9)) == "fence")
        #expect(copy(from: at([5], 0), to: at([5], .max)) == "let fence = \"```\"")
        // Across blocks, part of it is still its lines; all of it is fenced.
        #expect(copy(from: at([5], 4), to: nil) == "fence = \"```\"")
        #expect(copy(from: at([4, 2, 1], 0), to: at([5], 3)).hasSuffix("|  | two |\n\nlet"))
        #expect(copy(from: at([4, 2, 1], 0), to: nil).hasSuffix("\n\n```swift\nlet fence = \"```\"\n```"))
    }

    @Test func partOfATableIsMarkdownRowsWithItsHeader() {
        #expect(copy(from: at([4, 2, 0], 0), to: at([4, 2, 1], 3)) == "| Name | Kind |\n|---|---|\n| beta | two |")
    }

    private static let linked = "Before.\n\n| Key | `code` | Link |\n|---|---|---|\n| **bold** | *it* | [site](https://example.com) |\n| x |  | ~~old~~ |\n\nAfter."

    @Test func aLinkCellIsItsVisibleText() {
        #expect(copy(Self.linked, from: at([1, 1, 2], 0), to: at([1, 1, 2], .max)) == "site")
        #expect(copy(Self.linked, from: at([1, 1, 2], 1), to: at([1, 1, 2], 3)) == "it")
        #expect(copy(Self.linked, from: at([1, 1, 1], 0), to: at([1, 1, 2], .max))
            == "| Key | `code` | Link |\n|---|---|---|\n|  | *it* | site |")
    }

    /// A table's Copy is tabbed rows; a drag across all of it is its Markdown as written. Links
    /// are their text in both.
    @Test func aWholeTableWithALinkCopiesItsText() throws {
        let blocks = MarkdownParser.parse(Self.linked[...], base: 0, zoom: 1)
        guard case .table(let table) = blocks[1].kind else { Issue.record("no table"); return }
        #expect(table.copyText(markdown: false) == "Key\tcode\tLink\nbold\tit\tsite\nx\t\told")
        #expect(table.copyText(markdown: true) == "| Key | `code` | Link |\n|---|---|---|\n| **bold** | *it* | site |\n| x |  | ~~old~~ |")
        let dragged = copy(Self.linked, from: at([1, 0, 0], 0), to: at([2], 0))
        #expect(dragged == "| Key | `code` | Link |\n|---|---|---|\n| **bold** | *it* | site |\n| x |  | ~~old~~ |")
    }

    @Test func aTablesCopyIsTabbedAndItsSelectionMarkdown() throws {
        let blocks = MarkdownParser.parse(Self.reply[...], base: 0, zoom: 1)
        guard case .table(let table) = blocks[4].kind else { Issue.record("no table"); return }
        #expect(table.copyText(markdown: false) == "Name\tKind\nalpha\tone\nbeta\ttwo")
        #expect(table.copyText(markdown: true) == "| Name | Kind |\n|---|---|\n| alpha | one |\n| beta | two |")
        #expect(table.copyText(markdown: true) == copy(from: at([4, 0, 0], 0), to: at([5], 0)))
    }

    @Test func linksInSourceAreTheirText() {
        #expect(MarkdownLinks.unlinked("See [the **guide**](https://x.y/a_(b)) and <https://x.y>.") == "See the **guide** and https://x.y.")
        #expect(MarkdownLinks.unlinked("Keep `[a](b)`, ![img](p.png), \\[no](link) and a < b > c.") == "Keep `[a](b)`, ![img](p.png), \\[no](link) and a < b > c.")
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

    /// A normal shell call keeps its invocation in the header and has only an OUT block.
    private func openCommand() throws -> (Script, TranscriptStore.Entry, TranscriptStore.Entry) {
        let script = Script()
        script.send("first")
        script.start("turn")
        script.say("before", "Before.")
        script.on(.toolStarted(ToolCall(id: "command", name: "Bash", detail: "printf hello", input: "printf hello")))
        script.done("command", "hello")
        script.store.drawNow()
        let rows = SelectionCopy.rows(script.store)
        let before = try #require(rows.first { $0.entry.text == "Before." }?.entry)
        let command = try #require(rows.first { $0.entry.toolId == "command" }?.entry)
        script.store.toggle(command.id.uuidString)
        #expect(!ToolItem.parts(command).contains { $0.label == "IN" })
        return (script, before, command)
    }

    @Test func selectionEndingInsideAnOpenCommandHeaderDoesNotCopyItsBody() throws {
        let (script, before, command) = try openCommand()
        let copied = SelectionCopy.text(script.store,
            from: TextPoint(entry: before.id, path: [0], offset: 0),
            to: TextPoint(entry: command.id, path: [-1], offset: "Bash printf".utf16.count))
        #expect(copied == "Before.\n\nBash printf")
    }

    @Test func selectionReachingCommandOutputKeepsItsHeaderOnlyInvocation() throws {
        let (script, before, command) = try openCommand()
        let copied = SelectionCopy.text(script.store,
            from: TextPoint(entry: before.id, path: [0], offset: 0),
            to: TextPoint(entry: command.id, path: [0], offset: "hello".utf16.count))
        #expect(copied == "Before.\n\nprintf hello\nhello")
    }

    @Test func messagesAreTaggedOnlyWhenTheCopySpansMoreThanOne() throws {
        let script = Script()
        script.send("hi there")
        script.start("turn")
        script.say("answer", "# Plan\n\nUse **bold** `code`.")
        script.on(.finalAnswer("answer"))
        script.finish("turn")
        script.store.drawNow()
        let rows = SelectionCopy.rows(script.store)
        let user = try #require(rows.first { $0.entry.kind == .user }?.entry)
        let answer = try #require(rows.first { $0.entry.kind == .answer }?.entry)
        let both = SelectionCopy.text(script.store,
            from: TextPoint(entry: user.id, path: [0], offset: 3), to: TextPoint(entry: answer.id, path: [1], offset: .max))
        #expect(both == "You:\nthere\n\nClaude:\n# Plan\n\nUse **bold** `code`.")
        let one = SelectionCopy.text(script.store,
            from: TextPoint(entry: answer.id, path: [1], offset: 4), to: TextPoint(entry: answer.id, path: [1], offset: 8))
        #expect(one == "bold")
    }
}
