import AppKit
import HostClient
import KoreCore
import LinkProtocol
import SwiftUI
import UniformTypeIdentifiers

/// A box window's left panel: the box folder's files, with the Files explorer's buttons, keys and
/// menus, over the link. New File, New Folder, Reload and Collapse all on the header while the
/// pointer is over it, Search always. A folder's click opens or closes it; a file's opens it in a
/// preview tab (a double click keeps it), editable. Return renames, ⌘⌫ moves to the box's trash,
/// ⌘C ⌘X ⌘V copy and move to and from any explorer (this Mac's, another box's), ⌘ and ⇧ choose
/// several; a drag within the box moves (⌥ copies), one from this Mac or another box copies (⌘
/// moves).
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
        // The link back after a drop lists the open folders again (`HostConnection`'s watches).
        .task { await store.start() }
        .onChange(of: FileCarries.shared.revision) { store.carriesChanged() }
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
            // Quiet, in place: never a blank panel or a spinner over it.
            Text("Loading…").font(Chrome.label).foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity).padding(.top, Layout.Explorer.stateTop)
        } else if let why = store.rootError {
            ExplorerState(message: why, color: Theme.secondary, button: "Try Again") { Task { await store.refresh() } }
        } else if store.isEmpty {
            VStack(spacing: Space.md) {
                Text("This folder is empty").font(Chrome.label).foregroundStyle(Theme.tertiary)
                HStack(spacing: Space.sm) {
                    Button("New File") { store.startNew(folder: false) }.buttonStyle(SubtleButtonStyle())
                    Button("New Folder") { store.startNew(folder: true) }.buttonStyle(SubtleButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Layout.Explorer.stateTop)
        } else {
            tree
        }
        if let problem = store.problem, !searching {
            // What the box refused, put back: one plain line, gone after a while.
            Text(problem).font(Chrome.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                .padding(.horizontal, Layout.Explorer.headerInset).padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
        if !searching { CarryLine(root: .box(alias: store.alias, path: store.root)) }
    }

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.rows) { row in
                        BoxTreeRow(
                            row: row, store: store, workspace: workspace, relative: store.relative(row.id), selected: store.isChosen(row.id),
                            state: row.kind == .node ? box.git.state(of: row.id) : nil,
                            focused: focused && store.isChosen(row.id), typed: store.selection == row.id ? typed.value : "",
                            editing: row.kind == .newFile || row.kind == .newFolder || store.edit == .rename(row.id),
                            drop: store.dropTarget.map { row.id == $0 ? .target : row.id.hasPrefix($0 + "/") ? .inside : .none } ?? .none
                        ) { count, flags in
                            focused = true
                            click(row, count: count, flags: flags)
                        }
                        .id(row.id)
                    }
                }
                // The drop's badge at the pointer, over the row (or the space) it's on.
                .overlay(alignment: .topLeading) {
                    if let badge = store.dropping.badge {
                        let index = badge.row.flatMap { path in store.rows.firstIndex { $0.id == path } } ?? store.rows.count
                        DropBadge(badge: badge).offset(y: CGFloat(index) * Size.Tree.row)
                    }
                }
                .animation(Motion.fade, value: store.dropping.badge?.text)
                .padding(.bottom, Space.md)
                // The empty part below the rows: the keys come to the tree; a drop there goes
                // into the folder itself.
                Color.clear
                    .frame(height: max(treeHeight.value - CGFloat(store.rows.count) * Size.Tree.row - Space.md, 0))
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
                    .onDrop(of: BoxDrop.types, delegate: BoxDrop(folder: store.root, store: store, workspace: workspace))
            }
            .onAppear {
                // Under a drag, a row at an edge brings its neighbour into view: the tree scrolls.
                store.dropping.nudge = { [store] path in
                    let rows = store.rows
                    guard let i = rows.firstIndex(where: { $0.id == path }) else { return }
                    withAnimation(.linear(duration: 0.12)) {
                        if i + 1 < rows.count { proxy.scrollTo(rows[i + 1].id) }
                        if i > 0 { proxy.scrollTo(rows[i - 1].id) }
                    }
                }
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
            .onCommand(#selector(NSText.cut(_:))) { BoxTreeMenu.put(store.chosenTops, cut: true, store: store) }
            .onCommand(#selector(NSText.copy(_:))) { BoxTreeMenu.put(store.chosenTops, cut: false, store: store) }
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
        case .return, KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)):
            // VS Code: Return (or F2) renames.
            if index != nil, store.picked.isEmpty, let selection = store.selection { store.edit = .rename(selection) }
        case "n" where press.modifiers.contains(.command):
            // ⌘N a file, ⇧⌘N a folder, in the tree.
            store.startNew(folder: press.modifiers.contains(.shift))
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
    /// The box's git state (link 1.8, `BoxGitStatus`), as the Files explorer colours a row.
    let state: GitStatus.State?
    let focused: Bool
    let typed: String
    let editing: Bool
    let drop: DropFill
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
                FileIconView(
                    name: editing ? "" : row.name, color: state.map(Theme.Git.color) ?? (selected ? Theme.text : Theme.secondary), isFolder: row.isFolder)
                Spacer().frame(width: Size.Tree.iconGap)
                if editing {
                    BoxNameField(row: row, store: store, workspace: workspace)
                } else {
                    Text(name).font(Chrome.body).lineLimit(1).truncationMode(.tail)
                        .opacity(FileClipboard.shared.isCut(.box(alias: store.alias, path: row.id)) ? 0.5 : 1)
                    if row.isLink {
                        Image(systemName: "arrow.turn.up.right").font(Chrome.caption).foregroundStyle(Theme.tertiary).padding(.leading, Space.xs)
                    }
                    Spacer(minLength: Space.md)
                    gitMark
                }
            }
        }
        .padding(.trailing, Size.Tree.trailing)
        .frame(height: Size.Tree.row)
        // On its way here (a carry): dimmed, with its bar.
        .opacity(carrying == nil ? 1 : 0.5)
        .overlay(alignment: .bottom) { if let carrying { CarryBar(fraction: carrying).padding(.horizontal, Space.sm) } }
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.chip))
        .animation(Motion.fade, value: drop)
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
            BoxDrag.start(store.isChosen(row.id) && !store.picked.isEmpty ? store.chosenTops : [row.id], alias: store.alias)
            // As text, the box paths (a terminal or another app takes them so); and as box files,
            // which a box chat's composer attaches as chips, sent by their paths.
            let provider = NSItemProvider(object: BoxDrag.paths.joined(separator: " ") as NSString)
            let lines = Data(BoxDrag.paths.joined(separator: "\n").utf8)
            provider.registerDataRepresentation(forTypeIdentifier: BoxFileRef.dragType, visibility: .ownProcess) { done in
                done(lines, nil)
                return nil
            }
            return provider
        }
        .onDrop(
            of: BoxDrop.types,
            delegate: BoxDrop(folder: row.isFolder ? row.id : store.parent(of: row.id), store: store, workspace: workspace, row: row.id, isFolder: row.isFolder))
        .koreContextMenu("explorer") {
            guard row.kind == .node else { return [] }
            if !store.isChosen(row.id) { store.pickOnly(row.id) }
            return BoxTreeMenu(path: row.id, isFolder: row.isFolder, store: store, workspace: workspace).items
        }
    }

    private var name: AttributedString {
        let tint = state.map(Theme.Git.color)
        var text: AttributedString
        if !typed.isEmpty, row.name.lowercased().hasPrefix(typed.lowercased()) {
            var matched = AttributedString(String(row.name.prefix(typed.count)))
            matched.foregroundColor = tint ?? Theme.accent
            matched.font = Chrome.bodySemibold
            var rest = AttributedString(String(row.name.dropFirst(typed.count)))
            rest.foregroundColor = tint ?? Theme.text
            text = matched + rest
        } else {
            text = AttributedString(row.name)
            text.foregroundColor = tint ?? Theme.text
        }
        return text
    }

    /// The Files explorer's git mark: a folder's dot, a file's letter; none for ignored.
    @ViewBuilder private var gitMark: some View {
        if let state, state != .ignored {
            if row.isFolder {
                Circle().fill(Theme.Git.color(state)).frame(width: Size.Tree.point, height: Size.Tree.point)
            } else if let letter = Theme.Git.letter(state) {
                Text(letter).font(Chrome.captionStrong).foregroundStyle(Theme.Git.color(state)).frame(width: Size.Tree.letterBox)
            }
        }
    }

    private var carrying: Double? {
        FileCarries.shared.pending.isEmpty ? nil : FileCarries.shared.progress(of: .box(alias: store.alias, path: row.id))
    }

    private var fill: Color {
        switch drop {
        case .target: return Theme.Tree.dropTarget
        case .inside: return Theme.Tree.dropInside
        case .none: break
        }
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
                if case .success(let path) = await store.create(value, in: parent, folder: false) {
                    workspace.openBoxFile(path, preview: false)
                    workspace.activeFile?.showsRaw = true
                    workspace.activeFile?.editor.focus()
                }
            case .newFolder(let parent):
                // A refusal is the store's line; what was shown goes back.
                _ = await store.create(value, in: parent, folder: true)
            case .rename(let path):
                _ = await store.rename(path, to: value)
            }
        }
    }
}

