import AppKit
import SwiftUI

/// CSV and TSV files as a grid (look §2): a sticky header and row-number gutter, columns that
/// fit their content and resize, three-way sort, cell selection that copies as TSV. Only the
/// visible cells are drawn.
enum DelimitedRenderer: FileRenderer {
    static let id = "delimited"
    static let hasRaw = true

    static func matches(_ file: FileInfo) -> Bool { ["csv", "tsv", "tab"].contains(file.ext) }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(DelimitedView(file: file, context: context))
    }
}

private struct DelimitedView: View {
    let file: FileInfo
    let context: RendererContext
    @StateObject private var loaded = Local<Loaded<DelimitedTable>>(.loading)

    var body: some View {
        Group {
            switch loaded.value {
            case .loading: RendererLoading()
            case .tooLarge: RendererState.tooLarge(file, context: context)
            case .failed(let reason): RendererState.cantRender(file, reason: reason, context: context, hasRaw: true)
            case .ready(let table): GridRepresentable(table: table, zoom: context.zoom, setFacts: context.setFacts)
            }
        }
        .task(id: context.reloadToken) { await load() }
    }

    private func load() async {
        guard file.size <= Limit.csvBytes else {
            loaded.value = .tooLarge
            return
        }
        let url = file.url
        let tsv = file.ext != "csv"
        do {
            let table = try await Task.detached(priority: .userInitiated) {
                // Mapped: the file's pages stay the file's, not the app's memory.
                try DelimitedTable.parse(Data(contentsOf: url, options: .alwaysMapped), isTSV: tsv, limit: Limit.csvRows)
            }.value
            loaded.value = .ready(table)
            RenderTiming.ready(DelimitedRenderer.id)
        } catch DelimitedTable.Failure.notText {
            loaded.value = .failed("This file isn't text.")
        } catch {
            loaded.value = .failed(error.localizedDescription)
        }
    }
}

private struct GridRepresentable: NSViewRepresentable {
    let table: DelimitedTable
    let zoom: CGFloat
    let setFacts: ([String]) -> Void

    func makeNSView(context: Context) -> CanvasScrollView {
        let grid = GridCanvas()
        let scroll = CanvasScrollView(canvas: grid)
        update(grid)
        return scroll
    }

    func updateNSView(_ scroll: CanvasScrollView, context: Context) {
        if let grid = scroll.canvas as? GridCanvas { update(grid) }
    }

    private func update(_ grid: GridCanvas) {
        grid.onFacts = setFacts
        grid.set(table: table, zoom: zoom)
    }
}

// MARK: - The grid

private final class GridCanvas: CanvasView {
    var onFacts: ([String]) -> Void = { _ in }
    private var table: DelimitedTable?
    private var zoom: CGFloat = 0

    /// Display row i shows table row `order[i]` (1-based), or i + 1 in the file's order.
    private var order: [Int32]?
    private var sort: (column: Int, ascending: Bool)?
    private var sorting = 0
    private var widths: [CGFloat] = []
    /// Each column's left edge from the gutter's right edge; one more for the last right edge.
    private var lefts: [CGFloat] = [0]
    private var gutter: CGFloat = 0
    private var rowHeight: CGFloat = 0

    private struct Cell: Equatable {
        var row: Int
        var column: Int
    }

    private var anchor: Cell?
    private var head: Cell?
    private var hoverRow: Int?
    private var resizing: (column: Int, startX: CGFloat, width: CGFloat)?

    // Drawing state, made once per zoom.
    private var font = NSFont.systemFont(ofSize: 12)
    private var digits = NSFont.systemFont(ofSize: 12)
    private var bold = NSFont.systemFont(ofSize: 12)
    private var textAttributes: [NSAttributedString.Key: Any] = [:]
    private var numberAttributes: [NSAttributedString.Key: Any] = [:]
    private var headerAttributes: [NSAttributedString.Key: Any] = [:]
    private var gutterAttributes: [NSAttributedString.Key: Any] = [:]
    private var noteAttributes: [NSAttributedString.Key: Any] = [:]

    private var rows: Int { table?.rows ?? 0 }
    private var columns: Int { table?.columns ?? 0 }
    /// The note row under the last row when the file was cut short.
    private var noteRows: Int { table?.capped == true ? 1 : 0 }

