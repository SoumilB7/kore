import AppKit
import HostClient
import SwiftUI

/// The title row's box button, beside the panel button in every window (the new window's too):
/// a click opens the box popup under it. In a box's window it also carries that box's one cue: a
/// point while it's offline or its sync has something to say, the line itself on hover.
struct BoxButton: View {
    /// The window's workspace; nil in the new window, which has no folder.
    let workspace: Workspace?
    let size: CGFloat
    @StateObject private var hovered = Local(false)
    @StateObject private var open = Local(false)
    @StateObject private var frame = Held(CGRect.zero)

    var body: some View {
        let lit = hovered.value || open.value
        let box = workspace?.box
        let cue = box.map(\.cue)
        Button {
            if !open.value { OptionsMenu.shared.close() }
            open.value.toggle()
        } label: {
            Image(systemName: "server.rack")
                .font(Chrome.bodyMedium)
                .foregroundStyle(lit ? Theme.text : Theme.secondary)
                .frame(width: size, height: size)
                .background(lit ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(alignment: .topTrailing) {
                    if let cue, cue.marked {
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
        .popupAwareHelp(cue?.line ?? "Boxes")
        .accessibilityLabel(Text(cue?.line ?? "Boxes"))
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

/// The box popup: in a box's window its line first; then "Open <folder> on <box>" where the window
/// has a Mac folder; a row per box (its dot and name), whose click shows its folders one level
/// deeper; Add a box…, a field in its place. A folder's click only lights it: its window glyphs
/// (or Return) open it. ↑ ↓ move the lit row, Return takes it, Esc goes back a level, then closes.
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
        /// kore-host on the box didn't answer in time: its note's action, and Try again.
        case unreachable(String)
    }

    /// A row the keys can light: its click, and Return's when that differs.
    private struct Item {
        let id: String
        var story: StoryID?
        let click: () -> Void
        var enter: (() -> Void)?
        let label: AnyView
    }

    private enum Piece: Identifiable {
        case item(Item)
        case view(String, AnyView)
        var id: String {
            switch self {
            case .item(let item): item.id
            case .view(let id, _): id
            }
        }
    }

    @Environment(\.openWindow) private var openWindow
    @StateObject private var level = Local(Level.boxes)
    @StateObject private var copy = Local(Copy.idle)
    /// The first copy under way: cancelled with Cancel or the popup closing, so it never opens a
    /// window after the user moved on.
    @StateObject private var copying = Held<Task<Void, Never>?>(nil)
    /// The lit row, by id: the pointer's or the keys'.
    @StateObject private var lit = Local<String?>(nil)
    /// Add a box…'s field while it's open.
    @StateObject private var typed = Local<String?>(nil)
    /// Add folder…'s field, by the box it's under.
    @StateObject private var addingFolder = Local<String?>(nil)
    @FocusState private var typing: Bool
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)

    private var list: BoxList { .shared }

    var body: some View {
        let pieces = self.pieces
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pieces) { piece in
                switch piece {
                case .item(let item):
                    PopupRow(lit: lit.value == item.id, action: item.click, take: { lit.value = item.id }, label: item.label)
                        .storyID(item.story)
                case .view(_, let view):
                    view
                }
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
        .onChange(of: level.value) { lit.value = nil }
        .onAppear {
            PointerGate.keyed()
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { handle($0) }
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
            copying.value?.cancel()
            copying.value = nil
        }
    }

    // MARK: Pieces

    private var pieces: [Piece] {
        switch level.value {
        case .boxes: boxesLevel
        case .box(let alias): foldersLevel(alias)
        case .pick: pickLevel
        }
    }

    /// The window's folder on this Mac; nil in a box's window and the new window.
    private var mac: URL? { workspace.flatMap { $0.box == nil ? $0.folder : nil } }

    private var rule: Piece {
        .view("rule", AnyView(Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.xxs)))
    }

    private var boxesLevel: [Piece] {
        var pieces: [Piece] = []
        if let box = workspace?.box {
            pieces.append(.view("cue", AnyView(line(box.cue.line, tint: box.cue.marked ? Theme.secondary : Theme.tertiary))))
            pieces.append(rule)
        }
        if mac != nil, !list.boxes.isEmpty {
            pieces += syncPieces
            pieces.append(rule)
        }
        for box in list.boxes {
            pieces.append(.item(Item(id: "box:" + box.alias, story: StoryID.Boxes.box(box.alias), click: { show(box.alias) }, label: AnyView(HStack(spacing: Space.sm) {
                StatusDot(state: box.dotState).frame(width: Size.Box.lead)
                Text(box.alias).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.tertiary)
            }))))
        }
        if let text = typed.value {
            pieces.append(.view("box.field", AnyView(boxField(text))))
            for alias in list.suggestions(text).prefix(6) {
                pieces.append(.item(Item(id: "suggest:" + alias, click: { addBox(alias) }, label: AnyView(HStack(spacing: Space.sm) {
                    Color.clear.frame(width: Size.Box.lead, height: 1)
                    Text(alias).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
                }))))
            }
        } else {
            pieces.append(.item(Item(id: "box.add", story: StoryID.Boxes.add, click: { typed.value = "" }, label: AnyView(HStack(spacing: Space.sm) {
                Image(systemName: "plus").font(Chrome.caption).foregroundStyle(Theme.tertiary).frame(width: Size.Box.lead)
                Text("Add a box…").font(Chrome.label).foregroundStyle(Theme.secondary)
            }))))
        }
        return pieces
    }

    /// "Open <folder> on <box>", or where it stands: checking, the one question, copying, why not.
    private var syncPieces: [Piece] {
        let name = mac?.lastPathComponent ?? ""
        func label(_ text: String, chevron: Bool = false) -> AnyView {
            AnyView(HStack(spacing: Space.sm) {
                syncGlyph
                Text(text).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                if chevron {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(Chrome.glyphCrumb).foregroundStyle(Theme.tertiary)
                }
            })
        }
        switch copy.value {
        case .idle:
            if let pair = mac.flatMap({ SyncPairs.pair(mac: $0.standardizedFileURL.path) }) {
                return [.item(Item(id: "sync", story: StoryID.Boxes.sync, click: { openPair(pair) }, label: label("Open on \(pair.alias) · in sync")))]
            }
            if list.boxes.count == 1, let only = list.boxes.first {
                return [.item(Item(id: "sync", story: StoryID.Boxes.sync, click: { begin(only.alias) }, label: label("Open \(name) on \(only.alias)")))]
            }
            return [.item(Item(id: "sync", story: StoryID.Boxes.sync, click: { level.value = .pick }, label: label("Open \(name) on…", chevron: true)))]
        case .checking:
            return [.view("sync.state", AnyView(line("Checking \(name)…", glyph: true)))]
        case .copying(let alias):
            return [
                .view("sync.state", AnyView(line("Copying \(name) to \(alias)…", glyph: true))),
                .view("sync.ask", AnyView(HStack(spacing: Space.sm) {
                    Spacer(minLength: 0)
                    Button("Cancel") { cancelCopy() }.smallButton()
                }
                .padding(.horizontal, Space.sm)
                .padding(.bottom, Space.xs))),
            ]
        case .unreachable(let alias):
            let note = list.box(alias)?.note
            return [
                .view("sync.state", AnyView(line(note?.line ?? "Can't reach \(alias)", tint: Theme.secondary, glyph: true))),
                .view("sync.ask", AnyView(HStack(spacing: Space.sm) {
                    Spacer(minLength: 0)
                    if let action = note?.action {
                        Button(action.title) { Task { await list.act(action, on: alias) } }.smallButton()
                    }
                    Button("Try again") { begin(alias) }.smallButton(prominent: true)
                }
                .padding(.horizontal, Space.sm)
                .padding(.bottom, Space.xs))),
            ]
        case .failed(let why):
            return [.view("sync.state", AnyView(line(why, tint: Theme.danger, glyph: true)))]
        case .ask(let question, let alias):
            return [
                .view("sync.state", AnyView(line(question, glyph: true))),
                .view("sync.ask", AnyView(HStack(spacing: Space.sm) {
                    Spacer(minLength: 0)
                    Button("Cancel") { copy.value = .idle }.smallButton()
                    Button("Copy") { Task { await makeCopy(alias) } }.smallButton(prominent: true)
                }
                .padding(.horizontal, Space.sm)
                .padding(.bottom, Space.xs))),
            ]
        }
    }

    private var syncGlyph: some View {
        Image(systemName: "arrow.triangle.2.circlepath").font(Chrome.caption).foregroundStyle(Theme.accent).frame(width: Size.Box.lead)
    }

    private func foldersLevel(_ alias: String) -> [Piece] {
        let box = list.box(alias)
        var pieces: [Piece] = [
            .item(Item(id: "back", click: { level.value = .boxes }, label: AnyView(HStack(spacing: Space.sm) {
                Image(systemName: "chevron.left").font(Chrome.glyphCrumb).foregroundStyle(Theme.secondary).frame(width: Size.Box.lead)
                Text(alias).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let box { StatusDot(state: box.dotState) }
            })))
        ]
        // The box's one line (BoxList's note), with its action (Set up, Start, Update) when it has one.
        if let note = box?.note {
            pieces.append(.view("status", AnyView(HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                line(note.line, tint: Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                if let action = note.action {
                    Button(action.title) { Task { await list.act(action, on: alias) } }
                        .buttonStyle(.plain)
                        .font(Chrome.label)
                        .foregroundStyle(Theme.accent)
                        .fixedSize()
                        .padding(.trailing, Space.sm)
                }
            })))
        }
        let here = workspace.map(\.givesWay) ?? window.value
        for folder in box?.folders ?? [] {
            let id = "folder:" + folder.path
            let place = BoxPlace(alias: alias, folder: folder.path)
            let shown = lit.value == id
            pieces.append(.item(Item(
                id: id, story: StoryID.Boxes.folder(folder.path), click: { lit.value = id }, enter: { openFolder(place) },
                label: AnyView(HStack(spacing: Space.sm) {
                    Image(systemName: "folder").font(Chrome.caption).foregroundStyle(Theme.secondary).frame(width: Size.Box.lead)
                    Text(folder.name).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1).help(folder.path)
                    Spacer(minLength: 0)
                    BoxFolderGlyphs(place: place, here: here).opacity(shown ? 1 : 0).allowsHitTesting(shown)
                }))))
        }
        if box?.status == .ready {
            if addingFolder.value == alias {
                pieces.append(.view("folder.field", AnyView(BoxAddFolderField(alias: alias) { addingFolder.value = nil } added: { folder in
                    addingFolder.value = nil
                    lit.value = "folder:" + folder.path
                })))
            } else {
                pieces.append(.item(Item(id: "folder.add", click: { addingFolder.value = alias }, label: AnyView(HStack(spacing: Space.sm) {
                    Image(systemName: "plus").font(Chrome.caption).foregroundStyle(Theme.tertiary).frame(width: Size.Box.lead)
                    Text("Add folder…").font(Chrome.label).foregroundStyle(Theme.secondary)
                }))))
            }
        }
        return pieces
    }

