import Foundation
import KoreCore
import KoreUI
import LinkProtocol
import src

/// Kore's state as the agent channel's values: Watch's reads, built from what the local link
/// already reads (`LinkSnapshot`), plain text instead of render trees.
@MainActor
enum AgentReads {
    /// The most of a row's text sent; `textLen` says how long it was.
    static let textCap = 16 * 1024
    /// Rows `tx.read` gives by default, and at most.
    static let page = 20
    static let pageMax = 200
    /// The most of a card's questions sent, and of each one's options.
    static let questionsMax = 16
    static let optionsMax = 32
    /// Rows a follow starts with, and how far back it looks for changes.
    static let followWindow = 40

    static func short(_ id: String) -> String { AgentRefs.short(id) }

    /// The windows a caller sees: a closed one can stay in `Workspace.all` until it's freed.
    static func workspaces() -> [Workspace] { LinkSnapshot.workspaces().filter { !$0.isClosed } }

    static func workspace(of chat: Chat) -> Workspace? { workspaces().first { LinkSnapshot.chats($0).contains { $0 === chat } } }

    static func chatsByID() -> [String: Chat] {
        var out: [String: Chat] = [:]
        for workspace in workspaces() {
            for chat in LinkSnapshot.chats(workspace) { out[chat.id.uuidString] = chat }
        }
        return out
    }

    /// The open chats a caller may read, window by window, tab order: those in the folder of the
    /// caller's own chat, and those whose own access is above Off. A caller outside Kore's chats
    /// has no folder, so only the second.
    static func readable(own: String?) -> [Chat] {
        let home = own.flatMap { chatsByID()[$0] }.flatMap(workspace(of:))?.folder.standardizedFileURL.path
        return workspaces().flatMap { w -> [Chat] in
            let same = w.folder.standardizedFileURL.path == home
            return LinkSnapshot.chats(w).filter { same || AgentGrants.tier(chat: $0.id.uuidString) != .off }
        }
    }

    static func title(_ text: String) -> String { LinkSnapshot.capped(text, LinkSnapshot.inputCap).text }

    static func state(_ chat: Chat) -> String {
        switch chat.attention {
        case .waiting: "needs-you"
        case .failed: "failed"
        case .stuck: "stuck"
        case .working: "working"
        case .idle: "idle"
        }
    }

    static func chat(_ chat: Chat, in workspace: Workspace?, own: String?) -> AgentChat {
        let id = chat.id.uuidString
        let mode = chat.provider.modes.first { $0.id == chat.controls.mode }
        let folder = workspace?.folder ?? chat.folder
        return AgentChat(
            id: id, short: short(id), title: title(chat.title), provider: chat.provider.id,
            folder: workspace?.boxFolder ?? LinkSnapshot.homeRelative(folder.path),
            window: folder.lastPathComponent, state: state(chat), mode: chat.controls.mode, modeLabel: mode?.label,
            planOn: chat.provider.planToggle != nil ? chat.controls.planMode : nil, model: chat.controls.currentModel?.name,
            queued: chat.queuedCount, cards: LinkSnapshot.cards(chat).count, own: id == own ? true : nil,
            alwaysAllowed: chat.alwaysAllowed ? true : nil)
    }

    /// Every chat this caller may read, window by window, tab order; `scope`: one window's.
    static func chats(own: String?, scope: String? = nil) -> [AgentChat] {
        readable(own: own).compactMap { chat in
            let window = workspace(of: chat)
            guard window.map({ named($0, scope) }) ?? (scope == nil) else { return nil }
            return Self.chat(chat, in: window, own: own)
        }
    }

    /// Each window's strip as `chats.list` gives it: the caller's own whole, another only the
    /// tabs of the chats it may read (no files, boards or sub-agents' tabs). `scope`: one window.
    static func windows(own: String?, scope: String? = nil) -> [AgentWindow] {
        let shown = Set(readable(own: own).map(ObjectIdentifier.init))
        let home = own.flatMap { chatsByID()[$0] }.flatMap(workspace(of:))
        return workspaces().compactMap { window in
            guard named(window, scope) else { return nil }
            let here = window === home
            let view = window.arsenalView(whole: here) { shown.contains(ObjectIdentifier($0)) }
            guard here || !view.tabs.isEmpty else { return nil }
            let groups = view.groups.map { AgentWindow.Group(name: $0.name, by: $0.by, folded: $0.folded ? true : nil, tabs: $0.tabs) }
            return AgentWindow(
                name: view.name, selected: view.selected, tabs: view.tabs, groups: groups.isEmpty ? nil : groups,
                other: view.other.isEmpty ? nil : view.other, here: here ? true : nil)
        }
    }

    /// A window `scope` names (its name, or its folder as listed); every one when nil.
    static func named(_ window: Workspace, _ scope: String?) -> Bool {
        guard let scope = scope?.trimmingCharacters(in: .whitespaces).lowercased(), !scope.isEmpty else { return true }
        let folder = window.boxFolder ?? LinkSnapshot.homeRelative(window.folder.path)
        return window.folder.lastPathComponent.lowercased() == scope || folder.lowercased() == scope
    }

