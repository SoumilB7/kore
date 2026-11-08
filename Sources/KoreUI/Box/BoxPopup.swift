import AppKit
import HostClient
import SwiftUI

/// The title row's box button, beside the panel button in every window (the new window's too):
/// a click opens the box popup under it.
struct BoxButton: View {
    /// The window's workspace; nil in the new window, which has no folder.
    let workspace: Workspace?
    let size: CGFloat
    @StateObject private var hovered = Local(false)
    @StateObject private var open = Local(false)
    @StateObject private var frame = Held(CGRect.zero)

    var body: some View {
        let lit = hovered.value || open.value
        Button {
            if !open.value { OptionsMenu.shared.close() }
            open.value.toggle()
        } label: {
            Image(systemName: "server.rack")
                .font(Chrome.bodyMedium)
                .foregroundStyle(lit ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(lit ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .popupAwareHelp("Boxes")
        .accessibilityLabel(Text("Boxes"))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .storyID(StoryID.Titlebar.boxes)
        // Under the row, over the window's content (the row is above it, see FolderWindow).
        .overlay(alignment: .topLeading) {
            if open.value {
                BoxPopup(workspace: workspace, anchor: { frame.value }) { open.value = false }
                    .offset(y: size + Space.xs)
            }
        }
    }
}

/// The box popup: a row per box (its dot and name), a click showing its folders one level deeper,
/// where a folder opens its window; then Add a box…, a field in its place. Esc, a pick or a click
/// elsewhere closes it.
struct BoxPopup: View {
    let workspace: Workspace?
    /// The button: a click on it isn't outside (its own click closes the popup).
    let anchor: () -> CGRect
    let close: () -> Void

    enum Level: Equatable {
        case boxes
        /// A box's folders.
        case box(String)
        /// Which box the window's folder opens on.
        case pick
    }

    /// The top row's way through a first copy.
    enum Copy: Equatable {
        case idle, checking
        /// Big: one line, then Copy or Cancel.
        case ask(String, alias: String)
        case copying(String)
        case failed(String)
    }

    @Environment(\.openWindow) private var openWindow
    @StateObject private var level = Local(Level.boxes)
    @StateObject private var copy = Local(Copy.idle)
    /// Add a box…'s field while it's open.
    @StateObject private var typed = Local<String?>(nil)
    @FocusState private var typing: Bool
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)

    private var list: BoxList { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch level.value {
            case .boxes:
                if mac != nil, !list.boxes.isEmpty {
                    syncRow
                    Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.xxs)
                }
                boxes
            case .box(let alias): folders(alias)
            case .pick: pick
            }
        }
        .padding(Space.xs)
        .frame(width: Size.Box.popupWidth, alignment: .leading)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .background(WindowReader { window.value = $0 })
        .storyID(StoryID.Boxes.popup)
        .onAppear {
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { handle($0) }
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
        }
    }

    // MARK: Levels

    /// The window's folder on this Mac; nil in a box's window and the new window.
    private var mac: URL? { workspace.flatMap { $0.box == nil ? $0.folder : nil } }

