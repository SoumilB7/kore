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
    @StateObject private var hovered = Local(false)
    /// Type to find: what's been typed, cleared after a pause or by Esc.
    @StateObject private var typed = Local("")
    @StateObject private var typedAt = Held(Date.distantPast)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(floating ? Theme.surface : Theme.background)
        .onHover { hovered.value = $0 }
    }

    private var header: some View {
        HStack(spacing: Space.xs) {
            Text(workspace.folder.lastPathComponent)
                .font(Chrome.bodyMedium)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(workspace.folder.path)
            Spacer(minLength: Space.md)
            Group {
                HeaderButton(symbol: "doc.badge.plus", help: "New File") { store.startNew(folder: false) }
                HeaderButton(symbol: "folder.badge.plus", help: "New Folder") { store.startNew(folder: true) }
                HeaderButton(symbol: "arrow.clockwise", help: "Refresh Explorer") { store.refresh() }
                HeaderButton(symbol: "rectangle.compress.vertical", help: "Collapse Folders in Explorer") { store.collapseAll() }
            }
            .opacity(hovered.value || focused ? 1 : 0)
        }
        .padding(.horizontal, Layout.Explorer.headerInset)
        .frame(height: Layout.Explorer.header)
    }

    @ViewBuilder private var content: some View {
        if !store.rootLoaded {
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
                            focus: { focused = true }
                        )
                        .id(row.id)
                    }
                }
                .padding(.bottom, Space.md)
            }
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in key(press, rows: rows) }
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
    let help: String
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.label)
                .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                .frame(width: Size.Tree.headerButton, height: Size.Tree.headerButton)
                .hoverFill(hovered.value, Theme.toolHover)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(help)
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
    /// A click puts the keyboard in the tree, as in VS Code.
    let focus: () -> Void
    @StateObject private var hovered = Local(false)

    private var isSelected: Bool { store.selection == row.id }
    private var editing: Bool {
        if row.kind != .node { return true }
        return store.edit == .rename(row.id)
    }

    var body: some View {
        let state = store.state(of: row.id)
        let ignored = state == .ignored
        HStack(spacing: 0) {
            Spacer().frame(width: Size.Tree.leading + CGFloat(row.depth) * Size.Tree.indent)
            chevron
            if !row.isFolder {
                FileIconView(name: editing ? "" : row.names[0], color: ignored ? Theme.tertiary : (isSelected ? Theme.text : Theme.secondary))
                Spacer().frame(width: Size.Tree.iconGap)
            }
            if editing {
                InlineNameField(row: row, store: store, workspace: workspace)
            } else {
                name(ignored: ignored)
                Spacer(minLength: Space.md)
                trailing(state)
            }
        }
        .padding(.trailing, Size.Tree.trailing)
        .frame(height: Size.Tree.row)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.chip))
        .padding(.horizontal, Size.Tree.rowInset)
        .background(alignment: .leading) { guides }
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .onTapGesture { click() }
        .contextMenu { TreeMenu(path: row.id, isFolder: row.isFolder, store: store, workspace: workspace) }
        .help(row.names.count > 1 ? row.names.joined(separator: "/") : "")
    }

    private var fill: Color {
        if isSelected { return focused ? Theme.Tree.selectedFocused : Theme.Tree.selected }
        return hovered.value ? Theme.Tree.hover : .clear
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

    private func name(ignored: Bool) -> some View {
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
                matched.foregroundColor = Theme.accent
                matched.font = Chrome.bodySemibold
                var rest = AttributedString(String(name.dropFirst(typed.count)))
                rest.foregroundColor = ignored ? Theme.tertiary : Theme.text
                text += matched + rest
            } else {
                var part = AttributedString(name)
                part.foregroundColor = ignored ? Theme.tertiary : Theme.text
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
            .help("Changed this turn · \(touch.help)")
        } else if row.isFolder, folderTouched || (state != nil && state != .ignored) {
            Circle()
                .fill(state == .conflicted ? Theme.danger : Theme.accent)
                .frame(width: Size.Tree.point, height: Size.Tree.point)
        } else if let state, state != .ignored {
            if row.isFolder {
                Circle()
                    .fill(state == .conflicted ? Theme.danger : Theme.accent)
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
        guard !editing else { return }
        let double = (NSApp.currentEvent?.clickCount ?? 1) >= 2
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

private struct TreeMenu: View {
    let path: String
    let isFolder: Bool
    let store: FilesStore
    let workspace: Workspace

    var body: some View {
        Button("New File…") {
            store.selection = path
            store.startNew(folder: false)
        }
        Button("New Folder…") {
            store.selection = path
            store.startNew(folder: true)
        }
        Divider()
        if !isFolder {
            Button("Open") { workspace.openFile(URL(fileURLWithPath: path)) }
            Button("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Divider()
        Button("Copy Path") { TreeActions.copy(path) }
        Button("Copy Relative Path") { TreeActions.copy(store.relative(path)) }
        Divider()
        Button("Rename…") { store.edit = .rename(path) }
        Button("Move to Trash") { TreeActions.trash(path, store: store) }
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
    @StateObject private var hot = Local(false)
    @StateObject private var start = Held<CGFloat?>(nil)
    @StateObject private var hover = Held<Task<Void, Never>?>(nil)

    var body: some View {
        Rectangle()
            .fill(hot.value ? Theme.accentLine : Theme.border)
            .frame(width: Stroke.hairline)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: Layout.Explorer.sashHit)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hover.value?.cancel()
                        if inside {
                            NSCursor.resizeLeftRight.push()
                            hover.value = Task {
                                try? await Task.sleep(for: .seconds(Motion.sashHover))
                                if !Task.isCancelled { hot.value = true }
                            }
                        } else {
                            NSCursor.pop()
                            hot.value = false
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let base = start.value ?? width
                                start.value = base
                                width = min(max(base + drag.translation.width, Layout.Explorer.minWidth), Layout.Explorer.maxWidth)
                            }
                            .onEnded { _ in start.value = nil }
                    )
                    .onTapGesture(count: 2) { width = Layout.Explorer.width }
            }
    }
}
