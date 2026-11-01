import Foundation
import KoreCore
import KoreUI

/// Kore's state as the link's wire values: windows, tabs, chats, cards and transcript entries.
/// Every cap on what goes over the link is here, named.
@MainActor
enum LinkSnapshot {
    /// The most of a message, answer or notice's text sent at once; `entry.more` reads the rest.
    static let textCap = 64 * 1024
    /// A tool call's input.
    static let inputCap = 2 * 1024
    /// A tool's output: its start and its end.
    static let resultHead = 1024
    static let resultTail = 3 * 1024
    /// A card's content as shown; `card.more` reads the rest.
    static let bodyCap = 4 * 1024
    /// A plan card's plan, as a render tree.
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

    static func level(_ mode: ModeOption) -> ModeLevel { ModeLevel(rawValue: mode.level) ?? .danger }

    // MARK: Windows

    /// The folder windows open now.
    static func workspaces() -> [Workspace] {
        Workspace.all.allObjects.filter { $0.window != nil }
    }

    static func windowID(_ workspace: Workspace) -> String { StableID.of(workspace.folder.path, prefix: "w_") }

    static func window(_ workspace: Workspace) -> LinkWindow { window(workspace, full: false) }

    /// `full`: with the run's full control, its groups and whether a closed tab can come back too.
    static func window(_ workspace: Workspace, full: Bool) -> LinkWindow {
        let groups = workspace.tabGroups
        let tabs = workspace.tabs.map { tab -> LinkTab in
            var made = linkTab(tab)
            if full { made.groupId = groups.member[tab.id]?.uuidString }
            return made
        }
        return LinkWindow(
            id: windowID(workspace), name: workspace.folder.lastPathComponent, path: homeRelative(workspace.folder.path), tabs: tabs,
            activeTabId: workspace.activeTab.id.uuidString,
            groups: full ? groups.groups.map { LinkGroup(id: $0.id.uuidString, name: $0.name, color: $0.color.rawValue, folded: $0.folded) } : nil,
            canReopenTab: full ? workspace.linkCanReopenTab : nil)
    }

    private static func linkTab(_ tab: ChatTab) -> LinkTab {
        let id = tab.id.uuidString
        if let board = tab.board {
            let sections = board.board.sections.map { section in
                LinkTab.Section(
                    id: section.id.uuidString, name: section.name,
                    chatIds: section.tiles.compactMap { board.chats[$0.id]?.id.uuidString })
            }
            return LinkTab(id: id, kind: .board, title: tab.title, board: .init(sections: sections))
        }
        if let chat = tab.chat {
            return LinkTab(id: id, kind: tab.agentID == nil ? .chat : .agent, title: tab.title, chatId: chat.id.uuidString)
        }
        return LinkTab(id: id, kind: tab.isFile ? .file : .empty, title: tab.title)
    }

    /// The window a chat is open in.
    static func workspace(of chat: Chat) -> Workspace? { workspaces().first { chats($0).contains { $0 === chat } } }

    /// The chat's own tab (not an agent's) in `workspace`.
    static func tab(of chat: Chat, in workspace: Workspace) -> ChatTab? { workspace.tabs.first { $0.chat === chat && $0.agentID == nil } }

    /// The board tab holding the chat.
    static func board(of chat: Chat, in workspace: Workspace) -> ChatTab? {
        workspace.tabs.first { $0.board?.orderedChats.contains { $0 === chat } == true }
    }

    // MARK: The Mac (full control)

    /// A recent folder's opaque id: the link names folders only by Kore's recents.
    static func recentID(_ folder: URL) -> String { StableID.of(folder.path, prefix: "r_") }

    static func recent(_ id: String) -> URL? { AppModel.shared?.linkRecents.first { recentID($0) == id } }

    static func mac() -> MacState {
        let recents = (AppModel.shared?.linkRecents ?? []).prefix(20).map {
            MacState.Recent(id: recentID($0), name: $0.lastPathComponent, path: homeRelative($0.path))
        }
        return MacState(
            recents: Array(recents), canReopenWindow: AppModel.shared?.linkCanReopenWindow ?? false,
            stayAwake: LinkAwake.state.map { MacState.StayAwake(mode: $0.mode, on: $0.on) })
    }

