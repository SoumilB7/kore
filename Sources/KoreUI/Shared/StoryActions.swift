import AppKit
import KoreCore

// What a chat's controls do, for a storyline host (phase 12): the same calls the composer, the
// Stop button, approval cards and Fork buttons make, plus the rows in plain terms for checks.
// Steps use these until their controls can be pressed by identifier; a storyline names the
// step either way.

/// One transcript row, as a storyline checks it.
package struct StoryRow: Sendable, Equatable {
    /// "user", "assistant", "tool", "agent", "notice", … (`DumpRows`' names).
    package let kind: String
    package let tool: String?
    package let text: String
    package let result: String?
    package let done: Bool
    package let isError: Bool
    /// A call a stopped turn left open.
    package let stopped: Bool
    /// A message the CLI took into a running turn.
    package let inTurn: Bool
}

extension Chat {
    package var rows: [StoryRow] {
        transcript.entries.map { e in
            StoryRow(
                kind: e.kind == .answer ? "assistant" : "\(e.kind)", tool: e.toolName, text: e.text, result: e.result,
                done: e.done, isError: e.isError, stopped: e.stopped, inTurn: e.inTurn)
        }
    }

    package var storyTitle: String { title }
    package var isRunning: Bool { status.isRunning }
    package var pendingApprovals: [Approval] { approvals.pending }
    package var mode: String { controls.mode }
    package var isCompacting: Bool { context.compacting }

    /// The context wheel's click: compacts, between turns only.
    package func storyCompact() { compact() }
    /// The context card's auto-compact point (a percent), nil for Off.
    package func storySetAutoCompact(_ point: Int?) { setAutoCompact(point) }

    /// The composer's Send (or a queued send, while a turn runs).
    package func storySend(_ text: String) {
        draft = text
        send()
    }

    /// The Stop button.
    package func storyStop() { stop() }

    /// An approval card's buttons.
    package func storyAnswer(_ approval: Approval, _ decision: Decision) { answer(approval, decision) }

    /// The mode menu.
    package func storySetMode(_ id: String) { setMode(id) }
    /// Codex's plan switch.
    package var storyPlanMode: Bool { controls.planMode }
    /// The session it forks, while its own hasn't come.
    package var storyForkOf: String? { fork?.from }

    /// The model and mode pickers: which is open.
    package var isModelPickerOpen: Bool { picker.open == .model }
    package var isModePickerOpen: Bool { picker.open == .mode }
    /// The chat's model (its id) and effort, and the pill as it reads ("Lyra 3 · High").
    package var storyModel: String? { controls.modelId }
    package var storyEffort: String? { controls.effort }
    package var storyModelPill: String { [controls.modelLabel, controls.effortLabel].compactMap { $0 }.joined(separator: " · ") }
    /// The picker's rows as they read: "Lyra: [3] 2.5 *2", the current chip in brackets and the
    /// lit one (pointer or keys) starred; a family without versions is its own chip ("[Nova]").
    package var storyModelRows: [String] {
        ModelFamily.group(controls.models).enumerated().map { row, family in
            let chips = family.members.enumerated().map { column, member in
                let label = member.version ?? member.model.name
                let lit = picker.lit == .chip(row: row, column: column) ? "*" : ""
                return lit + (member.model.id == controls.modelId ? "[\(label)]" : label)
            }
            return family.versionless ? chips[0] : family.name + ": " + chips.joined(separator: " ")
        }
    }
    /// The effort slider's stops, lowest first: the level, "(level)" for one this model lacks
    /// (hollow), "[level]" for the thumb's; with "*" first when the keys are on the slider.
    package var storyEffortStops: [String] {
        let offered = controls.currentModel?.efforts ?? []
        let stops = controls.effortScale.map { level in
            !offered.contains(level) ? "(\(level))" : level == controls.effort ? "[\(level)]" : level
        }
        return (picker.lit == .effort ? ["*"] : []) + stops
    }
    /// The mode pill as it reads ("Auto"), and a mode's tint by its rung: "neutral", "plan",
    /// "edits", "auto" or "danger".
    package var storyModePill: String { (provider.planToggle != nil ? controls.permissionsMode : controls.activeMode).label }
    package func storyModeTint(_ id: String) -> String? {
        guard let mode = (provider.modes + [provider.planToggle].compactMap { $0 }).first(where: { $0.id == id }) else { return nil }
        let rungs: [(Rung, String)] = [(.plan, "plan"), (.edits, "edits"), (.auto, "auto"), (.danger, "danger")]
        return mode.rung.map { rung in rungs.first { $0.0 == rung }?.1 ?? "other" } ?? "neutral"
    }
    /// The mode popup's rows as they read: "✓ Manual", "Plan: on" for Codex's switch, the lit
    /// row starred.
    package var storyModeRows: [String] {
        let modes = controls.availableModes
        var rows = modes.enumerated().map { index, mode in
            (picker.lit == .row(index) ? "*" : "") + (mode.id == controls.mode ? "✓ " : "") + mode.label
        }
        if let plan = provider.planToggle {
            rows.append((picker.lit == .row(modes.count) ? "*" : "") + plan.label + (controls.planMode ? ": on" : ": off"))
        }
        return rows
    }

