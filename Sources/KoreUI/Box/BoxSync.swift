import AppKit
import HostClient
import SwiftUI

/// A box window's title-row button, beside the panel button: the folder's two-way sync with a Mac
/// folder (the window is the box folder already). Not synced, a click picks a Mac folder, then one
/// card asks the level (Files, or Files + chats) and pairs them; synced, one quiet point says how
/// it stands (accent in sync, pulsing while files move, grey while paused) and a click opens the
/// option list: its one line, the level, Keep syncing when closed, Open on this Mac, Show in
/// Finder and Stop syncing.
struct BoxSyncButton: View {
    let workspace: Workspace
    let box: BoxBinding
    let size: CGFloat
    @StateObject private var hovered = Local(false)
    @StateObject private var open = Local(false)
    @StateObject private var frame = Held(CGRect.zero)
    /// The pairing while it's checked, asked or refused: the popup shows it.
    @StateObject private var pairing = Local<BoxPairing?>(nil)
    @StateObject private var checking = Held<Task<Void, Never>?>(nil)

    private var pair: SyncPair? { SyncPairList.shared.pair(alias: box.alias, box: box.folder) }

    var body: some View {
        let lit = hovered.value || open.value
        let state = BoxSyncState.of(box)
        Button(action: click) { glyph(lit: lit, state: state) }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .popupAwareHelp(state.help(box))
        .accessibilityLabel(Text(state.help(box)))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .storyID(StoryID.Titlebar.boxSync)
        .overlay(alignment: .topLeading) {
            if open.value || pairing.value != nil {
                popup.offset(y: size + Space.xs)
            }
        }
        .onDisappear { checking.value?.cancel() }
    }

    private func click() {
        if !open.value { OptionsMenu.shared.close() }
        if pair == nil, BoxSyncState.of(box) == .off { return startPairing() }
        if let pair, pairing.value == nil { return showOptions(pair) }
        open.value.toggle()
    }

    /// The synced folder's option list, under the button.
    private func showOptions(_ pair: SyncPair) {
        guard let window = workspace.window, let content = window.contentView else { return }
        let below = CGPoint(x: frame.value.minX, y: content.bounds.height - frame.value.maxY - Space.xs)
        OptionsMenu.shared.show(BoxSyncOptions.items(pair, box: box), at: below, in: window, source: "sync")
    }

    private func glyph(lit: Bool, state: BoxSyncState) -> some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(Chrome.bodyMedium)
            .foregroundStyle(lit ? Theme.text : Theme.secondary)
            .frame(width: size, height: size)
            .background(lit ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(alignment: .topTrailing) { point(state) }
            // In sync ⇄ syncing ⇄ paused: the point changes colour softly.
            .animation(Motion.fade, value: state)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
    }

    /// The sync's one quiet point: accent in sync, pulsing while files move, grey while paused.
    @ViewBuilder private func point(_ state: BoxSyncState) -> some View {
        if let tint = state.point {
            let dot = Circle().fill(tint).frame(width: Size.statusPoint, height: Size.statusPoint)
            Group {
                if state == .moving { dot.pulse(low: Motion.blinkLow, period: Motion.blinkPeriod) } else { dot }
            }
            .padding(Size.avatarCutout)
            .background(Theme.background, in: Circle())
            .padding(Size.statusPointInset - Size.avatarCutout)
            .transition(.opacity)
        }
    }

    // MARK: The popup

    private var popup: some View {
        BoxSyncPopup(anchor: { frame.value }, close: close) {
            if let pairing = pairing.value {
                pairingCard(pairing)
            } else if let around = SyncPairList.shared.around(alias: box.alias, box: box.folder) {
                Text("Inside \(BoxFolder.lastPart(around.box)), synced locally to \(SyncPairs.shown(mac: around.mac))")
                    .font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(2)
            }
        }
    }

