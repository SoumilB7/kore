import AppKit
import KoreCore
import SwiftUI

// MARK: - Button

/// The title row's Explorer button (look §2): two documents, at the leading end over the
/// sidebar it opens. A point at its corner while files in this window have unsaved edits.
struct ExplorerButton: View {
    let workspace: Workspace
    let size: CGFloat
    @StateObject private var hovered = Local(false)

    var body: some View {
        let open = workspace.explorerOpen
        Button {
            workspace.explorerOpen.toggle()
        } label: {
            ExplorerGlyph()
                .fill(hovered.value || open ? Theme.text : Theme.secondary)
                .frame(width: Size.explorerGlyph, height: Size.explorerGlyph)
                .frame(width: size, height: size)
                .background(hovered.value || open ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(alignment: .topTrailing) {
                    if workspace.hasUnsavedFiles {
                        Circle()
                            .fill(Theme.secondary)
                            .frame(width: Size.statusPoint, height: Size.statusPoint)
                            .padding(Size.avatarCutout)
                            .background(Theme.background, in: Circle())
                            .padding(Size.statusPointInset - Size.avatarCutout)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Explorer (⇧⌘E)")
    }
}

// MARK: - Sidebar

/// The folder's tree (look §3): a header with the folder's name and actions, then the rows.
struct ExplorerSidebar: View {
    let workspace: Workspace
    let store: FilesStore
    let floating: Bool
    @FocusState private var focused: Bool
    @Environment(\.undoManager) private var undoManager
    @StateObject private var hovered = Local(false)
    /// Type to find: what's been typed, cleared after a pause or by Esc.
    @StateObject private var typed = Local("")
    /// The tree's visible height, for the empty area below the rows.
    @StateObject private var treeHeight = Local<CGFloat>(0)
    @StateObject private var typedAt = Held(Date.distantPast)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(floating ? Theme.surface : Theme.background)
        // Floating, the rows sit on the panel: their hover and selection a step above it.
        .environment(\.listGround, floating ? .surface : .window)
        .onHover { hovered.value = $0 }
    }

    private var header: some View {
        let searching = workspace.sidebar == .search
        return HStack(spacing: Space.xs) {
            Text(searching ? "Search" : workspace.folder.lastPathComponent)
                .font(Chrome.bodyMedium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(searching ? "Search in \(workspace.folder.lastPathComponent)" : workspace.folder.path)
            Spacer(minLength: Space.md)
            if searching {
                let search = workspace.searchStore()
                Group {
                    HeaderButton(symbol: "arrow.clockwise", help: "Refresh") { search.rerun() }
                    HeaderButton(symbol: "xmark.circle", help: "Clear") { search.clear() }
                    HeaderButton(
                        symbol: search.allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                        help: search.allCollapsed ? "Expand All" : "Collapse All"
                    ) { search.collapseOrExpandAll() }
                }
                .opacity(hovered.value ? 1 : 0)
            } else {
                Group {
                    // Shown only while the pointer is over the explorer: pressed through their actions.
                    HeaderButton(symbol: "doc.badge.plus", help: "New File") { store.startNew(folder: false) }
                        .storyID(StoryID.Explorer.newfile, press: { store.startNew(folder: false) })
                    HeaderButton(symbol: "folder.badge.plus", help: "New Folder") { store.startNew(folder: true) }
                        .storyID(StoryID.Explorer.newfolder, press: { store.startNew(folder: true) })
                    HeaderButton(symbol: "arrow.clockwise", help: "Refresh") { store.refresh() }
                        .storyID(StoryID.Explorer.refresh, press: { store.refresh() })
                    HeaderButton(symbol: "rectangle.compress.vertical", help: "Collapse all") { store.collapseAll() }
                        .storyID(StoryID.Explorer.collapse, press: { store.collapseAll() })
                }
                .opacity(hovered.value || focused ? 1 : 0)
            }
            // Search: the fifth icon, shown always; it swaps the tree for the Search view.
            HeaderButton(symbol: "magnifyingglass", isOn: searching, help: searching ? "Explorer (⇧⌘E)" : "Search (⇧⌘F)") {
                if searching { workspace.sidebar = .explorer } else { workspace.showSearch() }
            }
            // One toggle: back to the files while searching, else to Search.
            .storyID(searching ? StoryID.Explorer.filesTab : StoryID.Explorer.searchTab)
        }
        .padding(.horizontal, Layout.Explorer.headerInset)
        .frame(height: Layout.Explorer.header)
    }

    @ViewBuilder private var content: some View {
        if workspace.sidebar == .search {
            SearchView(workspace: workspace, store: workspace.searchStore())
        } else if !store.rootLoaded {
            DelayedSpinner().padding(.top, Layout.Explorer.stateTop)
        } else if workspace.folderLost {
            ExplorerState(message: "This folder was moved or deleted.", color: Theme.secondary, button: "Locate…") {
                workspace.locateFolder()
            }
        } else if store.rootError {
            ExplorerState(message: "Kore can't read this folder.", color: Theme.secondary, button: "Try Again") {
                workspace.followFolder()
                store.refresh()
            }
        } else if !store.hasRows {
            ExplorerState(message: "This folder is empty", color: Theme.tertiary, button: "New File") { store.startNew(folder: false) }
        } else {
            tree
        }
    }

    /// The turns' changes are read here, apart from the rows: a click, which only moves the
    /// selection, redraws the list and the rows it changed, without walking the chats again.
    private var tree: some View {
        let touches = workspace.turnTouches
        return ScrollViewReader { proxy in
            ScrollView {
                TreeList(
                    store: store, workspace: workspace, touches: touches, focused: focused, typed: typed.value,
                    height: treeHeight.value, proxy: proxy, undo: undoManager, focus: { focused = true }
                )
                .equatable()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { treeHeight.value = $0 }
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in key(press, rows: store.rows) }
            // The Edit menu's ⌘A ⌘C ⌘X ⌘V while the tree has the keys (VS Code's tree).
            .onCommand(#selector(NSResponder.selectAll(_:))) { if store.edit == nil { store.pickAll() } }
            .onCommand(#selector(NSText.copy(_:))) { TreeActions.copy(store.chosenTops, cut: false, store: store) }
            .onCommand(#selector(NSText.cut(_:))) { TreeActions.copy(store.chosenTops, cut: true, store: store) }
            .onCommand(#selector(NSText.paste(_:))) {
                TreeActions.paste(into: store.targetFolder(), store: store, workspace: workspace, undo: undoManager)
            }
            .onAppear {
                store.undo = undoManager
                DevFileHooks.explorerShown(store: store, workspace: workspace, undo: undoManager)
            }
        }
    }

    // MARK: Keys (VS Code's tree keys)

    private func key(_ press: KeyPress, rows: [FilesStore.Row]) -> KeyPress.Result {
        guard store.edit == nil else { return .ignored }
        let index = store.selection.flatMap { selection in rows.firstIndex { $0.shows(selection) } }
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
            if let index, !rows[index].isFolder { workspace.openFile(URL(fileURLWithPath: rows[index].id)) }
        case .downArrow: select((index ?? -1) + 1)
        case .upArrow: select((index ?? rows.count) - 1)
        case .rightArrow:
            guard let index, rows[index].isFolder else { return .handled }
            // A chain's next name first, as VS Code steps through compact folders.
            if let selection = store.selection, let next = rows[index].path(1, from: selection) {
                store.selection = next
            } else if rows[index].isOpen { select(index + 1) } else { store.expand(rows[index].id) }
        case .leftArrow:
            guard let index else { return .handled }
            let row = rows[index]
            if let selection = store.selection, let previous = row.path(-1, from: selection) {
                store.selection = previous
            } else if row.isFolder, row.isOpen {
                store.collapse(row.id)
            } else if let parent = rows[..<index].lastIndex(where: { $0.depth < row.depth }) {
                select(parent)
            }
        case .space:
            guard let index else { return .handled }
            let row = rows[index]
            if row.isFolder { store.toggle(row.id) } else { workspace.openFile(URL(fileURLWithPath: row.id), preview: true) }
        case .return:
            // VS Code: Return renames (a chain's chosen folder, not just its last).
            if index != nil, store.picked.isEmpty, let selection = store.selection { store.edit = .rename(selection) }
        // ⌘⌫: the key sends U+007F, which SwiftUI's `.delete` (U+0008) doesn't match.
        case _ where (press.key == .delete || press.key.character == "\u{7F}") && press.modifiers.contains(.command):
            if index != nil { TreeActions.trash(store.chosenTops, store: store, undo: undoManager) }
        case .escape where !store.picked.isEmpty:
            store.pickOnly(store.selection)
        case .escape where !typed.value.isEmpty:
            typed.value = ""
        default:
            return find(press, rows: rows, from: index) ? .handled : .ignored
        }
        return .handled
    }

    /// Typing jumps to the next row whose name starts with what's typed (VS Code's type to
    /// find, as Finder does it); a pause starts over.
    private func find(_ press: KeyPress, rows: [FilesStore.Row], from index: Int?) -> Bool {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]), !press.characters.isEmpty,
            press.characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let now = Date()
        let fresh = now.timeIntervalSince(typedAt.value) > 1
        typedAt.value = now
        let query = (fresh ? "" : typed.value) + press.characters
        // Repeating the same letter steps through the names that start with it.
        let start = fresh || query.count == 1 ? (index ?? -1) + 1 : (index ?? 0)
        let order = Array(rows[start...]) + Array(rows[..<min(start, rows.count)])
        guard let match = order.first(where: { $0.kind == .node && $0.names.last?.lowercased().hasPrefix(query.lowercased()) == true })
        else {
            typed.value = query
            return true
        }
        typed.value = query
        store.selection = match.id
        return true
    }
}

private struct HeaderButton: View {
    let symbol: String
    var isOn = false
    let help: String
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.label)
                .foregroundStyle(hovered.value || isOn ? Theme.text : Theme.secondary)
                .frame(width: Size.Tree.headerButton, height: Size.Tree.headerButton)
                .hoverFill(hovered.value || isOn, isOn ? Theme.surfaceHover : Theme.toolHover)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// Nothing for the first moments, then a spinner (look §3).
private struct DelayedSpinner: View {
    @StateObject private var shown = Local(false)

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: Size.spinner, height: Size.spinner)
            .opacity(shown.value ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                shown.value = true
            }
    }
}

private struct ExplorerState: View {
    let message: String
    let color: Color
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Space.md) {
            Text(message).font(Chrome.label).foregroundStyle(color)
            Button(button, action: action).buttonStyle(SubtleButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Layout.Explorer.stateTop)
    }
}

// MARK: - Rows

/// The rows and the space under them. Each row gets only what it shows, worked out here, so
/// a click redraws the rows whose look it changed and no others.
private struct TreeList: View, Equatable {
    let store: FilesStore
    let workspace: Workspace
    let touches: [String: Workspace.Touch]
    let focused: Bool
    let typed: String
    /// The tree's visible height, for the empty area below the rows.
    let height: CGFloat
    let proxy: ScrollViewProxy
    let undo: UndoManager?
    let focus: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.touches == b.touches && a.focused == b.focused && a.typed == b.typed && a.height == b.height
    }

