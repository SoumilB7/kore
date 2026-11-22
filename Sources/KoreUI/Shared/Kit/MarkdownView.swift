import AppKit
import KoreCore
import SwiftUI

/// An assistant reply's markdown, as blocks (look.md §13). While `streaming`, only settled blocks
/// show, as in the Claude Code extension: the text up to its last blank line, and never a code
/// fence that hasn't closed. Blocks are parsed once and kept; a growing reply parses only its
/// last block again, so keep the view's identity stable for the life of the reply.
struct MarkdownView: View {
    let text: String
    var streaming = false
    /// What the parse is kept under (a reply's entry id); nil keys it by the text itself.
    var key: String?

    var body: some View {
        let document = MarkdownCache.shared.document(key ?? "text:" + text)
        document.update(streaming ? MarkdownParser.settled(text) : text[...])
        var blocks = document.blocks
        if streaming, blocks.last?.isOpen == true { blocks.removeLast() }
        return MarkdownBlocks(blocks: blocks, listDepth: 0, path: [])
    }
}

/// A run of blocks with collapsed gaps between them (the larger of the two neighbours' margins).
private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    /// How many lists this run sits inside (bullets change by depth; nested lists have no gap).
    let listDepth: Int
    /// Where these blocks sit in the reply: a text's path for the transcript's selection.
    let path: [Int]

    var body: some View {
        // One block (most list items) needs no stack around it.
        if blocks.count == 1 {
            MarkdownBlockView(block: blocks[0], listDepth: listDepth, path: path + [0])
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    MarkdownBlockView(block: block, listDepth: listDepth, path: path + [index])
                        .padding(.top, index == 0 ? 0 : gap(blocks[index - 1], block))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func gap(_ above: MarkdownBlock, _ below: MarkdownBlock) -> CGFloat {
        max(margin(above), margin(below))
    }

    private func margin(_ block: MarkdownBlock) -> CGFloat {
        switch block.kind {
        case .heading: Markdown.headingGap
        case .paragraph: Markdown.paragraphGap
        case .list: listDepth > 0 ? 0 : Markdown.listGap
        case .code, .quote, .table: Markdown.blockGap
        case .rule: Markdown.ruleGap
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let listDepth: Int
    let path: [Int]

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            RunText(text: text)
                .font(TextStyle.heading(level))
                .foregroundStyle(Theme.text)
                .selectableText(path, text, .heading(level))
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            RunText(text: text)
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(TextStyle.leading)
                .selectableText(path, text, .running)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            // Coloured once its fence closes; plain while it streams.
            MarkdownCodeBlock(text: text, language: block.isOpen ? .plain : Language.named(language), path: path)
        case .list(let list):
            MarkdownListView(list: list, depth: listDepth, path: path)
        case .quote(let blocks):
            MarkdownBlocks(blocks: blocks, listDepth: 0, path: path)
                .padding(Inset.quote)
                .background(Theme.quoteFill, in: RoundedRectangle(cornerRadius: Radius.chip))
                .padding(.leading, Markdown.quoteIndent)
        case .table(let table):
            MarkdownTableView(table: table, path: path)
        case .rule:
            Rectangle()
                .fill(Theme.rule)
                .frame(height: Stroke.hairline)
        }
    }
}

/// A fenced code block: a well that scrolls sideways (no wrap), with Copy just below it at its
/// right edge on hover (`CopyBelow`). A fence that names its language is in the editor's colours
/// (`SyntaxText`).
private struct MarkdownCodeBlock: View {
    let text: String
    let language: Language
    let path: [Int]

    var body: some View {
        CopyBelow(id: StoryID.Transcript.code(path), text: { [text] in text }) {
            SidewaysWhenWide(fade: true) {
                code
                    .font(TextStyle.code)
                    .foregroundStyle(Theme.text)
                    .selectableText(path, text, .code)
                    .fixedSize()
                    .padding(Inset.codeBlock)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.codeBlock, in: RoundedRectangle(cornerRadius: Radius.chip))
        }
    }

    private var code: Text {
        language.family == .plain ? Text(text) : Text(SyntaxText.attributed(text, language))
    }
}

/// Copy just below a block at its right edge, shown on hover, in a row kept for it as under a
/// message, so it covers none of the block: a code block's.
private struct CopyBelow<Block: View>: View {
    let id: StoryID
    let text: () -> String
    @ViewBuilder let block: Block
    @StateObject private var hovered = Local(false)
    @StateObject private var copied = Local(false)
    /// How far the block's right edge runs past the visible page (pinched in and panned left):
    /// the button comes in by that much, so it's where the eye is, not off to the right.
    @StateObject private var past = Local(CGFloat(0))

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            block
            HStack(spacing: 0) {
                if hovered.value {
                    IconButton(symbol: copied.value ? "checkmark" : "doc.on.doc", kind: .mini, font: Chrome.label, help: "Copy") {
                        copyToBoard(text, copied)
                    }
                    .storyID(id.part(.copy))
                    .padding(.trailing, past.value)
                }
            }
            .frame(height: Size.MessageActions.row)
        }
        // Read only while the button shows: nothing per scroll or frame otherwise.
        .background(VisibleRightEdge(active: hovered.value, keep: Size.MessageActions.row * 2) { if past.value != $0 { past.value = $0 } })
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .storyID(id)
        .storyAction(id.part(.hover)) { hovered.value = true }
        // The copy button is built only on hover.
        .accessibilityActions {
            Button("Copy") { copyToBoard(text, copied) }
        }
    }
}