    // MARK: Reads (full control)

    /// History rows a page holds.
    static let historyPage = 50

    /// A window's past chats, newest first: archived ones or the rest, filtered by title.
    static func history(_ workspace: Workspace, query: String?, archived: Bool, offset: Int) -> ([HistorySession], Bool) {
        let words = (query ?? "").lowercased().split(separator: " ")
        let openIds = Set(chats(workspace).compactMap(\.sessionId))
        let rows = workspace.linkSessions.filter { session in
            session.archived == archived && words.allSatisfy { session.title.lowercased().contains($0) }
        }
        let start = min(max(offset, 0), rows.count)
        let page = rows[start..<min(start + historyPage, rows.count)].map { session in
            HistorySession(
                id: session.id, provider: session.agent.rawValue, title: String(session.title.prefix(LinkPolicy.maxTitle)), updatedAt: ms(session.updated),
                archived: session.archived, open: openIds.contains(session.id))
        }
        return (page, start + historyPage < rows.count)
    }

    /// The most of a diff sent: 256 KiB of lines.
    static let diffCap = 256 * 1024

    /// A file's change as hunks, with "+", "-" or " " before each line; cut at `diffCap`.
    static func hunks(_ change: FileChange) -> ([LinkMessage.Hunk], Bool) {
        var size = 0
        var out: [LinkMessage.Hunk] = []
        for hunk in change.hunks {
            var lines: [String] = []
            for line in hunk.lines {
                let mark = switch line.kind {
                case .add: "+"
                case .remove: "-"
                case .context: " "
                }
                let text = mark + line.text
                size += text.utf8.count + 1
                if size > diffCap {
                    out.append(.init(oldStart: hunk.oldStart, newStart: hunk.newStart, lines: lines))
                    return (out, true)
                }
                lines.append(text)
            }
            out.append(.init(oldStart: hunk.oldStart, newStart: hunk.newStart, lines: lines))
        }
        return (out, change.isTruncated)
    }