    private func pairingCard(_ pairing: BoxPairing) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // Whole: a refusal names the folder and the box in the way.
            Text(pairing.line)
                .font(Chrome.label)
                .foregroundStyle(pairing.failed ? Theme.danger : Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.sm) {
                Spacer(minLength: 0)
                switch pairing.state {
                case .checking:
                    Button("Cancel") { close() }.smallButton()
                        .storyID(StoryID.Boxes.pairing("checking.cancel"))
                case .ask(_, _, let mac):
                    // The level is the button: Files, or Files + chats.
                    Button("Cancel") { close() }.smallButton()
                        .storyID(StoryID.Boxes.pairing("ask.cancel"))
                    Button("Files") { finishPairing(mac) }.smallButton()
                        .storyID(StoryID.Boxes.pairing("files"))
                    Button("Files + chats") { finishPairing(mac, chats: true) }.smallButton(prominent: true)
                        .storyID(StoryID.Boxes.pairing("chats"))
                case .failed:
                    Button("Close") { close() }.smallButton()
                        .storyID(StoryID.Boxes.pairing("failed.close"))
                    Button("Pick another…") { startPairing() }.smallButton(prominent: true)
                        .storyID(StoryID.Boxes.pairing("failed.pick"))
                case .blocked(_, let other, let mac):
                    Button("Pick another…") { startPairing() }.smallButton()
                        .storyID(StoryID.Boxes.pairing("blocked.pick"))
                    Button("Unpair that first") {
                        SyncPairList.shared.unpair(alias: other.alias, box: other.box)
                        BoxBinding.pairsChanged()
                        check(mac)
                    }
                    .smallButton(prominent: true)
                    .storyID(StoryID.Boxes.pairing("blocked.unpair"))
                }
            }
        }
    }

    private func close() {
        checking.value?.cancel()
        checking.value = nil
        pairing.value = nil
        open.value = false
    }

    // MARK: Pairing

    /// Sync with a Mac folder…: the open-folder panel, then the pair checked, asked once when
    /// both have files or it's big, and kept.
    private func startPairing() {
        checking.value?.cancel()
        guard let mac = AppModel.shared?.chooseFolder(
            prompt: "Sync", message: "Sync \(BoxFolder.lastPart(box.folder)) on \(NodeNames.name(box.alias)) with a folder on this Mac")
        else { return close() }
        check(mac)
    }

    /// The Mac folder against the box folder: refused (another pair in the way offers Unpair
    /// that first), asked, or paired.
    private func check(_ mac: URL) {
        let place = BoxPlace(alias: box.alias, folder: box.folder)
        let pairs = SyncPairList.shared
        if let why = pairs.refusal(mac: mac, alias: box.alias, box: box.folder) {
            let other = pairs.blocker(mac: mac, alias: box.alias, box: box.folder)
            pairing.value = BoxPairing(place: place, state: other.map { .blocked(why, $0, mac) } ?? .failed(why))
            return
        }
        guard let ssh = SyncBox.box(box.connection) ?? SyncBox.ssh(box.alias) else {
            pairing.value = BoxPairing(place: place, state: .failed("\(NodeNames.name(box.alias)) has no way to copy files yet: no KoreNet link, no SSH alias"))
            return
        }
        pairing.value = BoxPairing(place: place, state: .checking(SyncPairs.shown(mac: mac.path)))
        let (alias, folder, link) = (box.alias, box.folder, box.connection)
        checking.value = Task {
            let check = await pairs.check(mac: mac, alias: alias, box: folder, via: ssh, link: link)
            guard !Task.isCancelled, pairing.value?.place == place else { return }
            switch check {
            case .go(let start):
                let line = "Sync \(BoxFolder.lastPart(folder)) with \(SyncPairs.shown(mac: mac.path))"
                pairing.value = BoxPairing(place: place, state: .ask(line, start, mac))
            case .ask(let question, let start): pairing.value = BoxPairing(place: place, state: .ask(question, start, mac))
            case .refuse(let why): pairing.value = BoxPairing(place: place, state: .failed(why))
            }
        }
    }

    private func finishPairing(_ mac: URL, chats: Bool = false) {
        SyncPairList.shared.pair(mac: mac, alias: box.alias, box: box.folder)
        if chats { SyncPairList.shared.setSyncsChats(true, mac: mac.standardizedFileURL.path) }
        BoxBinding.pairsChanged()
        close()
    }
}

