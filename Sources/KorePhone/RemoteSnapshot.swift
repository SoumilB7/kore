import Foundation
import KoreCore
import KoreRemote
import KoreUI

/// Kore's state as the phone remote's wire values: windows, tabs, chats, cards and transcript
/// entries. Every cap on what goes to the phone is here, named.
@MainActor
package enum RemoteSnapshot {
    /// The most of a message, answer or notice's text sent at once; `entry.more` reads the rest.
    static let textCap = 64 * 1024
    /// A tool call's input.
    static let inputCap = 2 * 1024
    /// A tool's output: its start and its end.
    static let resultHead = 1024
    static let resultTail = 3 * 1024
    /// A card's body (the command or file it asks about).
    static let bodyCap = 4 * 1024
    /// A plan card's plan.
    static let planCap = 64 * 1024

    // MARK: Providers

    static func providers() -> [ProviderInfo] {
        Registry.all.map { p in
            ProviderInfo(
                id: p.id, name: p.name,
                modes: p.modes.map { ModeInfo(id: $0.id, label: $0.label, level: level($0), listed: $0.listed) },
                planToggle: p.planToggle.map { PlanToggleInfo(id: $0.id, label: $0.label) },
                features: ProviderFeatures(effort: true, fastMode: p.id == "claude"))
        }
    }

    /// A mode's level on the wire.
    static func level(_ mode: ModeOption) -> ModeLevel { ModeLevel(rawValue: mode.level) ?? .danger }

    // MARK: Windows

    /// The folder windows open now.
    static func workspaces() -> [Workspace] {
        Workspace.all.allObjects.filter { $0.window != nil }
    }

    static func windowID(_ workspace: Workspace) -> String { StableID.of(workspace.folder.path, prefix: "w_") }

    static func window(_ workspace: Workspace) -> WireWindow {
        let tabs = workspace.tabs.map { tab -> WireTab in
            let id = tab.id.uuidString
            if let board = tab.board {
                let sections = board.board.sections.map { section in
                    WireTab.Section(
                        id: section.id.uuidString, name: section.name,
                        chatIds: section.tiles.compactMap { board.chats[$0.id]?.id.uuidString })
                }
                return WireTab(id: id, kind: .board, title: tab.title, board: .init(sections: sections))
            }
            if let chat = tab.chat {
                return WireTab(id: id, kind: tab.agentID == nil ? .chat : .agent, title: tab.title, chatId: chat.id.uuidString)
            }
            return WireTab(id: id, kind: tab.isFile ? .file : .empty, title: tab.title)
        }
        return WireWindow(
            id: windowID(workspace), name: workspace.folder.lastPathComponent, path: homeRelative(workspace.folder.path), tabs: tabs,
            activeTabId: workspace.activeTab.id.uuidString)
    }

    /// Every chat open in a window: its tabs' chats, then its boards'.
    static func chats(_ workspace: Workspace) -> [Chat] {
        var seen = Set<ObjectIdentifier>()
        var out: [Chat] = []
        for tab in workspace.tabs {
            for chat in (tab.chat.map { [$0] } ?? []) + (tab.board?.orderedChats ?? []) where seen.insert(ObjectIdentifier(chat)).inserted {
                out.append(chat)
            }
        }
        return out
    }

    static func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Chats

    static func facts(_ chat: Chat) -> RemotePolicy.ChatFacts {
        let modes = Dictionary(chat.controls.availableModes.map { ($0.id, Self.level($0)) }, uniquingKeysWith: { a, _ in a })
        let current = chat.provider.modes.first { $0.id == chat.controls.mode }.map(Self.level) ?? .danger
        var cards: [String: RemotePolicy.ChatFacts.Card] = [:]
        for approval in chat.approvals.pending { cards[approval.id] = .init(kind: kind(approval)) }
        if chat.approvals.offerImplementPlan { cards[planReadyID] = .init(kind: .planReady) }
        return RemotePolicy.ChatFacts(level: current, planOn: chat.provider.planToggle != nil && chat.controls.planMode, modes: modes, cards: cards)
    }

    static func meta(_ chat: Chat, grant: RemotePolicy.Grant) -> ChatMeta {
        let facts = facts(chat)
        let state: ChatMeta.State =
            switch chat.attention {
            case .waiting: .needsYou
            case .failed: .failed
            case .stuck: .stuck
            case .working: .working
            case .idle: .idle
            }
        let sendable = RemotePolicy.check(.send(chatId: "", text: "."), facts, grant: grant) == .allow
        return ChatMeta(
            id: chat.id.uuidString, provider: chat.provider.id, title: chat.title, state: state,
            mode: .init(id: chat.controls.mode, level: facts.level, planOn: chat.provider.planToggle != nil ? chat.controls.planMode : nil),
            modeIds: chat.controls.availableModes.map(\.id), allowedModeIds: RemotePolicy.allowedModes(facts).sorted(),
            model: chat.controls.currentModel?.name, queued: chat.queuedCount, running: chat.isBusy, cards: cards(chat),
            can: .init(send: sendable && !chat.accountRestartPending, stop: chat.isWorking))
    }

    // MARK: Cards

    /// Codex's "Implement this plan?", which isn't an approval of the CLI's.
    static let planReadyID = "planReady"

    static func kind(_ approval: Approval) -> WireCard.Kind {
        if approval.signIn { return .signIn }
        if approval.plan != nil { return .plan }
        if !approval.questions.isEmpty { return .questions }
        return .permission
    }

    static func cards(_ chat: Chat) -> [WireCard] {
        var out = chat.approvals.pending.map { card($0, in: chat) }
        if chat.approvals.offerImplementPlan {
            out.append(
                WireCard(
                    id: planReadyID, kind: .planReady, title: "Implement this plan?",
                    actions: [.init(id: .implement, label: "Yes, implement it", style: .primary), .init(id: .stay, label: "Stay in Plan", style: .neutral)]))
        }
        return out
    }

    static func card(_ approval: Approval, in chat: Chat) -> WireCard {
        let agent: String? =
            switch approval.agent {
            case .main: nil
            case .sub(let id): chat.transcript.agent(id)?.name ?? id
            }
        let body = approval.body.map { capped($0, bodyCap) }
        let actions: [CardAction]
        var plan: [Block]?
        var questions: [WireQuestion]?
        switch kind(approval) {
        case .signIn, .unknown:
            actions = []
        case .plan:
            plan = doc(capped(approval.plan ?? "", planCap).text)
            actions = [
                .init(id: .approvePlan, label: "Yes, manually approve edits", style: .primary),
                .init(id: .approvePlanAcceptEdits, label: "Yes, and auto-accept edits", style: .neutral, refused: true),
                .init(id: .keepPlanning, label: "No, keep planning", style: .neutral),
            ]
        case .questions:
            questions = approval.questions.map { q in
                WireQuestion(
                    id: q.id, text: q.text, header: q.header,
                    options: q.options.map { .init(label: $0.label, description: $0.description, preview: $0.preview) }, multiple: q.multiple,
                    secret: q.secret, other: q.other)
            }
            actions = [.init(id: .submitAnswers, label: "Submit", style: .primary), .init(id: .deny, label: "Skip", style: .neutral)]
        case .permission, .planReady:
            actions =
                [.init(id: .allow, label: "Allow", style: .primary)]
                + (approval.canAlwaysAllow ? [.init(id: .allowAlways, label: "Always allow", style: .neutral, refused: true)] : [])
                + [.init(id: .deny, label: "Deny", style: .destructive)]
        }
        return WireCard(
            id: approval.id, kind: kind(approval), title: approval.title, detail: approval.detail, body: body?.text,
            bodyLen: body?.cut == true ? body?.length : nil, plan: plan, questions: questions, agent: agent, actions: actions)
    }

    // MARK: Transcript

    static func entry(_ e: TranscriptStore.Entry, folder: URL) -> WireEntry {
        let kind: WireEntry.Kind =
            switch e.kind {
            case .user: .user
            case .answer: .answer
            case .thinking: .thinking
            case .plan: .plan
            case .tool: .tool
            case .agent: .agent
            case .notice: .notice
            case .peer: .peer
            case .divider: .divider
            case .mode: .mode
            case .summary: .summary
            }
        let text = capped(e.text, textCap)
        let formatted = [.answer, .plan, .summary].contains(kind)
        var tool: WireEntry.Tool?
        if e.kind == .tool, let name = e.toolName {
            let input = e.input.map { capped($0, inputCap) }
            let result = e.result.map(headAndTail)
            tool = WireEntry.Tool(
                name: name, summary: e.summary, input: input?.text, inputLen: e.input?.unicodeScalars.count ?? 0,
                path: e.path.map { relative($0, to: folder) }, readOnly: e.readOnly, result: result,
                resultLen: e.result?.unicodeScalars.count ?? 0)
        }
        return WireEntry(
            id: e.id.uuidString, kind: kind, turn: e.turn, text: formatted || e.text.isEmpty ? nil : text.text,
            doc: formatted && !e.text.isEmpty ? doc(text.text) : nil, textLen: text.length, done: e.done, isError: e.isError,
            stopped: e.stopped, inTurn: e.inTurn, tool: tool,
            changes: e.changes.isEmpty ? nil : e.changes.map { .init(path: relative($0.path, to: folder), added: $0.added, removed: $0.removed) },
            agent: e.agent.map { .init(id: $0.id, name: $0.name, status: $0.statusName) })
    }

    static func turn(_ t: TranscriptStore.Turn) -> WireTurn {
        let outcome: WireTurn.Outcome =
            switch t.outcome {
            case .completed: .completed
            case .interrupted: .interrupted
            case .failed: .failed
            case .authFailed: .authFailed
            case .slept: .slept
            }
        return WireTurn(
            id: t.id, startedAt: (t.startedAt.timeIntervalSince1970 * 1000).rounded(), duration: t.duration, finished: t.finished,
            outcome: outcome)
    }

    // MARK: Text

    /// At most `cap` of the text, and its whole length (in Unicode scalars, as `entry.more` counts).
    static func capped(_ text: String, _ cap: Int) -> (text: String, length: Int, cut: Bool) {
        let scalars = text.unicodeScalars
        let length = scalars.count
        guard length > cap else { return (text, length, false) }
        var head = String.UnicodeScalarView()
        head.append(contentsOf: scalars.prefix(cap))
        return (String(head), length, true)
    }

    /// A tool's output, its start and end when it's long.
    static func headAndTail(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > resultHead + resultTail else { return text }
        var head = String.UnicodeScalarView()
        head.append(contentsOf: scalars.prefix(resultHead))
        var tail = String.UnicodeScalarView()
        tail.append(contentsOf: scalars.suffix(resultTail))
        return String(head) + "\n…\n" + String(tail)
    }

    static func relative(_ path: String, to folder: URL) -> String {
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : homeRelative(path)
    }

    /// Markdown as the phone's render tree, parsed by Kore's own parser.
    static func doc(_ text: String) -> [Block] {
        MarkdownParser.parse(Substring(text), base: 0, zoom: 1).map(block)
    }

    private static func block(_ b: MarkdownBlock) -> Block {
        switch b.kind {
        case .heading(let level, let text): .heading(level: level, spans: spans(text))
        case .paragraph(let text): .paragraph(spans(text))
        case .code(let language, let text): .code(lang: language, text: text, open: b.isOpen)
        case .list(let list):
            .list(
                ordered: list.ordered, start: list.start,
                items: list.items.map { ListItem(task: $0.task, blocks: $0.blocks.map(block)) })
        case .quote(let blocks): .quote(blocks.map(block))
        case .table(let table): .table(header: table.header.map(spans), rows: table.rows.map { $0.map(spans) })
        case .rule: .rule
        }
    }

    private static func spans(_ string: AttributedString) -> [Span] {
        string.runs.map { run in
            let text = String(string[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            return Span(
                text, code: intent.contains(.code) ? true : nil, em: intent.contains(.emphasized) ? true : nil,
                strong: intent.contains(.stronglyEmphasized) ? true : nil, strike: intent.contains(.strikethrough) ? true : nil,
                link: run.link?.absoluteString)
        }
    }
}
