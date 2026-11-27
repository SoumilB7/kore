import Foundation
import KoreCore

/// A past session's newest page as events, read without its CLI: what a box shows of a session
/// it never kept (one opened from History, one run in a terminal there) before a send starts
/// the CLI, whose own replay then takes over.
package struct PastPage: Sendable {
    package let events: [ChatEvent]
    /// There's history before the page.
    package let more: Bool

    package init(events: [ChatEvent], more: Bool) {
        self.events = events
        self.more = more
    }

    /// Claude's transcript, a long one read from its end (`ClaudeTranscript.latest`), as a
    /// resumed chat's first page is.
    @Sendable
    static func claude(_ id: String, folder: URL) async -> PastPage? {
        await claude(ClaudeTranscript(sessionId: id, in: folder), id: id, folder: folder)
    }

    /// The user turns a page holds when the session has no compaction to start from.
    static let claudeTurns = 10

    static func claude(_ reader: ClaudeTranscript, id: String, folder: URL) async -> PastPage? {
        let (page, more) = await Task.detached(priority: .userInitiated) { () -> (ClaudeHistory.Page, Bool) in
            // Back to its last compaction when it has one near the end (what's before it is the
            // earlier history); else its newest turns only, never the whole of a long session.
            if let latest = reader.latest(), latest.from > 0 { return (latest.page, true) }
            let page = reader.page(userTurns: claudeTurns)
            return (page, page.earlier != nil)
        }.value
        guard !page.messages.isEmpty else { return nil }
        let replayed = await ClaudeTranslator.replayed(page.messages, folder: folder, sessionId: id)
        return PastPage(events: replayed.events, more: more)
    }

    /// The turns a page holds, as a resumed Codex chat's first page does.
    static let codexTurns = 10

    /// Codex's newest turns from a short-lived app-server that only reads the thread (it never
    /// resumes it), with their settings from the end of its rollout.
    @Sendable
    static func codex(_ id: String, folder: URL) async -> PastPage? {
        guard let server = try? await CodexAppServer.start(cwd: folder) else { return nil }
        defer { Task { await server.close() } }
        let thread = try? await server.request("thread/read", ["threadId": .string(id), "includeTurns": false])["thread"]
        var turns: [JSONValue]
        var more: Bool
        let params: JSONValue = [
            "threadId": .string(id), "sortDirection": "desc", "limit": .number(Double(codexTurns)), "itemsView": "full",
        ]
        if let listed = try? await server.request("thread/turns/list", params) {
            turns = (listed["data"]?.array ?? []).reversed()
            more = listed["nextCursor"]?.string != nil
        } else if let whole = try? await server.request("thread/read", ["threadId": .string(id), "includeTurns": true]) {
            // An app-server without the paged list: the whole thread, its newest turns kept.
            let all = whole["thread"]?["turns"]?.array ?? []
            turns = Array(all.suffix(codexTurns))
            more = all.count > turns.count
        } else {
            return nil
        }
        return await codex(turns, more: more, rollout: thread?["path"]?.string, folder: folder)
    }

    /// A page of turns as events, with their settings from the rollout at `path`.
    static func codex(_ turns: [JSONValue], more: Bool, rollout path: String?, folder: URL) async -> PastPage? {
        guard !turns.isEmpty else { return nil }
        var rollout = CodexRollout()
        if let path {
            let wanted = turns.map { CodexRolloutReader.Turn(id: $0["id"]?.string ?? "", start: CodexTranslator.date($0["startedAt"])) }
            rollout = await Task.detached(priority: .userInitiated) {
                var reader = CodexRolloutReader(path: path)
                return reader.read(wanted)
            }.value
        }
        let replayed = await CodexTranslator.replayed(turns, rollout: rollout, folder: folder)
        return PastPage(events: replayed.events, more: more)
    }
}