/// The synced folder's option list (the same frame as a tab's menu): its one line (or why it's
/// paused), the bulk delete it waits on, the level, Keep syncing when closed, then its actions.
@MainActor
enum BoxSyncOptions {
    static func items(_ pair: SyncPair, box: BoxBinding) -> [OptionItem] {
        let pairs = SyncPairList.shared, sync = box.sync
        var items = [OptionItem(sync?.notice ?? "Synced locally to \(SyncPairs.shown(mac: pair.mac))", enabled: false)]
        if let deletes = sync?.askDeletes {
            items.append(OptionItem("Delete \(deletes.formatted()) files", destructive: true) { sync?.allowDeletes() })
        }
        items += [
            .rule,
            OptionItem("Files", checked: !pair.syncsChats) { pairs.setSyncsChats(false, mac: pair.mac) },
            OptionItem("Files + chats", checked: pair.syncsChats) { pairs.setSyncsChats(true, mac: pair.mac) },
            .rule,
            OptionItem("Keep syncing when closed", checked: pair.keepsSyncing) {
                pairs.setKeepsSyncing(!pair.keepsSyncing, mac: pair.mac)
                BoxBinding.pairsChanged()
            },
            .rule,
            OptionItem("Open on this Mac") { ChatMoving.openLocal(URL(fileURLWithPath: pair.mac)) },
            OptionItem("Show in Finder") { StoryHost.open(URL(fileURLWithPath: pair.mac)) },
            OptionItem("Stop syncing") {
                pairs.unpair(alias: box.alias, box: box.folder)
                BoxBinding.pairsChanged()
            },
        ]
        return items
    }
}

/// How the sync stands, as the button's point says it.
enum BoxSyncState: Equatable {
    /// No pair, and not inside one.
    case off
    case inSync
    case moving
    /// It has something to say: paused, or the box not watching.
    case paused
    /// Inside a folder that syncs.
    case inside

    @MainActor static func of(_ box: BoxBinding) -> BoxSyncState {
        let pairs = SyncPairList.shared
        guard pairs.pair(alias: box.alias, box: box.folder) != nil else {
            return pairs.around(alias: box.alias, box: box.folder) == nil ? .off : .inside
        }
        guard let sync = box.sync else { return .paused }
        if sync.notice != nil || sync.askDeletes != nil { return .paused }
        return sync.carrying ? .moving : .inSync
    }

    var point: Color? {
        switch self {
        case .off, .inside: nil
        case .inSync, .moving: Theme.accent
        case .paused: Theme.secondary
        }
    }

    @MainActor func help(_ box: BoxBinding) -> String {
        switch self {
        case .off: "Sync with a Mac folder…"
        case .inside: "Inside a synced folder"
        case .inSync: box.syncedTo.map { "Synced locally to " + $0 } ?? "In sync"
        case .moving: "Syncing"
        case .paused: box.sync?.notice ?? "Sync paused"
        }
    }
}

/// A small popup under a title-row button: opaque, accent corners, closed by a click outside it
/// or Esc.
struct BoxSyncPopup<Content: View>: View {
    let anchor: () -> CGRect
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)

    var body: some View {
        content()
            .padding(Space.md)
            .frame(width: Size.Box.popupWidth + Space.xxl, alignment: .leading)
            .panel(.panel)
            .cornerMarks(Theme.cornerOption)
            .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
            .background(WindowReader { window.value = $0 })
            .onAppear {
                monitor.value = WindowEvents.monitor([.leftMouseDown, .rightMouseDown, .keyDown]) { event in
                    guard let window = window.value, event.window === window, let view = window.contentView else { return event }
                    if event.type == .keyDown {
                        guard event.keyCode == 53 else { return event }
                        close()
                        return nil
                    }
                    let point = CGPoint(x: event.locationInWindow.x, y: view.bounds.height - event.locationInWindow.y)
                    if !frame.value.contains(point), !anchor().contains(point) { close() }
                    return event
                }
            }
            .onDisappear {
                if let m = monitor.value { NSEvent.removeMonitor(m) }
                monitor.value = nil
            }
    }
}

// MARK: - The link down

/// Over a box window while its box can't be reached (after 2 s, so a blip shows nothing): one
/// card in the middle, the chats dimmed but readable under it, the composer still taking
/// messages ("Sends when mybox is back"). Reconnecting… with Try again while it dials; the
/// box's own action (Start, Set up, Update) when it's set up wrong. It stays through a link that
/// comes and goes, and goes once the link has stayed back (`LinkDownCard`).
struct BoxOfflineDialog: View {
    let box: BoxBinding

