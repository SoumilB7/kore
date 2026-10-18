import AppKit
import SwiftUI

/// JSON and JSONL files as a collapsible tree (look §2): the explorer tree's geometry, the
/// editor's colours, two levels open, the selected node's path in the status row, Copy Value /
/// Copy Path, and ⌘F to filter by key or value. Only the visible rows are drawn.
enum JSONRenderer: FileRenderer {
    static let id = "json"
    static let hasRaw = true

    static func matches(_ file: FileInfo) -> Bool {
        ["json", "jsonl", "ndjson", "geojson", "webmanifest"].contains(file.ext) || file.url.lastPathComponent == ".babelrc"
    }

    static func makeView(_ file: FileInfo, context: RendererContext) -> AnyView {
        AnyView(JSONTreeView(file: file, context: context))
    }
}

private struct JSONTreeView: View {
    let file: FileInfo
    let context: RendererContext
    @StateObject private var loaded = Local<Loaded<JSONIndex>>(.loading)
    @StateObject private var filter = Local<String?>(nil)

    var body: some View {
        Group {
            switch loaded.value {
            case .loading: RendererLoading()
            case .tooLarge: RendererState.tooLarge(file, context: context)
            case .failed(let reason): RendererState.cantRender(file, reason: reason, context: context, hasRaw: true)
            case .ready(let index):
                TreeRepresentable(
                    index: index, zoom: context.zoom, filter: filter.value ?? "", place: context.memory.state { CanvasPlace() },
                    setFacts: context.setFacts,
                    openFilter: { if filter.value == nil { filter.value = "" } })
                .overlay(alignment: .topTrailing) {
                    if filter.value != nil {
                        TreeFilterField(query: $filter.value) { filter.value = nil }
                            .padding(.top, Space.md)
                            .padding(.horizontal, Size.Editor.findMargin)
                    }
                }
            }
        }
        .task(id: context.reloadToken) { await load() }
    }

    private func load() async {
        guard file.size <= Limit.jsonBytes else {
            loaded.value = .tooLarge
            return
        }
        let url = file.url
        let lines = ["jsonl", "ndjson"].contains(file.ext)
        do {
            let index = try await Task.detached(priority: .userInitiated) {
                try JSONIndex.parse(Data(contentsOf: url, options: .alwaysMapped), lines: lines)
            }.value
            loaded.value = .ready(index)
            RenderTiming.ready(JSONRenderer.id)
        } catch let failure as JSONIndex.Failure {
            // Opens the source with the caret on the bad line (look §2).
            context.failed("This JSON couldn't be parsed: line \(failure.line), \(failure.message.lowercasedFirst). Showing the source.", failure.line)
        } catch {
            loaded.value = .failed(error.localizedDescription)
        }
    }
}

extension String {
    fileprivate var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// ⌘F over the tree: filters by key or value; Esc closes it.
private struct TreeFilterField: View {
    @Binding var query: String?
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "line.3.horizontal.decrease").font(Chrome.label).foregroundStyle(Theme.secondary)
            TextField("Filter keys and values", text: Binding(get: { query ?? "" }, set: { query = $0 }))
                .textFieldStyle(.plain)
                .font(Chrome.body)
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onExitCommand(perform: close)
            IconButton(symbol: "xmark", kind: .small, font: Chrome.label, help: "Close (Esc)", action: close)
        }
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.xs)
        .frame(width: Size.Editor.find)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
        .onAppear { focused = true }
    }
}

private struct TreeRepresentable: NSViewRepresentable {
    let index: JSONIndex
    let zoom: CGFloat
    let filter: String
    let place: CanvasPlace
    let setFacts: ([String]) -> Void
    let openFilter: () -> Void

    func makeCoordinator() -> CanvasPlace { place }

    func makeNSView(context: Context) -> CanvasScrollView {
        let tree = TreeCanvas()
        let scroll = CanvasScrollView(canvas: tree)
        scroll.hasHorizontalScroller = false
        update(tree)
        if let kept = place.tree { tree.reopen(kept) }
        scroll.restore = place.origin
        return scroll
    }

    static func dismantleNSView(_ scroll: CanvasScrollView, coordinator: CanvasPlace) {
        coordinator.origin = scroll.visible.origin
        coordinator.tree = (scroll.canvas as? TreeCanvas)?.opened
    }

