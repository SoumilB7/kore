import AppKit
import SwiftUI

/// A path row segment's menu (look §5, VS Code's breadcrumbs): the folder's entries, folders
/// first. A folder opens in place (with a row back up), a file opens in the preview tab, and
/// "Reveal in Explorer" is the last row. ↑ ↓ move, Return opens, ← goes up, Esc or a click
/// outside closes. Drawn inside the window, under the segment.
struct CrumbMenu: View {
    /// The file tab's coordinate space, where the menu is placed.
    nonisolated static let space = "fileTab"

    /// What a segment opens: the folder to list, the item to mark, and where the segment sits.
    struct Target: Equatable {
        let folder: String
        let current: String?
        /// The segment, in the file tab's coordinates and the window's.
        let anchor: CGRect
        let window: CGRect
    }

    let target: Target
    let workspace: Workspace
    let close: () -> Void
    @StateObject private var folder: Local<String>
    @StateObject private var entries = Local<[FilesStore.Node]?>(nil)
    @StateObject private var selected = Local(0)
    @StateObject private var frame = Local(CGRect.zero)
    @StateObject private var monitor = Held<Any?>(nil)

    init(target: Target, workspace: Workspace, close: @escaping () -> Void) {
        self.target = target
        self.workspace = workspace
        self.close = close
        _folder = StateObject(wrappedValue: Local(target.folder))
    }

    private var root: String { workspace.filesStore().root }
    private var canGoUp: Bool { folder.value != root && folder.value.hasPrefix(root) }

    /// Rows in order: the way up (when there is one), the entries, then Reveal in Explorer.
    private var count: Int { (canGoUp ? 1 : 0) + (entries.value?.count ?? 0) + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if canGoUp {
                            row(0, symbol: "chevron.left", name: (parent as NSString).lastPathComponent, tint: Theme.secondary) { goUp() }
                        }
                        if let entries = entries.value {
                            ForEach(Array(entries.enumerated()), id: \.element.path) { index, node in
                                entryRow(node, index: index + (canGoUp ? 1 : 0))
                            }
                            if entries.isEmpty {
                                Text("This folder is empty")
                                    .font(Chrome.label)
                                    .foregroundStyle(Theme.tertiary)
                                    .padding(Inset.row)
                            }
                        }
                    }
                    .padding(Space.xs)
                }
                .onChange(of: selected.value) { _, index in proxy.scrollTo(index) }
            }
            .frame(maxHeight: Size.menuMax)
            .fixedSize(horizontal: false, vertical: true)
            Rule()
            row(count - 1, symbol: "sidebar.left", name: "Reveal in Explorer", tint: Theme.secondary) { reveal() }
                .padding(Space.xs)
        }
        .frame(width: Size.Editor.crumbMenu)
        // An in-window menu, like Kore's others: no shadow.
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .task(id: folder.value) { await load() }
        .onAppear {
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { handle($0) }
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
        }
    }

    private var parent: String { (folder.value as NSString).deletingLastPathComponent }

    private func entryRow(_ node: FilesStore.Node, index: Int) -> some View {
        let store = workspace.filesStore()
        let dim = store.state(of: node.path) == .ignored
        let marked = node.path == target.current
        return row(
            index, symbol: node.isFolder ? "folder" : nil, file: node.isFolder ? nil : node.name, name: node.name,
            tint: dim ? Theme.tertiary : (marked ? Theme.text : Theme.secondary), bold: marked,
            trailing: node.isFolder
        ) {
            choose(node)
        }
    }

    private func row(
        _ index: Int, symbol: String? = nil, file: String? = nil, name: String, tint: Color, bold: Bool = false,
        trailing: Bool = false, action: @escaping () -> Void
    ) -> some View {
        CrumbMenuRow(
            symbol: symbol, file: file, name: name, tint: tint, bold: bold, folder: trailing, selected: selected.value == index,
            hover: { selected.value = index }, action: action
        )
        .id(index)
    }

    // MARK: Actions

    private func load() async {
        let folder = folder.value
        let listed = await Task.detached { FilesStore.list(folder) ?? [] }.value
        guard folder == self.folder.value else { return }
        entries.value = listed
        // Start on the marked item, else the first entry.
        let offset = canGoUp ? 1 : 0
        selected.value = (listed.firstIndex { $0.path == target.current } ?? 0) + offset
    }

    private func choose(_ node: FilesStore.Node) {
        if node.isFolder {
            entries.value = nil
            folder.value = node.path
        } else {
            close()
            workspace.openFile(URL(fileURLWithPath: node.path), preview: true)
        }
    }

    private func goUp() {
        guard canGoUp else { return }
        entries.value = nil
        folder.value = parent
    }

    private func reveal() {
        close()
        workspace.explorerOpen = true
        let store = workspace.filesStore()
        let path = target.current ?? folder.value
        Task {
            await store.reveal(path)
            if target.current == nil { store.expand(path) }
        }
    }

    private func activate(_ index: Int) {
        if canGoUp, index == 0 { return goUp() }
        if index == count - 1 { return reveal() }
        let entry = index - (canGoUp ? 1 : 0)
        if let entries = entries.value, entries.indices.contains(entry) { choose(entries[entry]) }
    }

    /// Keys while it's open, whatever has focus; a click outside it (or its segment) closes it
    /// and still goes where it was aimed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let content = event.window?.contentView else { return event }
        if event.type == .keyDown {
            switch event.keyCode {
            case 53: close()
            case 126: selected.value = max(selected.value - 1, 0)
            case 125: selected.value = min(selected.value + 1, count - 1)
            case 36, 76: activate(selected.value)
            case 123: goUp()
            case 124:
                let entry = selected.value - (canGoUp ? 1 : 0)
                if let entries = entries.value, entries.indices.contains(entry), entries[entry].isFolder { choose(entries[entry]) }
            default: return event
            }
            return nil
        }
        let location = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !frame.value.contains(location) && !target.window.contains(location) { close() }
        return event
    }
}

private struct CrumbMenuRow: View {
    let symbol: String?
    let file: String?
    let name: String
    let tint: Color
    let bold: Bool
    /// A folder: a chevron at the end says it opens in place.
    let folder: Bool
    let selected: Bool
    let hover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Group {
                    if let file {
                        FileIconView(name: file, color: tint)
                    } else if let symbol {
                        Image(systemName: symbol).font(Chrome.glyphTreeIcon).foregroundStyle(tint)
                    }
                }
                .frame(width: Size.Tree.icon)
                Text(name)
                    .font(bold ? Chrome.bodySemibold : Chrome.body)
                    .foregroundStyle(selected || bold ? Theme.text : tint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.md)
                if folder {
                    Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, Space.md)
            .frame(height: Size.QuickOpen.row)
            .hoverFill(selected, Theme.Row.selected(.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { hover() } }
    }
}
