import AppKit
import HostClient
import SwiftUI

/// A box window's left panel: the box folder's files, as the Files explorer shows a Mac folder's,
/// read over the link. A folder's click opens or closes it; a file's opens it read-only in a
/// preview tab (a double click keeps the tab). ↑ ↓ move, → ← open and close, Space or Return
/// opens. Reload and Collapse all on the header while the pointer is over it. Nothing here
/// creates, renames or deletes; the folder's sync is the title row's Sync button.
struct BoxExplorer: View {
    let workspace: Workspace
    let box: BoxBinding
    let floating: Bool
    @FocusState private var focused: Bool
    @StateObject private var hovered = Local(false)

    private var store: BoxExplorerStore { box.files }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(floating ? Theme.surface : Theme.background)
        .environment(\.listGround, floating ? .surface : .window)
        .onHover { hovered.value = $0 }
        .task { await store.start() }
        // The link back after a drop: what changed meanwhile shows.
        .onChange(of: box.connection.isOnline) { _, online in if online, store.rootLoaded { Task { await store.refresh() } } }
    }

    private var header: some View {
        HStack(spacing: Space.xs) {
            Text(workspace.folder.lastPathComponent)
                .font(Chrome.bodyMedium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(box.label)
            Spacer(minLength: Space.md)
            Group {
                HeaderButton(symbol: "arrow.clockwise", help: "Reload") { Task { await store.refresh() } }
                    .storyID(StoryID.Explorer.refresh, press: { Task { await store.refresh() } })
                HeaderButton(symbol: "rectangle.compress.vertical", help: "Collapse all") { store.collapseAll() }
                    .storyID(StoryID.Explorer.collapse, press: { store.collapseAll() })
            }
            .opacity(hovered.value || focused ? 1 : 0)
        }
        .padding(.horizontal, Layout.Explorer.headerInset)
        .frame(height: Layout.Explorer.header)
    }

    @ViewBuilder private var content: some View {
        if !store.rootLoaded {
            DelayedSpinner().padding(.top, Layout.Explorer.stateTop)
        } else if let why = store.rootError {
            ExplorerState(message: why, color: Theme.secondary, button: "Try Again") { Task { await store.refresh() } }
        } else if store.isEmpty {
            Text("This folder is empty").font(Chrome.label).foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity).padding(.top, Layout.Explorer.stateTop)
        } else {
            tree
        }
    }

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.rows) { row in
                        BoxTreeRow(row: row, relative: store.relative(row.id), selected: store.selection == row.id, focused: focused && store.selection == row.id) { count in
                            focused = true
                            click(row, count: count)
                        }
                        .id(row.id)
                    }
                }
                .padding(.bottom, Space.md)
            }
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in key(press, proxy: proxy) }
        }
    }

    // MARK: Acts

    private func click(_ row: BoxExplorerStore.Row, count: Int) {
        guard row.kind == .node else { return }
        store.selection = row.id
        if row.isFolder {
            store.toggle(row.id)
        } else {
            workspace.openBoxFile(row.id, preview: count < 2)
        }
    }

    private func key(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = store.rows.filter { $0.kind == .node }
        let index = store.selection.flatMap { selection in rows.firstIndex { $0.id == selection } }
        func select(_ i: Int) {
            guard rows.indices.contains(i) else { return }
            store.selection = rows[i].id
            proxy.scrollTo(rows[i].id)
        }
        switch press.key {
        case .downArrow: select((index ?? -1) + 1)
        case .upArrow: select((index ?? rows.count) - 1)
        case .rightArrow:
            guard let index, rows[index].isFolder else { return .handled }
            if rows[index].isOpen { select(index + 1) } else { store.expand(rows[index].id) }
        case .leftArrow:
            guard let index else { return .handled }
            let row = rows[index]
            if row.isFolder, row.isOpen {
                store.collapse(row.id)
            } else if let parent = rows[..<index].lastIndex(where: { $0.depth < row.depth }) {
                select(parent)
            }
        case .space, .return:
            guard let index else { return .handled }
            let row = rows[index]
            if row.isFolder { store.toggle(row.id) } else { workspace.openBoxFile(row.id, preview: press.key == .space) }
        default:
            return .ignored
        }
        return .handled
    }
}

