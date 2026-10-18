import Foundation
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

    /// The `/` menu's names, and the command chip's.
    package var storyCommands: [String] { controls.commands.map(\.name) }

    /// Whether the agent map shows over the chat (the Agents button, ⇧⌘A).
    package var isAgentMapOpen: Bool { agentMap.isOpen }
    /// The agent map's selected agent, and its closed groups' rows as they read ("Done 2 · 1
    /// foreground · 1 background").
    package var storyAgentMapSelected: String? { agentMap.selected }
    package var storyAgentMapGroups: [String] {
        let rows = AgentMapRows(transcript.agentTree(), folded: [], open: [])
        return AgentMapState.Fold.allCases.compactMap { fold in
            rows.nodes(fold).isEmpty ? nil : AgentMapRows.label(fold, rows.nodes(fold))
        }
    }

    /// Whether the usage popup is open, its account ("Claude Max · you@example.com · Example Org",
    /// the plan name and its tooltip), its bars as they read ("Weekly limit · 6% · Resets in 4d")
    /// and its extras line.
    package var isUsageOpen: Bool { usage.isOpen }
    package var storyUsageHeader: String {
        guard let account = usage.reading?.account else { return "" }
        return [account.plan, UsageText.who(account)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    package var storyUsage: [String] { usage.lines }
    /// The bars' titles as their rows show them ("Session", "5h").
    package var storyUsageTitles: [String] { (usage.reading?.limits?.bars ?? []).map { UsageText.label($0.title) } }
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
    /// The ⌄ menu as it last opened, leaf by leaf in its order: each by its path
    /// ("3rd-party platform/Amazon Bedrock…"), "✓ " before the current one, "—" for a separator;
    /// nil while it isn't open.
    package var storyAccountMenu: [String]? {
        account.hostMenu.map { items in
            MethodMenuItem.paths(items).flatMap { path, item in
                (item.separated ? ["—"] : []) + [(item.checked ? "✓ " : "") + path]
            }
        }
    }
    /// The open menu's top level with its hints: "Claude account with subscription · Pro, Max,
    /// Team, or Enterprise", "Anthropic Console account ▸ · API usage billing".
    package var storyAccountMenuTop: [String]? {
        account.hostMenu.map { items in
            items.map { item in [item.title + (item.method == nil ? " ▸" : ""), item.hint].compactMap { $0 }.joined(separator: " · ") }
        }
    }
    /// Picks an item of the open ⌄ menu by its path (or title), as a click on it does.
    package func storyPickMethod(_ path: String) { account.pickHostMenu(path) }
    /// Whether the ⌄ shows (more than one method to pick).
    package var storyAccountHasMenu: Bool { account.hasMenu }
    /// A form's picker, as a pick from its menu: "credentials" by the choice's case name
    /// ("profile", "apiKey", "accessKey", "environment"; "gcloud", "keyFile"), "profile" by name.
    package func storyAccountChoose(_ picker: String, _ value: String) {
        switch (account.editor, picker) {
        case (.platform(.bedrock), "credentials"):
            if let choice = ClaudeSettings.BedrockCredentials(rawValue: value) { account.form.bedrock = choice }
        case (.platform(.vertex), "credentials"):
            if let choice = ClaudeSettings.VertexCredentials(rawValue: value) { account.form.vertex = choice }
        case (.platform(.bedrock), "profile"):
            account.form.pick(profile: value)
        default: break
        }
        account.editedForm()
    }
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