    /// The boxes the window's folder could open on.
    private var pickLevel: [Piece] {
        var pieces: [Piece] = [
            .item(Item(id: "back", click: { level.value = .boxes }, label: AnyView(HStack(spacing: Space.sm) {
                Image(systemName: "chevron.left").font(Chrome.glyphCrumb).foregroundStyle(Theme.secondary).frame(width: Size.Box.lead)
                Text("Open \(mac?.lastPathComponent ?? "") on…").font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(1)
            })))
        ]
        for box in list.boxes {
            pieces.append(.item(Item(id: "pick:" + box.alias, story: StoryID.Boxes.box(box.alias), click: { begin(box.alias) }, label: AnyView(HStack(spacing: Space.sm) {
                StatusDot(state: box.dotState).frame(width: Size.Box.lead)
                Text(box.alias).font(Chrome.label).foregroundStyle(Theme.text).lineLimit(1)
            }))))
        }
        return pieces
    }

    private func line(_ text: String, tint: Color = Theme.secondary, glyph: Bool = false) -> some View {
        HStack(spacing: Space.sm) {
            if glyph { syncGlyph }
            Text(text).font(Chrome.label).foregroundStyle(tint).lineLimit(2)
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, minHeight: Layout.Options.row, alignment: .leading)
    }