// MARK: - Menu and actions

/// The tree's right-click menu, as the Files explorer's, less what a box's files can't do from
/// this Mac (Open with Default App, Reveal in Finder, Open in Terminal, Compress).
@MainActor struct BoxTreeMenu {
    let path: String
    let isFolder: Bool
    let store: BoxExplorerStore
    let workspace: Workspace

    var items: [OptionItem] {
        let chosen = store.chosenTops
        if chosen.count > 1 {
            return [
                OptionItem("Cut") { Self.put(chosen, cut: true, store: store) },
                OptionItem("Copy") { Self.put(chosen, cut: false, store: store) },
                OptionItem("Duplicate") { Self.duplicate(chosen, store: store) }, .rule,
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
        items += [
            .rule,
            OptionItem("Cut") { Self.put([path], cut: true, store: store) },
            OptionItem("Copy") { Self.put([path], cut: false, store: store) },
        ]
        if FileClipboard.shared.canPaste { items.append(OptionItem("Paste") { Self.paste(into: folder, store: store) }) }
        items += [
            OptionItem("Duplicate") { Self.duplicate([path], store: store) }, .rule,
            OptionItem("Copy Path") { Self.copy(path) },
            OptionItem("Copy Relative Path") { Self.copy(store.relative(path)) }, .rule,
            OptionItem("Rename…") { store.edit = .rename(path) },
            OptionItem("Move to Trash", destructive: true) { Self.trash([path], store: store) },
        ]
        return items
    }

    static func copy(_ text: String) { TreeActions.copy(text) }

    /// ⌘C / ⌘X: on Kore's file clipboard (the paths as text on the pasteboard), for ⌘V in any
    /// explorer, in any window.
    static func put(_ paths: [String], cut: Bool, store: BoxExplorerStore) {
        FileClipboard.shared.put(paths.map { .box(alias: store.alias, path: $0) }, cut: cut)
    }

    /// ⌘V into `folder`: a cut in this tree moves at once (`fs.rename`); anything else (a copy,
    /// another window's, this Mac's, another box's) goes by `FilePaste`.
    static func paste(into folder: String, store: BoxExplorerStore) {
        guard let clip = FileClipboard.shared.current() else { return }
        let here = clip.items.compactMap { place -> String? in
            guard case .box(let alias, let path) = place, alias == store.alias, store.shows(path) else { return nil }
            return path
        }
        if clip.cut, here.count == clip.items.count {
            FileClipboard.shared.pasted()
            Task { _ = await store.move(here, into: folder) }
            return
        }
        FilePaste.carry(clip.items, into: .box(alias: store.alias, path: folder), move: clip.cut) { outcome in
            if clip.cut, outcome.failure == nil { FileClipboard.shared.pasted() }
            await store.landed(outcome)
        }
    }

    /// Duplicate: a copy beside each, named " copy" (`fs.copy`).
    static func duplicate(_ paths: [String], store: BoxExplorerStore) {
        for (parent, group) in Dictionary(grouping: paths, by: store.parent(of:)) {
            FilePaste.carry(group.map { .box(alias: store.alias, path: $0) }, into: .box(alias: store.alias, path: parent), move: false) { outcome in
                await store.landed(outcome)
            }
        }
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
        Task { _ = await store.trash(paths) }
    }

    static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

// MARK: - Dragging and dropping

/// The rows a drag in a box tree carries, and the box they're on (the provider holds their paths
/// as text, which a drop checks against these).
@MainActor enum BoxDrag {
    static var paths: [String] = []
    static var alias: String?
    private static var started = Date.distantPast

    static func start(_ paths: [String], alias: String) {
        self.paths = paths
        self.alias = alias
        started = Date()
    }

    /// A box drag may be over a drop now.
    static var active: Bool { !paths.isEmpty && Date().timeIntervalSince(started) < 600 }

    /// The rows a drop's text carries, when it's this drag's.
    static func places(_ providers: [NSItemProvider]) async -> [FilePlace]? {
        guard active, let alias, let provider = providers.first else { return nil }
        let text: String? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in continuation.resume(returning: (object as? NSString) as String?) }
        }
        guard text == paths.joined(separator: " ") else { return nil }
        defer { paths = [] }
        return paths.map { .box(alias: alias, path: $0) }
    }
}

/// A drop on a folder (a file row: its folder; the space under the rows: the root), its row lit
/// and a badge at the pointer saying what a drop does (`DropRules`): rows of this box move (⌥
/// copies); this Mac's files and another box's rows copy (⌘ moves), by `FilePaste`.
private struct BoxDrop: DropDelegate {
    static let types: [UTType] = [.fileURL, .plainText]
    let folder: String
    let store: BoxExplorerStore
    let workspace: Workspace
    var row: String?
    var isFolder = true