    var body: some View {
        let model = box.linkCard
        let down = !box.connection.isOnline
        ZStack {
            if model.shown {
                Theme.background.opacity(0.45).allowsHitTesting(false).transition(.opacity)
                card.storyID(StoryID.Boxes.offline).transition(.opacity)
            }
        }
        .animation(Motion.fade, value: model.shown)
        // The link's each change, then a sleep to the card's next change: nothing runs while it's
        // hidden and the link is up.
        .task(id: down) {
            model.stableAfter = box.connection.stableAfter
            model.linked(!down, at: .now, heard: box.connection.lastHeard)
            while let wake = model.wake {
                try? await Task.sleep(until: wake, clock: .continuous)
                guard !Task.isCancelled else { return }
                model.tick(at: .now)
            }
        }
    }

    private var card: some View {
        let connection = box.connection
        let note = Self.note(box)
        return VStack(alignment: .leading, spacing: Space.sm) {
            Text(Self.line(box)).font(Chrome.bodyMedium).foregroundStyle(Theme.text).lineLimit(2)
            if let note, let action = note.action, action != .tryAgain {
                BoxNoteLine(note: note, alias: box.alias)
            } else if connection.phase == .refused(.paused) {
                // Taken offline here on purpose: nothing dials, so the one action is to bring it back.
                HStack(spacing: Space.sm) {
                    Circle().fill(Theme.tertiary).frame(width: Size.statusPoint, height: Size.statusPoint)
                    Text(Self.status(box, note: note)).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(2)
                    Spacer(minLength: Space.sm)
                    Button("Bring online") {
                        NetPauses.shared.set(box.alias, paused: false)
                        connection.bringOnline()
                        Devices.shared.changed()
                    }.smallButton()
                    .storyID(StoryID.Boxes.offlineBringOnline)
                }
            } else {
                HStack(spacing: Space.sm) {
                    // Trying: the dot pulses. Given up: it stays still (nothing runs until an event or Try again).
                    if connection.gaveUp {
                        Circle().fill(Theme.tertiary).frame(width: Size.statusPoint, height: Size.statusPoint)
                    } else {
                        Circle().fill(Theme.accent).frame(width: Size.statusPoint, height: Size.statusPoint)
                            .pulse(low: Motion.blinkLow, period: Motion.blinkPeriod)
                    }
                    Text(Self.status(box, note: note)).font(Chrome.label).foregroundStyle(Theme.secondary).lineLimit(2)
                    Spacer(minLength: Space.sm)
                    Button("Try again") { connection.retry() }.smallButton()
                        .storyID(StoryID.Boxes.offlineRetry)
                }
            }
        }
        .padding(Space.lg)
        .frame(width: Size.Box.agentsWidth, alignment: .leading)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
    }

    /// "mybox disconnected · last update 14:32".
    @MainActor static func line(_ box: BoxBinding) -> String {
        NodeNames.name(box.alias) + " disconnected" + ((box.connection.lastHeard ?? box.linkCard.lastHeard).map { " · last update " + BoxBinding.when($0) } ?? "")
    }

    /// The line by the dot: which way it's trying ("Reconnecting over Kore's tailnet · mybox-kore"),
    /// that the box keeps dropping, or, given up, what it tried (`ReconnectWords`).
    @MainActor static func status(_ box: BoxBinding, note: BoxList.Note?) -> String {
        let connection = box.connection
        if box.linkCard.keepsDropping, !connection.gaveUp { return NodeNames.name(box.alias) + " keeps dropping · Reconnecting…" }
        guard let note, !(note.action == .tryAgain && note.line == "Can't reach \(NodeNames.name(box.alias))") else { return connection.reconnectLine }
        return note.line
    }

    /// What the box's state says to do, from how the link ended; nil while it only dials again.
    @MainActor static func note(_ box: BoxBinding) -> BoxList.Note? {
        let connection = box.connection
        var state = BoxList.Box(alias: box.alias)
        state.status = BoxList.status(box.alias, phase: connection.phase, reason: connection.lastReason, lateHello: connection.lateHello)
        switch state.status {
        case .unknown, .probing, .ready: return nil
        default: return state.note
        }
    }
}

extension StoryID.Boxes {
    /// The link-down card's Try again and Bring online (storylines).
    package static let offlineRetry = offline.part(.retry)
    package static let offlineBringOnline = offline.part(.open)
    /// The Sync button's pairing card: a button by its state and role ("checking.cancel",
    /// "ask.cancel", "files", "chats", "failed.close", "failed.pick", "blocked.pick",
    /// "blocked.unpair") (storylines).
    package static func pairing(_ role: String) -> StoryID { StoryID(.titlebar, "boxsync.pairing", key: role) }
}