    /// The `/` menu's names, and the command chip's.
    package var storyCommands: [String] { controls.commands.map(\.name) }

    /// Whether the agent map shows over the chat (the Agents button, ⇧⌘A).
    package var isAgentMapOpen: Bool { agentMap.isOpen }
    /// The Agents button's words and the map header's counts, as they read ("4 agents",
    /// "4 · 2 failed").
    package var storyAgentCounts: (button: String, header: String) {
        let summary = transcript.agentSummary
        let header = MapHeader.counts(summary)
        return (AgentsButton.label(summary), header.counts + header.failed)
    }

    /// The agent map's selected agent, and its closed groups' rows as they read ("Done 2 · 1
    /// foreground · 1 background").
    package var storyAgentMapSelected: String? { agentMap.selected }
    package var storyAgentMapGroups: [String] {
        let rows = AgentMapRows(transcript.agentTree(), folded: [], open: [])
        return AgentMapState.Fold.allCases.compactMap { fold in
            rows.nodes(fold).isEmpty ? nil : AgentMapRows.label(fold, rows.nodes(fold))
        }
    }

    /// The chat's background commands as their rows read ("Run the dev server · running ·
    /// main"), and how many are live and how many outlived their agents.
    package var storyBackground: [String] {
        commands.all.map { row in
            [row.title, CommandText.word(row.state) ?? (row.isLive ? "running" : "done"), row.owner.sub ?? "main"].joined(separator: " · ")
        }
        .sorted()
    }
    package var storyLiveCommands: Int { commands.summary.total }
    /// The CLI's account changed elsewhere (as `AccountStore` tells each of its chats).
    package func storyAccountChanged() { accountChanged() }
    package var storyOutlivedCommands: Int { commands.summary.outlived }

