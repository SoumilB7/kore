import HostClient
import SwiftUI

/// The left panel's switch, at its header's left end: Files ⇄ Boxes. Tinted while Boxes shows. A
/// box's window shows only Boxes, so there it stays on.
struct BoxesSwitch: View {
    let workspace: Workspace

    var body: some View {
        let on = workspace.showsBoxes
        HeaderButton(symbol: "server.rack", isOn: on, tint: Theme.accent, help: on ? "Files" : "Boxes") {
            guard workspace.box == nil else { return }
            workspace.showsBoxes.toggle()
        }
    }
}

/// Boxes in the left panel: a row per box (its status dot and name); opened, it asks the box for
/// its folders, and a folder opens in its own window. Add a box… at the end. Nothing dials until a
/// row opens.
struct BoxesPanel: View {
    let workspace: Workspace
    /// The rows opened, by alias; a box's window starts with its own.
    @StateObject private var open: Local<Set<String>>
    /// Add folder…'s field: the box it's under.
    @StateObject private var addingFolder = Local<String?>(nil)
    /// The folder row lit by a click (its window glyphs show): alias and path.
    @StateObject private var selected = Local<BoxPlace?>(nil)
    /// Add a box…'s field.
    @StateObject private var addingBox = Local<String?>(nil)
    @FocusState private var fieldFocused: Bool

    init(workspace: Workspace) {
        self.workspace = workspace
        _open = StateObject(wrappedValue: Local(Set(workspace.box.map { [$0.alias] } ?? [])))
    }