    var body: some View {
        let rows = store.rows
        let selection = store.selection
        let edit = store.edit
        let active = activeGuide(rows)
        let touchedFolders = Workspace.folders(of: touches)
        let marked = store.markedFolder
        // A drag over a chain's upper name fills that name, not the rows under it.
        let target = store.dropTarget
        let dropSegment = target.flatMap { target in store.row(showing: target).flatMap { $0.id == target ? nil : target } }
        let drop = dropSegment == nil ? target : nil
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                let isSelected = store.isChosen(row)
                TreeRow(
                    row: row, store: store, workspace: workspace,
                    isSelected: isSelected,
                    editing: row.kind != .node || edit == .rename(row.id),
                    state: store.state(of: row.id),
                    focused: focused && isSelected,
                    activeGuide: active.flatMap { row.id.hasPrefix($0.path + "/") ? $0.depth : nil },
                    touch: row.isFolder ? nil : touches[row.id],
                    folderTouched: row.isFolder && touchedFolders.contains(row.id),
                    typed: selection == row.id ? typed : "",
                    marked: marked.flatMap { row.shows($0) ? $0 : nil },
                    inDropTarget: drop.map { row.id == $0 || row.id.hasPrefix($0 + "/") } ?? false,
                    dropSegment: dropSegment.flatMap { row.shows($0) ? $0 : nil },
                    // Focus with nothing selected marks where the keys start (look §3).
                    outlined: focused && selection == nil && row.id == rows.first?.id,
                    focus: focus
                )
                .equatable()
                .id(row.id)
            }
        }
        .padding(.bottom, Space.md)
        .onChange(of: selection) { _, selection in
            let pointed = store.pointed
            store.pointed = nil
            // A clicked row is in view already. The keys' and a reveal's row scrolls into view
            // at once, without a slide.
            guard let selection, selection != pointed else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { proxy.scrollTo(store.row(showing: selection)?.id ?? selection) }
        }
        // The empty part below the rows: a click there puts the keyboard in the tree
        // without selecting anything, as in VS Code.
        Button {
            focus()
        } label: {
            Color.clear
                .frame(height: max(height - CGFloat(rows.count) * Size.Tree.row - Space.md, 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityHidden(true)
        // Dropped below the rows: into the folder itself.
        .onDrop(of: [.fileURL], delegate: TreeDrop(folder: store.root, store: store, workspace: workspace, undo: undo))
    }

    /// The selected row's parent folder, whose guide is brighter.
    private func activeGuide(_ rows: [FilesStore.Row]) -> (path: String, depth: Int)? {
        guard let selection = store.selection, let row = rows.first(where: { $0.shows(selection) }) else { return nil }
        let parent = row.isFolder && row.isOpen ? row.id : store.parent(of: row.id)
        guard parent != store.root, let folder = rows.first(where: { $0.id == parent }) else { return nil }
        return (parent, folder.depth)
    }
}

/// One row; drawn again only when what it shows changes (`==`).
private struct TreeRow: View, Equatable {
    let row: FilesStore.Row
    let store: FilesStore
    let workspace: Workspace
    /// The row, or one of its chain's folders, is chosen.
    let isSelected: Bool
    /// A rename's field, or a new item's.
    let editing: Bool
    let state: GitStatus.State?
    /// Chosen while the tree has the keys.
    let focused: Bool
    let activeGuide: Int?
    /// Changed by the running or latest agent turn (look §8).
    let touch: Workspace.Touch?
    let folderTouched: Bool
    /// Type to find's text, shown on the selected row's name.
    let typed: String
    /// The folder whose name is underlined (`FilesStore.markedFolder`), when it's this row's.
    let marked: String?
    /// Under a drag: the target folder, or a row inside it.
    let inDropTarget: Bool
    /// The chain's upper folder a drag is over, when it's this row's: only its name fills.
    let dropSegment: String?
    /// The tree has focus and nothing is selected: this first row gets the focus line.
    let outlined: Bool
    /// A click puts the keyboard in the tree, as in VS Code.
    let focus: () -> Void
    @StateObject private var hovered = Local(false)
    @Environment(\.undoManager) private var undoManager
    @Environment(\.listGround) private var ground

    nonisolated static func == (a: Self, b: Self) -> Bool {
        guard a.row == b.row, a.isSelected == b.isSelected, a.editing == b.editing, a.state == b.state else { return false }
        guard a.focused == b.focused, a.activeGuide == b.activeGuide, a.touch == b.touch, a.folderTouched == b.folderTouched else {
            return false
        }
        return a.typed == b.typed && a.marked == b.marked && a.inDropTarget == b.inDropTarget && a.dropSegment == b.dropSegment
            && a.outlined == b.outlined
    }

    /// Where a drop on this row goes: into it if it's a folder, else beside it.
    private var dropFolder: String { row.isFolder ? row.id : (row.id as NSString).deletingLastPathComponent }

    var body: some View {
        let tint = state.map(Theme.Git.color)
        HStack(spacing: 0) {
            Spacer().frame(width: Size.Tree.leading + CGFloat(row.depth) * Size.Tree.indent)
            chevron
            // Folders take the icon slot too: one name column at each depth.
            FileIconView(
                name: editing ? "" : row.names[0], color: tint ?? (isSelected ? Theme.text : Theme.secondary),
                isFolder: row.isFolder)
            Spacer().frame(width: Size.Tree.iconGap)
            if editing {
                InlineNameField(row: row, store: store, workspace: workspace)
            } else {
                name(state: state)
                Spacer(minLength: Space.md)
                trailing(state)
            }
        }
        .padding(.trailing, Size.Tree.trailing)
        .frame(height: Size.Tree.row)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.chip))
        .overlay {
            if outlined {
                RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.accentLine, lineWidth: Stroke.hairline)
            }
        }
        .padding(.horizontal, Size.Tree.rowInset)
        .background(alignment: .leading) { guides }
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .onTapGesture { click() }
        // A tap gesture, not a button: one element to VoiceOver and Full Keyboard Access, a click's
        // action its own.
        .accessibilityElement(children: editing ? .contain : .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { click(count: 1, flags: []) }
        // Pressed through its action.
        .storyID(StoryID.Explorer.row(store.relative(row.id)), press: click)
        // The pointer's stand-in: no synthetic event reaches `.onHover`.
        .storyAction(StoryID.Explorer.row(store.relative(row.id)).part(.hover)) { hovered.value = true }
        // As a file URL: it drops into another folder here, or into Finder.
        .onDrag {
            // A chosen row carries the whole choice; the others only themselves.
            TreeDrag.paths = store.isChosen(row) && !store.picked.isEmpty ? store.chosenTops : [row.id]
            return NSItemProvider(object: URL(fileURLWithPath: row.id) as NSURL)
        }
        // A press that moved a few points starts a drag; dropped back on this row, it's the click.
        .onDrop(
            of: [.fileURL],
            delegate: TreeDrop(
                folder: dropFolder, store: store, workspace: workspace, undo: undoManager, row: row.id,
                click: { click(count: 1, flags: []) }))
        .koreContextMenu("explorer") {
            // A right-click outside the choice chooses just that row, as VS Code does.
            if !store.isChosen(row) { store.pickOnly(row.id) }
            return TreeMenu(path: row.id, isFolder: row.isFolder, store: store, workspace: workspace, undo: undoManager).items
        }
    }

    private var fill: Color {
        if inDropTarget { return Theme.Tree.dropTarget }
        if isSelected { return focused ? Theme.Row.selectedFocused : Theme.Row.selected(ground) }
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

    /// The name; a chain's names each select their own folder, as VS Code's compact folders do,
    /// take a drop into it and show its path, and the chosen one is underlined.
    @ViewBuilder private func name(state: GitStatus.State?) -> some View {
        let tint = state.map(Theme.Git.color)
        if row.names.count == 1 {
            Text(segment(0, tint: tint, marked: marked == row.id)).font(Chrome.body).lineLimit(1).truncationMode(.tail)
        } else {
            let paths = row.paths
            HStack(spacing: 0) {
                ForEach(paths.indices, id: \.self) { i in
                    if i > 0 { Text(" / ").foregroundStyle(Theme.tertiary) }
                    let path = paths[i]
                    let text = Text(segment(i, tint: tint, marked: marked == path)).lineLimit(1).truncationMode(.tail)
                        .background(dropSegment == path ? Theme.Tree.dropTarget : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
                        .contentShape(Rectangle())
                        .pointerStyle(.link)
                        .help(store.relative(path))
                    if i == paths.count - 1 {
                        // The last name is the row's: its clicks, menu and drops are the row's.
                        text.storyID(StoryID.Explorer.segment(store.relative(path)), press: click)
                    } else {
                        text
                            .onTapGesture { pick(path) }
                            .onDrop(of: [.fileURL], delegate: TreeDrop(folder: path, store: store, workspace: workspace, undo: undoManager))
                            .koreContextMenu("explorer") { TreeMenu(path: path, isFolder: true, store: store, workspace: workspace, undo: undoManager).items }
                            .storyID(StoryID.Explorer.segment(store.relative(path)), press: { pick(path) })
                    }
                }
            }
            .font(Chrome.body)
        }
    }

    private func segment(_ i: Int, tint: Color?, marked: Bool) -> AttributedString {
        let name = row.names[i]
        var text: AttributedString
        if i == row.names.count - 1, !typed.isEmpty, name.lowercased().hasPrefix(typed.lowercased()) {
            var matched = AttributedString(String(name.prefix(typed.count)))
            matched.foregroundColor = tint ?? Theme.accent
            matched.font = Chrome.bodySemibold
            var rest = AttributedString(String(name.dropFirst(typed.count)))
            rest.foregroundColor = tint ?? Theme.text
            text = matched + rest
        } else {
            text = AttributedString(name)
            text.foregroundColor = tint ?? Theme.text
        }
        if marked { text.underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.accent) }
        return text
    }

    @ViewBuilder private func trailing(_ state: GitStatus.State?) -> some View {
        if let touch {
            // The turn's counts take the git letter's place.
            HStack(spacing: Space.xs) {
                if touch.writing { BlinkingDot(size: Size.Tree.point) }
                if let index = touch.agentIndex {
                    AgentAvatar(index: index, name: touch.agentName ?? "", place: .crumb)
                }
                ChangeCounts(added: touch.added, removed: touch.removed, font: Chrome.captionDigits)
            }
            .help("Changed by \(touch.help)")
        } else if row.isFolder, folderTouched || (state != nil && state != .ignored) {
            Circle()
                .fill(state.map(Theme.Git.color) ?? Theme.Git.modified)
                .frame(width: Size.Tree.point, height: Size.Tree.point)
        } else if let state, state != .ignored {
            if row.isFolder {
                Circle()
                    .fill(Theme.Git.color(state))
                    .frame(width: Size.Tree.point, height: Size.Tree.point)
            } else if let letter = Theme.Git.letter(state) {
                Text(letter)
                    .font(Chrome.captionStrong)
                    .foregroundStyle(Theme.Git.color(state))
                    .frame(width: Size.Tree.letterBox)
            }
        }
    }

    /// 1pt lines at each ancestor's chevron centre.
    private var guides: some View {
        Canvas { context, size in
            for depth in 0..<row.depth {
                let x = Size.Tree.rowInset + Size.Tree.leading + CGFloat(depth) * Size.Tree.indent + Size.Tree.chevronBox / 2
                let line = Path(CGRect(x: x, y: 0, width: Stroke.hairline, height: size.height))
                context.fill(line, with: .color(depth == activeGuide ? Theme.Tree.guideActive : Theme.Tree.guide))
            }
        }
        .allowsHitTesting(false)
    }

    /// One click selects (a folder opens or closes; a file opens in the preview tab); the
    /// second click of a double click keeps the file's tab and puts the caret in it. The count
    /// comes from the event, as AppKit sends both clicks.
    private func click() {
        click(count: NSApp.mouseClickCount, flags: NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [])
    }

    /// A chain's upper folder: selected (underlined), the row left open as it is.
    private func pick(_ path: String) {
        guard !editing else { return }
        focus()
        store.pointed = path
        store.pickOnly(path)
    }

    private func click(count: Int, flags: NSEvent.ModifierFlags) {
        guard !editing else { return }
        focus()
        store.pointed = row.id
        // ⌘ adds or drops this row, ⇧ takes the rows from the anchor (VS Code's tree).
        if flags.contains(.command) { return store.pickToggle(row.id) }
        if flags.contains(.shift) { return store.pickRange(to: row.id) }
        store.pickOnly(row.id)
        if row.isFolder {
            // Every click opens or closes it, the quick second and third of a run too.
            store.toggle(row.id)
        } else if count >= 2 {
            workspace.openFile(URL(fileURLWithPath: row.id), preview: false)
            workspace.activeFile?.editor.focus()
        } else {
            workspace.openFile(URL(fileURLWithPath: row.id), preview: true)
        }
    }
}

