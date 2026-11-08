import AppKit
import HostClient
import LinkProtocol
import SwiftUI
import UniformTypeIdentifiers

/// A box window's left panel: the box folder's files, with the Files explorer's buttons, keys and
/// menus, over the link. New File, New Folder, Reload and Collapse all on the header while the
/// pointer is over it, Search always. A folder's click opens or closes it; a file's opens it in a
/// preview tab (a double click keeps it), editable. Return renames, ⌘⌫ moves to the box's trash,
/// ⌘X ⌘V move, ⌘ and ⇧ choose several; a drag within the tree moves, a drop from Finder uploads.
/// The folder's sync is the title row's Sync button.
struct BoxExplorer: View {
    let workspace: Workspace
    let box: BoxBinding
    let floating: Bool
    @FocusState private var focused: Bool
    @StateObject private var hovered = Local(false)
    @StateObject private var typed = Local("")
    @StateObject private var typedAt = Held(Date.distantPast)
    @StateObject private var treeHeight = Local<CGFloat>(0)

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

    private var searching: Bool { workspace.sidebar == .search }

    private var header: some View {
        HStack(spacing: Space.xs) {
            Text(searching ? "Search" : workspace.folder.lastPathComponent)
                .font(Chrome.bodyMedium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(searching ? "Search in \(workspace.folder.lastPathComponent)" : box.label)
            Spacer(minLength: Space.md)
            if searching {
                Group {
                    HeaderButton(symbol: "arrow.clockwise", help: "Refresh") { box.search.run() }
                    HeaderButton(symbol: "xmark.circle", help: "Clear") { box.search.clear() }
                }
                .opacity(hovered.value ? 1 : 0)
            } else {
                Group {
                    HeaderButton(symbol: "doc.badge.plus", help: "New File") { store.startNew(folder: false) }
                        .storyID(StoryID.Explorer.newfile, press: { store.startNew(folder: false) })
                    HeaderButton(symbol: "folder.badge.plus", help: "New Folder") { store.startNew(folder: true) }
                        .storyID(StoryID.Explorer.newfolder, press: { store.startNew(folder: true) })
                    HeaderButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refresh() } }
                        .storyID(StoryID.Explorer.refresh, press: { Task { await store.refresh() } })
                    HeaderButton(symbol: "rectangle.compress.vertical", help: "Collapse all") { store.collapseAll() }
                        .storyID(StoryID.Explorer.collapse, press: { store.collapseAll() })
                }
                .opacity(hovered.value || focused ? 1 : 0)
            }
            HeaderButton(symbol: "magnifyingglass", isOn: searching, help: searching ? "Explorer (⇧⌘E)" : "Search (⇧⌘F)") {
                if searching { workspace.sidebar = .explorer } else { workspace.showSearch() }
            }
            .storyID(searching ? StoryID.Explorer.filesTab : StoryID.Explorer.searchTab)
        }
        .padding(.horizontal, Layout.Explorer.headerInset)
        .frame(height: Layout.Explorer.header)
    }

    @ViewBuilder private var content: some View {
        if searching {
            BoxSearchView(workspace: workspace, search: box.search)
        } else if !store.rootLoaded {
            DelayedSpinner().padding(.top, Layout.Explorer.stateTop)
        } else if let why = store.rootError {
            ExplorerState(message: why, color: Theme.secondary, button: "Try Again") { Task { await store.refresh() } }
        } else if store.isEmpty {
            ExplorerState(message: "This folder is empty", color: Theme.tertiary, button: "New File") { store.startNew(folder: false) }
        } else {
            tree
        }
    }

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.rows) { row in
                        BoxTreeRow(
                            row: row, store: store, workspace: workspace, relative: store.relative(row.id), selected: store.isChosen(row.id),
                            focused: focused && store.isChosen(row.id), typed: store.selection == row.id ? typed.value : "",
                            editing: row.kind == .newFile || row.kind == .newFolder || store.edit == .rename(row.id),
                            inDrop: store.dropTarget.map { row.id == $0 || row.id.hasPrefix($0 + "/") } ?? false
                        ) { count, flags in
                            focused = true
                            click(row, count: count, flags: flags)
                        }
                        .id(row.id)
                    }
                }
                .padding(.bottom, Space.md)
                // The empty part below the rows: the keys come to the tree; a drop there goes
                // into the folder itself.
                Color.clear
                    .frame(height: max(treeHeight.value - CGFloat(store.rows.count) * Size.Tree.row - Space.md, 0))
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
                    .onDrop(of: BoxDrop.types, delegate: BoxDrop(folder: store.root, store: store, workspace: workspace))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { treeHeight.value = $0 }
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in key(press, proxy: proxy) }
            .onCommand(#selector(NSResponder.selectAll(_:))) {
                guard store.edit == nil else { return }
                for row in store.rows where row.kind == .node { store.pickToggle(row.id) }
            }
            .onCommand(#selector(NSText.cut(_:))) { store.cut = store.chosenTops }
            .onCommand(#selector(NSText.copy(_:))) { BoxTreeMenu.copy(store.chosenTops.joined(separator: "\n")) }
            .onCommand(#selector(NSText.paste(_:))) { BoxTreeMenu.paste(into: store.targetFolder(), store: store) }
            .onChange(of: store.selection) { _, selection in
                guard let selection else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { proxy.scrollTo(selection) }
            }
        }
    }

    // MARK: Acts

    private func click(_ row: BoxExplorerStore.Row, count: Int, flags: NSEvent.ModifierFlags) {
        guard row.kind == .node else { return }
        if flags.contains(.command) { return store.pickToggle(row.id) }
        if flags.contains(.shift) { return store.pickRange(to: row.id) }
        store.pickOnly(row.id)
        if row.isFolder {
            store.toggle(row.id)
        } else {
            workspace.openBoxFile(row.id, preview: count < 2)
            if count >= 2 { workspace.activeFile?.editor.focus() }
        }
    }

    private func key(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard store.edit == nil else { return .ignored }
        let rows = store.rows.filter { $0.kind == .node }
        let index = store.selection.flatMap { selection in rows.firstIndex { $0.id == selection } }
        func select(_ i: Int) {
            guard rows.indices.contains(i) else { return }
            store.pickOnly(rows[i].id)
        }
        func extend(_ i: Int) {
            guard rows.indices.contains(i) else { return }
            store.pickRange(to: rows[i].id)
        }
        switch press.key {
        case .downArrow where press.modifiers.contains(.shift): extend((index ?? -1) + 1)
        case .upArrow where press.modifiers.contains(.shift): extend((index ?? rows.count) - 1)
        case .downArrow where press.modifiers.contains(.command):
            if let index, !rows[index].isFolder { workspace.openBoxFile(rows[index].id, preview: false) }
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
        case .space:
            guard let index else { return .handled }
            let row = rows[index]
            if row.isFolder { store.toggle(row.id) } else { workspace.openBoxFile(row.id, preview: true) }
        case .return:
            // VS Code: Return renames.
            if index != nil, store.picked.isEmpty, let selection = store.selection { store.edit = .rename(selection) }
        case _ where (press.key == .delete || press.key.character == "\u{7F}") && press.modifiers.contains(.command):
            if index != nil { BoxTreeMenu.trash(store.chosenTops, store: store) }
        case .escape where !store.picked.isEmpty:
            store.pickOnly(store.selection)
        case .escape where !typed.value.isEmpty:
            typed.value = ""
        default:
            return find(press, rows: rows, from: index) ? .handled : .ignored
        }
        return .handled
    }

    /// Typing jumps to the next row whose name starts with what's typed; a pause starts over.
    private func find(_ press: KeyPress, rows: [BoxExplorerStore.Row], from index: Int?) -> Bool {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]), !press.characters.isEmpty,
            press.characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let now = Date()
        let fresh = now.timeIntervalSince(typedAt.value) > 1
        typedAt.value = now
        let query = (fresh ? "" : typed.value) + press.characters
        let start = fresh || query.count == 1 ? (index ?? -1) + 1 : (index ?? 0)
        let order = Array(rows[min(start, rows.count)...]) + Array(rows[..<min(start, rows.count)])
        typed.value = query
        if let match = order.first(where: { $0.name.lowercased().hasPrefix(query.lowercased()) }) { store.pickOnly(match.id) }
        return true
    }
}

