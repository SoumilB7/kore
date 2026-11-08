import AppKit
import HostClient
import KoreCore
import LinkProtocol
import src
import SwiftUI

/// A Mac folder synced with a box folder (`syncPairs`): the box's chats there, for the window's
/// one cue ("mybox · 1 chat here · Open") and its History. It never links on its own: the count
/// is the live link's while something else holds it (a box window), else the box's last saved
/// state; History holds the link while it's open, and a row it opens holds it until it's done.
@MainActor @Observable
final class PairedBox {
    let alias: String
    /// The box's folder, absolute on the box.
    let folder: String
    /// The open chats as last saved here, while no link is up.
    private var saved: [ChatMeta] = []
    /// The link, while something holds it.
    @ObservationIgnored private weak var live: HostConnection?
    /// Bumped as the link comes and goes, so the cue reads it again.
    private var linkTurn = 0
    @ObservationIgnored private var held: HostConnection?
    @ObservationIgnored private let cacheRoot: URL

    /// The pair a Mac folder is in, if any.
    static var pairFor: @MainActor (URL) -> SyncPair? = { SyncPairs.pair(mac: $0.standardizedFileURL.path) }
    /// Brings a box folder's window forward (opened if it isn't), a chat of it in front.
    static var openBox: @MainActor (BoxPlace, String?) -> Void = { AppModel.shared?.openBox($0, chat: $1) }
    /// How long a row waits for the box to link before giving up.
    static var patience: Duration = .seconds(10)

    init(alias: String, folder: String, cacheRoot: URL = HostCache.root()) {
        self.alias = alias
        self.folder = folder
        self.cacheRoot = cacheRoot
        refresh()
    }

    /// The window's pair, if its folder has one.
    static func of(_ folder: URL) -> PairedBox? {
        pairFor(folder).map { PairedBox(alias: $0.alias, folder: $0.box) }
    }

    var place: BoxPlace { BoxPlace(alias: alias, folder: folder) }

    /// The cue's Open: the box's window for the folder forward, opened if it isn't.
    func openWindow() { Self.openBox(place, nil) }

    /// The box's open chats in the folder: live while linked, else as last saved.
    var chats: [ChatMeta] {
        _ = linkTurn
        return live.map { $0.chats(in: folder) } ?? saved
    }

    /// The cue's words, nil when the box has no chat open there.
    var line: String? {
        let count = chats.count
        guard count > 0 else { return nil }
        return "\(alias) · \(count) \(count == 1 ? "chat" : "chats") here"
    }

    /// The link again if something holds it, else the saved state (a file read, no link).
    func refresh() {
        live = held ?? HostConnection.existing(alias)
        if live == nil { saved = HostCache(alias: alias, root: cacheRoot).chats(in: folder) }
        linkTurn += 1
    }

    // MARK: History

    /// History is open: the link is held (dialed if nothing else holds it) until it closes.
    func hold() {
        guard held == nil else { return }
        let connection = BoxBinding.connection(alias)
        connection.retain()
        held = connection
        refresh()
    }

    func letGo() {
        guard let connection = held else { return }
        held = nil
        connection.release()
        refresh()
    }

    /// The box's chats for History: those open there now, then its closed ones and its CLIs' past
    /// sessions (`history.list`) once linked. Their ids, and which are open.
    func rows() async -> (rows: [SessionSummary], open: Set<String>) {
        let openRows = chats.compactMap { meta -> SessionSummary? in
            guard let provider = Registry.provider(meta.provider) else { return nil }
            return SessionSummary(id: meta.id, agent: provider.historyAgent, title: meta.title.isEmpty ? "New chat" : meta.title, updated: .now)
        }
        let open = Set(openRows.map(\.id))
        guard let connection = await linked() else { return (openRows, open) }
        let liveOpen = connection.chats(in: folder).compactMap { meta -> SessionSummary? in
            guard let provider = Registry.provider(meta.provider) else { return nil }
            return SessionSummary(id: meta.id, agent: provider.historyAgent, title: meta.title.isEmpty ? "New chat" : meta.title, updated: .now)
        }
        let closed = await connection.closedChats(windowId: connection.windowId(of: folder)).compactMap { session -> SessionSummary? in
            guard let provider = Registry.provider(session.provider) else { return nil }
            return SessionSummary(id: session.id, agent: provider.historyAgent, title: session.title, updated: Date(timeIntervalSince1970: Double(session.updatedAt) / 1000))
        }
        return (liveOpen + closed.filter { !liveOpen.map(\.id).contains($0.id) }, Set(liveOpen.map(\.id)))
    }

    /// A History row in the box's window: an open chat at once; a closed one or a past session
    /// back on the box first (held meanwhile), then its tab in front.
    func open(_ row: SessionSummary, isOpen: Bool) async {
        if isOpen { return Self.openBox(place, row.id) }
        let connection = BoxBinding.connection(alias)
        connection.retain()
        defer { connection.release() }
        guard await linked(connection) != nil else { return }
        let chatId: String?
        if connection.keepsHistory {
            let provider = Registry.provider(for: row.agent)
            let args = ControlArgs(windowId: connection.windowId(of: folder), title: row.title, provider: provider.id, sessionId: row.id)
            if case .success(let result) = await connection.history(.historyOpen, args) { chatId = result.chatId } else { chatId = nil }
        } else if case .success(let id) = await connection.reopen(row.id) {
            chatId = id
        } else {
            chatId = nil
        }
        if let chatId { Self.openBox(place, chatId) }
    }

    /// The held link once it's up; nil when it can't link in time.
    private func linked(_ connection: HostConnection? = nil) async -> HostConnection? {
        guard let connection = connection ?? held else { return nil }
        let end = ContinuousClock.now + Self.patience
        while ContinuousClock.now < end, !connection.isOnline, connection.phase != .offline {
            if case .refused = connection.phase { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if live !== connection { refresh() }
        return connection.isOnline ? connection : nil
    }
}

/// The paired Mac window's one cue, after its folder's name: "mybox · 1 chat here · Open". Shown
/// only while the box has a chat open there; Open brings the box's window for it forward.
struct PairedBoxCue: View {
    let paired: PairedBox
    @StateObject private var hovered = Local(false)

    var body: some View {
        if let line = paired.line {
            Button(action: paired.openWindow) {
                HStack(spacing: Space.xs) {
                    Text(line).foregroundStyle(Theme.tertiary)
                    Text("·").foregroundStyle(Theme.tertiary)
                    Text("Open").foregroundStyle(hovered.value ? Theme.text : Theme.accent)
                }
                .font(Chrome.label)
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered.value = $0 }
            .help("\(paired.alias) · \(paired.folder)")
            .layoutPriority(-1)
        }
    }
}