/// The name field for a new file or folder, or a rename (look §3).
private struct InlineNameField: View {
    let row: FilesStore.Row
    let store: FilesStore
    let workspace: Workspace
    @StateObject private var name = Local("")
    @StateObject private var done = Held(false)
    @FocusState private var focused: Bool
    @Environment(\.undoManager) private var undoManager

    private var folder: String {
        switch store.edit {
        case .newFile(let parent), .newFolder(let parent): parent
        case .rename(let path): store.parent(of: path)
        case nil: store.root
        }
    }

    private var failure: FilesStore.Failure? {
        guard !name.value.isEmpty else { return nil }
        if case .rename(let path) = store.edit {
            let target = folder + "/" + name.value
            return target.lowercased() == path.lowercased() ? nil : store.clash(name.value, in: folder)
        }
        return store.clash(name.value, in: folder)
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
                    Text(failure.message)
                        .font(Chrome.caption)
                        .foregroundStyle(Theme.text)
                        .padding(Inset.row)
                        .panel(.panel)
                        .fixedSize()
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
        if value.isEmpty {
            cancel()
            return
        }
        if failure != nil { return }
        done.value = true
        let result: Result<String, FilesStore.Failure>
        var newFile = false
        switch edit {
        case .newFile(let parent):
            result = store.create(value, folder: false, in: parent)
            newFile = true
        case .newFolder(let parent):
            result = store.create(value, folder: true, in: parent)
        case .rename(let path):
            result = store.rename(path, to: value)
            if case .success(let target) = result { workspace.renamed(path, to: target) }
        }
        store.edit = nil
        switch result {
        case .success(let path):
            recordUndo(edit, made: path)
            store.selection = path
            if newFile {
                workspace.openFile(URL(fileURLWithPath: path))
                // An empty new file is for writing: its text, not a renderer's view (a .md's preview).
                workspace.activeFile?.showsRaw = true
                workspace.activeFile?.editor.focus()
            }
        case .failure(let failure):
            TreeActions.show(failure)
        }
    }