    /// Each CLI's models, read from its open chats (a CLI says them once it runs).
    static func clis(_ chats: [Chat]) -> [CLIState] {
        Registry.all.compactMap { provider in
            guard let chat = chats.first(where: { $0.provider.id == provider.id && !$0.linkModels.isEmpty }) else { return nil }
            return CLIState(
                provider: provider.id,
                models: chat.linkModels.map { .init(id: $0.id, name: $0.name, efforts: $0.efforts, fast: $0.supportsFastMode, auto: $0.supportsAutoMode) },
                effortScale: chat.linkEffortScale)
        }
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

    /// Every open chat by its wire id.
    static func chatsByID() -> [String: Chat] {
        var out: [String: Chat] = [:]
        for workspace in workspaces() {
            for chat in chats(workspace) { out[chat.id.uuidString] = chat }
        }
        return out
    }

    static func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Chats

    static func facts(_ chat: Chat) -> LinkPolicy.ChatFacts {
        let modes = Dictionary(chat.controls.availableModes.map { ($0.id, Self.level($0)) }, uniquingKeysWith: { a, _ in a })
        let current = chat.provider.modes.first { $0.id == chat.controls.mode }.map(Self.level) ?? .danger
        var waiting: [String: LinkPolicy.ChatFacts.Card] = [:]
        for card in cards(chat) { waiting[card.id] = .init(kind: card.kind, digest: card.digest) }
        let all = chat.controls.linkCommands
        return LinkPolicy.ChatFacts(
            level: current, planOn: chat.provider.planToggle != nil && chat.controls.planMode, modes: modes, cards: waiting,
            commands: Set(all.filter { $0.kind != .kore }.map(\.name)), koreEntries: Set(all.filter { $0.kind == .kore }.map(\.name)))
    }

    /// The most commands, and the longest description, a chat's meta carries.
    static let commandsMax = 200
    static let descriptionCap = 100

    /// The "/" commands the link may send: the chat's own, without Kore's entries and the ones the
    /// policy refuses.
    static func commands(_ chat: Chat) -> [LinkSlash] {
        chat.controls.linkCommands
            .filter { $0.kind != .kore && !LinkPolicy.koreOnly.contains($0.name) }
            .prefix(commandsMax)
            .map { LinkSlash(name: $0.name, description: String($0.description.prefix(descriptionCap)), kind: $0.kind == .skill ? .skill : .command) }
    }

    static func meta(_ chat: Chat) -> ChatMeta { meta(chat, full: false) }

    /// `full`: with the run's full control, the chat's controls, rescue and wider `can` too.
    static func meta(_ chat: Chat, full: Bool) -> ChatMeta {
        var made = baseMeta(chat)
        guard full else { return made }
        let c = chat.linkControlState
        made.controls = ChatControls(
            modelId: c.modelId, effort: c.effort, fast: c.fast, fastOffered: c.fastOffered, planAllow: c.planAllow, contextPct: c.contextPct,
            autoCompactAt: c.autoCompactAt, compacting: c.compacting, remote: ChatControls.Remote(rawValue: c.remote) ?? .unknown)
        let r = chat.linkRescueState
        made.rescue = ChatRescue(
            connection: r.offline ? .offline : r.stalled ? .stalled : .ok, retryTurn: r.retryTurn, slept: r.slept ? true : nil,
            limitReset: r.limitReset.map(Self.ms), continuesAt: r.continuesAt.map(Self.ms), sendsAtReset: r.sendsAtReset ? true : nil)
        made.can.compact = chat.linkCanCompact
        made.can.fork = chat.linkCanFork
        made.can.rename = true
        made.can.close = true
        made.can.sendAtReset = chat.linkCanSendAtReset
        return made
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func baseMeta(_ chat: Chat) -> ChatMeta {
        let facts = facts(chat)
        let state: ChatMeta.State =
            switch chat.attention {
            case .waiting: .needsYou
            case .failed: .failed
            case .stuck: .stuck
            case .working: .working
            case .idle: .idle
            }
        let sendable = LinkPolicy.check(.send(chatId: "", text: "."), facts) == .allow
        return ChatMeta(
            id: chat.id.uuidString, provider: chat.provider.id, title: chat.title, state: state,
            mode: .init(id: chat.controls.mode, level: facts.level, planOn: chat.provider.planToggle != nil ? chat.controls.planMode : nil),
            modeIds: chat.controls.availableModes.map(\.id), allowedModeIds: LinkPolicy.allowedModes(facts).sorted(),
            model: chat.controls.currentModel?.name, queued: chat.queuedCount, running: chat.isBusy, cards: cards(chat),
            can: .init(send: sendable && !chat.accountRestartPending, stop: chat.isWorking), commands: commands(chat))
    }

    // MARK: Cards

    /// Codex's "Implement this plan?", which isn't an approval of the CLI's.
    static let planReadyID = "planReady"

    static func kind(_ approval: Approval) -> LinkCard.Kind {
        if approval.signIn { return .signIn }
        if approval.plan != nil { return .plan }
        if !approval.questions.isEmpty { return .questions }
        return .permission
    }

    static func cards(_ chat: Chat) -> [LinkCard] {
        var out = chat.approvals.pending.map { card($0, in: chat) }
        if chat.approvals.offerImplementPlan {
            let actions: [CardAction] = [
                .init(id: .implement, label: "Yes, implement it", style: .primary), .init(id: .stay, label: "Stay in Plan", style: .neutral),
            ]
            let title = "Implement this plan?"
            let digest = LinkCardDigest(kind: .planReady, title: title, detail: nil, body: nil, plan: nil, questions: nil, actions: actions).digest
            out.append(LinkCard(id: planReadyID, kind: .planReady, title: title, actions: actions, digest: digest))
        }
        return out
    }

    /// A card's whole content: a plan card's plan, otherwise its body (the command, or the file
    /// and its change). What `card.more` reads and the digest covers.
    static func fullContent(_ approval: Approval) -> String? { approval.plan ?? approval.body }

    static func card(_ approval: Approval, in chat: Chat) -> LinkCard {
        let agent: String? =
            switch approval.agent {
            case .main: nil
            case .sub(let id): chat.transcript.agent(id)?.name ?? id
            }
        let kind = kind(approval)
        let body = approval.body.map { capped($0, bodyCap) }
        let actions: [CardAction]
        var plan: [Block]?
        var questions: [LinkQuestion]?
        switch kind {
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
                LinkQuestion(
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
        let digest = LinkCardDigest(
            kind: kind, title: approval.title, detail: approval.detail, body: approval.body, plan: approval.plan, questions: questions,
            actions: actions
        ).digest
        return LinkCard(
            id: approval.id, kind: kind, title: approval.title, detail: approval.detail, body: body?.text,
            bodyLen: body?.cut == true ? body?.length : nil, plan: plan, questions: questions, agent: agent, actions: actions, digest: digest)
    }

    // MARK: Transcript

    static func entry(_ e: TranscriptStore.Entry, folder: URL) -> LinkEntry {
        let kind: LinkEntry.Kind =
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
        var tool: LinkEntry.Tool?
        if e.kind == .tool, let name = e.toolName {
            let input = e.input.map { capped($0, inputCap) }
            let result = e.result.map(headAndTail)
            tool = LinkEntry.Tool(
                name: name, summary: e.summary, input: input?.text, inputLen: e.input?.unicodeScalars.count ?? 0,
                path: e.path.map { relative($0, to: folder) }, readOnly: e.readOnly, result: result,
                resultLen: e.result?.unicodeScalars.count ?? 0)
        }
        return LinkEntry(
            id: e.id.uuidString, kind: kind, turn: e.turn, text: formatted || e.text.isEmpty ? nil : text.text,
            doc: formatted && !e.text.isEmpty ? doc(text.text) : nil, textLen: text.length, done: e.done, isError: e.isError,
            stopped: e.stopped, inTurn: e.inTurn, tool: tool,
            changes: e.changes.isEmpty ? nil : e.changes.map { .init(path: relative($0.path, to: folder), added: $0.added, removed: $0.removed) },
            agent: e.agent.map { .init(id: $0.id, name: $0.name, status: $0.statusName) },
            attachments: e.linkAttachments.isEmpty ? nil : e.linkAttachments.enumerated().map { i, a in
                LinkAttachment(ref: attachmentRef(entryId: e.id.uuidString, index: i), name: a.name, kind: attachmentKind(a.linkKind))
            })
    }

    /// An attachment's ref: its message's id and its place there. It names nothing on disk.
    static func attachmentRef(entryId: String, index: Int) -> String { "\(entryId)/\(index)" }

    static func attachmentKind(_ kind: Attachment.Kind) -> LinkAttachment.Kind {
        switch kind {
        case .image: .image
        case .text: .text
        case .pdf: .pdf
        case .other: .other
        }
    }

    static func turn(_ t: TranscriptStore.Turn) -> LinkTurn {
        let outcome: LinkTurn.Outcome =
            switch t.outcome {
            case .completed: .completed
            case .interrupted: .interrupted
            case .failed: .failed
            case .authFailed: .authFailed
            case .slept: .slept
            }
        return LinkTurn(
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

    /// A piece of `text` from `offset`, at most `textCap` scalars: what `entry.chunk` and
    /// `card.chunk` carry.
    static func piece(_ text: String, from offset: Int) -> (text: String, offset: Int, total: Int) {
        let scalars = Array(text.unicodeScalars)
        let start = min(max(offset, 0), scalars.count)
        var piece = String.UnicodeScalarView()
        piece.append(contentsOf: scalars[start..<min(start + textCap, scalars.count)])
        return (String(piece), start, scalars.count)
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

    /// Markdown as the link's render tree, parsed by Kore's own parser.
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