    func set(table: DelimitedTable, zoom: CGFloat) {
        let tableChanged = table !== self.table
        let zoomChanged = zoom != self.zoom
        guard tableChanged || zoomChanged else { return }
        let columnsChanged = table.columns != self.table?.columns
        self.table = table
        self.zoom = zoom
        if zoomChanged { makeStyle() }
        if tableChanged || zoomChanged {
            if columnsChanged || zoomChanged || widths.isEmpty { measure() }
            if let sort, tableChanged {
                order = nil
                startSort(sort.column, ascending: sort.ascending)
            }
            clampSelection()
        }
        layoutDocument()
        needsDisplay = true
        reportFacts()
    }

    private func makeStyle() {
        rowHeight = (Size.Grid.row * zoom).rounded()
        font = TextStyle.gridFont
        digits = TextStyle.gridFontDigits
        bold = TextStyle.gridHeaderFont
        let left = NSMutableParagraphStyle()
        left.lineBreakMode = .byTruncatingTail
        let right = NSMutableParagraphStyle()
        right.lineBreakMode = .byTruncatingTail
        right.alignment = .right
        textAttributes = [.font: font, .foregroundColor: NSColor(Theme.text), .paragraphStyle: left]
        numberAttributes = [.font: digits, .foregroundColor: NSColor(Theme.text), .paragraphStyle: right]
        headerAttributes = [.font: bold, .foregroundColor: NSColor(Theme.text), .paragraphStyle: left]
        gutterAttributes = [.font: digits, .foregroundColor: NSColor(Theme.Grid.rowNumber), .paragraphStyle: right]
        noteAttributes = [.font: font, .foregroundColor: NSColor(Theme.tertiary), .paragraphStyle: left]
    }

    /// Columns fit the header and the first rows, between the min and max width.
    private func measure() {
        guard let table else { return }
        let sample = min(table.rows, Size.Grid.measuredRows, max(1, 20_000 / max(table.columns, 1)))
        let padding = 2 * Size.Grid.cellPadding * zoom
        let sortRoom = (Size.Grid.sortGlyph + Size.Grid.sortGap) * zoom
        widths = (0..<table.columns).map { column in
            var width = (table.text(row: 0, column: column) as NSString).size(withAttributes: headerAttributes).width + sortRoom
            for row in stride(from: 1, through: sample, by: 1) {
                let text = table.text(row: row, column: column)
                guard !text.isEmpty else { continue }
                width = max(width, (text as NSString).size(withAttributes: table.numeric[column] ? numberAttributes : textAttributes).width)
            }
            return clampWidth(width + padding)
        }
        let label = String(table.rows) as NSString
        gutter = ceil(label.size(withAttributes: gutterAttributes).width + padding)
    }