    /// Whether the usage popup is open, its account ("Claude Max · you@example.com · Example Org",
    /// the plan name and its tooltip), its bars as they read ("Weekly limit · 6% · Resets in 4d")
    /// and its extras line.
    package var isUsageOpen: Bool { usage.isOpen }
    /// The context card, opened as the keyboard opens it (a hover needs the real pointer).
    package var isContextCardOpen: Bool { contextCard.shown }
    package func storyOpenContextCard() { contextCard.open() }
    package var storyUsageHeader: String {
        guard let account = usage.reading?.account else { return "" }
        return [account.plan, UsageText.who(account)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    package var storyUsage: [String] { usage.lines }
    /// The bars' titles as their rows show them ("Session", "5h").
    package var storyUsageTitles: [String] { (usage.reading?.limits?.bars ?? []).map { UsageText.label($0.title) } }
    /// A bar's tooltip, by its limit's title: Kore's share ("~12% in Kore"), else its reset.
    package func storyUsageBarHelp(_ title: String) -> String? {
        usage.reading?.limits?.bars.first { $0.title == title }.map { usage.barHelp($0, now: Date()) }
    }
    /// Whether the usage card (the extended view) is open, the limit it shows, and that limit's
    /// ledger as it reads ("In Kore · ~12%", "This chat · ~3%", "Outside Kore · ~18%").
    package var isUsageExtendedOpen: Bool { usage.extended }
    package var storyUsagePicked: String? { usage.pickedLimit?.title }
    package var storyUsageLedger: [String] { usage.ledger(current: sessionId) }
    package var storyUsageExtras: String { UsageText.extras(usage.reading?.limits?.extras ?? []) }
    /// Whether the full resets are unfolded, and whether a row's "Yes" would go yet (a
    /// double-click's time after its "Use").
    package var isUsageResetsOpen: Bool { usage.resetsOpen }
    package var storyUsageConfirmable: Bool { usage.confirmable }

    /// Whether the Account popup is open, and its lines as they read: the email, the caption,
    /// then the action row's words ("Waiting for the browser…"), or the signed-out row alone.
    package var isAccountOpen: Bool { account.isOpen }
    package var storyAccount: [String] { account.lines(product: provider.usage.product) }
    /// The caption under the action row ("Also signs out Terminal and VS Code on this Mac.",
    /// "Stored in your Keychain.", "Pick Console account, then …").
    package var storyAccountCaption: String? {
        let store = AccountStore.shared
        if account.askingSignOut {
            return AccountText.signOutCaption(working: store.workingChats(provider.id), setting: account.identity?.isKoreSetting == true)
        }
        if account.showsKeyField {
            if case .keyFailed(let reason) = store.flow(provider.id)?.step { return AccountText.signInFailed(reason) }
            return AccountText.keyCaption(provider.id)
        }
        guard let flow = store.flow(provider.id) else { return nil }
        if flow.step == .terminal { return AccountText.terminalCaption(flow.method) }
        guard flow.switching, flow.step.cancellable else { return nil }
        return AccountText.moving
    }
    /// Whether "Yes, sign out" would go yet (a double-click's time after Sign out).
    package var storyAccountConfirmable: Bool { account.confirmable }
    /// The ⌄'s methods while they're unfolded in the card, leaf by leaf in their order, closed
    /// groups too: each by its path ("3rd-party platform/Amazon Bedrock…"), "✓ " before the
    /// current one, "—" for the CLI's separator; nil while they're folded.
    package var storyAccountMenu: [String]? {
        account.methodsShown.map { items in
            MethodMenuItem.paths(items).flatMap { path, item in
                (item.separated ? ["—"] : []) + [(item.checked ? "✓ " : "") + path]
            }
        }
    }
    /// The unfolded methods' top level with their hints: "Claude account with subscription · Pro, Max,
    /// Team, or Enterprise", "Anthropic Console account ▸ · API usage billing".
    package var storyAccountMenuTop: [String]? {
        account.methodsShown.map { items in
            items.map { item in [item.title + (item.method == nil ? " ▸" : ""), item.hint].compactMap { $0 }.joined(separator: " · ") }
        }
    }
    /// Whether the ⌄ shows (more than one method to pick).
    package var storyAccountHasMenu: Bool { account.hasMenu }
    /// Whether a field or form is open in the popup, and has the keys.
    package var storyAccountEditing: Bool { account.isEditing }
    /// The account changed since the chat's CLI started: it hasn't started again yet.
    package var storyAccountGeneration: Int { AccountStore.shared.generation(provider.id) }

    /// The turn whose refused login shows its notice, newest first.
    package var storySignInNoticeTurn: String? {
        for section in transcript.sections.reversed() {
            for item in section.items.reversed() {
                if case .signIn(let turn, _) = item.row { return turn }
            }
        }
        return nil
    }
    /// The notice's words.
    package var storySignInNotice: String? {
        guard storySignInNoticeTurn != nil else { return nil }
        return AccountText.expired(provider.usage.product, signedOut: AccountStore.shared.status(provider.id) == .signedOut)
    }
}

extension Workspace {
    /// The tab asking before its close stops its turn, and whether its Yes (or a second ⌘W)
    /// would go yet: a double click's time after it asked.
    package var storyClosingTab: UUID? { tabs.first(where: asking)?.id }
    package var storyCloseConfirmable: Bool {
        closing.map { ProcessInfo.processInfo.systemUptime - $0.at >= NSEvent.doubleClickInterval } ?? false
    }

    /// The nth user message's Fork button (1-based): its fork opens in a new tab. False when
    /// there's no such message or the fork failed.
    package func storyFork(_ chat: Chat, message n: Int) async -> Bool {
        let messages = chat.transcript.entries.filter { $0.kind == .user }
        guard n >= 1, n <= messages.count else { return false }
        let entry = messages[n - 1]
        guard let start = await chat.forkStart(entry) else { return false }
        fork(chat, start, text: entry.text)
        return true
    }

    /// The nth answer's Fork button (1-based).
    package func storyFork(_ chat: Chat, answer n: Int) async -> Bool {
        let answers = chat.transcript.entries.filter { $0.kind == .answer }
        guard n >= 1, n <= answers.count else { return false }
        guard let start = await chat.forkStart(after: answers[n - 1]) else { return false }
        fork(chat, start, text: "")
        return true
    }
}

/// Stay awake, for a storyline host: what it shows and holds, in plain terms. Under a host its
/// hold only records (`RecordedHold`), so no storyline keeps the Mac awake.
@MainActor
package enum StoryAwake {
    package static var isOn: Bool { StayAwake.current?.isOn ?? false }
    /// The mode's id ("agents", "always", "1h", "4h").
    package static var mode: String? { StayAwake.current?.mode.rawValue }
    /// "off", "holding", "waiting" or "paused".
    package static var state: String {
        switch StayAwake.current?.state {
        case .holding: "holding"
        case .waiting: "waiting"
        case .paused: "paused"
        case .off, nil: "off"
        }
    }
    /// The cup's hover line.
    package static var line: String? { StayAwake.current?.line }
    /// The reason it holds for now; nil when it holds nothing.
    package static var held: String? { (StayAwake.current?.hold as? RecordedHold)?.current }
    /// Every reason it was asked to hold, nil for each let-go, since the host started.
    package static var holds: [String?] { (StayAwake.current?.hold as? RecordedHold)?.reasons ?? [] }

    /// Off, in While Agents Work, holding `grace` after the last agent ends.
    package static func reset(grace: TimeInterval = 120) {
        guard let awake = StayAwake.current else { return }
        awake.choose(.whileAgentsWork)
        awake.turnOff()
        awake.grace = grace
    }
}

extension Chat {
    /// The turn whose limit notice says when the chat continues, and the words it says.
    package var storyContinuesTurn: String? { transcript.continuation?.turn }
    package var storyContinuesLine: String? { continuesAt.map { ContinueText.line($0, now: Date()) } }
    /// The message set to go when the limit resets, as it will be sent; and the notice's words.
    package var storySendsAtReset: String? { sendsAtReset.map { Chat.message(command: $0.command, draft: $0.draft) } }
    package var storySendsLine: String? { transcript.continuation?.sends }
}

extension Chat {
    /// The empty chat's import picker as a storyline checks it: open or not, the chats it lists
    /// (titles), its footer line, and whether Import is on.
    package var storyImportOpen: Bool { importer.isOpen }
    package var storyImportRows: [String] { importer.shown.map(\.title) }
    /// The picked row's title.
    package var storyImportPicked: String? { importer.shown.first { $0.id == importer.picked }?.title }
    /// A row's id, by its title.
    package func storyImportRowID(_ title: String) -> String? { importer.shown.first { $0.title == title }?.id }
    package var storyImportLine: String { importer.text(in: self) }
    package var storyImportReady: Bool { importer.canImport }
    /// The context ring's tokens as it words them ("~80k"), "" with no reading.
    package var storyContextUsed: String { context.usedText }
}