/// Copy by a block's top-right corner, outside it, shown on hover over it: beside the corner in
/// the page's margin when there's room there, else just above the block's top edge, so it never
/// covers the block's text (a short table's header was under it). It hangs outside the block and
/// takes no room, so the block's height is the same with it or without (a row kept under a table
/// moved the reader to a chat's end on a quick resize). Only the chip takes clicks: a press on it
/// is the button's, not a selection; a drag from anywhere else still selects. Its reach meets the
/// block's edge, so the pointer going onto it never leaves both. Zoomed in and panned, it comes
/// in to the visible edge, above the block.
private struct CopyByCorner<Block: View>: View {
    let id: StoryID
    let text: () -> String
    @ViewBuilder let block: Block
    @Environment(\.transcriptSelection) private var selection
    @StateObject private var hovered = Local(false)
    /// The pointer on the chip itself.
    @StateObject private var held = Local(false)
    @StateObject private var copied = Local(false)
    @StateObject private var past = Local(CGFloat(0))
    /// The visible page's room right of the block, read while the chip shows.
    @StateObject private var room = Local(CGFloat(0))

    var body: some View {
        let shown = hovered.value || held.value
        block
            .overlay(alignment: .topTrailing) {
                if shown { chip }
            }
            // Read only while the button shows: nothing per scroll or frame otherwise.
            .background(
                VisibleRightEdge(active: shown, keep: Size.MessageActions.row * 2, room: { if room.value != $0 { room.value = $0 } }) {
                    if past.value != $0 { past.value = $0 }
                }
            )
            .onHover { hovered.value = $0 }
            .storyID(id)
            .storyAction(id.part(.hover)) { hovered.value = true }
            .accessibilityActions { Button("Copy") { copyToBoard(text, copied) } }
    }

    private var chip: some View {
        let size = Size.MessageActions.button
        // Where the button's own reach ends: the gap between it and the block.
        let gap = HitTarget.reach(width: size, height: size).leading
        let beside = past.value == 0 && room.value >= size + gap
        return IconButton(symbol: copied.value ? "checkmark" : "doc.on.doc", kind: .mini, font: Chrome.label, help: "Copy") {
            copyToBoard(text, copied)
        }
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
        .storyID(id.part(.copy))
        // Its frame is the selection's to leave alone: a press here copies.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TranscriptSelection.space)) } action: { [selection, raw = id.raw] in
            selection?.blocker(raw, $0)
        }
        .onDisappear { [selection, raw = id.raw] in selection?.blocker(raw, nil) }
        .onHover { held.value = $0 }
        // Hung off the overlay's top-right point by frames of no size, so it lays out (and takes
        // clicks) where it shows. Beside: its left edge past the block's right one, tops level.
        // Above: its bottom over the block's top, right edges level (or in at the visible edge).
        .padding(beside ? .leading : .bottom, gap)
        .padding(.trailing, beside ? 0 : past.value)
        .frame(width: beside ? 0 : nil, alignment: .leading)
        .frame(height: beside ? nil : 0, alignment: .bottom)
    }
}