    /// ⌘Z for a rename (back to the old name) or a new item (to the Trash).
    private func recordUndo(_ edit: FilesStore.Edit, made path: String) {
        let (store, workspace, undo) = (store, workspace, undoManager)
        switch edit {
        case .rename(let old) where old != path:
            Self.recordRename(from: old, to: path, store: store, workspace: workspace, undo: undo)
        case .newFile, .newFolder:
            Self.recordNew(path, store: store, undo: undo)
        default:
            break
        }
    }

    private static func recordRename(from old: String, to new: String, store: FilesStore, workspace: Workspace, undo: UndoManager?) {
        let oldName = (old as NSString).lastPathComponent
        let newName = (new as NSString).lastPathComponent
        TreeActions.record("Rename", undo: undo, store: store, back: {
            switch store.rename(new, to: oldName) {
            case .success(let back): workspace.renamed(new, to: back); return nil
            case .failure(let failure): return failure
            }
        }) {
            switch store.rename(old, to: newName) {
            case .success(let again):
                workspace.renamed(old, to: again)
                recordRename(from: old, to: again, store: store, workspace: workspace, undo: undo)
                return nil
            case .failure(let failure): return failure
            }
        }
    }

    private static func recordNew(_ path: String, store: FilesStore, undo: UndoManager?) {
        var trashed: [FilesStore.Trashed] = []
        TreeActions.record("New", undo: undo, store: store, back: {
            let result = store.trash([path])
            trashed = result.done
            return result.failure
        }) {
            let failure = store.restore(trashed)
            recordNew(path, store: store, undo: undo)
            return failure
        }
    }
}

