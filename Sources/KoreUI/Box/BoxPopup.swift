import AppKit
import HostClient
import SwiftUI

/// The title row's box button, beside the panel button once there's a box (the Boxes panel adds
/// the first): a click opens the box popup under it. In a box's window it also carries that box's
/// one cue: an accent point while online, a grey one while it's offline or its sync has something
/// to say, the line itself on hover.
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
                    // A box's window: its one quiet cue. Accent while it's online, grey with
                    // something to say (offline, a sync line).
                    if let cue {
                        Circle()
                            .fill(cue.marked ? Theme.secondary : Theme.accent)
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

/// The box popup: in a box's window its line first; a row per box (its dot and name), whose click
/// shows its folders one level deeper; Add a box…, a field in its place. A folder's click only lights it: its window glyphs
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
        }
    }

    // MARK: Pieces

    private var pieces: [Piece] {
        switch level.value {
        case .boxes: boxesLevel
        case .box(let alias): foldersLevel(alias)
        }
    }

    private var rule: Piece {
        .view("rule", AnyView(Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.xxs)))
    }

    private var boxesLevel: [Piece] {
        var pieces: [Piece] = []
        if let box = workspace?.box {
            pieces.append(.view("cue", AnyView(line(box.cue.line, tint: box.cue.marked ? Theme.secondary : Theme.tertiary))))
            // A round that stopped before a bulk delete goes on only with this.
            if let sync = box.sync, let count = sync.askDeletes {
                pieces.append(.view("deletes", AnyView(HStack(spacing: Space.sm) {
                    Spacer(minLength: 0)
                    Button("Delete \(count.formatted()) files") { sync.allowDeletes() }.smallButton(danger: true)
                }
                .padding(.horizontal, Space.sm)
                .padding(.bottom, Space.xs))))
            }
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
            pieces.append(.view("status", AnyView(BoxNoteLine(note: note, alias: alias, opened: close).padding(.horizontal, Space.sm).padding(.vertical, Space.xs))))
        }
        let here = workspace.map(\.givesWay) ?? window.value
        for folder in box?.folders ?? [] {
            let id = "folder:" + folder.path
            let place = BoxPlace(alias: alias, folder: folder.path)
            let shown = lit.value == id
            // A folder missing on the box is dim, and neither lights nor opens.
            let missing = folder.missing == true
            pieces.append(.item(Item(
                id: id, story: StoryID.Boxes.folder(folder.path), click: { if !missing { lit.value = id } }, enter: { if !missing { openFolder(place) } },
                label: AnyView(HStack(spacing: Space.sm) {
                    Image(systemName: "folder").font(Chrome.caption).foregroundStyle(missing ? Theme.tertiary : Theme.secondary).frame(width: Size.Box.lead)
                    Text(folder.name).font(Chrome.label).foregroundStyle(missing ? Theme.tertiary : Theme.text).lineLimit(1)
                        .help(missing ? "Missing on \(alias): \(folder.path)" : folder.path)
                    Spacer(minLength: 0)
                    BoxFolderGlyphs(place: place, here: here).opacity(shown && !missing ? 1 : 0).allowsHitTesting(shown && !missing)
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

    private func line(_ text: String, tint: Color = Theme.secondary) -> some View {
        HStack(spacing: Space.sm) {
            Text(text).font(Chrome.label).foregroundStyle(tint).lineLimit(2)
        }
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, minHeight: Layout.Options.row, alignment: .leading)
    }

    /// Add a box…: the field; the SSH hosts it could be follow as rows.
    private func boxField(_ text: String) -> some View {
        BoxAliasField(text: Binding(get: { text }, set: { typed.value = $0 }), add: addBox) { typed.value = nil }
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

    private func addBox(_ typed: String) {
        guard let alias = BoxList.alias(typed) else { return }
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
                if level.value != .boxes { level.value = .boxes } else { close() }
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
