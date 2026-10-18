import AppKit
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
        return MarkdownBlocks(blocks: blocks, listDepth: 0)
    }
}

/// A run of blocks with collapsed gaps between them (the larger of the two neighbours' margins).
private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    /// How many lists this run sits inside (bullets change by depth; nested lists have no gap).
    let listDepth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                MarkdownBlockView(block: block, listDepth: listDepth)
                    .padding(.top, index == 0 ? 0 : gap(blocks[index - 1], block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(text)
                .font(TextStyle.heading(level))
                .foregroundStyle(Theme.text)
                .selectableOnHover()
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(text)
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(TextStyle.leading)
                .selectableOnHover()
                .fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            MarkdownCodeBlock(text: text)
        case .list(let list):
            MarkdownListView(list: list, depth: listDepth)
        case .quote(let blocks):
            MarkdownBlocks(blocks: blocks, listDepth: 0)
                .padding(Inset.quote)
                .background(Theme.quoteFill, in: RoundedRectangle(cornerRadius: Radius.chip))
                .padding(.leading, Markdown.quoteIndent)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Rectangle()
                .fill(Theme.rule)
                .frame(height: Stroke.hairline)
        }
    }
}

/// A fenced code block: a well that scrolls sideways (no wrap), with a copy button on hover.
private struct MarkdownCodeBlock: View {
    let text: String
    @StateObject private var hovered = Local(false)

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(TextStyle.code)
                .foregroundStyle(Theme.text)
                .selectableOnHover()
                .fixedSize()
                .padding(Inset.codeBlock)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeBlock, in: RoundedRectangle(cornerRadius: Radius.chip))
        .overlay(alignment: .topTrailing) {
            if hovered.value {
                IconButton(symbol: "doc.on.doc", kind: .small, help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .padding(Inset.codeCopy)
            }
        }
        .onHover { hovered.value = $0 }
    }
}

/// A list: markers right-aligned in a fixed indent, items with no gap between them.
private struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int

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
                        MarkdownBlocks(blocks: item.blocks, listDepth: depth + 1)
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
/// centred header, and sideways scrolling when wider than the column.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    private var columns: Int { max(table.header.count, table.rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: Stroke.hairline, verticalSpacing: Stroke.hairline) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(column < table.header.count ? table.header[column] : AttributedString(), header: true)
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            let cells = table.rows[row]
                            cell(column < cells.count ? cells[column] : AttributedString(), header: false)
                        }
                    }
                }
            }
            .padding(Stroke.hairline)
            .background(Theme.tableRule)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Rows as tall as their text: cells fill their row, not the height on offer.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ text: AttributedString, header: Bool) -> some View {
        Text(text)
            .font(TextStyle.body)
            .bold(header)
            .foregroundStyle(Theme.text)
            .selectableOnHover()
            .padding(Inset.tableCell)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: header ? .center : .leading)
            .background(Theme.background)
    }
}
