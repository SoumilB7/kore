import Foundation
import KoreCore
import LinkProtocol
import src

/// The box's own titles and archive for its CLIs' past sessions that aren't box chats (1.9):
/// `history.json` in the box's state (0600). The CLIs' own lists aren't touched.
struct HostHistoryKept: Codable, Sendable, Equatable {
    var titles: [String: String] = [:]
    var archived: Set<String> = []
}

/// Link 1.9: a folder's history on the box, as a Mac window's History shows a folder's: the
/// chats closed there, and the past sessions each CLI on the box keeps for that folder. Opened,
/// renamed and archived from any client.
extension HostDaemon {
    private var historyURL: URL { paths.state.appendingPathComponent("history.json") }

    private var kept: HostHistoryKept {
        get {
            if let historyKept { return historyKept }
            let read = (try? Data(contentsOf: historyURL)).flatMap { try? JSONDecoder().decode(HostHistoryKept.self, from: $0) } ?? HostHistoryKept()
            historyKept = read
            return read
        }
        set {
            historyKept = newValue
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(newValue) { try? HostPaths.privateFile(data, to: historyURL) }
        }
    }

    /// The box chat that is, or holds, `id`: by its own id, or by its CLI's session.
    func boxChat(_ id: String) -> HostChat? {
        chats.first { $0.id == id || $0.record.session == id } ?? closedChats.first { $0.id == id || $0.record.session == id }
    }

    /// A folder's history, newest first: its closed chats and its CLIs' past sessions that aren't
    /// a box chat's, archived ones only when `archived`. Codex lists through its app-server, so a
    /// list may take a moment; nothing runs until a client asks.
    func history(windowId: String, query: String?, archived: Bool) async -> [HistorySession] {
        guard let folder = folder(windowId: windowId) else { return [] }
        let words = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        func shown(_ title: String) -> Bool { words.isEmpty || title.lowercased().contains(words) }
        var out: [HistorySession] = closedChats.filter { $0.record.folder == folder && ($0.record.archived == true) == archived && shown($0.title) }.map {
            HistorySession(
                id: $0.id, provider: $0.record.provider, title: $0.title, updatedAt: Int64($0.closedAt.timeIntervalSince1970 * 1000),
                archived: $0.record.archived == true, open: false)
        }
        let boxSessions = Set((chats + closedChats).compactMap(\.record.session))
        let kept = self.kept
        let list = pastSessions
        let url = URL(fileURLWithPath: folder)
        for provider in Registry.all {
            for session in await list(provider, url) ?? [] where !boxSessions.contains(session.id) {
                let title = kept.titles[session.id] ?? session.title
                let isArchived = session.archived || kept.archived.contains(session.id)
                guard isArchived == archived, shown(title) else { continue }
                out.append(
                    HistorySession(
                        id: session.id, provider: provider.id, title: title, updatedAt: Int64(session.updated.timeIntervalSince1970 * 1000),
                        archived: isArchived, open: false))
            }
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// `history.open`, `history.rename`, `history.archive`: a closed box chat, or a past session of
    /// the folder's CLIs. The result of an open names the chat (`chatId`, `windowId`).
    func historyOp(_ kind: ControlKind, _ args: ControlArgs, id: String, reply: @escaping @MainActor (LinkMessage.Result) -> Void) -> LinkMessage.Result? {
        func fail(_ code: ResultCode, _ message: String) -> LinkMessage.Result { .init(id: id, ok: false, code: code, message: message) }
        guard let session = args.sessionId else { return fail(.invalid, "Name the chat.") }
        let hc = boxChat(session)
        switch kind {
        case .historyOpen:
            if let hc {
                // Opened, it's no longer archived.
                hc.setArchived(false)
                let open = chats.contains { $0 === hc } ? hc : reopen(hc.id)
                guard let open else { return fail(.goneSession, "That chat isn't kept any more.") }
                return .init(id: id, ok: true, chatId: open.id, windowId: Self.windowID(open.record.folder))
            }
            guard let folder = args.windowId.flatMap(folder(windowId:)) else { return fail(.goneWindow, "Name the folder it's in.") }
            Task {
                // A past session of the folder's CLI: a box chat resuming it.
                guard let (provider, listed) = await pastSession(session, named: args.provider, folder: folder) else {
                    return reply(fail(.goneSession, "That chat isn't in this folder's history."))
                }
                let title = args.title ?? kept.titles[session] ?? (listed.title.isEmpty ? nil : listed.title)
                guard let made = newChat(folder: folder, provider: provider, modelId: nil, title: title, session: session) else {
                    return reply(fail(.goneFolder, "That folder isn't on this box."))
                }
                kept.titles[session] = nil
                reply(.init(id: id, ok: true, chatId: made.id, windowId: Self.windowID(folder)))
            }
            return nil
        case .historyRename:
            let title = (args.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let hc {
                hc.setTitle(title)
                if let chat = hc.chat { chat.rename(title) }
                if chats.contains(where: { $0 === hc }) { broadcast(chats: [hc]) }
            } else {
                kept.titles[session] = title
            }
            return .init(id: id, ok: true)
        case .historyArchive:
            let on = args.on ?? true
            if let hc {
                // An open chat archived closes, as a Mac window's tab does.
                if on, chats.contains(where: { $0 === hc }) { close(hc) }
                hc.setArchived(on)
            } else if on {
                kept.archived.insert(session)
            } else {
                kept.archived.remove(session)
            }
            return .init(id: id, ok: true)
        default:
            return fail(.invalid, "Not taken here.")
        }
    }

    /// The CLI that lists a past session for the folder, and the session as listed: the CLI
    /// named, else each in turn (Claude's list is a file read; Codex is asked only after).
    private func pastSession(_ session: String, named: String?, folder: String) async -> (String, SessionSummary)? {
        let url = URL(fileURLWithPath: folder)
        let list = pastSessions
        for provider in Registry.all where named == nil || named == provider.id {
            if let found = await list(provider, url)?.first(where: { $0.id == session }) { return (provider.id, found) }
        }
        return nil
    }
}
