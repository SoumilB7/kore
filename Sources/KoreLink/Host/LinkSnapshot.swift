import Foundation
import KoreCore
import KoreUI
import LinkProtocol
import src

/// Kore's state as the link's wire values: windows, tabs, chats, cards and transcript entries.
/// Every cap on what goes over the link is here, named.
@MainActor
enum LinkSnapshot {
    /// The link's caps, as `LinkProjection` sets them.
    static let textCap = LinkProjection.textCap
    static let inputCap = LinkProjection.inputCap
    static let resultHead = LinkProjection.resultHead
    static let resultTail = LinkProjection.resultTail
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
            stayAwake: LinkAwake.state.map { MacState.StayAwake(mode: $0.mode, on: $0.on) },
            arsenalTiers: ArsenalTier.allCases.filter(\.built).map(\.rawValue))
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

    /// Each CLI's models, read from its open chats (a CLI says them once it runs), and its account.
    static func clis(_ chats: [Chat]) -> [CLIState] {
        Registry.all.compactMap { provider in
            let chat = chats.first(where: { $0.provider.id == provider.id && !$0.linkModels.isEmpty })
            let account = self.account(provider.id)
            return CLIState(
                provider: provider.id,
                models: (chat?.linkModels ?? []).map {
                    .init(id: $0.id, name: $0.name, efforts: $0.efforts, fast: $0.supportsFastMode, auto: $0.supportsAutoMode)
                },
                effortScale: chat?.linkEffortScale ?? [], account: account)
        }
    }

    /// A CLI's account as the link sees it (`AccountStore.linkAccount`).
    static func account(_ provider: String) -> LinkAccountState {
        let a = AccountStore.shared.linkAccount(provider)
        return LinkAccountState(
            status: a.status, email: a.email, plan: a.plan, workspace: a.workspace, method: a.method, privacy: a.privacy,
            logins: a.logins.map { .init(id: $0.id, email: $0.email, workspace: $0.workspace, active: $0.active, signedOut: $0.signedOut, duplicate: $0.duplicate) },
            methods: a.methods.map { .init(id: $0.id, label: $0.label, hint: $0.hint, group: $0.group, kind: $0.kind, where: $0.onLink ? .link : .mac) },
            workingChats: a.workingChats,
            flow: a.flow.map {
                .init(
                    serial: $0.serial, method: $0.method, startedByLink: $0.startedByLink, switching: $0.switching, step: $0.step, url: $0.url,
                    code: $0.code, takesPaste: $0.takesPaste, error: $0.error)
            })
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

    // MARK: Chats

    static func facts(_ chat: Chat) -> LinkPolicy.ChatFacts {
        let modes = Dictionary(chat.controls.availableModes.map { ($0.id, Self.level($0)) }, uniquingKeysWith: { a, _ in a })
        let current = chat.provider.modes.first { $0.id == chat.controls.mode }.map(Self.level) ?? .danger
        var waiting: [String: LinkPolicy.ChatFacts.Card] = [:]
        for card in cards(chat) { waiting[card.id] = .init(kind: card.kind, digest: card.digest) }
        let all = chat.controls.linkCommands
        return LinkPolicy.ChatFacts(
            level: current, planOn: chat.provider.planToggle != nil && chat.controls.planMode, modes: modes, cards: waiting,
            commands: Set(all.filter { $0.kind != .kore }.map(\.name)), koreEntries: Set(all.filter { $0.kind == .kore }.map(\.name)),
            arsenalUnavailable: Arsenal.unavailable(chat))
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

    /// `full`: with the run's full control, the chat's controls, rescue, wider `can` and Arsenal too.
    static func meta(_ chat: Chat, full: Bool) -> ChatMeta {
        var made = baseMeta(chat, full: full)
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
        made.arsenal = chat.arsenal?.rawValue ?? "off"
        made.arsenalUnavailable = Arsenal.unavailable(chat)
        return made
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func baseMeta(_ chat: Chat, full: Bool) -> ChatMeta {
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
            modeIds: chat.controls.availableModes.map(\.id), allowedModeIds: LinkPolicy.allowedModes(facts, control: full ? .full : .standard).sorted(),
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

    /// The link's client has full control this run.
    static var fullControl: Bool { LinkHost.current?.run.control == .full }

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
                // Full control may take it (`LinkPolicy`): it raises the mode only to Edit automatically.
                .init(id: .approvePlanAcceptEdits, label: "Yes, and auto-accept edits", style: .neutral, refused: fullControl ? nil : true),
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

    static func entry(_ e: TranscriptStore.Entry, folder: URL, reading: any LinkReading) -> LinkEntry {
        LinkProjection.entry(e, folder: folder, reading: reading)
    }

    static func turn(_ t: TranscriptStore.Turn) -> LinkTurn { LinkProjection.turn(t) }

    static func capped(_ text: String, _ cap: Int) -> (text: String, length: Int, cut: Bool) { LinkProjection.capped(text, cap) }

    static func piece(_ text: String, from offset: Int) -> (text: String, offset: Int, total: Int) { LinkProjection.piece(text, from: offset) }

    static func headAndTail(_ text: String) -> String { LinkProjection.headAndTail(text) }

    static func relative(_ path: String, to folder: URL) -> String { LinkProjection.relative(path, to: folder) }

    static func homeRelative(_ path: String) -> String { LinkProjection.homeRelative(path) }

    static func attachmentKind(_ kind: Attachment.Kind) -> LinkAttachment.Kind { LinkProjection.attachmentKind(kind) }

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

/// The projector's reads of one chat: its transcript's chips, and markdown through Kore's parser.
@MainActor
struct ChatLinkReading: LinkReading {
    let chat: Chat

    func chips(_ entry: TranscriptLog.Entry) -> [Attachment] { chat.transcript.linkAttachments(entry) }

    func blocks(_ markdown: String) -> [Block]? { LinkSnapshot.doc(markdown) }
}