    func updateNSView(_ scroll: CanvasScrollView, context: Context) {
        if let tree = scroll.canvas as? TreeCanvas { update(tree) }
    }

    private func update(_ tree: TreeCanvas) {
        tree.onFacts = setFacts
        tree.onFind = openFilter
        tree.set(index: index, zoom: zoom)
        tree.setFilter(filter)
    }
}

// MARK: - The tree

private final class TreeCanvas: CanvasView {
    var onFacts: ([String]) -> Void = { _ in }
    var onFind: () -> Void = {}
    private var index: JSONIndex?
    private var zoom: CGFloat = 0

    private struct Row {
        let node: Int32
        let depth: Int32
        /// An array element's position, else -1.
        let ordinal: Int32
    }

    private var rows: [Row] = []
    private var expanded = Set<Int>()
    private var selectedNode: Int?
    private var hoverRow: Int?
    private var query = ""
    /// While filtering: the matches, and the matches plus their ancestors (the rows shown).
    private var matches = Set<Int>()
    private var shown: Set<Int>?
    private var filtering = 0

    private var rowHeight: CGFloat = 0
    private var gutter: CGFloat = 0
    private var font = NSFont.systemFont(ofSize: 12)
    private var colors: [JSONIndex.Kind: NSColor] = [:]
    private var plain = NSColor.white
    private var punctuation = NSColor.white
    private var hint = NSColor.white
    private var lineNumbers: [NSAttributedString.Key: Any] = [:]

    func set(index: JSONIndex, zoom: CGFloat) {
        let indexChanged = index !== self.index
        let zoomChanged = zoom != self.zoom
        guard indexChanged || zoomChanged else { return }
        let previous = self.index
        self.index = index
        self.zoom = zoom
        if zoomChanged { makeStyle() }
        if indexChanged {
            // A reload of the same shape keeps what was open and selected.
            if previous?.nodes.count != index.nodes.count {
                expanded = defaultExpanded(index)
                selectedNode = nil
            }
            if !query.isEmpty { runFilter() }
        }
        measureGutter()
        rebuild()
    }

    func setFilter(_ text: String) {
        guard text != query else { return }
        query = text
        runFilter()
    }