// MARK: - Actions

@MainActor private struct TreeMenu {
    let path: String
    let isFolder: Bool
    let store: FilesStore
    let workspace: Workspace
    let undo: UndoManager?

    var items: [OptionItem] {
        let chosen = store.chosenTops
        // Several chosen: only what applies to all of them.
        if chosen.count > 1 {
            return [
                OptionItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen.map { URL(fileURLWithPath: $0) }) },
                OptionItem("Compress \(chosen.count) Items") { Task { if let failure = await store.compress(chosen) { TreeActions.show(failure) } } }, .rule,
                OptionItem("Cut") { TreeActions.copy(chosen, cut: true, store: store) },
                OptionItem("Copy") { TreeActions.copy(chosen, cut: false, store: store) },
                OptionItem("Duplicate") { TreeActions.duplicate(chosen, store: store, workspace: workspace, undo: undo) }, .rule,
                OptionItem("Copy Paths") { TreeActions.copy(chosen.joined(separator: "\n")) },
                OptionItem("Copy Relative Paths") { TreeActions.copy(chosen.map(store.relative).joined(separator: "\n")) }, .rule,
                OptionItem("Move \(chosen.count) Items to Trash", destructive: true) { TreeActions.trash(chosen, store: store, undo: undo) },
            ]
        }
        let folder = isFolder ? path : store.parent(of: path)
        var items: [OptionItem] = [
            OptionItem("New File…") { store.pickOnly(path); store.startNew(folder: false) },
            OptionItem("New Folder…") { store.pickOnly(path); store.startNew(folder: true) }, .rule,
        ]
        if !isFolder {
            items += [OptionItem("Open") { workspace.openFile(URL(fileURLWithPath: path)) },
                      OptionItem("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }]
        }
        items += [
            OptionItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            OptionItem("Open in Terminal") { workspace.terminals.newShell(folder: URL(fileURLWithPath: folder)) },
        ]
        if isFolder { items.append(OptionItem("Find in Folder…") { TreeActions.find(in: path, store: store, workspace: workspace) }) }
        items += [
            OptionItem("Compress") { Task { if let failure = await store.compress([path]) { TreeActions.show(failure) } } }, .rule,
            OptionItem("Cut") { TreeActions.copy([path], cut: true, store: store) },
            OptionItem("Copy") { TreeActions.copy([path], cut: false, store: store) },
        ]
        if TreeActions.canPaste(store: store) {
            items.append(OptionItem("Paste") { TreeActions.paste(into: folder, store: store, workspace: workspace, undo: undo) })
        }
        items += [
            OptionItem("Duplicate") { TreeActions.duplicate([path], store: store, workspace: workspace, undo: undo) }, .rule,
            OptionItem("Copy Path") { TreeActions.copy(path) },
            OptionItem("Copy Relative Path") { TreeActions.copy(store.relative(path)) }, .rule,
            OptionItem("Rename…") { store.edit = .rename(path) },
            OptionItem("Move to Trash", destructive: true) { TreeActions.trash([path], store: store, undo: undo) },
        ]
        return items
    }
}

