import HostClient
import SwiftUI

/// The Boxes panel's mark, at its header's left end, lit: only a box's window has the panel.
struct BoxesSwitch: View {
    let workspace: Workspace

    var body: some View {
        HeaderButton(symbol: "server.rack", isOn: true, tint: Theme.accent, help: "Boxes") {}
    }
}

/// Boxes in a box window's left panel: a row per box (its status dot and name); opened, it asks
/// the box for its folders, this window's lit. A folder's click selects it, its glyphs (or Return,
/// or ⌘-click) open it; ↑ ↓ move, Space selects. A folder syncs with a Mac folder from its Sync
/// glyph or right-click. Add a box… at the end. Nothing dials until a row opens.
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
    /// The folder row the keys are on (↑ ↓): filled as under the pointer.
    @StateObject private var cursor = Local<BoxPlace?>(nil)
    /// A folder's pairing with a Mac folder while it's asked or refused, under its row.
    @StateObject private var pairing = Local<BoxPairing?>(nil)
    @StateObject private var checking = Held<Task<Void, Never>?>(nil)
    @FocusState private var keyed: Bool
    @Environment(\.openWindow) private var openWindow

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
        .focusable()
        .focusEffectDisabled()
        .focused($keyed)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            step(press.key == .downArrow ? 1 : -1)
            return .handled
        }
        .onKeyPress(.space) {
            guard let at = cursor.value else { return .ignored }
            selected.value = at
            return .handled
        }
        .onKeyPress(.return) {
            guard let at = cursor.value ?? selected.value else { return .ignored }
            open(at, newWindow: false)
            return .handled
        }
        .onDisappear { checking.value?.cancel() }
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
        if let note = box.note { BoxNoteLine(note: note, alias: box.alias).padding(.leading, Space.xl + Space.md).padding(.vertical, Space.xs) }
        ForEach(box.folders, id: \.self) { folder in
            folderRow(box.alias, folder)
            if let pairing = pairing.value, pairing.place == BoxPlace(alias: box.alias, folder: folder.path) { pairingCard(pairing) }
        }
        if box.status == .ready { addFolder(box.alias) }
    }

    /// A box folder: its name, the Mac folder it syncs with (or the synced folder it's in) on a
    /// second line, a dot while files move, and on hover or selected its Sync and window glyphs.
    private func folderRow(_ alias: String, _ folder: BoxFolder) -> some View {
        let place = BoxPlace(alias: alias, folder: folder.path)
        let here = workspace.box?.alias == alias && workspace.box?.folder == folder.path
        let picked = selected.value == place
        let missing = folder.missing == true
        let pairs = SyncPairList.shared
        let pair = pairs.pair(alias: alias, box: folder.path)
        let around = pair == nil ? pairs.around(alias: alias, box: folder.path) : nil
        let moving = pair.flatMap { pairs.live[$0.mac]?.carrying } == true
        let second = pair.map { "synced locally to " + SyncPairs.shown(mac: $0.mac) } ?? around.map { "inside \(BoxFolder.lastPart($0.box)), synced" }
        return PanelRow(indent: 1, lit: here || picked, keyed: cursor.value == place) {
            if NSEvent.modifierFlags.contains(.command), !missing {
                open(place, newWindow: true)
                return
            }
            selected.value = place
            cursor.value = place
            keyed = true
        } label: { hovered in
            Image(systemName: "folder").font(Chrome.caption).foregroundStyle(missing ? Theme.tertiary : Theme.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.name).font(Chrome.label).foregroundStyle(missing ? Theme.tertiary : here || picked ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                if let second {
                    Text(second).font(Chrome.caption).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            .help(missing ? "Missing on \(alias): \(folder.path)" : folder.path + (pair.map { " · synced locally to " + $0.mac } ?? ""))
            if moving {
                Circle().fill(Theme.accent).frame(width: Size.statusPoint, height: Size.statusPoint)
                    .pulse(low: Motion.blinkLow, period: Motion.blinkPeriod)
                    .help("Syncing")
            }
            Spacer(minLength: 0)
            if !missing, pair == nil, around == nil, hovered || picked || here {
                IconButton(symbol: "arrow.triangle.2.circlepath", kind: .mini, font: Chrome.caption, help: "Sync with a Mac folder…") { startPairing(place) }
            }
            if picked, !here, !missing { BoxFolderGlyphs(place: place, here: workspace.givesWay) }
        }
        .disabled(missing)
        .koreContextMenu("box-folder") { folderMenu(place, pair: pair, around: around, missing: missing) }
    }

    private func folderMenu(_ place: BoxPlace, pair: SyncPair?, around: SyncPair?, missing: Bool) -> [OptionItem] {
        guard !missing, around == nil else { return [] }
        guard pair != nil, let folder = place.folder else { return [OptionItem("Sync with a Mac folder…") { startPairing(place) }] }
        // A step in, as Remove: it stops syncing and deletes nothing on either side.
        return [OptionItem("Stop syncing", children: [OptionItem("Stop · files stay on both sides") { stopSyncing(place.alias, folder) }])]
    }

    /// Under a folder row while it's paired: the one line, and its one action.
    private func pairingCard(_ pairing: BoxPairing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(pairing.line)
                .font(Chrome.caption)
                .foregroundStyle(pairing.failed ? Theme.danger : Theme.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch pairing.state {
            case .checking:
                Button("Cancel") { cancelPairing() }.smallButton()
            case .ask(_, let start, let mac):
                Button("Cancel") { cancelPairing() }.smallButton()
                Button(start == .merge ? "Merge" : "Copy") { finishPairing(pairing.place, mac: mac) }.smallButton(prominent: true)
            case .failed:
                Button("OK") { cancelPairing() }.smallButton()
            }
        }
        .padding(Space.sm)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .padding(.leading, Space.xl + Space.md)
        .padding(.vertical, Space.xxs)
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
                BoxAliasField(text: Binding(get: { typed }, set: { addingBox.value = $0 }), add: submitBox) { addingBox.value = nil }
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
        let label = label()
        return PanelRow(indent: indent, lit: lit, action: action) { _ in label }
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

    // MARK: Folders

    /// The folders shown, in order: what ↑ ↓ step through.
    private var shownFolders: [BoxPlace] {
        list.boxes.filter { open.value.contains($0.alias) }.flatMap { box in
            box.folders.filter { $0.missing != true }.map { BoxPlace(alias: box.alias, folder: $0.path) }
        }
    }

    private func step(_ by: Int) {
        let folders = shownFolders
        guard !folders.isEmpty else { return }
        let from = cursor.value ?? selected.value ?? workspace.box.map { BoxPlace(alias: $0.alias, folder: $0.folder) }
        let at = from.flatMap { folders.firstIndex(of: $0) }
        cursor.value = folders[at.map { min(max($0 + by, 0), folders.count - 1) } ?? (by > 0 ? 0 : folders.count - 1)]
        PointerGate.keyed()
    }

    /// Opens a box folder: its own window, here while this window gives way. Its own folder stays.
    private func open(_ place: BoxPlace, newWindow: Bool) {
        if workspace.box?.alias == place.alias, workspace.box?.folder == place.folder { return }
        openWindow(value: place)
        if !newWindow, let here = workspace.givesWay { here.close() }
    }

    // MARK: Sync

    /// Sync with a Mac folder…: the open-folder panel, then the pair checked, asked once when
    /// both have files or it's big, and kept.
    private func startPairing(_ place: BoxPlace) {
        guard let folder = place.folder else { return }
        checking.value?.cancel()
        guard let mac = AppModel.shared?.chooseFolder(prompt: "Sync", message: "Sync \(BoxFolder.lastPart(folder)) on \(place.alias) with a folder on this Mac")
        else { return }
        selected.value = place
        let pairs = SyncPairList.shared
        if let why = pairs.refusal(mac: mac, alias: place.alias, box: folder) {
            pairing.value = BoxPairing(place: place, state: .failed(why))
            return
        }
        guard let box = SyncBox.ssh(place.alias) else {
            pairing.value = BoxPairing(place: place, state: .failed("\(place.alias) isn't an SSH alias Kore can use"))
            return
        }
        pairing.value = BoxPairing(place: place, state: .checking(SyncPairs.shown(mac: mac.path)))
        checking.value = Task {
            let check = await pairs.check(mac: mac, alias: place.alias, box: folder, via: box)
            guard !Task.isCancelled, pairing.value?.place == place else { return }
            switch check {
            case .go: finishPairing(place, mac: mac)
            case .ask(let question, let start): pairing.value = BoxPairing(place: place, state: .ask(question, start, mac))
            case .refuse(let why): pairing.value = BoxPairing(place: place, state: .failed(why))
            }
        }
    }

    private func finishPairing(_ place: BoxPlace, mac: URL) {
        guard let folder = place.folder else { return }
        checking.value = nil
        pairing.value = nil
        SyncPairList.shared.pair(mac: mac, alias: place.alias, box: folder)
        BoxBinding.pairsChanged()
    }

    private func cancelPairing() {
        checking.value?.cancel()
        checking.value = nil
        pairing.value = nil
    }

    private func stopSyncing(_ alias: String, _ folder: String) {
        SyncPairList.shared.unpair(alias: alias, box: folder)
        BoxBinding.pairsChanged()
    }

    private func submitBox(_ typed: String) {
        guard let alias = BoxList.alias(typed) else { return }
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

/// A row of the Boxes panel: lit when picked, filled while the pointer or the keys are on it, as
/// the explorer's.
private struct PanelRow<Label: View>: View {
    let indent: Int
    let lit: Bool
    var keyed = false
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) { label(hovered.value) }
                .padding(.leading, Space.sm + CGFloat(indent) * (Space.xl + Space.xs))
                .padding(.trailing, Space.sm)
                .frame(maxWidth: .infinity, minHeight: Size.Tree.row, alignment: .leading)
                .background(lit ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .hoverFill((hovered.value || keyed) && !lit, Theme.Row.selected(.surface), radius: Radius.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }
}

/// A folder's pairing with a Mac folder, while it's checked, asked or refused.
struct BoxPairing: Equatable {
    enum State: Equatable {
        /// The Mac folder, as shown.
        case checking(String)
        case ask(String, HostSync.Start, URL)
        case failed(String)
    }

    let place: BoxPlace
    let state: State

    var line: String {
        switch state {
        case .checking(let mac): "Checking \(mac)…"
        case .ask(let question, _, _): question
        case .failed(let why): why
        }
    }

    var failed: Bool { if case .failed = state { true } else { false } }
}