    static func detail(_ chat: Chat, own: String?) -> AgentChatDetail {
        let workspace = workspace(of: chat)
        let context = chat.agentContext.map { c in
            AgentChatDetail.Context(used: c.used, window: c.window, pct: chat.linkControlState.contextPct)
        }
        return AgentChatDetail(
            chat: self.chat(chat, in: workspace, own: own), session: chat.sessionId, effort: chat.linkControlState.effort, context: context,
            rows: chat.transcript.entries.count, pending: cards(chat))
    }

    static func cards(_ chat: Chat) -> [AgentCard] {
        let id = chat.id.uuidString
        return LinkSnapshot.cards(chat).map { card in
            AgentCard(
                chat: id, chatShort: short(id), chatTitle: title(chat.title), id: card.id, kind: card.kind.rawValue, title: LinkSnapshot.capped(card.title, LinkSnapshot.inputCap).text,
                detail: card.detail.map { LinkSnapshot.capped($0, LinkSnapshot.bodyCap).text }, body: card.body.map { LinkSnapshot.capped($0, LinkSnapshot.bodyCap).text },
                questions: card.questions?.prefix(questionsMax).map { question in
                    .init(
                        text: LinkSnapshot.capped(question.text, LinkSnapshot.bodyCap).text,
                        options: question.options.prefix(optionsMax).map { LinkSnapshot.capped($0.label, LinkSnapshot.inputCap).text })
                })
        }
    }

    static func row(_ e: TranscriptStore.Entry, folder: URL) -> AgentRow {
        let kind: String =
            switch e.kind {
            case .user: "user"
            case .answer: "answer"
            case .thinking: "thinking"
            case .plan: "plan"
            case .tool: "tool"
            case .agent: "agent"
            case .notice: "notice"
            case .peer: "peer"
            case .divider: "divider"
            case .mode: "mode"
            case .summary: "summary"
            }
        let text = LinkSnapshot.capped(e.text, textCap)
        var tool: AgentRow.Tool?
        if e.kind == .tool, let name = e.toolName {
            tool = AgentRow.Tool(
                name: name, summary: e.summary.map { LinkSnapshot.capped($0, LinkSnapshot.inputCap).text }, path: e.path.map { LinkSnapshot.relative($0, to: folder) },
                input: e.input.map { LinkSnapshot.capped($0, LinkSnapshot.inputCap).text }, result: e.result.map(LinkSnapshot.headAndTail))
        }
        return AgentRow(
            id: e.id.uuidString, kind: kind, turn: e.turn, text: e.text.isEmpty ? nil : text.text, textLen: text.cut ? text.length : nil,
            tool: tool, agent: e.agent?.name, done: e.done, error: e.isError ? true : nil, stopped: e.stopped ? true : nil)
    }

    /// Up to `last` rows ending before the row `before` (the newest when nil).
    static func rows(_ chat: Chat, last: Int?, before: String?) -> AgentRows {
        let entries = chat.transcript.entries
        let end = before.flatMap { id in entries.firstIndex { $0.id.uuidString == id } } ?? entries.count
        let count = min(max(last ?? page, 1), pageMax)
        let start = max(0, end - count)
        return AgentRows(chat: chat.id.uuidString, rows: entries[start..<end].map { row($0, folder: chat.folder) }, more: start > 0)
    }

    /// A row a follow sends: it's finished, or of a kind that doesn't stream. The rest wait for
    /// the turn to end, so a growing answer isn't encoded again every tenth of a second.
    static func settled(_ e: TranscriptStore.Entry) -> Bool {
        switch e.kind {
        case .user, .notice, .peer, .divider, .mode, .summary: true
        default: e.done || e.stopped || e.isError
        }
    }

    /// What a row looks like now, cheaply: a follow resends a row whose mark changed.
    static func mark(_ e: TranscriptStore.Entry) -> Int {
        var h = Hasher()
        h.combine(e.text.utf8.count)
        h.combine(e.result?.utf8.count ?? -1)
        h.combine(e.input?.utf8.count ?? -1)
        h.combine(e.summary)
        h.combine(e.done)
        h.combine(e.isError)
        h.combine(e.stopped)
        h.combine(e.agent?.statusName)
        return h.finalize()
    }

    static func history(_ workspace: Workspace, query: String?, archived: Bool, offset: Int) -> AgentHistory {
        let (sessions, more) = LinkSnapshot.history(workspace, query: query, archived: archived, offset: offset)
        let format = ISO8601DateFormatter()
        return AgentHistory(
            folder: workspace.boxFolder ?? LinkSnapshot.homeRelative(workspace.folder.path),
            sessions: sessions.map {
                AgentSession(
                    id: $0.id, provider: $0.provider, title: title($0.title),
                    updated: format.string(from: Date(timeIntervalSince1970: Double($0.updatedAt) / 1000)), archived: $0.archived, open: $0.open)
            }, more: more)
    }
}