/// The rows a drag from the tree carries: SwiftUI's drag holds one file, so the rest of a
/// chosen set waits here for the drop that takes it.
@MainActor enum TreeDrag {
    static var paths: [String] = []

    /// The dropped files, widened to the whole chosen set when the drag started on one of them.
    static func expand(_ urls: [URL]) -> [URL] {
        guard urls.count == 1, paths.count > 1, paths.contains(urls[0].path) else { return urls }
        defer { paths = [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }
}

@MainActor
enum TreeActions {
    /// The pasteboard: a storyline host's own, so a run never touches the user's.
    static var board: NSPasteboard { DraftClipboard.pasteboard }

    static func copy(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    // MARK: Trash

    /// One question for all of `paths`, then the Trash; one undo brings them all back.
    static func trash(_ paths: [String], store: FilesStore, undo: UndoManager?) {
        guard !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? "Are you sure you want to delete “\((paths[0] as NSString).lastPathComponent)”?"
            : "Are you sure you want to delete the following \(paths.count) items?"
        alert.informativeText = (paths.count == 1 ? "" : paths.prefix(10).map { ($0 as NSString).lastPathComponent }.joined(separator: "\n") + "\n\n")
            + "You can restore \(paths.count == 1 ? "it" : "them") from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard StorylineSeams.confirm?("trash") ?? (alert.runModal() == .alertFirstButtonReturn) else { return }
        let result = store.trash(paths)
        if let failure = result.failure { show(failure) }
        recordTrash(result.done, store: store, undo: undo)
    }

    private static func recordTrash(_ done: [FilesStore.Trashed], store: FilesStore, undo: UndoManager?) {
        guard !done.isEmpty else { return }
        record("Move to Trash", undo: undo, store: store, back: { store.restore(done) }) {
            let again = store.trash(done.map(\.path))
            recordTrash(again.done, store: store, undo: undo)
            return again.failure
        }
    }

    /// Registers an undo that runs `back`, whose redo runs `forward` (which registers the
    /// next undo itself, as a redo makes new things).
    static func record(
        _ name: String, undo: UndoManager?, store: FilesStore,
        back: @escaping @MainActor () -> FilesStore.Failure?, forward: @escaping @MainActor () -> FilesStore.Failure?
    ) {
        guard let undo else { return }
        undo.registerUndo(withTarget: store) { store in
            MainActor.assumeIsolated {
                if let failure = back() { show(failure) }
                undo.registerUndo(withTarget: store) { _ in
                    MainActor.assumeIsolated { if let failure = forward() { show(failure) } }
                }
                undo.setActionName(name)
            }
        }
        undo.setActionName(name)
    }

    // MARK: Cut, copy, paste, duplicate

    /// ⌘C / ⌘X: the files on the pasteboard (Finder can paste them too) and kept for ⌘V.
    static func copy(_ paths: [String], cut: Bool, store: FilesStore) {
        guard !paths.isEmpty else { return }
        board.clearContents()
        board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        store.clipboard = (paths, cut)
    }

    static func canPaste(store: FilesStore) -> Bool {
        board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// ⌘V into `folder`: the pasteboard's files, moved after a cut in the tree, copied
    /// otherwise; a taken name gets " copy", as Finder does. One undo.
    static func paste(into folder: String, store: FilesStore, workspace: Workspace, undo: UndoManager?) {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let paths = urls.map { realPath($0.path) }
        guard !paths.isEmpty else { return }
        let cut = store.clipboard.map { $0.cut && Set($0.paths) == Set(paths) } ?? false
        Task {
            let result = await store.transfer(paths, into: folder, copy: !cut, collision: { _ in .keepBoth }, moved: workspace.renamed)
            if let failure = result.failure { show(failure) }
            // A cut pastes once; a copy can paste again.
            if cut, !result.done.isEmpty { store.clipboard = nil; board.clearContents() }
            registerUndo(result.done, store: store, workspace: workspace, undo: undo)
        }
    }

    /// Duplicate: a copy beside each, named " copy". One undo.
    static func duplicate(_ paths: [String], store: FilesStore, workspace: Workspace, undo: UndoManager?) {
        Task {
            var done: [FilesStore.Transfer] = []
            for path in paths {
                let result = await store.transfer(
                    [path], into: store.parent(of: path), copy: true, collision: { _ in .keepBoth }, moved: workspace.renamed)
                if let failure = result.failure { show(failure) }
                done += result.done
            }
            registerUndo(done, store: store, workspace: workspace, undo: undo)
        }
    }

    /// From outside the folder (Finder, another app): a drop copies, as in VS Code.
    static func fromOutside(_ paths: [String], store: FilesStore) -> Bool {
        paths.contains { !$0.hasPrefix(store.root + "/") }
    }

    // MARK: Find in Folder

    /// Search, its files to include set to this folder.
    static func find(in folder: String, store: FilesStore, workspace: Workspace) {
        let search = workspace.searchStore()
        search.include = folder == store.root ? "" : "./" + store.relative(folder) + "/**"
        if !search.include.isEmpty { search.showsDetails = true }
        workspace.showSearch()
    }

    // MARK: Dropping

    /// Moves (or with ⌥, or from outside the folder, copies) `sources` into `folder`, as VS
    /// Code does: a drop of several asks first, a taken name asks Replace / Keep Both / Cancel,
    /// open tabs follow, and it's one undo.
    static func drop(
        _ sources: [String], into folder: String, copy: Bool, store: FilesStore, workspace: Workspace, undo: UndoManager?,
        answer: FilesStore.Collision? = nil
    ) {
        let sources = sources.filter { store.canDrop($0, into: folder, copy: copy) }
        guard !sources.isEmpty else { return }
        let folderName = folder == store.root ? (folder as NSString).lastPathComponent : store.relative(folder)
        if sources.count > 1, answer == nil {
            let alert = NSAlert()
            alert.messageText = "\(copy ? "Copy" : "Move") \(sources.count) items into “\(folderName)”?"
            alert.addButton(withTitle: copy ? "Copy" : "Move")
            alert.addButton(withTitle: "Cancel")
            guard StorylineSeams.confirm?(copy ? "copy" : "move") ?? (alert.runModal() == .alertFirstButtonReturn) else { return }
        }
        Task { await transfer(sources, into: folder, folderName: folderName, copy: copy, store: store, workspace: workspace, undo: undo, answer: answer) }
    }

    private static func transfer(
        _ sources: [String], into folder: String, folderName: String, copy: Bool, store: FilesStore, workspace: Workspace,
        undo: UndoManager?, answer: FilesStore.Collision?
    ) async {
        var always = answer
        let result = await store.transfer(sources, into: folder, copy: copy, collision: { name in
            if let always { return always }
            let alert = NSAlert()
            alert.messageText = "“\(name)” already exists in “\(folderName)”."
            alert.informativeText = "Replacing it moves the one that's there to the Trash."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Cancel")
            if sources.count > 1 {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Apply to all"
            }
            let choice: FilesStore.Collision = switch alert.runModal() {
            case .alertFirstButtonReturn: .replace
            case .alertSecondButtonReturn: .keepBoth
            default: .cancel
            }
            if alert.suppressionButton?.state == .on { always = choice }
            return choice
        }, moved: workspace.renamed)
        if let failure = result.failure { show(failure) }
        registerUndo(result.done, store: store, workspace: workspace, undo: undo)
    }

    private static func registerUndo(_ done: [FilesStore.Transfer], store: FilesStore, workspace: Workspace, undo: UndoManager?) {
        guard let undo, !done.isEmpty else { return }
        undo.registerUndo(withTarget: store) { store in
            MainActor.assumeIsolated {
                if let failure = store.undo(done, moved: workspace.renamed) { show(failure) }
                undo.registerUndo(withTarget: store) { store in
                    MainActor.assumeIsolated {
                        let again = store.redo(done, moved: workspace.renamed)
                        if let failure = again.failure { show(failure) }
                        registerUndo(again.done, store: store, workspace: workspace, undo: undo)
                    }
                }
            }
        }
        undo.setActionName(done.first?.copied == true ? "Copy" : "Move")
    }

    static func show(_ failure: FilesStore.Failure) {
        let alert = NSAlert()
        alert.messageText = failure.message
        alert.runModal()
    }
}

// MARK: - Resizing

/// The divider between the sidebar and the content: drag to resize, double-click for 260.
struct ExplorerSash: View {
    @Binding var width: CGFloat

    var body: some View {
        PaneSash(width: $width, range: Layout.Explorer.minWidth...Layout.Explorer.maxWidth) { width = Layout.Explorer.width }
    }
}

/// A row (or the space under the rows) as a drop target: it and its open rows fill while a drag
/// is over it, and the drop moves or copies into its folder.
private struct TreeDrop: DropDelegate {
    let folder: String
    let store: FilesStore
    let workspace: Workspace
    let undo: UndoManager?
    /// The row it's on, and its click: a drag from the row dropped back on it is a click whose
    /// press moved a few points (AppKit started a drag, and the tap was lost).
    var row: String?
    var click: (@MainActor () -> Void)?

    /// The drag started on this row alone: nothing fills, as it can't go anywhere.
    private var fromHere: Bool { row != nil && TreeDrag.paths == [row] }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        if !fromHere { store.dropTarget = folder }
    }

    func dropExited(info: DropInfo) {
        if store.dropTarget == folder { store.dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !fromHere, store.dropTarget != folder { store.dropTarget = folder }
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.dropTarget = nil
        let option = NSEvent.modifierFlags.contains(.option)
        let providers = info.itemProviders(for: [.fileURL])
        let (folder, store, workspace, undo, row, click) = (folder, store, workspace, undo, row, click)
        Task { @MainActor in
            var paths: [String] = []
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.url(provider) { urls.append(url) }
            }
            if let row, let click, TreeDrag.paths == [row], urls.count == 1, realPath(urls[0].path) == row {
                TreeDrag.paths = []
                return click()
            }
            paths = TreeDrag.expand(urls).map { realPath($0.path) }
            TreeActions.drop(paths, into: folder, copy: option || TreeActions.fromOutside(paths, store: store), store: store, workspace: workspace, undo: undo)
        }
        return true
    }

    private static func url(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
    }
}

// MARK: - Storylines

extension Workspace {
    /// The tree's chosen rows, relative to the folder, in the tree's order.
    package var storyTreeChosen: [String] { files.map { store in store.chosen.map(store.relative) } ?? [] }

    /// Where `title` sits in the tree's menu for the row at `relativePath` (rules counted), as
    /// a right-click there would show it now.
    package func storyTreeMenuIndex(_ relativePath: String, _ title: String) -> Int? {
        guard let store = files else { return nil }
        let path = realPath(folder.appendingPathComponent(relativePath).path)
        let isFolder = store.row(showing: path)?.isFolder ?? false
        return TreeMenu(path: path, isFolder: isFolder, store: store, workspace: self, undo: store.undo).items.firstIndex { $0.title == title }
    }

    /// Drops the chosen rows on the folder at `relativePath`, as a drag that starts on one of
    /// them does (SwiftUI's drag isn't driven by synthetic events).
    package func storyTreeDragChosen(into relativePath: String) {
        guard let store = files, let first = store.chosenTops.first else { return }
        TreeDrag.paths = store.chosenTops
        let sources = TreeDrag.expand([URL(fileURLWithPath: first)]).map(\.path)
        let target = relativePath.isEmpty ? store.root : realPath(folder.appendingPathComponent(relativePath).path)
        TreeActions.drop(sources, into: target, copy: false, store: store, workspace: self, undo: store.undo)
    }

    /// Drops files from outside the folder (as from Finder) on the folder at `relativePath`.
    package func storyTreeDropFromOutside(_ paths: [String], into relativePath: String) {
        guard let store = files else { return }
        let target = relativePath.isEmpty ? store.root : realPath(folder.appendingPathComponent(relativePath).path)
        let sources = paths.map(realPath)
        TreeActions.drop(sources, into: target, copy: TreeActions.fromOutside(sources, store: store), store: store, workspace: self, undo: store.undo)
    }

    /// ⌘Z and ⇧⌘Z on the window's undo manager.
    package func storyUndo() { files?.undo?.undo() }
    package func storyRedo() { files?.undo?.redo() }

    /// Search's files to include.
    package var storySearchInclude: String? { search?.include }

    /// The active terminal's starting folder.
    package var storyTerminalFolder: String? { terminals.active?.shell?.folder.path }
}
