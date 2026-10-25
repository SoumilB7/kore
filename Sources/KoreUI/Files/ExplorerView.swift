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
        } else if store.rootError {
            ExplorerState(message: "Kore can't read this folder.", color: Theme.secondary, button: "Try Again") { store.refresh() }
        } else if store.rows.isEmpty {
            ExplorerState(message: "This folder is empty", color: Theme.tertiary, button: "New File") { store.startNew(folder: false) }
        } else {
            tree
        }
    }

    private var tree: some View {
        let rows = store.rows
        let active = activeGuide(rows)
        let touches = workspace.turnTouches
        let touchedFolders = Workspace.folders(of: touches)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        TreeRow(
                            row: row, store: store, workspace: workspace, focused: focused,
                            activeGuide: active.flatMap { row.id.hasPrefix($0.path + "/") ? $0.depth : nil },
                            touch: row.isFolder ? nil : touches[row.id],
                            folderTouched: row.isFolder && touchedFolders.contains(row.id),
                            typed: store.selection == row.id ? typed.value : "",
                            // Focus with nothing selected marks where the keys start (look §3).
                            outlined: focused && store.selection == nil && row.id == rows.first?.id,
                            focus: { focused = true }
                        )
                        .id(row.id)
                    }
                }
                .padding(.bottom, Space.md)
                // The empty part below the rows: a click there puts the keyboard in the tree
                // without selecting anything, as in VS Code.
                Button {
                    focused = true
                } label: {
                    Color.clear
                        .frame(height: max(treeHeight.value - CGFloat(rows.count) * Size.Tree.row - Space.md, 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHidden(true)
                // Dropped below the rows: into the folder itself.
                .onDrop(of: [.fileURL], delegate: TreeDrop(folder: store.root, store: store, workspace: workspace, undo: undoManager))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { treeHeight.value = $0 }
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in key(press, rows: rows) }
            .onAppear { DevFileHooks.explorerShown(store: store, workspace: workspace, undo: undoManager) }
            .onChange(of: store.selection) { _, selection in
                if let selection { withAnimation(Motion.fade) { proxy.scrollTo(selection) } }
            }
        }
    }

    /// The selected row's parent folder, whose guide is brighter.
    private func activeGuide(_ rows: [FilesStore.Row]) -> (path: String, depth: Int)? {
        guard let selection = store.selection, let row = rows.first(where: { $0.id == selection }) else { return nil }
        let parent = row.isFolder && row.isOpen ? row.id : store.parent(of: row.id)
        guard parent != store.root, let folder = rows.first(where: { $0.id == parent }) else { return nil }
        return (parent, folder.depth)
    }

    // MARK: Keys (VS Code's tree keys)

    private func key(_ press: KeyPress, rows: [FilesStore.Row]) -> KeyPress.Result {
        guard store.edit == nil else { return .ignored }
        let index = store.selection.flatMap { selection in rows.firstIndex { $0.id == selection } }
        func select(_ i: Int) {
            guard rows.indices.contains(i) else { return }
            store.selection = rows[i].id
        }
        switch press.key {
        case .downArrow where press.modifiers.contains(.command):
            if let index, !rows[index].isFolder { workspace.openFile(URL(fileURLWithPath: rows[index].id)) }
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
            if row.isFolder { store.toggle(row.id) } else { workspace.openFile(URL(fileURLWithPath: row.id), preview: true) }
        case .return:
            // VS Code: Return renames.
            if let index { store.edit = .rename(rows[index].id) }
        case .delete where press.modifiers.contains(.command):
            if let index { TreeActions.trash(rows[index].id, store: store) }
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

private struct TreeRow: View {
    let row: FilesStore.Row
    let store: FilesStore
    let workspace: Workspace
    let focused: Bool
    let activeGuide: Int?
    /// Changed by the running or latest agent turn (look §8).
    let touch: Workspace.Touch?
    let folderTouched: Bool
    /// Type to find's text, shown on the selected row's name.
    let typed: String
    /// The tree has focus and nothing is selected: this first row gets the focus line.
    var outlined = false
    /// A click puts the keyboard in the tree, as in VS Code.
    let focus: () -> Void
    @StateObject private var hovered = Local(false)
    @Environment(\.undoManager) private var undoManager
    @Environment(\.listGround) private var ground

    private var isSelected: Bool { store.selection == row.id }

    /// Where a drop on this row goes: into it if it's a folder, else beside it.
    private var dropFolder: String { row.isFolder ? row.id : (row.id as NSString).deletingLastPathComponent }

    /// Under a drag: the target folder, or a row inside it.
    private var inDropTarget: Bool {
        guard let target = store.dropTarget else { return false }
        return row.id == target || row.id.hasPrefix(target + "/")
    }
    private var editing: Bool {
        if row.kind != .node { return true }
        return store.edit == .rename(row.id)
    }

    var body: some View {
        let state = store.state(of: row.id)
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
        .accessibilityAction { click(double: false) }
        // Pressed through its action.
        .storyID(StoryID.Explorer.row(store.relative(row.id)), press: click)
        // The pointer's stand-in: no synthetic event reaches `.onHover`.
        .storyAction(StoryID.Explorer.row(store.relative(row.id)).part(.hover)) { hovered.value = true }
        // As a file URL: it drops into another folder here, or into Finder.
        .onDrag {
            NSItemProvider(object: URL(fileURLWithPath: row.id) as NSURL)
        }
        .onDrop(of: [.fileURL], delegate: TreeDrop(folder: dropFolder, store: store, workspace: workspace, undo: undoManager))
        .koreContextMenu("explorer") { TreeMenu(path: row.id, isFolder: row.isFolder, store: store, workspace: workspace).items }
        .help(row.names.count > 1 ? row.names.joined(separator: "/") : "")
    }

    private var fill: Color {
        if inDropTarget { return Theme.Tree.dropTarget }
        if isSelected { return focused ? Theme.Row.selectedFocused : Theme.Row.selected(ground) }
        return hovered.value ? Theme.Row.hover(ground) : .clear
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

    private func name(state: GitStatus.State?) -> some View {
        let tint = state.map(Theme.Git.color)
        var text = AttributedString()
        for (i, name) in row.names.enumerated() {
            if i > 0 {
                var separator = AttributedString(" / ")
                separator.foregroundColor = Theme.tertiary
                text += separator
            }
            let last = i == row.names.count - 1
            if last, !typed.isEmpty, name.lowercased().hasPrefix(typed.lowercased()) {
                var matched = AttributedString(String(name.prefix(typed.count)))
                matched.foregroundColor = tint ?? Theme.accent
                matched.font = Chrome.bodySemibold
                var rest = AttributedString(String(name.dropFirst(typed.count)))
                rest.foregroundColor = tint ?? Theme.text
                text += matched + rest
            } else {
                var part = AttributedString(name)
                part.foregroundColor = tint ?? Theme.text
                text += part
            }
        }
        return Text(text).font(Chrome.body).lineLimit(1).truncationMode(.tail)
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
    private func click() { click(double: NSApp.mouseClickCount >= 2) }

    private func click(double: Bool) {
        guard !editing else { return }
        focus()
        store.selection = row.id
        if row.isFolder {
            if !double { store.toggle(row.id) }
        } else if double {
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
            store.selection = path
            if newFile {
                workspace.openFile(URL(fileURLWithPath: path))
                workspace.activeFile?.editor.focus()
            }
        case .failure(let failure):
            TreeActions.show(failure)
        }
    }
}

// MARK: - Actions

@MainActor private struct TreeMenu {
    let path: String
    let isFolder: Bool
    let store: FilesStore
    let workspace: Workspace

    var items: [OptionItem] {
        var items: [OptionItem] = [
            OptionItem("New File…") { store.selection = path; store.startNew(folder: false) },
            OptionItem("New Folder…") { store.selection = path; store.startNew(folder: true) }, .rule,
        ]
        if !isFolder {
            items += [OptionItem("Open") { workspace.openFile(URL(fileURLWithPath: path)) },
                      OptionItem("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }]
        }
        items += [
            OptionItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }, .rule,
            OptionItem("Copy Path") { TreeActions.copy(path) },
            OptionItem("Copy Relative Path") { TreeActions.copy(store.relative(path)) }, .rule,
            OptionItem("Rename…") { store.edit = .rename(path) },
            OptionItem("Move to Trash", destructive: true) { TreeActions.trash(path, store: store) },
        ]
        return items
    }
}

@MainActor
enum TreeActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func trash(_ path: String, store: FilesStore) {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to delete “\((path as NSString).lastPathComponent)”?"
        alert.informativeText = "You can restore it from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let failure = store.trash(path) { show(failure) }
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
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var always = answer
        let result = store.transfer(sources, into: folder, copy: copy, collision: { name in
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

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) { store.dropTarget = folder }

    func dropExited(info: DropInfo) {
        if store.dropTarget == folder { store.dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if store.dropTarget != folder { store.dropTarget = folder }
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.dropTarget = nil
        let option = NSEvent.modifierFlags.contains(.option)
        let providers = info.itemProviders(for: [.fileURL])
        let (folder, store, workspace, undo) = (folder, store, workspace, undo)
        Task { @MainActor in
            var paths: [String] = []
            for provider in providers {
                if let url = await Self.url(provider) { paths.append(realPath(url.path)) }
            }
            // From outside the folder (Finder, another app): a copy, as in VS Code.
            let outside = paths.contains { !$0.hasPrefix(store.root + "/") }
            TreeActions.drop(paths, into: folder, copy: option || outside, store: store, workspace: workspace, undo: undo)
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