    /// Add a box…: the field; the SSH hosts it could be follow as rows.
    private func boxField(_ text: String) -> some View {
        TextField("", text: Binding(get: { text }, set: { typed.value = $0 }), prompt: Text("SSH alias").foregroundStyle(Theme.tertiary))
            .textFieldStyle(.plain)
            .font(Chrome.label)
            .focused($typing)
            .fieldWell(focused: typing)
            .onSubmit { addBox(text) }
            .onExitCommand { typed.value = nil }
            .onAppear { typing = true }
            .padding(.vertical, Space.xxs)
            .storyID(StoryID.Boxes.field)
    }

    // MARK: Acts

    /// A box's folders, one level deeper: asked of the box now (nothing opens yet).
    private func show(_ alias: String) {
        typed.value = nil
        addingFolder.value = nil
        level.value = .box(alias)
        guard list.box(alias)?.status != .probing else { return }
        Task { await list.probe(alias) }
    }

    private func openFolder(_ place: BoxPlace) {
        close()
        openWindow(value: place)
    }

    private func openPair(_ pair: SyncPair) {
        openFolder(BoxPlace(alias: pair.alias, folder: pair.box))
    }

    /// The first copy: counted and checked against the box's room, asked once when big.
    private func begin(_ alias: String) {
        guard let mac else { return }
        guard let box = SyncBox.ssh(alias) else {
            copy.value = .failed("\(alias) isn't an SSH alias Kore can use")
            return
        }
        level.value = .boxes
        copy.value = .checking
        copying.value?.cancel()
        copying.value = Task {
            switch await HostSync.preflight(mac: mac, box: box) {
            case .refuse(let why): if !Task.isCancelled { copy.value = .failed(why) }
            case .ask(let question): if !Task.isCancelled { copy.value = .ask(question, alias: alias) }
            case .go: await makeCopy(alias)
            }
        }
    }

