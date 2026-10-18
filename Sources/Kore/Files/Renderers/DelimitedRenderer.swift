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
        grid.installParts(in: scroll)
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

/// The grid's cells, as the scroll view's document (document coordinates throughout). Row i's
/// top is `rowHeight * (i + 1)`: the first row's height is under the floating header; the
/// gutter's width is under the floating row numbers.
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
    fileprivate private(set) var gutter: CGFloat = 0
    fileprivate private(set) var rowHeight: CGFloat = 0

    private struct Cell: Equatable {
        var row: Int
        var column: Int
    }

    private var anchor: Cell?
    private var head: Cell?
    private var hoverRow: Int?
    private var resizing: (column: Int, startX: CGFloat, width: CGFloat)?

    /// The rules between rows and columns, as plain layers over the visible cells: lines drawn
    /// into the cells would make them keep a full bitmap.
    private let rules = GridRules()
    private let header = GridPart(.header)
    private let rowNumbers = GridPart(.rowNumbers)
    private let corner = GridPart(.corner)

    // Drawing state, made once per zoom.
    private var font = NSFont.systemFont(ofSize: 12)
    private var textAttributes: [NSAttributedString.Key: Any] = [:]
    private var numberAttributes: [NSAttributedString.Key: Any] = [:]
    private var headerAttributes: [NSAttributedString.Key: Any] = [:]
    private var gutterAttributes: [NSAttributedString.Key: Any] = [:]
    private var noteAttributes: [NSAttributedString.Key: Any] = [:]

    private var rows: Int { table?.rows ?? 0 }
    private var columns: Int { table?.columns ?? 0 }
    /// The note row under the last row when the file was cut short.
    private var noteRows: Int { table?.capped == true ? 1 : 0 }
    private var contentWidth: CGFloat { gutter + (lefts.last ?? 0) }

    /// The header, row numbers and corner sit over the scrolled cells, the size of what's
    /// visible, and redraw as it scrolls: strips that small cost little to keep or redraw.
    func installParts(in scroll: CanvasScrollView) {
        scroll.addSubview(rules, positioned: .above, relativeTo: scroll.contentView)
        for part in [rowNumbers, header, corner] {
            part.grid = self
            scroll.addSubview(part, positioned: .above, relativeTo: rules)
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    @objc private func scrolled() {
        guard let origin = scroller?.visible.origin else { return }
        if origin.x != lastOrigin.x { header.needsDisplay = true }
        if origin.y != lastOrigin.y { rowNumbers.needsDisplay = true }
        lastOrigin = origin
        placeRules()
    }

    /// One layer a visible rule, placed for the current scroll.
    private func placeRules() {
        guard let scroller, rowHeight > 0 else { return }
        let visible = scroller.visible
        var lines: [NSRect] = []
        let bottom = min(rowTop(rows), visible.maxY) - visible.minY
        if let range = rows(in: visible) {
            for display in range where display < rows {
                let y = rowTop(display + 1) - Stroke.hairline - visible.minY
                lines.append(NSRect(x: gutter, y: y, width: max(0, min(contentWidth, visible.maxX) - visible.minX - gutter), height: Stroke.hairline))
            }
        }
        if let range = columns(in: visible) {
            for column in range {
                let (x, width) = columnRect(column)
                let left = x + width - Stroke.hairline - visible.minX
                if left >= gutter { lines.append(NSRect(x: left, y: rowHeight, width: Stroke.hairline, height: max(0, bottom - rowHeight))) }
            }
        }
        rules.show(lines)
    }

    private var lastOrigin = NSPoint.zero

    override func documentResized(_ size: NSSize) { layoutParts() }

    fileprivate func layoutParts() {
        guard let scroller else { return }
        let clip = scroller.contentView.frame
        rules.frame = clip
        header.frame = NSRect(x: clip.minX, y: clip.minY, width: clip.width, height: rowHeight)
        rowNumbers.frame = NSRect(x: clip.minX, y: clip.minY, width: gutter, height: clip.height)
        corner.frame = NSRect(x: clip.minX, y: clip.minY, width: gutter, height: rowHeight)
        for part in [header, rowNumbers, corner] { part.needsDisplay = true }
        placeRules()
    }

    func set(table: DelimitedTable, zoom: CGFloat) {
        let tableChanged = table !== self.table
        let zoomChanged = zoom != self.zoom
        guard tableChanged || zoomChanged else { return }
        let columnsChanged = table.columns != self.table?.columns
        self.table = table
        self.zoom = zoom
        if zoomChanged { makeStyle() }
        if columnsChanged || zoomChanged || widths.isEmpty { measure() }
        if let sort, tableChanged {
            order = nil
            startSort(sort.column, ascending: sort.ascending)
        }
        clampSelection()
        layoutDocument()
        redraw()
        reportFacts()
    }

    private func makeStyle() {
        rowHeight = (Size.Grid.row * zoom).rounded()
        font = TextStyle.gridFont
        let left = NSMutableParagraphStyle()
        left.lineBreakMode = .byTruncatingTail
        let right = NSMutableParagraphStyle()
        right.lineBreakMode = .byTruncatingTail
        right.alignment = .right
        textAttributes = [.font: font, .foregroundColor: NSColor(Theme.text), .paragraphStyle: left]
        numberAttributes = [.font: TextStyle.gridFontDigits, .foregroundColor: NSColor(Theme.text), .paragraphStyle: right]
        headerAttributes = [.font: TextStyle.gridHeaderFont, .foregroundColor: NSColor(Theme.text), .paragraphStyle: left]
        gutterAttributes = [.font: TextStyle.gridFontDigits, .foregroundColor: NSColor(Theme.Grid.rowNumber), .paragraphStyle: right]
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
        scroller?.documentSize = NSSize(width: gutter + x, height: rowHeight * CGFloat(1 + rows + noteRows))
        layoutParts()
    }

    private func redraw() {
        needsDisplay = true
        for part in [header, rowNumbers, corner] { part.needsDisplay = true }
        placeRules()
    }

    // MARK: Geometry

    private func tableRow(_ display: Int) -> Int { order.map { Int($0[display]) } ?? display + 1 }

    private func rowTop(_ display: Int) -> CGFloat { rowHeight * CGFloat(display + 1) }

    private func columnRect(_ column: Int) -> (x: CGFloat, width: CGFloat) { (gutter + lefts[column], widths[column]) }

    private func cellRect(_ cell: Cell) -> NSRect {
        let column = columnRect(cell.column)
        return NSRect(x: column.x, y: rowTop(cell.row), width: column.width, height: rowHeight)
    }

    private func rowRect(_ display: Int) -> NSRect {
        NSRect(x: gutter, y: rowTop(display), width: frame.width - gutter, height: rowHeight)
    }

    private func column(atX x: CGFloat) -> Int? {
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

    private func row(atY y: CGFloat) -> Int? {
        let row = Int((y - rowHeight) / rowHeight)
        return y >= rowHeight && row < rows ? row : nil
    }

    /// A column's right edge under the pointer, in the header.
    fileprivate func edge(atX x: CGFloat) -> Int? {
        let hit = Size.Grid.edgeHit / 2
        guard let column = column(atX: x - hit) ?? column(atX: x + hit) else { return nil }
        for candidate in [column, column - 1] where candidate >= 0 {
            if abs(gutter + lefts[candidate + 1] - x) <= hit { return candidate }
        }
        return nil
    }

    private func rows(in rect: NSRect) -> ClosedRange<Int>? {
        let first = max(0, Int(rect.minY / rowHeight) - 1)
        let last = min(rows + noteRows - 1, Int(rect.maxY / rowHeight))
        return first <= last ? first...last : nil
    }

    private func columns(in rect: NSRect) -> ClosedRange<Int>? {
        guard columns > 0 else { return nil }
        let first = column(atX: max(rect.minX, gutter)) ?? (rect.minX < gutter ? 0 : columns)
        let last = column(atX: rect.maxX) ?? (columns - 1)
        return first <= last ? first...last : nil
    }

    // MARK: Drawing the cells

    override func draw(_ dirty: NSRect) {
        guard let table, rowHeight > 0 else { return }
        let visibleRows = rows(in: dirty)
        let visibleColumns = columns(in: dirty)
        let selection = selectedRange

        if let hoverRow, hoverRow < rows {
            NSColor(Theme.Grid.hover).setFill()
            rowRect(hoverRow).intersection(dirty).fill()
        }
        if let selection {
            NSColor(Theme.Grid.selection).setFill()
            selectionRect(selection).intersection(dirty).fill()
        }
        if let visibleRows, let visibleColumns {
            for display in visibleRows where display < rows {
                let row = tableRow(display)
                let y = rowTop(display)
                for column in visibleColumns {
                    let text = table.text(row: row, column: column)
                    guard !text.isEmpty else { continue }
                    let (x, width) = columnRect(column)
                    draw(text, in: NSRect(x: x, y: y, width: width, height: rowHeight),
                         attributes: table.numeric[column] ? numberAttributes : textAttributes)
                }
            }
        }
        if let selection {
            let rect = selectionRect(selection)
            if rect.intersects(dirty) {
                NSColor(Theme.Grid.selectionLine).setStroke()
                let outline = NSBezierPath(rect: rect.insetBy(dx: Stroke.hairline / 2, dy: Stroke.hairline / 2))
                outline.lineWidth = Stroke.hairline
                outline.stroke()
            }
        }
        if table.capped {
            let visible = self.visible
            draw("Showing the first \(Self.count(Limit.csvRows)) rows",
                 in: NSRect(x: visible.minX + gutter, y: rowTop(rows), width: visible.width - gutter, height: rowHeight),
                 attributes: noteAttributes)
        }
    }

    // MARK: Drawing the floating parts (each in its own coordinates)

    fileprivate func drawHeader(_ dirty: NSRect) {
        NSColor(Theme.Grid.header).setFill()
        dirty.fill()
        if let range = columns(in: dirty) {
            for column in range {
                let (x, width) = columnRect(column)
                header(column, in: NSRect(x: x, y: 0, width: width, height: rowHeight))
                NSColor(Theme.Grid.rule).setFill()
                NSRect(x: x + width - Stroke.hairline, y: 0, width: Stroke.hairline, height: rowHeight).fill()
            }
        }
        NSColor(Theme.Grid.headerRule).setFill()
        NSRect(x: dirty.minX, y: rowHeight - Stroke.hairline, width: dirty.width, height: Stroke.hairline).fill()
    }

    fileprivate func drawRowNumbers(_ dirty: NSRect) {
        NSColor(Theme.background).setFill()
        dirty.fill()
        if let range = rows(in: dirty) {
            for display in range where display < rows {
                draw(String(tableRow(display)), in: NSRect(x: 0, y: rowTop(display), width: gutter, height: rowHeight),
                     attributes: gutterAttributes)
            }
        }
        NSColor(Theme.Grid.rule).setFill()
        NSRect(x: gutter - Stroke.hairline, y: dirty.minY, width: Stroke.hairline, height: dirty.height).fill()
    }

    fileprivate func drawCorner(_ bounds: NSRect) {
        NSColor(Theme.Grid.header).setFill()
        bounds.fill()
        NSColor(Theme.Grid.rule).setFill()
        NSRect(x: bounds.maxX - Stroke.hairline, y: 0, width: Stroke.hairline, height: bounds.height).fill()
        NSColor(Theme.Grid.headerRule).setFill()
        NSRect(x: 0, y: bounds.maxY - Stroke.hairline, width: bounds.width, height: Stroke.hairline).fill()
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
        let configuration = NSImage.SymbolConfiguration(pointSize: Size.Grid.sortGlyph * zoom, weight: .semibold)
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
        let flat = text.contains(where: \.isNewline)
            ? text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") : text
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
        let before = selectedRange.map(selectionRect)
        if !extend || anchor == nil { anchor = cell }
        head = cell
        if let before { setNeedsDisplay(before.insetBy(dx: -Stroke.hairline, dy: -Stroke.hairline)) }
        if let after = selectedRange.map(selectionRect) { setNeedsDisplay(after.insetBy(dx: -Stroke.hairline, dy: -Stroke.hairline)) }
        scroller?.reveal(cellRect(cell), inset: NSSize(width: gutter, height: rowHeight))
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
                redraw()
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
        header.needsDisplay = true
        Task { @MainActor [weak self] in
            let order = await Task.detached(priority: .userInitiated) { table.order(column: column, ascending: ascending) }.value
            guard let self, self.sorting == ticket, self.table === table else { return }
            self.order = order
            self.redraw()
            self.reportFacts()
        }
    }

    // MARK: Mouse and keys

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func setHover(_ row: Int?) {
        guard row != hoverRow else { return }
        if let hoverRow { setNeedsDisplay(rowRect(hoverRow)) }
        hoverRow = row
        if let row { setNeedsDisplay(rowRect(row)) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        let hovered = row(atY: p.y)
        setHover(hovered)
        // The full text of a cut-off cell.
        var tip: String?
        if let hovered, let column = column(atX: p.x), let table {
            let text = table.text(row: tableRow(hovered), column: column)
            let width = (text as NSString).size(withAttributes: textAttributes).width + 2 * Size.Grid.cellPadding * zoom
            if width > widths[column] { tip = text }
        }
        if toolTip != tip { toolTip = tip }
    }

    override func mouseExited(with event: NSEvent) { setHover(nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        guard let column = column(atX: p.x), let row = row(atY: p.y) else { return }
        select(Cell(row: row, column: column), extend: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        guard anchor != nil, rows > 0 else { return }
        let column = column(atX: max(p.x, gutter)) ?? (columns - 1)
        let row = min(max(Int((p.y - rowHeight) / rowHeight), 0), rows - 1)
        select(Cell(row: row, column: column), extend: true)
    }

    /// The header's clicks: sort by a column, or drag (double-click to fit) its edge.
    fileprivate func headerDown(_ event: NSEvent, x: CGFloat) {
        window?.makeFirstResponder(self)
        if let edge = edge(atX: x) {
            if event.clickCount == 2 {
                fit(edge)
            } else {
                resizing = (edge, x, widths[edge])
            }
        } else if let column = column(atX: x) {
            cycleSort(column)
        }
    }

    fileprivate func headerDragged(x: CGFloat) {
        guard let resizing else { return }
        widths[resizing.column] = max(Size.Grid.minColumn * zoom, resizing.width + x - resizing.startX)
        layoutDocument()
        redraw()
    }

    fileprivate func headerUp() { resizing = nil }

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
        redraw()
    }

    override func keyDown(with event: NSEvent) {
        let extend = event.modifierFlags.contains(.shift)
        let current = head ?? Cell(row: 0, column: 0)
        let page = max(1, Int(visible.height / max(rowHeight, 1)) - 2)
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
            if let range = selectedRange { setNeedsDisplay(selectionRect(range).insetBy(dx: -Stroke.hairline, dy: -Stroke.hairline)) }
            anchor = nil
            head = nil
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

/// The grid's header, row numbers or corner: drawn and clicked through the grid.
private final class GridPart: NSView {
    enum Kind { case header, rowNumbers, corner }

    let kind: Kind
    weak var grid: GridCanvas?

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where this part's points sit in the grid's document.
    private var shift: NSPoint {
        guard let origin = grid?.visible.origin else { return .zero }
        switch kind {
        case .header: return NSPoint(x: origin.x, y: 0)
        case .rowNumbers: return NSPoint(x: 0, y: origin.y)
        case .corner: return .zero
        }
    }

    override func draw(_ dirty: NSRect) {
        guard let grid else { return }
        let shift = shift
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: -shift.x, yBy: -shift.y)
        transform.concat()
        let rect = dirty.offsetBy(dx: shift.x, dy: shift.y)
        switch kind {
        case .header: grid.drawHeader(rect)
        case .rowNumbers: grid.drawRowNumbers(rect)
        case .corner: grid.drawCorner(bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard kind == .header else { return }
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func x(_ event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x + shift.x }

    /// Scrolling over a part scrolls the grid.
    override func scrollWheel(with event: NSEvent) { grid?.scroller?.scrollWheel(with: event) }

    override func mouseMoved(with event: NSEvent) {
        guard kind == .header, let grid else { return }
        (grid.edge(atX: x(event)) != nil ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) { if kind == .header { grid?.headerDown(event, x: x(event)) } }
    override func mouseDragged(with event: NSEvent) { if kind == .header { grid?.headerDragged(x: x(event)) } }
    override func mouseUp(with event: NSEvent) { if kind == .header { grid?.headerUp() } }
}

/// Lines as plain filled layers: no bitmap behind them, however much of the grid they cross.
private final class GridRules: NSView {
    private var lines: [CALayer] = []
    private let color = NSColor(Theme.Grid.rule).cgColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        let host = CALayer()
        // Top-left origin, like the grid.
        host.isGeometryFlipped = true
        layer = host
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ rects: [NSRect]) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while lines.count < rects.count {
            let line = CALayer()
            line.backgroundColor = color
            layer.addSublayer(line)
            lines.append(line)
        }
        for (index, line) in lines.enumerated() {
            if index < rects.count {
                line.frame = rects[index]
                line.isHidden = false
            } else {
                line.isHidden = true
            }
        }
        CATransaction.commit()
    }
}