    private var list: BoxList { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                // A box's window shows only Boxes: no switch.
                if workspace.box == nil { BoxesSwitch(workspace: workspace) }
                Text("Boxes").font(Chrome.bodyMedium).foregroundStyle(Theme.secondary)
                Spacer(minLength: Space.md)
            }
            .padding(.horizontal, Layout.Explorer.headerInset)
            .frame(height: Layout.Explorer.header)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list.boxes) { box in
                        boxRow(box)
                        if open.value.contains(box.alias) { inside(box) }
                    }
                    addBox
                }
                .padding(.horizontal, Space.sm)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .task {
            // The box whose window this is: its folders, fresh.
            if let alias = workspace.box?.alias { await list.probe(alias) }
        }
    }

    // MARK: Rows

    private func boxRow(_ box: BoxList.Box) -> some View {
        row(indent: 0) {
            toggle(box.alias)
        } label: {
            Image(systemName: open.value.contains(box.alias) ? "chevron.down" : "chevron.right")
                .font(Chrome.caption).foregroundStyle(Theme.tertiary).frame(width: Space.md)
            StatusDot(state: box.dotState)
            Text(box.alias).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
        }
        .koreContextMenu("box-row") {
            // Remove asks once, a step in: it forgets the box here and leaves the box as it is.
            [OptionItem("Remove", destructive: true, children: [OptionItem("Forget \(box.alias) on this Mac", destructive: true) { list.remove(box.alias) }])]
        }
    }

    @ViewBuilder private func inside(_ box: BoxList.Box) -> some View {
        if let note = box.note { noteLine(note, alias: box.alias) }
        ForEach(box.folders, id: \.self) { folder in
            let here = workspace.box?.alias == box.alias && workspace.box?.folder == folder.path
            let place = BoxPlace(alias: box.alias, folder: folder.path)
            let picked = selected.value == place
            let missing = folder.missing == true
            // A click lights it; its glyphs open it.
            row(indent: 1, lit: here || picked) {
                selected.value = place
            } label: {
                Image(systemName: "folder").font(Chrome.caption).foregroundStyle(missing ? Theme.tertiary : Theme.secondary)
                Text(folder.name).font(Chrome.label).foregroundStyle(missing ? Theme.tertiary : here || picked ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                    .help(missing ? "Missing on \(box.alias): \(folder.path)" : folder.path)
                Spacer(minLength: 0)
                if picked, !here, !missing { BoxFolderGlyphs(place: place, here: workspace.givesWay) }
            }
            .disabled(missing)
        }
        if box.status == .ready { addFolder(box.alias) }
    }

    /// The box's one line, and its action after a dot ("Not set up on mybox · Set up").
    private func noteLine(_ note: BoxList.Note, alias: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(note.line).foregroundStyle(Theme.tertiary).lineLimit(2)
            if let action = note.action {
                Text("·").foregroundStyle(Theme.tertiary)
                Button(action.title) { Task { await list.act(action, on: alias) } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
            }
        }
        .font(Chrome.caption)
        .padding(.leading, Space.xl + Space.md).padding(.vertical, Space.xs)
    }

    @ViewBuilder private func addFolder(_ alias: String) -> some View {
        if addingFolder.value == alias {
            BoxAddFolderField(alias: alias) { addingFolder.value = nil } added: { folder in
                addingFolder.value = nil
                selected.value = BoxPlace(alias: alias, folder: folder.path)
            }
            .padding(.leading, Space.xl + Space.md)
        } else {
            row(indent: 1) {
                (addingFolder.value, addingBox.value) = (alias, nil)
            } label: {
                Image(systemName: "plus").font(Chrome.caption).foregroundStyle(Theme.tertiary)
                Text("Add folder…").font(Chrome.label).foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private var addBox: some View {
        if let typed = addingBox.value {
            VStack(alignment: .leading, spacing: 0) {
                field(Binding(get: { typed }, set: { addingBox.value = $0 }), prompt: "SSH alias") { submitBox(typed) } cancel: { addingBox.value = nil }
                    .padding(.vertical, Space.xs)
                ForEach(list.suggestions(typed).prefix(6), id: \.self) { alias in
                    row(indent: 1) { submitBox(alias) } label: {
                        Text(alias).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.leading, Space.md)
        } else {
            row(indent: 0) {
                (addingBox.value, addingFolder.value) = ("", nil)
            } label: {
                Image(systemName: "plus").font(Chrome.caption).foregroundStyle(Theme.tertiary).frame(width: Space.md)
                Text("Add a box…").font(Chrome.label).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func row<Label: View>(indent: Int, lit: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: Space.sm) { label() }
                .padding(.leading, Space.sm + CGFloat(indent) * (Space.xl + Space.xs))
                .padding(.trailing, Space.sm)
                .frame(maxWidth: .infinity, minHeight: Size.Tree.row, alignment: .leading)
                .background(lit ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func field(_ text: Binding<String>, prompt: String, submit: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.tertiary))
            .textFieldStyle(.plain)
            .font(Chrome.label)
            .focused($fieldFocused)
            .fieldWell(focused: fieldFocused)
            .onSubmit(submit)
            .onExitCommand(perform: cancel)
            .onAppear { fieldFocused = true }
    }

    // MARK: Acts

    private func toggle(_ alias: String) {
        if open.value.contains(alias) {
            open.value.remove(alias)
            return
        }
        open.value.insert(alias)
        guard list.box(alias)?.status != .probing else { return }
        Task { await list.probe(alias) }
    }

    private func submitBox(_ alias: String) {
        let alias = alias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty else { return }
        list.add(alias)
        addingBox.value = nil
        if !open.value.contains(alias) { toggle(alias) }
    }
}

/// A box's status: connected (filled, green), offline (filled, dim), not set up (a ring), not
/// asked yet (a faint ring).
struct StatusDot: View {
    enum State { case connected, offline, notSetUp, unknown }
    let state: State

    var body: some View {
        let size = Size.statusPoint
        Group {
            switch state {
            case .connected: Circle().fill(Theme.success)
            case .offline: Circle().fill(Theme.tertiary)
            case .notSetUp: Circle().strokeBorder(Theme.tertiary, lineWidth: Stroke.hairline * 1.5)
            case .unknown: Circle().strokeBorder(Theme.border, lineWidth: Stroke.hairline * 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        switch state {
        case .connected: "Connected"
        case .offline: "Offline"
        case .notSetUp: "Not set up"
        case .unknown: "Not checked"
        }
    }
}