/// One row, drawn as the Files explorer's: guides, chevron, icon, name. A link carries a small
/// arrow; a note (a folder that couldn't be listed, a capped listing) is a dim line.
private struct BoxTreeRow: View, Equatable {
    let row: BoxExplorerStore.Row
    /// From the folder, for storylines.
    let relative: String
    let selected: Bool
    let focused: Bool
    let click: (Int) -> Void
    @StateObject private var hovered = Local(false)
    @Environment(\.listGround) private var ground

    nonisolated static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.selected == b.selected && a.focused == b.focused }

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Size.Tree.leading + CGFloat(row.depth) * Size.Tree.indent)
            chevron
            if case .note(let line) = row.kind {
                Text(line).font(Chrome.caption).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            } else {
                FileIconView(name: row.name, color: selected ? Theme.text : Theme.secondary, isFolder: row.isFolder)
                Spacer().frame(width: Size.Tree.iconGap)
                Text(row.name).font(Chrome.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                if row.isLink {
                    Image(systemName: "arrow.turn.up.right").font(Chrome.caption).foregroundStyle(Theme.tertiary).padding(.leading, Space.xs)
                }
                Spacer(minLength: Space.md)
            }
        }
        .padding(.trailing, Size.Tree.trailing)
        .frame(height: Size.Tree.row)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.chip))
        .padding(.horizontal, Size.Tree.rowInset)
        .background(alignment: .leading) {
            if row.depth > 0 { TreeGuides(depth: row.depth).fill(Theme.Tree.guide).allowsHitTesting(false) }
        }
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .onTapGesture { click(NSApp.mouseClickCount) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { click(1) }
        .storyID(StoryID.Explorer.row(relative), press: { click(1) })
    }

    private var fill: Color {
        guard row.kind == .node else { return .clear }
        if selected { return focused ? Theme.Row.selectedFocused : Theme.Row.selected(ground) }
        return hovered.value ? Theme.Row.hoverQuiet(ground) : .clear
    }

    @ViewBuilder private var chevron: some View {
        Group {
            if row.isFolder {
                Image(systemName: "chevron.right")
                    .font(Chrome.glyphTreeChevron)
                    .foregroundStyle(Theme.secondary)
                    .rotationEffect(.degrees(row.isOpen ? 90 : 0))
                    .animation(Motion.fade, value: row.isOpen)
            } else {
                Color.clear
            }
        }
        .frame(width: Size.Tree.chevronBox, height: Size.Tree.chevronBox)
    }
}

// MARK: - Opening a box file

extension Workspace {
    /// Opens a box file read-only: its tab if open, else the preview tab (a single click) or a new
    /// tab after the active one. Its text or image comes over the link (`fs.read`).
    func openBoxFile(_ path: String, preview: Bool) {
        guard let box else { return }
        let standIn = box.standIn(path)
        if let tab = tabs.first(where: { $0.file?.box?.path == path }) {
            if !preview { tab.isPreview = false }
            select(tab)
            return
        }
        let connection = box.connection
        let document = FileDocument(box: path, standIn: standIn) { await connection.read($0, max: nil) }
        if preview, let tab = tabs.first(where: { $0.isPreview && $0.file?.isDirty != true }) {
            tab.file = document
            select(tab)
            return
        }
        let tab = ChatTab()
        tab.file = document
        tab.isPreview = preview
        if tabs.count == 1, activeTab.isEmpty {
            tabs = [tab]
        } else {
            let index = tabs.firstIndex { $0.id == activeID } ?? tabs.count - 1
            tabs.insert(tab, at: index + 1)
        }
        select(tab)
    }

    /// A turn in this box window ended: the explorer's open folders and the open box files are
    /// read again (the agent may have changed them).
    func boxTurnEnded() {
        guard let box else { return }
        if box.filesMade { Task { await box.files.refresh() } }
        for tab in tabs { tab.file?.reloadFromBox() }
    }
}