    /// "Open <folder> on <box>", or where it stands: checking, the one question, copying, why not.
    @ViewBuilder private var syncRow: some View {
        let glyph = Image(systemName: "arrow.triangle.2.circlepath").font(Chrome.caption).foregroundStyle(Theme.accent).frame(width: Size.statusPoint)
        let name = mac?.lastPathComponent ?? ""
        switch copy.value {
        case .idle:
            if let pair = mac.flatMap({ SyncPairs.pair(mac: $0.standardizedFileURL.path) }) {
                row(story: StoryID.Boxes.sync, action: { openPair(pair) }) {
                    glyph
                    Text("Open on \(pair.alias) · in sync").font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
                }
                .help(pair.box)
            } else if list.boxes.count == 1, let only = list.boxes.first {
                row(story: StoryID.Boxes.sync, action: { begin(only.alias) }) {
                    glyph
                    Text("Open \(name) on \(only.alias)").font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                }
            } else {
                row(story: StoryID.Boxes.sync, action: { level.value = .pick }) {
                    glyph
                    Text("Open \(name) on…").font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.tertiary)
                }
            }
        case .checking:
            status(glyph, "Checking \(name)…")
        case .copying(let alias):
            status(glyph, "Copying \(name) to \(alias)…")
        case .failed(let why):
            status(glyph, why, tint: Theme.danger)
        case .ask(let line, let alias):
            VStack(alignment: .leading, spacing: Space.xs) {
                status(glyph, line)
                HStack(spacing: Space.sm) {
                    Spacer(minLength: 0)
                    Button("Cancel") { copy.value = .idle }.smallButton()
                    Button("Copy") { Task { await makeCopy(alias) } }.smallButton(prominent: true)
                }
                .padding(.horizontal, Space.sm)
                .padding(.bottom, Space.xs)
            }
        }
    }

    private func status(_ glyph: some View, _ line: String, tint: Color = Theme.secondary) -> some View {
        HStack(spacing: Space.sm) {
            glyph
            Text(line).font(Chrome.label).foregroundStyle(tint).lineLimit(2)
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, minHeight: Layout.Options.row, alignment: .leading)
    }

    /// The boxes the folder could open on.
    @ViewBuilder private var pick: some View {
        row(action: { level.value = .boxes }) {
            Image(systemName: "chevron.left").font(Chrome.glyphCrumb).foregroundStyle(Theme.secondary).frame(width: Size.statusPoint)
            Text("Open \(mac?.lastPathComponent ?? "") on…").font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        ForEach(list.boxes) { box in
            row(story: StoryID.Boxes.box(box.alias), action: { begin(box.alias) }) {
                StatusDot(state: box.dotState)
                Text(box.alias).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var boxes: some View {
        ForEach(list.boxes) { box in
            row(story: StoryID.Boxes.box(box.alias), action: { show(box.alias) }) {
                StatusDot(state: box.dotState)
                Text(box.alias).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.tertiary)
            }
        }
        if let text = typed.value {
            adding(text)
        } else {
            row(story: StoryID.Boxes.add, action: { typed.value = "" }) {
                Image(systemName: "plus").font(Chrome.caption).foregroundStyle(Theme.tertiary).frame(width: Size.statusPoint)
                Text("Add a box…").font(Chrome.label).foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private func folders(_ alias: String) -> some View {
        let box = list.box(alias)
        row(action: { level.value = .boxes }) {
            Image(systemName: "chevron.left").font(Chrome.glyphCrumb).foregroundStyle(Theme.secondary).frame(width: Size.statusPoint)
            Text(alias).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if let box { StatusDot(state: box.dotState) }
        }
        // The box's one line (BoxList's note), with its action (Set up, Start, Update) when it has one.
        if let note = box?.note {
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
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
        }
        ForEach(box?.folders ?? [], id: \.self) { folder in
            row(story: StoryID.Boxes.folder(folder.path), action: { openFolder(alias, folder) }) {
                Image(systemName: "folder").font(Chrome.caption).foregroundStyle(Theme.secondary).frame(width: Size.statusPoint)
                Text(folder.name).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
            }
            .help(folder.path)
        }
    }

    /// Add a box…: the field, and the SSH hosts it could be under it.
    @ViewBuilder private func adding(_ text: String) -> some View {
        TextField("", text: Binding(get: { text }, set: { typed.value = $0 }), prompt: Text("SSH host").foregroundStyle(Theme.tertiary))
            .textFieldStyle(.plain)
            .font(Chrome.label)
            .focused($typing)
            .fieldWell(focused: typing)
            .onSubmit { addBox(text) }
            .onExitCommand { typed.value = nil }
            .onAppear { typing = true }
            .padding(.vertical, Space.xxs)
            .storyID(StoryID.Boxes.field)
        ForEach(list.suggestions(text).prefix(6), id: \.self) { alias in
            row(action: { addBox(alias) }) {
                Color.clear.frame(width: Size.statusPoint, height: 1)
                Text(alias).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }

    private func row<Label: View>(story: StoryID? = nil, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        PopupRow(action: action, label: label()).storyID(story)
    }

    // MARK: Acts

    /// A box's folders, one level deeper: asked of the box now (nothing opens yet).
    private func show(_ alias: String) {
        typed.value = nil
        level.value = .box(alias)
        guard list.box(alias)?.status != .probing else { return }
        Task { await list.probe(alias) }
    }

    private func openFolder(_ alias: String, _ folder: BoxFolder) {
        close()
        openWindow(value: BoxPlace(alias: alias, folder: folder.path))
    }

    private func openPair(_ pair: SyncPair) {
        close()
        openWindow(value: BoxPlace(alias: pair.alias, folder: pair.box))
    }

    /// The first copy: counted and checked against the box's room, asked once when big.
    private func begin(_ alias: String) {
        guard let mac else { return }
        level.value = .boxes
        copy.value = .checking
        Task {
            switch await HostSync.preflight(mac: mac, box: .ssh(alias)) {
            case .refuse(let why): copy.value = .failed(why)
            case .ask(let line): copy.value = .ask(line, alias: alias)
            case .go: await makeCopy(alias)
            }
        }
    }

    /// Makes the box copy and opens its window, which keeps the two in sync.
    private func makeCopy(_ alias: String) async {
        guard let mac else { return }
        copy.value = .copying(alias)
        let connection = BoxBinding.connection(alias)
        connection.retain()
        let made = await HostSync.firstCopy(mac: mac, connection: connection, box: .ssh(alias))
        // A moment later, so the window takes the link over without it dropping.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { connection.release() }
        switch made {
        case .success(let pair):
            copy.value = .idle
            openPair(pair)
        case .failure(let refusal):
            copy.value = .failed(refusal.message)
        }
    }

    private func addBox(_ alias: String) {
        let alias = alias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty, !alias.contains(" ") else { return }
        list.add(alias)
        show(alias)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window, let content = window.contentView else { return event }
        if event.type == .keyDown {
            // Esc: the field's own first (it closes the field), then a level up, then the popup.
            guard event.keyCode == 53, !typing else { return event }
            if level.value != .boxes { level.value = .boxes } else if copy.value != .idle, copy.value != .checking { copy.value = .idle } else { close() }
            return nil
        }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !frame.value.contains(point), !anchor().contains(point) { close() }
        return event
    }
}

/// One row: lit under the pointer.
private struct PopupRow<Label: View>: View {
    let action: () -> Void
    let label: Label
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) { label }
                .padding(.horizontal, Space.sm)
                .frame(maxWidth: .infinity, minHeight: Layout.Options.row, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(hovered.value, Theme.Row.selected(.surface), radius: Radius.control)
        .onHover { hovered.value = $0 }
    }
}

extension BoxList.Box {
    /// Its dot: connected while a window holds it online or it last answered, else what the last
    /// probe found.
    @MainActor var dotState: StatusDot.State {
        if HostConnection.live(alias)?.isOnline == true { return .connected }
        switch status {
        case .ready: return .connected
        case .notSetUp, .noGrant, .stale, .failed: return .notSetUp
        case .stopped, .unreachable: return .offline
        case .unknown, .probing, .working: return .unknown
        }
    }
}