/// One row, drawn as the Files explorer's: guides, chevron, icon, name (or its name field). A
/// link carries a small arrow; a note (a folder that couldn't be listed, a capped listing) is a
/// dim line.
private struct BoxTreeRow: View {
    let row: BoxExplorerStore.Row
    let store: BoxExplorerStore
    let workspace: Workspace
    /// From the folder, for storylines.
    let relative: String
    let selected: Bool
    let focused: Bool
    let typed: String
    let editing: Bool
    let inDrop: Bool
    let click: (Int, NSEvent.ModifierFlags) -> Void
    @StateObject private var hovered = Local(false)
    @Environment(\.listGround) private var ground

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Size.Tree.leading + CGFloat(row.depth) * Size.Tree.indent)
            chevron
            if case .note(let line) = row.kind {
                Text(line).font(Chrome.caption).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            } else {
                FileIconView(name: editing ? "" : row.name, color: selected ? Theme.text : Theme.secondary, isFolder: row.isFolder)
                Spacer().frame(width: Size.Tree.iconGap)
                if editing {
                    BoxNameField(row: row, store: store, workspace: workspace)
                } else {
                    Text(name).font(Chrome.body).lineLimit(1).truncationMode(.tail)
                        .opacity(store.cut.contains(row.id) ? 0.5 : 1)
                    if row.isLink {
                        Image(systemName: "arrow.turn.up.right").font(Chrome.caption).foregroundStyle(Theme.tertiary).padding(.leading, Space.xs)
                    }
                    Spacer(minLength: Space.md)
                }
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
        .onTapGesture {
            guard !editing else { return }
            click(NSApp.mouseClickCount, NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [])
        }
        .accessibilityElement(children: editing ? .contain : .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { click(1, []) }
        .storyID(StoryID.Explorer.row(relative), press: { click(1, []) })
        .onDrag {
            // A chosen row carries the whole choice; the others only themselves.
            BoxDrag.paths = store.isChosen(row.id) && !store.picked.isEmpty ? store.chosenTops : [row.id]
            return NSItemProvider(object: BoxDrag.marker as NSString)
        }
        .onDrop(of: BoxDrop.types, delegate: BoxDrop(folder: row.isFolder ? row.id : store.parent(of: row.id), store: store, workspace: workspace))
        .koreContextMenu("explorer") {
            guard row.kind == .node else { return [] }
            if !store.isChosen(row.id) { store.pickOnly(row.id) }
            return BoxTreeMenu(path: row.id, isFolder: row.isFolder, store: store, workspace: workspace).items
        }
    }

    private var name: AttributedString {
        var text: AttributedString
        if !typed.isEmpty, row.name.lowercased().hasPrefix(typed.lowercased()) {
            var matched = AttributedString(String(row.name.prefix(typed.count)))
            matched.foregroundColor = Theme.accent
            matched.font = Chrome.bodySemibold
            var rest = AttributedString(String(row.name.dropFirst(typed.count)))
            rest.foregroundColor = Theme.text
            text = matched + rest
        } else {
            text = AttributedString(row.name)
            text.foregroundColor = Theme.text
        }
        return text
    }

    private var fill: Color {
        if inDrop { return Theme.Tree.dropTarget }
        guard row.kind == .node else { return .clear }
        if selected { return focused ? Theme.Row.selectedFocused : Theme.Row.selected(ground) }
        return hovered.value ? Theme.Row.hoverQuiet(ground) : .clear
    }

    @ViewBuilder private var chevron: some View {
        Group {
            if row.isFolder, row.kind == .node {
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

/// The name field for a new file or folder, or a rename: Return makes it on the box, Esc or an
/// empty name gives up, a taken or bad name says why under it.
private struct BoxNameField: View {
    let row: BoxExplorerStore.Row
    let store: BoxExplorerStore
    let workspace: Workspace
    @StateObject private var name = Local("")
    @StateObject private var done = Held(false)
    @FocusState private var focused: Bool

    private var failure: String? {
        guard !name.value.isEmpty else { return nil }
        return BoxExplorerStore.refusal(name.value)
    }

    var body: some View {
        TextField("", text: $name.value)
            .textFieldStyle(.plain)
            .storyID(StoryID.Explorer.namefield)
            .font(Chrome.body)
            .foregroundStyle(Theme.text)
            .focused($focused)
            .padding(.horizontal, Space.xs)
            .frame(height: Size.Tree.row - Space.xs)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .strokeBorder(failure == nil ? Theme.accentLine : Theme.danger, lineWidth: Stroke.hairline)
            )
            .overlay(alignment: .topLeading) {
                if let failure {
                    Text(failure).font(Chrome.caption).foregroundStyle(Theme.text).padding(Inset.row).panel(.panel).fixedSize()
                        .offset(y: Size.Tree.row)
                }
            }
            .zIndex(1)
            .onAppear {
                if case .rename(let path) = store.edit { name.value = (path as NSString).lastPathComponent }
                focused = true
            }
            .onSubmit { commit() }
            .onExitCommand { cancel() }
            .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func cancel() {
        done.value = true
        store.edit = nil
    }

    private func commit() {
        guard !done.value, let edit = store.edit else { return }
        let value = name.value.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return cancel() }
        if failure != nil { return }
        done.value = true
        store.edit = nil
        Task {
            switch edit {
            case .newFile(let parent):
                switch await store.create(value, in: parent, folder: false) {
                case .success(let path):
                    workspace.openBoxFile(path, preview: false)
                    workspace.activeFile?.showsRaw = true
                    workspace.activeFile?.editor.focus()
                case .failure(let why): BoxTreeMenu.show(why.message)
                }
            case .newFolder(let parent):
                if case .failure(let why) = await store.create(value, in: parent, folder: true) { BoxTreeMenu.show(why.message) }
            case .rename(let path):
                if case .failure(let why) = await store.rename(path, to: value) { BoxTreeMenu.show(why.message) }
            }
        }
    }
}

// MARK: - Menu and actions

/// The tree's right-click menu, as the Files explorer's, less what a box's files can't do from
/// this Mac (Open with Default App, Reveal in Finder, Open in Terminal, Compress, Copy and
/// Duplicate as files).
@MainActor struct BoxTreeMenu {
    let path: String
    let isFolder: Bool
    let store: BoxExplorerStore
    let workspace: Workspace

    var items: [OptionItem] {
        let chosen = store.chosenTops
        if chosen.count > 1 {
            return [
                OptionItem("Cut") { store.cut = chosen }, .rule,
                OptionItem("Copy Paths") { Self.copy(chosen.joined(separator: "\n")) },
                OptionItem("Copy Relative Paths") { Self.copy(chosen.map(store.relative).joined(separator: "\n")) }, .rule,
                OptionItem("Move \(chosen.count) Items to Trash", destructive: true) { Self.trash(chosen, store: store) },
            ]
        }
        let folder = isFolder ? path : store.parent(of: path)
        var items: [OptionItem] = [
            OptionItem("New File…") { store.pickOnly(path); store.startNew(folder: false) },
            OptionItem("New Folder…") { store.pickOnly(path); store.startNew(folder: true) }, .rule,
        ]
        if !isFolder { items.append(OptionItem("Open") { workspace.openBoxFile(path, preview: false) }) }
        if isFolder { items.append(OptionItem("Find in Folder…") { workspace.box?.search.scope(path); workspace.showSearch() }) }
        items += [.rule, OptionItem("Cut") { store.cut = [path] }]
        if !store.cut.isEmpty { items.append(OptionItem("Paste") { Self.paste(into: folder, store: store) }) }
        items += [
            .rule,
            OptionItem("Copy Path") { Self.copy(path) },
            OptionItem("Copy Relative Path") { Self.copy(store.relative(path)) }, .rule,
            OptionItem("Rename…") { store.edit = .rename(path) },
            OptionItem("Move to Trash", destructive: true) { Self.trash([path], store: store) },
        ]
        return items
    }

    static func copy(_ text: String) { TreeActions.copy(text) }

    /// ⌘V after ⌘X: the cut entries move into `folder`.
    static func paste(into folder: String, store: BoxExplorerStore) {
        let paths = store.cut
        guard !paths.isEmpty else { return }
        store.cut = []
        Task { if let failure = await store.move(paths, into: folder) { show(failure) } }
    }

    /// One question for all of them (as the Files explorer asks), then the box's trash.
    static func trash(_ paths: [String], store: BoxExplorerStore) {
        guard !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? "Are you sure you want to delete “\((paths[0] as NSString).lastPathComponent)”?"
            : "Are you sure you want to delete the following \(paths.count) items?"
        alert.informativeText = (paths.count == 1 ? "" : paths.prefix(10).map { ($0 as NSString).lastPathComponent }.joined(separator: "\n") + "\n\n")
            + "You can restore \(paths.count == 1 ? "it" : "them") from the trash on \(store.alias)."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard StorylineSeams.confirm?("trash") ?? (alert.runModal() == .alertFirstButtonReturn) else { return }
        Task { if let failure = await store.trash(paths) { show(failure) } }
    }

    static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

// MARK: - Dragging and dropping

/// The rows a drag in the box tree carries (the provider holds only a marker).
@MainActor enum BoxDrag {
    static var paths: [String] = []
    static let marker = "kore.box.rows"
}

/// A drop on a folder (a file row: its folder): rows from this tree move there; files from
/// Finder upload there (12 MB each at most; a folder isn't taken).
private struct BoxDrop: DropDelegate {
    static let types: [UTType] = [.fileURL, .plainText]
    let folder: String
    let store: BoxExplorerStore
    let workspace: Workspace

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }
    func dropEntered(info: DropInfo) { store.dropTarget = folder }
    func dropExited(info: DropInfo) { if store.dropTarget == folder { store.dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.dropTarget = nil
        let urls = info.itemProviders(for: [.fileURL])
        if urls.isEmpty {
            let paths = BoxDrag.paths
            BoxDrag.paths = []
            guard !paths.isEmpty else { return false }
            let movable = paths.filter { store.parent(of: $0) != folder && !LinkFiles.inside(folder, $0) }
            guard !movable.isEmpty else { return false }
            if movable.count > 1 {
                let alert = NSAlert()
                alert.messageText = "Move \(movable.count) items into “\((folder as NSString).lastPathComponent)”?"
                alert.addButton(withTitle: "Move")
                alert.addButton(withTitle: "Cancel")
                guard StorylineSeams.confirm?("move") ?? (alert.runModal() == .alertFirstButtonReturn) else { return false }
            }
            Task { if let failure = await store.move(movable, into: folder) { BoxTreeMenu.show(failure) } }
            return true
        }
        let (store, folder) = (store, folder)
        Task {
            var files: [(name: String, data: Data)] = []
            var skipped: [String] = []
            for provider in urls {
                guard let url = await Self.url(provider) else { continue }
                var isFolder: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
                if isFolder.boolValue {
                    skipped.append(url.lastPathComponent)
                    continue
                }
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= LinkUploads.maxSize,
                    let data = try? Data(contentsOf: url)
                else {
                    skipped.append(url.lastPathComponent)
                    continue
                }
                files.append((url.lastPathComponent, data))
            }
            let failure = await store.upload(files, into: folder) { name in
                let alert = NSAlert()
                alert.messageText = "“\(name)” already exists in “\((folder as NSString).lastPathComponent)”."
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Keep Both")
                alert.addButton(withTitle: "Cancel")
                switch StorylineSeams.confirm.map({ $0("replace") ? NSApplication.ModalResponse.alertFirstButtonReturn : .alertSecondButtonReturn })
                    ?? alert.runModal()
                {
                case .alertFirstButtonReturn: return .replace
                case .alertSecondButtonReturn: return .keepBoth
                default: return .cancel
                }
            }
            if !skipped.isEmpty {
                BoxTreeMenu.show("Not copied to \(store.alias): \(skipped.joined(separator: ", ")). Files of up to 12 MB go; folders don't.")
            } else if let failure {
                BoxTreeMenu.show(failure)
            }
        }
        return true
    }

    private static func url(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

// MARK: - Search

/// Search in a box folder: lines holding the query (`fs.search` text), in the folder or the one
/// Find in Folder… picked, files first then their lines; a line's click opens it there.
@MainActor @Observable
final class BoxSearchStore {
    var query = ""
    /// Find in Folder…: under this folder; nil: the whole folder.
    private(set) var within: String?
    private(set) var hits: [FileHit] = []
    private(set) var more = false
    private(set) var running = false
    private(set) var problem: String?
    /// Asks the field for the keys.
    var focusToken = 0
    @ObservationIgnored private let root: String
    @ObservationIgnored private let source: any BoxFileSource
    @ObservationIgnored private var task: Task<Void, Never>?

    init(root: String, source: any BoxFileSource) {
        self.root = root
        self.source = source
    }

    func scope(_ folder: String?) {
        within = folder == root ? nil : folder
        run()
    }

    func clear() {
        task?.cancel()
        query = ""
        hits = []
        more = false
        problem = nil
    }

    /// The hits by file, in the order they came.
    var files: [(path: String, lines: [FileHit])] {
        var order: [String] = []
        var lines: [String: [FileHit]] = [:]
        for hit in hits {
            if lines[hit.path] == nil { order.append(hit.path) }
            lines[hit.path, default: []].append(hit)
        }
        return order.map { ($0, lines[$0] ?? []) }
    }

    func run() {
        task?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clear() }
        running = true
        let root = within ?? root, source = source
        task = Task { [weak self] in
            // Typing settles first.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let result = await source.search(root, query, text: true, max: 500)
            guard !Task.isCancelled, let self else { return }
            running = false
            switch result {
            case .success(let found):
                (hits, more, problem) = (found.hits, found.more, nil)
            case .failure(let why):
                (hits, more, problem) = ([], false, why.message)
            }
        }
    }

    func relative(_ path: String) -> String { path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path }
}

private struct BoxSearchView: View {
    let workspace: Workspace
    let search: BoxSearchStore
    @FocusState private var field: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            TextField("", text: Binding(get: { search.query }, set: { search.query = $0 }), prompt: Text("Search").foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Chrome.label)
                .focused($field)
                .fieldWell(focused: field)
                .onChange(of: search.query) { search.run() }
                .padding(.horizontal, Space.sm)
            if let within = search.within {
                HStack(spacing: Space.xs) {
                    Text("in ./" + search.relative(within)).font(Chrome.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    Button { search.scope(nil) } label: { Image(systemName: "xmark").font(Chrome.caption) }.buttonStyle(.plain)
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, Space.md)
            }
            if let problem = search.problem {
                Text(problem).font(Chrome.caption).foregroundStyle(Theme.danger).padding(.horizontal, Space.md)
            } else if !search.query.isEmpty, !search.running, search.hits.isEmpty {
                Text("No results").font(Chrome.caption).foregroundStyle(Theme.tertiary).padding(.horizontal, Space.md)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(search.files, id: \.path) { file in
                        HStack(spacing: Space.sm) {
                            FileIconView(name: (file.path as NSString).lastPathComponent)
                            Text((file.path as NSString).lastPathComponent).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
                            Text(search.relative((file.path as NSString).deletingLastPathComponent)).font(Chrome.caption)
                                .foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 0)
                            Text("\(file.lines.count)").font(Chrome.captionDigits).foregroundStyle(Theme.tertiary)
                        }
                        .padding(.horizontal, Space.md)
                        .frame(height: Size.Tree.row)
                        ForEach(file.lines, id: \.self) { hit in
                            Button { open(hit) } label: {
                                Text(hit.text?.trimmingCharacters(in: .whitespaces) ?? "")
                                    .font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
                                    .padding(.leading, Space.xl + Space.md)
                                    .frame(maxWidth: .infinity, minHeight: Size.Tree.row, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if search.more {
                        Text("More results than shown · narrow the search").font(Chrome.caption).foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, Space.md).padding(.top, Space.xs)
                    }
                }
            }
        }
        .padding(.top, Space.xs)
        .onAppear { field = true }
        .onChange(of: search.focusToken) { field = true }
    }

    private func open(_ hit: FileHit) {
        workspace.openBoxFile(hit.path, preview: true)
        guard let line = hit.line, let file = workspace.activeFile else { return }
        let text = (hit.text ?? "") as NSString
        let found = text.range(of: search.query, options: .caseInsensitive)
        let columns = found.location == NSNotFound ? 0..<0 : found.location..<(found.location + found.length)
        file.reveal(FileDocument.Place(line: line, columns: columns))
    }
}

// MARK: - The window's box files

extension FileDocument {
    /// A box file, read and saved through `source`.
    convenience init(box path: String, source: any BoxFileSource, standIn: URL) {
        self.init(
            box: path, alias: source.alias, standIn: standIn, read: { await source.read($0, max: nil) },
            write: { await source.write($0, $1, base: $2) })
    }
}

extension Workspace {
    /// Opens a box file: its tab if open, else the preview tab (a single click) or a new tab after
    /// the active one. Its text or image comes over the link (`fs.read`) and saves back
    /// (`fs.write`).
    func openBoxFile(_ path: String, preview: Bool) {
        guard let box else { return }
        let standIn = box.standIn(path)
        remember(standIn.path)
        if let tab = tabs.first(where: { $0.file?.box?.path == path }) {
            if !preview { tab.isPreview = false }
            select(tab)
            return
        }
        let document = FileDocument(box: path, source: box.connection, standIn: standIn)
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

    /// A turn in this box window ended: where the box can't watch the open folders, they and the
    /// open box files are read again (the agent may have changed them).
    func boxTurnEnded() {
        guard let box, box.filesMade, !box.files.watching else { return }
        Task { await box.files.refresh() }
        for tab in tabs { tab.file?.reloadFromBox() }
    }

    /// The box's explorer moved or renamed an entry: its open files follow.
    func boxMoved(_ old: String, to new: String) {
        guard let box else { return }
        for tab in tabs {
            guard let file = tab.file, let path = file.box?.path else { continue }
            if path == old {
                file.boxMoved(to: new, standIn: box.standIn(new))
            } else if path.hasPrefix(old + "/") {
                let moved = new + path.dropFirst(old.count)
                file.boxMoved(to: moved, standIn: box.standIn(moved))
            }
        }
    }

    /// Files in these box folders changed: their open tabs read them again.
    func boxFoldersChanged(_ folders: Set<String>) {
        for tab in tabs {
            guard let file = tab.file, let path = file.box?.path, folders.contains((path as NSString).deletingLastPathComponent) else { continue }
            file.reloadFromBox()
        }
    }
}