    private func runFilter() {
        filtering += 1
        let ticket = filtering
        guard let index, !query.isEmpty else {
            matches = []
            shown = nil
            rebuild()
            return
        }
        let query = query
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> (Set<Int>, Set<Int>) in
                let matches = index.matches(query)
                var shown = matches
                for match in matches {
                    var parent = index.nodes[match].parent
                    while parent != .max, shown.insert(Int(parent)).inserted {
                        parent = index.nodes[Int(parent)].parent
                    }
                }
                return (matches, shown)
            }.value
            guard let self, self.filtering == ticket else { return }
            self.matches = found.0
            self.shown = found.1
            self.rebuild()
        }
    }

    private func makeStyle() {
        rowHeight = (Size.JSONTree.row * zoom).rounded()
        font = TextStyle.editorFont
        plain = NSColor(Theme.Syntax.plain)
        punctuation = NSColor(Theme.Syntax.punctuation)
        hint = NSColor(Theme.tertiary)
        let literal = NSColor(Theme.Syntax.string)
        let keyword = NSColor(Theme.Syntax.keyword)
        colors = [.string: literal, .number: literal, .bool: keyword, .null: keyword, .object: punctuation, .array: punctuation]
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        lineNumbers = [.font: font, .foregroundColor: hint, .paragraphStyle: right]
    }

    private func measureGutter() {
        guard let index, let last = index.rootLines.last else {
            gutter = 0
            return
        }
        gutter = ceil((String(last) as NSString).size(withAttributes: lineNumbers).width + 2 * Size.Tree.trailing)
    }

    /// The roots open, and their children too while that stays a screenful or so.
    /// The open and selected nodes, to open again in a tree made for the same file.
    var opened: (nodes: Int, expanded: Set<Int>, selected: Int?)? {
        index.map { ($0.nodes.count, expanded, selectedNode) }
    }

    func reopen(_ kept: (nodes: Int, expanded: Set<Int>, selected: Int?)) {
        guard let index, index.nodes.count == kept.nodes else { return }
        expanded = kept.expanded
        selectedNode = kept.selected
        rebuild()
    }

    private func defaultExpanded(_ index: JSONIndex) -> Set<Int> {
        var open = Set<Int>()
        let roots = index.roots.map(Int.init)
        if roots.count <= 200 { open.formUnion(roots.filter { index.nodes[$0].isContainer }) }
        var budget = 5_000
        outer: for root in roots where open.contains(root) {
            for child in index.children(root) where index.nodes[child].isContainer {
                budget -= Int(index.nodes[child].count)
                if budget < 0 { break outer }
                open.insert(child)
            }
        }
        return open
    }

    private func rebuild() {
        guard let index else { return }
        var rows: [Row] = []
        let shown = self.shown
        // Depth-first over what's open, iteratively.
        var stack: [(node: Int, depth: Int32, ordinal: Int32)] = index.roots.reversed().map { (Int($0), 0, -1) }
        while let (node, depth, ordinal) = stack.popLast() {
            if let shown, !shown.contains(node) { continue }
            rows.append(Row(node: Int32(node), depth: depth, ordinal: ordinal))
            let item = index.nodes[node]
            guard item.isContainer, shown != nil || expanded.contains(node) else { continue }
            let children = index.children(node)
            let isArray = item.kind == .array
            for (position, child) in children.enumerated().reversed() {
                stack.append((child, depth + 1, isArray ? Int32(position) : -1))
            }
        }
        self.rows = rows
        scroller?.documentSize = NSSize(width: 0, height: rowHeight * CGFloat(rows.count))
        needsDisplay = true
        reportFacts()
    }

    // MARK: Geometry

    private var selectedRow: Int? {
        guard let selectedNode else { return nil }
        return rows.firstIndex { Int($0.node) == selectedNode }
    }

    private func rowAt(_ point: NSPoint) -> Int? {
        let row = Int(point.y / rowHeight)
        return row >= 0 && row < rows.count ? row : nil
    }

    private func indentX(_ depth: Int32) -> CGFloat {
        gutter + Size.Tree.leading + CGFloat(depth) * Size.Tree.indent * zoom
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let index, rowHeight > 0, !rows.isEmpty else { return }
        let first = max(0, Int(dirtyRect.minY / rowHeight))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        let selected = selectedRow
        let focused = window?.firstResponder === self
        let activeParent = selectedNode.map { index.nodes[$0].parent }
        let box = Size.Tree.chevronBox * zoom

        for row in first...last {
            let item = rows[row]
            let node = index.nodes[Int(item.node)]
            let y = CGFloat(row) * rowHeight
            let fill = NSRect(x: gutter + Size.Tree.rowInset, y: y, width: bounds.width - gutter - 2 * Size.Tree.rowInset, height: rowHeight)
            if row == selected {
                NSColor(focused ? Theme.Tree.selectedFocused : Theme.Tree.selected).setFill()
                NSBezierPath(roundedRect: fill, xRadius: Radius.chip, yRadius: Radius.chip).fill()
            } else if row == hoverRow {
                NSColor(Theme.Tree.hover).setFill()
                NSBezierPath(roundedRect: fill, xRadius: Radius.chip, yRadius: Radius.chip).fill()
            }
            // Indent guides at each ancestor's chevron; the selected row's parent's is brighter.
            if item.depth > 0 {
                // The ancestor at each depth, walking up from the parent.
                var ancestor = node.parent
                for depth in stride(from: item.depth - 1, through: 0, by: -1) {
                    let x = indentX(depth) + box / 2
                    NSColor(ancestor == activeParent ? Theme.Tree.guideActive : Theme.Tree.guide).setFill()
                    NSRect(x: x, y: y, width: Stroke.hairline, height: rowHeight).fill()
                    if ancestor != .max { ancestor = index.nodes[Int(ancestor)].parent }
                }
            }
            let x = indentX(item.depth)
            if node.isContainer {
                chevron(open: shown != nil || expanded.contains(Int(item.node)), in: NSRect(x: x, y: y, width: box, height: rowHeight))
            }
            let text = label(item, node, index)
            let textX = x + box
            let line = ceil(font.ascender - font.descender + font.leading)
            let rect = NSRect(x: textX, y: y + (rowHeight - line) / 2, width: max(0, bounds.width - textX - Size.Tree.trailing), height: line)
            if matches.contains(Int(item.node)) {
                let width = min(text.size().width, rect.width)
                NSColor(Theme.JSONTree.match).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX - Space.xxs, y: y + Space.xxs, width: width + Space.xs, height: rowHeight - Space.xs),
                             xRadius: Radius.glyph, yRadius: Radius.glyph).fill()
            }
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if !index.rootLines.isEmpty, item.depth == 0, let root = index.roots.firstIndex(of: UInt32(item.node)) {
                (String(index.rootLines[root]) as NSString).draw(
                    with: NSRect(x: 0, y: rect.minY, width: gutter - Size.Tree.trailing, height: line),
                    options: [.usesLineFragmentOrigin], attributes: lineNumbers)
            }
        }
    }

    private func chevron(open: Bool, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9 * zoom, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(Theme.secondary)]))
        guard let glyph = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        glyph.draw(in: NSRect(
            x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2,
            width: glyph.size.width, height: glyph.size.height))
    }

    /// `"users": [] 3 items`, `0: {} 5 keys`, `"name": "Ada"`, `true`.
    private func label(_ row: Row, _ node: JSONIndex.Node, _ index: JSONIndex) -> NSAttributedString {
        let text = NSMutableAttributedString()
        func add(_ string: String, _ color: NSColor) {
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        if node.hasKey {
            add("\"\(index.key(node))\"", plain)
            add(": ", punctuation)
        } else if row.ordinal >= 0 {
            add(String(row.ordinal), plain)
            add(": ", punctuation)
        }
        switch node.kind {
        case .object:
            add("{}", punctuation)
            add(" \(Self.count(Int(node.count), "key", "keys"))", hint)
        case .array:
            add("[]", punctuation)
            add(" \(Self.count(Int(node.count), "item", "items"))", hint)
        case .string:
            add("\"\(index.value(node))\"", colors[.string] ?? plain)
        default:
            add(index.value(node), colors[node.kind] ?? plain)
        }
        return text
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted(.number.grouping(.automatic))) \(n == 1 ? one : many)"
    }

    // MARK: Paths and facts

    /// `$.users[0].name`; a key that isn't an identifier is bracketed.
    private func path(_ node: Int) -> String {
        guard let index else { return "$" }
        var parts: [String] = []
        var current = node
        while true {
            let item = index.nodes[current]
            guard item.parent != .max else { break }
            let parent = Int(item.parent)
            if index.nodes[parent].kind == .array {
                let position = index.children(parent).firstIndex(of: current) ?? 0
                parts.append("[\(position)]")
            } else {
                let key = index.key(item)
                let plain = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" } && !(key.first?.isNumber ?? true)
                parts.append(plain ? ".\(key)" : "[\"\(key.replacingOccurrences(of: "\"", with: "\\\""))\"]")
            }
            current = parent
        }
        return "$" + parts.reversed().joined()
    }

    private func root(of node: Int) -> Int {
        guard let index else { return node }
        var current = node
        while index.nodes[current].parent != .max { current = Int(index.nodes[current].parent) }
        return current
    }

    private func reportFacts() {
        guard let index else { return }
        var facts: [String] = []
        if let selectedNode {
            if !index.rootLines.isEmpty, let line = index.roots.firstIndex(of: UInt32(root(of: selectedNode))) {
                facts.append("Line \(index.rootLines[line])")
            }
            facts.append(path(selectedNode))
        }
        if shown != nil { facts.append(Self.count(matches.count, "match", "matches")) }
        if !index.rootLines.isEmpty {
            facts.append(Self.count(index.roots.count, "line", "lines"))
        } else {
            facts.append(Self.count(index.nodes.count, "value", "values"))
        }
        facts.append(index.rootLines.isEmpty ? "JSON" : "JSON Lines")
        onFacts(facts)
    }

    // MARK: Actions

    private func toggle(_ row: Int, all: Bool = false) {
        guard let index, shown == nil else { return }
        let node = Int(rows[row].node)
        guard index.nodes[node].isContainer else { return }
        if expanded.contains(node) {
            expanded.remove(node)
            if all { for inner in node..<Int(index.nodes[node].end) { expanded.remove(inner) } }
        } else {
            expanded.insert(node)
            // ⌥: everything under it too (VS Code's tree), within reason.
            if all, index.nodes[node].end - UInt32(node) < 50_000 {
                for inner in node..<Int(index.nodes[node].end) where index.nodes[inner].isContainer { expanded.insert(inner) }
            }
        }
        rebuild()
    }

    private func select(_ row: Int) {
        selectedNode = Int(rows[row].node)
        scroller?.reveal(NSRect(x: 0, y: CGFloat(row) * rowHeight, width: 1, height: rowHeight), inset: .zero)
        needsDisplay = true
        reportFacts()
    }

    private func copyValue(_ node: Int) {
        guard let index else { return }
        let item = index.nodes[node]
        let text = item.kind == .string ? index.decodedString(item) : index.source(item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyPath(_ node: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path(node), forType: .string)
    }

    @objc func copy(_ sender: Any?) {
        if let selectedNode { copyValue(selectedNode) }
    }

    @objc private func copyValueItem(_ item: NSMenuItem) { copyValue(item.tag) }
    @objc private func copyPathItem(_ item: NSMenuItem) { copyPath(item.tag) }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row = rowAt(point(event)) else { return nil }
        select(row)
        let node = Int(rows[row].node)
        let menu = NSMenu()
        for (title, action) in [("Copy Value", #selector(copyValueItem(_:))), ("Copy Path", #selector(copyPathItem(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = node
            menu.addItem(item)
        }
        return menu
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

    override func mouseMoved(with event: NSEvent) {
        let row = rowAt(point(event))
        if row != hoverRow {
            if let hoverRow { setNeedsDisplay(rowRect(hoverRow)) }
            hoverRow = row
            if let row { setNeedsDisplay(rowRect(row)) }
        }
        // The full value of a cut-off row.
        var tip: String?
        if let row, let index {
            let node = index.nodes[Int(rows[row].node)]
            if !node.isContainer, node.valueLength > 60 { tip = index.value(node, limit: 2_000) }
        }
        if toolTip != tip { toolTip = tip }
    }

    override func mouseExited(with event: NSEvent) {
        if let hoverRow { setNeedsDisplay(rowRect(hoverRow)) }
        hoverRow = nil
    }

    private func rowRect(_ row: Int) -> NSRect { NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        guard let row = rowAt(p) else { return }
        let x = indentX(rows[row].depth)
        let onChevron = p.x >= x && p.x < x + Size.Tree.chevronBox * zoom
        select(row)
        if onChevron || event.clickCount == 2 { toggle(row, all: event.modifierFlags.contains(.option)) }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" {
            onFind()
            return
        }
        guard let index, !rows.isEmpty else { return super.keyDown(with: event) }
        let current = selectedRow ?? -1
        let page = max(1, Int(visible.height / max(rowHeight, 1)) - 2)
        switch event.keyCode {
        case 126: select(max(current - 1, 0))
        case 125: select(min(current + 1, rows.count - 1))
        case 116: select(max(current - page, 0))
        case 121: select(min(current + page, rows.count - 1))
        case 115: select(0)
        case 119: select(rows.count - 1)
        case 124:
            // Right: open, or step into the first child.
            guard current >= 0 else { return select(0) }
            let node = Int(rows[current].node)
            if index.nodes[node].isContainer, !expanded.contains(node), shown == nil {
                toggle(current)
            } else if current + 1 < rows.count, rows[current + 1].depth > rows[current].depth {
                select(current + 1)
            }
        case 123:
            // Left: close, or step out to the parent.
            guard current >= 0 else { return }
            let node = Int(rows[current].node)
            if index.nodes[node].isContainer, expanded.contains(node), shown == nil {
                toggle(current)
            } else if let parent = rows[..<current].lastIndex(where: { $0.depth < rows[current].depth }) {
                select(parent)
            }
        case 36, 76, 49:
            if current >= 0 { toggle(current) }
        default:
            super.keyDown(with: event)
        }
    }
}