    private var into: FilePlace { .box(alias: store.alias, path: folder) }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) || BoxDrag.active }
    func dropEntered(info: DropInfo) { _ = update(info) }
    func dropExited(info: DropInfo) { store.dropping.out(row: row) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch update(info) {
        case .refused: DropProposal(operation: .forbidden)
        case .move: DropProposal(operation: .move)
        case .copy: DropProposal(operation: .copy)
        }
    }

    private func update(_ info: DropInfo) -> DropAct {
        let sources = DragSources.now()
        let act = DropRules.act(sources, into: into, flags: NSEvent.modifierFlags, reachable: store.reachable)
        let shown = folder == store.root ? BoxFolder.lastPart(folder) : store.relative(folder)
        store.dropping.over(row: row, isFolder: isFolder, folder: folder, point: info.location, act: act, text: DropRules.badge(act, sources: sources, into: into, shown: shown))
        return act
    }

    func performDrop(info: DropInfo) -> Bool {
        let act = DropRules.act(DragSources.now(), into: into, flags: NSEvent.modifierFlags, reachable: store.reachable)
        store.dropping.ended(droppedInto: act == .refused ? nil : folder)
        guard act != .refused else { return false }
        let urls = info.itemProviders(for: [.fileURL])
        let (store, folder, into) = (store, folder, into)
        func landed(_ outcome: CarryOutcome) async { await store.landed(outcome) }
        if urls.isEmpty {
            let texts = info.itemProviders(for: [.plainText])
            Task {
                guard let places = await BoxDrag.places(texts) else { return }
                let paths = places.map(\.path)
                // Rows this tree shows move at once (`fs.rename`); the rest go by `FilePaste`.
                guard act == .move, places.allSatisfy({ $0.alias == store.alias }), paths.allSatisfy(store.shows) else {
                    return FilePaste.carry(places, into: into, move: act == .move, done: landed)
                }
                let movable = paths.filter { store.parent(of: $0) != folder && !LinkFiles.inside(folder, $0) }
                guard !movable.isEmpty else { return }
                if movable.count > 1 {
                    let alert = NSAlert()
                    alert.messageText = "Move \(movable.count) items into “\((folder as NSString).lastPathComponent)”?"
                    alert.addButton(withTitle: "Move")
                    alert.addButton(withTitle: "Cancel")
                    guard StorylineSeams.confirm?("move") ?? (alert.runModal() == .alertFirstButtonReturn) else { return }
                }
                _ = await store.move(movable, into: folder)
            }
            return true
        }
        Task {
            var dropped: [URL] = []
            for provider in urls {
                if let url = await Self.url(provider) { dropped.append(url) }
            }
            // A local tree's drag carries its whole choice.
            let places = TreeDrag.expand(dropped).map { FilePlace.mac(realPath($0.path)) }
            guard SyncBox.ssh(store.alias) == nil else {
                return FilePaste.carry(places, into: into, move: act == .move, done: landed)
            }
            await Self.upload(places.map { URL(fileURLWithPath: $0.path) }, into: folder, store: store)
        }
        return true
    }

    /// Without an SSH alias to rsync over: files (12 MB each at most; not folders) uploaded over
    /// the link.
    private static func upload(_ urls: [URL], into folder: String, store: BoxExplorerStore) async {
        var files: [(name: String, data: Data)] = []
        var skipped: [String] = []
        for url in urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            guard !isFolder.boolValue, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= LinkUploads.maxSize,
                let data = try? Data(contentsOf: url)
            else {
                skipped.append(url.lastPathComponent)
                continue
            }
            files.append((url.lastPathComponent, data))
        }
        let failure = await store.upload(files, into: folder) { _ in .keepBoth }
        if !skipped.isEmpty {
            store.say("Not copied to \(store.alias): \(skipped.joined(separator: ", ")). Files up to 12 MB go; folders don't.")
        } else if let failure {
            store.say(failure)
        }
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
    @ObservationIgnored private var generation = 0

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
        generation += 1
        let root = within ?? root, source = source, asked = generation
        task = Task { [weak self] in
            // Typing settles first; the box stops the search before when this one starts.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.hits = []
            let result = await source.search(root, query, text: true, max: 500) { [weak self] page in
                guard self?.generation == asked else { return }
                self?.hits += page
            }
            guard !Task.isCancelled, let self, generation == asked else { return }
            running = false
            switch result {
            case .success(let found):
                (more, problem) = (found.more, nil)
                hits += found.hits
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
            box: path, alias: source.alias, standIn: standIn, read: { await source.read($0, max: nil, base: $1) },
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

    /// Files in these box folders changed: the open tabs it names read again (all of a folder
    /// said without names; one whose file didn't change costs the box a stat).
    func boxFoldersChanged(_ change: BoxChange) {
        let named = change.paths
        for tab in tabs {
            guard let file = tab.file, let path = file.box?.path else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            guard named.contains(path) || (change.folders.contains(folder) && change.names[folder] == nil) else { continue }
            file.reloadFromBox()
        }
    }
}