/// The text on the pasteboard, and the button's tick for a moment.
@MainActor
private func copyToBoard(_ text: () -> String, _ copied: Local<Bool>) {
    let board = TranscriptSelection.pasteboard
    board.clearContents()
    board.setString(text(), forType: .string)
    copied.value = true
    Task {
        try? await Task.sleep(for: .seconds(Motion.copied))
        copied.value = false
    }
}

/// How far a view's right edge runs past its scroll view's visible right edge, in the page's
/// points: 0 at the natural size or when it's in view. While `active` it follows the clip's
/// moves and the magnification (a pan or a pinch); otherwise it watches nothing. `keep`: the
/// width at the view's right that never comes in (the button's own room inside the view).
private struct VisibleRightEdge: NSViewRepresentable {
    let active: Bool
    let keep: CGFloat
    /// The visible page right of the view's edge (0 when there's none), besides.
    var room: ((CGFloat) -> Void)? = nil
    let past: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.keep = keep
        view.report = past
        view.reportRoom = room
        view.active = active
    }

    final class Probe: NSView {
        var keep: CGFloat = 0
        var report: (CGFloat) -> Void = { _ in }
        var reportRoom: ((CGFloat) -> Void)?
        var active = false {
            didSet {
                guard active != oldValue else { return }
                watch()
                measure()
            }
        }
        private var observers: [NSObjectProtocol] = []
        /// The clip posted no bounds changes until this turned them on: off again after.
        private weak var postingFor: NSClipView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        // Out of the window (the row unloaded), its watching ends with it.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watch()
            measure()
        }

        private func watch() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            postingFor?.postsBoundsChangedNotifications = false
            postingFor = nil
            guard active, window != nil, let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            if !clip.postsBoundsChangedNotifications {
                clip.postsBoundsChangedNotifications = true
                postingFor = clip
            }
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.measure() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.measure() }
            })
        }

        private func measure() {
            guard active, let scroll = enclosingScrollView, let document = scroll.documentView else {
                report(0)
                reportRoom?(0)
                return
            }
            let edge = convert(bounds, to: document).maxX
            // The message rail sits over the view's right edge at its own size (window points,
            // not the page's): the button stops short of it.
            let rail = (Size.railWidth + Size.railInset) / max(scroll.magnification, 1)
            let visible = scroll.documentVisibleRect.maxX - (edge > scroll.documentVisibleRect.maxX - rail ? rail : 0)
            report(max(0, min(edge - visible, bounds.width - keep)).rounded())
            // Room beside it stops short of the rail wherever the rail is.
            reportRoom?(max(0, scroll.documentVisibleRect.maxX - rail - edge).rounded(.down))
        }

    }
}

extension MarkdownTable {
    /// The whole table as its Copy takes it: cells split by tabs, a row a line, or as Markdown;
    /// links as their text either way.
    func copyText(markdown: Bool) -> String {
        Clip(lo: nil, hi: nil, plainText: !markdown).block(MarkdownBlock(id: 0, kind: .table(self), isOpen: false), [0]) ?? ""
    }
}