    private func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(ceil(width), Size.Grid.minColumn * zoom), Size.Grid.maxColumn * zoom)
    }

    private func layoutDocument() {
        var x: CGFloat = 0
        lefts = [0]
        for width in widths {
            x += width
            lefts.append(x)
        }
        scroller?.documentSize = NSSize(
            width: gutter + x, height: rowHeight * CGFloat(1 + rows + noteRows))
    }

    // MARK: Geometry (document coordinates)

    private func tableRow(_ display: Int) -> Int { order.map { Int($0[display]) } ?? display + 1 }

    private func rowTop(_ display: Int) -> CGFloat { rowHeight * CGFloat(display + 1) }

    private func columnRect(_ column: Int) -> (x: CGFloat, width: CGFloat) { (gutter + lefts[column], widths[column]) }

    private func cellRect(_ cell: Cell) -> NSRect {
        let column = columnRect(cell.column)
        return NSRect(x: column.x, y: rowTop(cell.row), width: column.width, height: rowHeight)
    }

    private func column(atDocumentX x: CGFloat) -> Int? {
        let inner = x - gutter
        guard inner >= 0, inner < lefts.last ?? 0 else { return nil }
        var low = 0
        var high = widths.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lefts[mid] <= inner { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// A column's right edge under the pointer, in the header.
    private func edge(atDocumentX x: CGFloat) -> Int? {
        let hit = Size.Grid.edgeHit / 2
        guard let column = column(atDocumentX: x - hit) ?? column(atDocumentX: x + hit) else { return nil }
        for candidate in [column, column - 1] where candidate >= 0 {
            if abs(gutter + lefts[candidate + 1] - x) <= hit { return candidate }
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let table, rowHeight > 0 else { return }
        let offset = offset
        let size = bounds.size
        NSColor(Theme.background).setFill()
        bounds.fill()

        let firstRow = max(0, Int((offset.y) / rowHeight) - 1)
        let lastRow = min(rows + noteRows - 1, Int((offset.y + size.height) / rowHeight))
        let firstColumn = column(atDocumentX: max(offset.x + gutter, gutter)) ?? 0
        let lastColumn = column(atDocumentX: offset.x + size.width) ?? (columns - 1)
        let selection = selectedRange

        // Body: hover, cells, selection, rules.
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: gutter, y: rowHeight, width: size.width - gutter, height: size.height - rowHeight).clip()
        if let hoverRow, hoverRow < rows {
            NSColor(Theme.Grid.hover).setFill()
            NSRect(x: gutter, y: rowTop(hoverRow) - offset.y, width: size.width, height: rowHeight).fill()
        }
        if let selection {
            let rect = selectionRect(selection).offsetBy(dx: -offset.x, dy: -offset.y)
            NSColor(Theme.Grid.selection).setFill()
            rect.fill()
        }
        if firstRow <= lastRow {
            for display in firstRow...lastRow where display < rows {
                let row = tableRow(display)
                let y = rowTop(display) - offset.y
                guard firstColumn <= lastColumn else { continue }
                for column in firstColumn...lastColumn {
                    let text = table.text(row: row, column: column)
                    guard !text.isEmpty else { continue }
                    let (x, width) = columnRect(column)
                    draw(text, in: NSRect(x: x - offset.x, y: y, width: width, height: rowHeight),
                         attributes: table.numeric[column] ? numberAttributes : textAttributes)
                }
            }
        }
        rules(firstRow: firstRow, lastRow: min(lastRow, rows - 1), firstColumn: firstColumn, lastColumn: lastColumn, offset: offset)
        if let selection {
            let rect = selectionRect(selection).offsetBy(dx: -offset.x, dy: -offset.y)
            NSColor(Theme.Grid.selectionLine).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: Stroke.hairline / 2, dy: Stroke.hairline / 2))
            outline.lineWidth = Stroke.hairline
            outline.stroke()
        }
        if table.capped {
            let y = rowTop(rows) - offset.y
            draw("Showing the first \(Self.count(Limit.csvRows)) rows",
                 in: NSRect(x: gutter, y: y, width: size.width - gutter, height: rowHeight), attributes: noteAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()

        // The row-number gutter, sticky at the left.
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: rowHeight, width: gutter, height: size.height - rowHeight).clip()
        NSColor(Theme.background).setFill()
        NSRect(x: 0, y: rowHeight, width: gutter, height: size.height).fill()
        if firstRow <= lastRow {
            for display in firstRow...lastRow where display < rows {
                draw(String(tableRow(display)), in: NSRect(x: 0, y: rowTop(display) - offset.y, width: gutter, height: rowHeight),
                     attributes: gutterAttributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(Theme.Grid.rule).setFill()
        NSRect(x: gutter - Stroke.hairline, y: rowHeight, width: Stroke.hairline, height: size.height).fill()

        // The header, sticky at the top.
        NSColor(Theme.Grid.header).setFill()
        NSRect(x: 0, y: 0, width: size.width, height: rowHeight).fill()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: gutter, y: 0, width: size.width - gutter, height: rowHeight).clip()
        if firstColumn <= lastColumn {
            for column in firstColumn...lastColumn {
                let (x, width) = columnRect(column)
                header(column, in: NSRect(x: x - offset.x, y: 0, width: width, height: rowHeight))
                NSColor(Theme.Grid.rule).setFill()
                NSRect(x: x - offset.x + width - Stroke.hairline, y: 0, width: Stroke.hairline, height: rowHeight).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(Theme.Grid.headerRule).setFill()
        NSRect(x: 0, y: rowHeight - Stroke.hairline, width: size.width, height: Stroke.hairline).fill()
    }

    private func rules(firstRow: Int, lastRow: Int, firstColumn: Int, lastColumn: Int, offset: NSPoint) {
        guard firstRow <= lastRow else { return }
        NSColor(Theme.Grid.rule).setFill()
        let right = min(bounds.width, gutter + (lefts.last ?? 0) - offset.x)
        for display in firstRow...lastRow {
            let y = rowTop(display + 1) - offset.y - Stroke.hairline
            NSRect(x: gutter, y: y, width: right - gutter, height: Stroke.hairline).fill()
        }
        let bottom = min(bounds.height, rowTop(rows) - offset.y)
        guard firstColumn <= lastColumn else { return }
        for column in firstColumn...lastColumn {
            let (x, width) = columnRect(column)
            NSRect(x: x - offset.x + width - Stroke.hairline, y: rowHeight, width: Stroke.hairline, height: bottom - rowHeight).fill()
        }
    }

    private func header(_ column: Int, in rect: NSRect) {
        guard let table else { return }
        let padding = Size.Grid.cellPadding * zoom
        let name = table.text(row: 0, column: column) as NSString
        let sortRoom = sort?.column == column ? (Size.Grid.sortGlyph + Size.Grid.sortGap) * zoom : 0
        let textWidth = min(name.size(withAttributes: headerAttributes).width, rect.width - 2 * padding - sortRoom)
        draw(name as String, in: NSRect(x: rect.minX, y: rect.minY, width: textWidth + 2 * padding, height: rect.height),
             attributes: headerAttributes)
        guard let sort, sort.column == column else { return }
        let size = Size.Grid.sortGlyph * zoom
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(Theme.Grid.sort)]))
        guard let glyph = NSImage(systemSymbolName: sort.ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let x = rect.minX + padding + textWidth + Size.Grid.sortGap * zoom
        glyph.draw(in: NSRect(x: x, y: rect.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
    }

    private func draw(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let padding = Size.Grid.cellPadding * zoom
        let font = attributes[.font] as? NSFont ?? self.font
        let line = ceil(font.ascender - font.descender + font.leading)
        let inner = NSRect(
            x: rect.minX + padding, y: rect.minY + (rect.height - line) / 2,
            width: max(0, rect.width - 2 * padding), height: line)
        // Line breaks inside a quoted cell show as spaces.
        let flat = text.contains(where: \.isNewline) ? text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") : text
        (flat as NSString).draw(with: inner, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    // MARK: Selection

    private var selectedRange: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        guard let anchor, let head else { return nil }
        return (min(anchor.row, head.row)...max(anchor.row, head.row), min(anchor.column, head.column)...max(anchor.column, head.column))
    }

    private func selectionRect(_ range: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)) -> NSRect {
        cellRect(Cell(row: range.rows.lowerBound, column: range.columns.lowerBound))
            .union(cellRect(Cell(row: range.rows.upperBound, column: range.columns.upperBound)))
    }

    private func clampSelection() {
        guard rows > 0, columns > 0 else {
            anchor = nil
            head = nil
            return
        }
        func clamp(_ cell: Cell?) -> Cell? {
            cell.map { Cell(row: min($0.row, rows - 1), column: min($0.column, columns - 1)) }
        }
        anchor = clamp(anchor)
        head = clamp(head)
    }

    private func select(_ cell: Cell, extend: Bool) {
        if !extend || anchor == nil { anchor = cell }
        head = cell
        scroller?.reveal(cellRect(cell), inset: NSSize(width: gutter, height: rowHeight))
        needsDisplay = true
        reportFacts()
    }

    private func reportFacts() {
        guard let table else { return }
        var facts = [
            "\(Self.count(table.rows)) \(table.rows == 1 ? "row" : "rows")",
            "\(Self.count(table.columns)) \(table.columns == 1 ? "column" : "columns")",
            table.delimiter.name,
        ]
        if let head { facts.insert("Row \(Self.count(tableRow(head.row))), Col \(head.column + 1)", at: 0) }
        onFacts(facts)
    }

    static func count(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }

    @objc func copy(_ sender: Any?) {
        guard let table, let range = selectedRange else { return }
        let text = range.rows.map { display in
            range.columns.map { table.text(row: tableRow(display), column: $0) }.joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard rows > 0, columns > 0 else { return }
        anchor = Cell(row: 0, column: 0)
        head = Cell(row: rows - 1, column: columns - 1)
        needsDisplay = true
        reportFacts()
    }

    // MARK: Sorting

    /// Ascending, then descending, then the file's order.
    private func cycleSort(_ column: Int) {
        if let sort, sort.column == column {
            if sort.ascending {
                startSort(column, ascending: false)
            } else {
                self.sort = nil
                order = nil
                sorting += 1
                needsDisplay = true
            }
        } else {
            startSort(column, ascending: true)
        }
    }

    private func startSort(_ column: Int, ascending: Bool) {
        guard let table else { return }
        sort = (column, ascending)
        sorting += 1
        let ticket = sorting
        needsDisplay = true
        Task { @MainActor [weak self] in
            let order = await Task.detached(priority: .userInitiated) { table.order(column: column, ascending: ascending) }.value
            guard let self, self.sorting == ticket, self.table === table else { return }
            self.order = order
            self.needsDisplay = true
            self.reportFacts()
        }
    }

    // MARK: Mouse and keys

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        let doc = NSPoint(x: p.x + offset.x, y: p.y + offset.y)
        if p.y < rowHeight, p.x >= gutter, edge(atDocumentX: doc.x) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
        let row = p.y >= rowHeight ? Int((doc.y - rowHeight) / rowHeight) : nil
        let hovered = row.flatMap { $0 < rows ? $0 : nil }
        if hovered != hoverRow {
            hoverRow = hovered
            needsDisplay = true
        }
        // The full text of a cut-off cell.
        var tip: String?
        if let hovered, p.x >= gutter, let column = column(atDocumentX: doc.x), let table {
            let text = table.text(row: tableRow(hovered), column: column)
            let width = (text as NSString).size(withAttributes: textAttributes).width + 2 * Size.Grid.cellPadding * zoom
            if width > widths[column] { tip = text }
        }
        if toolTip != tip { toolTip = tip }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverRow != nil {
            hoverRow = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        let doc = NSPoint(x: p.x + offset.x, y: p.y + offset.y)
        if p.y < rowHeight {
            guard p.x >= gutter else { return }
            if let edge = edge(atDocumentX: doc.x) {
                if event.clickCount == 2 {
                    fit(edge)
                } else {
                    resizing = (edge, doc.x, widths[edge])
                }
            } else if let column = column(atDocumentX: doc.x) {
                cycleSort(column)
            }
            return
        }
        guard p.x >= gutter, let column = column(atDocumentX: doc.x) else { return }
        let row = Int((doc.y - rowHeight) / rowHeight)
        guard row < rows else { return }
        select(Cell(row: row, column: column), extend: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        let doc = NSPoint(x: p.x + offset.x, y: p.y + offset.y)
        if let resizing {
            widths[resizing.column] = max(Size.Grid.minColumn * zoom, resizing.width + doc.x - resizing.startX)
            layoutDocument()
            needsDisplay = true
            return
        }
        guard anchor != nil, rows > 0 else { return }
        let column = column(atDocumentX: max(doc.x, gutter)) ?? (columns - 1)
        let row = min(max(Int((doc.y - rowHeight) / rowHeight), 0), rows - 1)
        select(Cell(row: row, column: column), extend: true)
    }

    override func mouseUp(with event: NSEvent) { resizing = nil }

    /// Double-clicking a column's edge fits it to everything in it (up to the max).
    private func fit(_ column: Int) {
        guard let table else { return }
        var width = (table.text(row: 0, column: column) as NSString).size(withAttributes: headerAttributes).width
            + (Size.Grid.sortGlyph + Size.Grid.sortGap) * zoom
        for row in stride(from: 1, through: min(table.rows, 5_000), by: 1) {
            let text = table.text(row: row, column: column)
            if !text.isEmpty { width = max(width, (text as NSString).size(withAttributes: textAttributes).width) }
        }
        widths[column] = clampWidth(width + 2 * Size.Grid.cellPadding * zoom)
        layoutDocument()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let extend = event.modifierFlags.contains(.shift)
        let current = head ?? Cell(row: 0, column: 0)
        let page = max(1, Int(bounds.height / max(rowHeight, 1)) - 2)
        var next = current
        switch event.keyCode {
        case 126: next.row -= 1
        case 125: next.row += 1
        case 123: next.column -= 1
        case 124: next.column += 1
        case 116: next.row -= page
        case 121: next.row += page
        case 115: next.row = 0
        case 119: next.row = rows - 1
        case 53:
            anchor = nil
            head = nil
            needsDisplay = true
            reportFacts()
            return
        default:
            super.keyDown(with: event)
            return
        }
        guard rows > 0, columns > 0 else { return }
        next.row = min(max(next.row, 0), rows - 1)
        next.column = min(max(next.column, 0), columns - 1)
        select(next, extend: extend)
    }
}