    private func cancelCopy() {
        copying.value?.cancel()
        copying.value = nil
        copy.value = .idle
    }

    /// Makes the box copy and opens its window, which keeps the two in sync. Gives up after about
    /// 20 s without kore-host; a cancel stops it and the connection's dialling with it.
    private func makeCopy(_ alias: String) async {
        guard let mac, let box = SyncBox.ssh(alias), !Task.isCancelled else { return }
        copy.value = .copying(alias)
        let connection = BoxBinding.connection(alias)
        connection.retain()
        let made = await HostSync.firstCopy(mac: mac, connection: connection, box: box)
        let cancelled = Task.isCancelled
        switch made {
        case .success(let pair) where !cancelled:
            copy.value = .idle
            openPair(pair)
            // A moment later, so the window takes the connection over without it dropping.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { connection.release() }
            return
        case .failure(.unreachable) where !cancelled:
            copy.value = .unreachable(alias)
            Task { await list.probe(alias) }
        case .failure(.refused(let why)) where !cancelled:
            copy.value = .failed(why)
        default:
            break
        }
        connection.release()
    }

    private func addBox(_ alias: String) {
        let alias = alias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty, !alias.contains(" ") else { return }
        list.add(alias)
        show(alias)
    }

    // MARK: Keys and clicks

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window, let content = window.contentView else { return event }
        if event.type == .keyDown {
            switch event.keyCode {
            case 53:
                // Esc: a field's own first (it closes the field), then a level up, then the popup.
                guard !typing, window.firstResponder as? NSTextView == nil else { return event }
                if level.value != .boxes { level.value = .boxes } else if copy.value != .idle { cancelCopy() } else { close() }
                return nil
            case 125, 126:
                let items = pieces.compactMap { if case .item(let item) = $0 { item } else { nil } }
                guard !items.isEmpty else { return nil }
                let at = lit.value.flatMap { id in items.firstIndex { $0.id == id } }
                let step = event.keyCode == 125 ? 1 : -1
                let next = at.map { min(max($0 + step, 0), items.count - 1) } ?? (step > 0 ? 0 : items.count - 1)
                lit.value = items[next].id
                PointerGate.keyed()
                return nil
            case 36, 76:
                // A field takes its own Return.
                guard window.firstResponder as? NSTextView == nil, let id = lit.value,
                    let item = pieces.lazy.compactMap({ if case .item(let item) = $0 { item } else { nil } }).first(where: { $0.id == id })
                else { return event }
                (item.enter ?? item.click)()
                return nil
            default:
                return event
            }
        }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !frame.value.contains(point), !anchor().contains(point) { close() }
        return event
    }
}

/// One row: lit under the pointer or by the keys.
private struct PopupRow: View {
    let lit: Bool
    let action: () -> Void
    let take: @MainActor () -> Void
    let label: AnyView

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, Space.sm)
                .frame(maxWidth: .infinity, minHeight: Layout.Options.row, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(lit, Theme.Row.selected(.surface), radius: Radius.control)
        .highlightRow(nil, lit: lit, take: take)
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