/// Content at its own width, in a sideways scroll view only when it's wider than the column. A
/// scroll view is most of what a short code block or a small table costs to build, and one that
/// fits looks and scrolls the same as no scroll view. With `fade`, a wide one's trailing edge
/// fades over `Size.tabFade` (the tab strip's "more this way"), and the content ends that much
/// further in, so scrolled to its end nothing is faded.
private struct SidewaysWhenWide<Content: View>: View {
    var fade = false
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content.fixedSize(horizontal: true, vertical: false)
            if fade {
                ScrollView(.horizontal) { content.padding(.trailing, Size.tabFade) }
                    .scrollBounceBehavior(.basedOnSize)
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: Size.tabFade)
                        }
                    }
            } else {
                ScrollView(.horizontal) { content }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

/// A list: markers right-aligned in a fixed indent, items with no gap between them.
private struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int
    let path: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    marker(index, item)
                        .frame(width: Markdown.listIndent - Markdown.markerGap, alignment: .trailing)
                        .padding(.trailing, Markdown.markerGap)
                    if item.blocks.isEmpty {
                        Text(" ").font(TextStyle.body)
                    } else {
                        MarkdownBlocks(blocks: item.blocks, listDepth: depth + 1, path: path + [index])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ index: Int, _ item: MarkdownList.Item) -> some View {
        if let checked = item.task {
            RoundedRectangle(cornerRadius: Radius.checkbox)
                .strokeBorder(Theme.timelineLine, lineWidth: Stroke.hairline)
                .frame(width: Size.checkbox, height: Size.checkbox)
                .overlay {
                    if checked {
                        Text("✓").font(TextStyle.caption).foregroundStyle(Theme.text)
                    }
                }
                // Sits on the item's first line like a glyph would.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - Stroke.emphasis }
        } else {
            Text(list.ordered ? "\(list.start + index)." : Self.bullets[min(depth, Self.bullets.count - 1)])
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
        }
    }

    private static let bullets = ["•", "◦", "▪"]
}

/// A table: 1pt rules around every cell (the grid's spacing over a rule-coloured ground), bold
/// centred header, and sideways scrolling when wider than the column. Copy by its top-right
/// corner on hover (`CopyByCorner`, outside it, no room kept) takes its cells split by tabs, a row a
/// line, links as their text.
private struct MarkdownTableView: View {
    let table: MarkdownTable
    let path: [Int]

    private var columns: Int { max(table.header.count, table.rows.map(\.count).max() ?? 0) }

    var body: some View {
        CopyByCorner(id: StoryID.Transcript.table(path), text: { [table] in table.copyText(markdown: false) }) { grid }
            // Rows as tall as their text: cells fill their row, not the height on offer.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var grid: some View {
        SidewaysWhenWide {
            Grid(horizontalSpacing: Stroke.hairline, verticalSpacing: Stroke.hairline) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(column < table.header.count ? table.header[column] : AttributedString(), header: true, at: [0, column])
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            let cells = table.rows[row]
                            cell(column < cells.count ? cells[column] : AttributedString(), header: false, at: [row + 1, column])
                        }
                    }
                }
            }
            .padding(Stroke.hairline)
            .background(Theme.tableRule)
        }
    }

    private func cell(_ text: AttributedString, header: Bool, at cell: [Int]) -> some View {
        RunText(text: text)
            .font(TextStyle.body)
            .bold(header)
            .foregroundStyle(Theme.text)
            .selectableText(path + cell, text, .cell(header: header))
            .padding(Inset.tableCell)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: header ? .center : .leading)
            .background(Theme.background)
    }
}

/// A markdown text. In a selectable transcript row it's drawn without `.link`: Kore's selection
/// opens a link on a click there (it keeps the links), and a SwiftUI link is a text responder of
/// its own; an answer streaming under the transparent titlebar kept changing it, which can send
/// AppKit round its window-regions pass until it throws ("more Update Structural Regions passes
/// than there are views"). The words, colours and underline are the same; VoiceOver still finds
/// links, with an action to open each.
private struct RunText: View {
    let text: AttributedString
    @Environment(\.transcriptSelection) private var selection
    @Environment(\.selectionEntry) private var entry
    @Environment(\.openURL) private var openURL

    var body: some View {
        if selection != nil, entry != nil, text.runs.contains(where: { $0.link != nil }) {
            let links = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0) } }
            Text(Self.unlinked(text))
                .accessibilityAddTraits(.isLink)
                .accessibilityActions {
                    ForEach(links.indices, id: \.self) { index in
                        Button("Open \(links[index].0)") { openURL(links[index].1) }
                    }
                }
        } else {
            Text(text)
        }
    }

    static func unlinked(_ text: AttributedString) -> AttributedString {
        var drawn = text
        for run in text.runs where run.link != nil { drawn[run.range].link = nil }
        return drawn
    }
}
