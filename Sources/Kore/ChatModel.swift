import Foundation
import KoreCore
import Observation
import SwiftUI

/// One conversation with Claude or Codex. Turns either CLI's events into a flat transcript.
@MainActor @Observable
final class ChatModel: Identifiable {
    struct Entry: Identifiable {
        enum Kind { case user, assistant, thinking, plan, tool, notice }

        let id = UUID()
        var kind: Kind
        var text: String
        var toolName: String?
        /// Claude tool_use id or Codex item id.
        var toolId: String?
        var result: String?
        var done = false
        var isError = false
        /// Files and images sent with a user message.
        var attachments: [Attachment] = []
    }

    struct Approval: Identifiable {
        struct Option {
            let label: String
            let description: String
        }

        struct Question {
            let id: String
            let text: String
            let options: [Option]
        }

        enum Source {
            case claude(PermissionRequest)
            case codex(CodexApproval)
        }

        let id: String
        let title: String
        let detail: String?
        let body: String?
        let canAlwaysAllow: Bool
        /// Non-empty means render as a question card.
        let questions: [Question]
        let source: Source
        /// Set for Claude's ExitPlanMode: the plan awaiting "Ready to code?".
        var plan: String? = nil
    }

    enum Decision {
        case allow, allowAlways, deny
        /// Claude's "Ready to code?": approve the plan, optionally switching to Accept edits.
        case approvePlan(autoAcceptEdits: Bool)
        case keepPlanning
        /// Keyed by `Approval.Question.id`.
        case answers([String: String])
    }

    /// An entry in the `/` menu. Picking it inserts `insertion` into the draft.
    struct SlashCommand: Identifiable, Hashable {
        enum Kind { case command, skill }
        let name: String
        let description: String
        let hint: String
        let kind: Kind
        var id: String { name }
        /// Claude runs `/name`; Codex invokes skills by mentioning `$name`.
        var insertion: String { kind == .skill ? "$\(name) " : "/\(name) " }
    }

    struct ModelOption: Identifiable, Hashable {
        let id: String
        let name: String
        let resolved: String
        let efforts: [String]
        var supportsAutoMode = false
    }

    private enum Backend {
        case claude(ClaudeSession)
        case codex(CodexSession)
    }

    let id = UUID()
    let provider: Provider
    let folder: URL
    private(set) var entries: [Entry] = []
    private(set) var approvals: [Approval] = []
    private(set) var isRunning = false
    /// Claude permission mode or Codex permissions preset (the CLI's own id).
    private(set) var mode: String
    /// Codex's Plan collaboration mode; Claude's plan is just `mode == "plan"`.
    private(set) var planMode = false
    /// Codex finished a plan in Plan mode: offer "Implement this plan?" like its CLI.
    private(set) var offerImplementPlan = false
    private(set) var models: [ModelOption] = []
    private(set) var modelId: String?
    private(set) var effort: String?
    private(set) var commands: [SlashCommand] = []
    /// Waiting in the composer, sent with the next message.
    private(set) var attachments: [Attachment] = []
    var draft = ""

    /// The CLI's name for the conversation (AI title or rename); nil until there is one.
    private(set) var name: String?

    private var backend: Backend?
    /// A past session to show and continue; replayed into `entries` on launch.
    private var resuming: SessionSummary?
    private var starting: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    /// Kept across process restarts so an exited CLI resumes the same conversation.
    private var resumeId: String?
    /// Claude: entry receiving streamed text; reset at each new content block.
    private var streamingIndex: Int?
    /// Codex: item id → entry index.
    private var itemIndex: [String: Int] = [:]

    init(provider: Provider, folder: URL, resume session: SessionSummary? = nil) {
        self.provider = provider
        self.folder = folder
        mode = provider.modes[0].id
        resuming = session
        resumeId = session?.id
        name = session?.title
    }

    /// Claude session id / Codex thread id, once known.
    var sessionId: String? { resumeId }

    var title: String {
        if let name { return name }
        guard let first = entries.first(where: { $0.kind == .user }) else { return provider.name }
        return first.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? first.text
    }

    /// A user rename, saved by the CLI (Claude: custom title, Codex: thread name).
    func rename(_ newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        name = newName
        Task {
            await start()
            switch backend {
            case .claude(let session): try? await session.rename(newName)
            case .codex(let session): try? await session.rename(newName)
            case nil: break
            }
        }
    }

    /// Modes to offer; Claude's Auto only when the model supports it.
    var availableModes: [ModeOption] {
        provider.modes.filter { $0.listed && ($0.id != "auto" || currentModel?.supportsAutoMode != false) }
    }

    var activeMode: ModeOption {
        if provider == .codex && planMode { return Provider.codexPlan }
        return provider.modes.first { $0.id == mode } ?? provider.modes[0]
    }

    /// Codex's permissions preset, shown apart from its Plan chip.
    var permissionsMode: ModeOption { provider.modes.first { $0.id == mode } ?? provider.modes[0] }

    /// The chat's highlight color for the active mode; nil when neutral.
    var tint: Color? { activeMode.tint }

    var currentModel: ModelOption? { models.first { $0.id == modelId } }

    var modelLabel: String { currentModel?.name ?? modelId ?? provider.name }

    var effortLabel: String? {
        guard let effort else { return nil }
        switch effort {
        case "xhigh": return "Extra high"
        default: return effort.capitalized
        }
    }

    // MARK: - Actions

    func start() async {
        if backend != nil { return }
        if let starting { return await starting.value }
        let task = Task {
            do {
                switch provider {
                case .claude: try await launchClaude()
                case .codex: try await launchCodex()
                }
            } catch {
                append(.notice, String(describing: error), isError: true)
            }
        }
        starting = task
        await task.value
        starting = nil
    }

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    func attach(_ urls: [URL]) {
        attachments += urls.map(Attachment.init(url:))
    }

    func removeAttachment(_ id: Attachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    /// Swaps in an edited copy (a marked-up image), keeping its place.
    func replaceAttachment(_ id: Attachment.ID, with url: URL) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index] = Attachment(url: url)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = attachments
        guard !text.isEmpty || !sent.isEmpty else { return }
        draft = ""
        attachments = []
        // Codex extension's /plan: a local toggle, nothing is sent.
        if provider == .codex && text == "/plan" && sent.isEmpty {
            setPlanMode(!planMode)
            return
        }
        streamingIndex = nil
        offerImplementPlan = false
        let isFirstPrompt = name == nil && !entries.contains { $0.kind == .user }
        var entry = Entry(kind: .user, text: text)
        entry.attachments = sent
        entries.append(entry)
        isRunning = true
        let files = Attachments.files(sent)
        let folder = folder
        Task {
            await start()
            do {
                switch backend {
                case .claude(let session):
                    if files.isEmpty {
                        try await session.send(text)
                    } else {
                        // Reading and encoding files can take a moment; keep it off the main actor.
                        let content = await Task.detached {
                            Attachments.claudeContent(text: text, files: files, folder: folder)
                        }.value
                        try await session.send(content: content)
                    }
                    if isFirstPrompt && !text.isEmpty && !text.hasPrefix("/") {
                        if let title = try? await session.generateTitle(from: text), name == nil { name = title }
                    }
                case .codex(let session):
                    if files.isEmpty {
                        try await sendCodex(text, to: session)
                    } else {
                        try await session.send(input: Attachments.codexInput(text: text, files: files))
                    }
                case nil: isRunning = false
                }
            } catch {
                isRunning = false
                append(.notice, String(describing: error), isError: true)
            }
        }
    }

    /// Codex's own slash commands map to RPCs (as in t3code); anything else is a prompt.
    private func sendCodex(_ text: String, to session: CodexSession) async throws {
        if text == "/compact" {
            try await session.compact()
        } else if text.hasPrefix("/goal ") {
            try await session.setGoal(String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            isRunning = false
            append(.notice, "Goal set")
        } else {
            try await session.send(text)
        }
    }

    func stop() {
        let backend = backend
        Task {
            switch backend {
            case .claude(let session): try? await session.interrupt()
            case .codex(let session): try? await session.interrupt()
            case nil: break
            }
        }
    }

    func setMode(_ id: String) {
        let previous = mode
        mode = id
        let backend = backend
        Task {
            do {
                switch backend {
                case .claude(let session):
                    if let m = ClaudeSession.PermissionMode(rawValue: id) { try await session.setPermissionMode(m) }
                case .codex(let session):
                    if let p = CodexSession.Permissions(rawValue: id) { await session.setPermissions(p) }
                case nil: break
                }
            } catch {
                mode = previous
                append(.notice, "Couldn't switch mode: \(error)", isError: true)
            }
        }
    }

    func setPlanMode(_ on: Bool) {
        planMode = on
        if case .codex(let session) = backend { Task { await session.setPlanMode(on) } }
    }

    /// Shift+Tab, as in each CLI: Claude cycles Manual → Edit automatically → Plan → Auto
    /// (if available) → Manual; Codex toggles Plan mode.
    func cycleMode() {
        switch provider {
        case .claude:
            let autoAvailable = availableModes.contains { $0.id == "auto" }
            let next =
                switch mode {
                case "default": "acceptEdits"
                case "acceptEdits": "plan"
                case "plan": autoAvailable ? "auto" : "default"
                default: "default"
                }
            setMode(next)
        case .codex:
            setPlanMode(!planMode)
        }
    }

    /// Codex CLI's "Yes, implement this plan": switch to Default and start coding.
    func implementPlan() {
        setPlanMode(false)
        draft = "Implement the plan."
        send()
    }

    func stayInPlanMode() {
        offerImplementPlan = false
    }

    func setModel(_ option: ModelOption) {
        modelId = option.id
        if let current = effort, !option.efforts.isEmpty, !option.efforts.contains(current) {
            let next = option.efforts.contains("high") ? "high" : option.efforts[0]
            effort = next
            apply(effort: next)
        }
        let backend = backend
        Task {
            do {
                switch backend {
                case .claude(let session): try await session.setModel(option.id)
                case .codex(let session): await session.setModel(option.id)
                case nil: break
                }
            } catch {
                append(.notice, "Couldn't switch model: \(error)", isError: true)
            }
        }
    }

    func setEffort(_ level: String) {
        effort = level
        apply(effort: level)
    }

    func answer(_ approval: Approval, _ decision: Decision) {
        approvals.removeAll { $0.id == approval.id }
        Task {
            switch approval.source {
            case .claude(let request):
                guard case .claude(let session) = backend else { return }
                let mapped: PermissionDecision =
                    switch decision {
                    case .allow: .allow
                    case .allowAlways: .allowAlways
                    case .deny: .deny(message: "The user denied this tool call.")
                    case .answers(let dict): .answers(dict)
                    case .approvePlan(let autoAcceptEdits): autoAcceptEdits ? .allowSettingMode("acceptEdits") : .allow
                    case .keepPlanning: .deny(message: "The user wants to keep planning. Ask what to change.")
                    }
                try? await session.respond(to: request, mapped)
            case .codex(let request):
                guard case .codex(let session) = backend else { return }
                let mapped: CodexDecision =
                    switch decision {
                    case .allow: .accept
                    case .allowAlways: .acceptForSession
                    case .deny: .decline
                    case .answers(let dict): .answers(dict.mapValues { [$0] })
                    case .approvePlan: .accept
                    case .keepPlanning: .decline
                    }
                try? await session.respond(to: request, mapped)
            }
        }
    }

    func close() {
        pump?.cancel()
        let backend = backend
        self.backend = nil
        Task {
            switch backend {
            case .claude(let session): await session.close()
            case .codex(let session): await session.close()
            case nil: break
            }
        }
    }

    private func apply(effort level: String) {
        let backend = backend
        Task {
            switch backend {
            case .claude(let session): try? await session.setEffort(level)
            case .codex(let session): await session.setEffort(level)
            case nil: break
            }
        }
    }

    // MARK: - Launch

    private func launchClaude() async throws {
        let session = try await ClaudeSession.start(
            .init(
                cwd: folder, permissionMode: ClaudeSession.PermissionMode(rawValue: mode) ?? .default,
                resume: resumeId))
        if resuming != nil {
            let folder = folder, id = resumeId ?? ""
            let messages = await Task.detached { ClaudeHistory.messages(sessionId: id, in: folder) }.value
            replayClaude(messages)
            resuming = nil
        }
        backend = .claude(session)
        // Cancelled by close(), which ends the loop and releases the model.
        pump = Task {
            for await event in session.events { self.handleClaude(event) }
        }

        let list = await session.capabilities["models"]?.array ?? []
        models = list.compactMap { json in
            guard let value = json["value"]?.string, value != "default" else { return nil }
            return ModelOption(
                id: value,
                name: json["displayName"]?.string ?? value,
                resolved: json["resolvedModel"]?.string ?? value,
                efforts: json["supportedEffortLevels"]?.array?.compactMap(\.string) ?? [],
                supportsAutoMode: json["supportsAutoMode"]?.bool ?? false)
        }
        commands = (await session.capabilities["commands"]?.array ?? []).compactMap { json in
            guard let name = json["name"]?.string else { return nil }
            return SlashCommand(
                name: name, description: json["description"]?.string ?? "",
                hint: json["argumentHint"]?.string ?? "", kind: .command)
        }
        if let applied = try? await session.settings()["applied"] {
            if let model = applied["model"]?.string {
                modelId = models.first { $0.resolved == model }?.id ?? model
            }
            effort = applied["effort"]?.string
        }
    }

    private func launchCodex() async throws {
        let session = try await CodexSession.start(
            .init(
                cwd: folder, permissions: CodexSession.Permissions(rawValue: mode) ?? .askForApproval,
                plan: planMode, resume: resumeId))
        if resuming != nil {
            replayCodex(await session.history)
            resuming = nil
        }
        backend = .codex(session)
        pump = Task {
            for await event in session.events { self.handleCodex(event) }
        }

        let list = (try? await session.models()) ?? []
        models = list.compactMap { json in
            guard let id = json["id"]?.string, json["hidden"]?.bool != true else { return nil }
            let efforts = json["supportedReasoningEfforts"]?.array?.compactMap {
                $0["reasoningEffort"]?.string ?? $0.string
            }
            return ModelOption(
                id: id,
                name: json["displayName"]?.string ?? id,
                resolved: json["model"]?.string ?? id,
                efforts: efforts ?? [])
        }
        var current = await session.model
        if current == nil || !models.contains(where: { $0.id == current }) {
            let fallbackJSON = list.first { $0["isDefault"]?.bool == true } ?? list.first
            if let fallback = fallbackJSON?["id"]?.string {
                if let old = current {
                    append(.notice, "\(old) isn't available on this account, using \(fallback)")
                }
                await session.setModel(fallback)
                current = fallback
            }
        }
        let skills = (try? await session.skills()) ?? []
        commands =
            [
                SlashCommand(name: "plan", description: "Plan mode", hint: "", kind: .command),
                SlashCommand(name: "compact", description: "Summarize the thread to free up context", hint: "", kind: .command),
                SlashCommand(
                    name: "goal", description: "Set a goal Codex keeps working toward until it is done",
                    hint: "objective", kind: .command),
            ]
            + skills.compactMap { json in
                guard let name = json["name"]?.string, json["enabled"]?.bool != false else { return nil }
                return SlashCommand(
                    name: name, description: json["shortDescription"]?.string ?? json["description"]?.string ?? "",
                    hint: "", kind: .skill)
            }
        modelId = current
        if let current, let json = list.first(where: { $0["id"]?.string == current }) {
            effort = json["defaultReasoningEffort"]?.string
        }
    }

    // MARK: - History

    /// Claude transcript entries go through the live event handling; only user prompts
    /// need adding here (live, the composer adds them).
    private func replayClaude(_ messages: [JSONValue]) {
        for message in messages {
            if message["type"]?.string == "user", let content = message["message"]?["content"] {
                let prompt = Self.promptText(content)
                let chips = Attachments.chips(fromClaude: content)
                if prompt != nil || !chips.isEmpty {
                    var entry = Entry(kind: .user, text: prompt ?? "")
                    entry.attachments = chips
                    entries.append(entry)
                    continue
                }
            }
            handleClaude(ClaudeEvent(message: message))
        }
        streamingIndex = nil
    }

    private func replayCodex(_ turns: [JSONValue]) {
        for item in turns.flatMap({ $0["items"]?.array ?? [] }).map(CodexItem.init) {
            if item.type == "userMessage" {
                let content = item.raw["content"] ?? []
                let text = content.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
                let chips = Attachments.chips(fromCodex: content)
                if !text.isEmpty || !chips.isEmpty {
                    var entry = Entry(kind: .user, text: text)
                    entry.attachments = chips
                    entries.append(entry)
                }
            } else {
                codexItemStarted(item)
                codexItemCompleted(item)
            }
        }
        offerImplementPlan = false
    }

    private static func promptText(_ content: JSONValue?) -> String? {
        let text = content?.string ?? content?.array?.last { $0["type"]?.string == "text" }?["text"]?.string
        guard let text, !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return text
    }

    // MARK: - Claude events

    private func handleClaude(_ event: ClaudeEvent) {
        switch event {
        case .sessionStarted(let info):
            resumeId = info.sessionId
            if let current = info.permissionMode { mode = current }
        case .permissionModeChanged(let current):
            mode = current
        case .textDelta(let text, nil):
            stream(.assistant, text)
        case .thinkingDelta(let text, nil):
            stream(.thinking, text)
        case .assistant(_, let blocks, nil):
            // Normally the text already arrived as deltas. Slash command output (e.g. /context)
            // comes as one complete message with none, so show its text here.
            if streamingIndex == nil {
                for case .text(let text) in blocks where !text.isEmpty { append(.assistant, text) }
            }
            streamingIndex = nil
            for case .toolUse(let id, let name, let input) in blocks {
                var entry = Entry(kind: .tool, text: Self.summary(of: input, in: folder))
                entry.toolName = name
                entry.toolId = id
                entries.append(entry)
            }
        case .user(let blocks, nil):
            for case .toolResult(let id, let content, let isError) in blocks {
                guard let i = entries.lastIndex(where: { $0.toolId == id }) else { continue }
                entries[i].result = Self.text(of: content)
                entries[i].done = true
                entries[i].isError = isError
            }
        case .permissionRequest(let r):
            approvals.append(claudeApproval(r))
        case .permissionCancelled(let id):
            approvals.removeAll { $0.id == id }
        case .turnCompleted(let r):
            isRunning = false
            streamingIndex = nil
            approvals.removeAll()
            if r.isError {
                let interrupted = r.subtype == "error_during_execution"
                append(.notice, interrupted ? "Interrupted" : (r.result ?? r.subtype), isError: !interrupted)
            }
        case .raw(let json):
            if json["type"]?.string == "stream_event", json["event"]?["type"]?.string == "content_block_start" {
                streamingIndex = nil
            }
        case .exited(let status):
            exited(status, name: "Claude")
        default:
            break  // subagent traffic, stderr
        }
    }

    private func claudeApproval(_ r: PermissionRequest) -> Approval {
        if r.toolName == "ExitPlanMode" {
            return Approval(
                id: r.id, title: "Ready to code?", detail: nil, body: nil, canAlwaysAllow: false,
                questions: [], source: .claude(r), plan: r.input["plan"]?.string ?? "")
        }
        if r.isQuestion {
            let questions = (r.input["questions"]?.array ?? []).map { q in
                let text = q["question"]?.string ?? ""
                return Approval.Question(id: text, text: text, options: Self.options(q["options"]))
            }
            return Approval(
                id: r.id, title: "", detail: nil, body: nil, canAlwaysAllow: false,
                questions: questions, source: .claude(r))
        }
        return Approval(
            id: r.id, title: "Allow \(r.toolName)?", detail: r.description,
            body: Self.summary(of: r.input, in: folder), canAlwaysAllow: !r.suggestions.isEmpty,
            questions: [], source: .claude(r))
    }

    private func stream(_ kind: Entry.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        if let i = streamingIndex, entries.indices.contains(i), entries[i].kind == kind {
            entries[i].text += text
        } else {
            append(kind, text)
            streamingIndex = entries.count - 1
        }
    }

    // MARK: - Codex events

    private func handleCodex(_ event: CodexEvent) {
        switch event {
        case .threadStarted(let threadId, _, _):
            resumeId = threadId
        case .turnStarted:
            isRunning = true
        case .textDelta(let itemId, let t):
            streamItem(itemId, .assistant, t)
        case .reasoningDelta(let itemId, let t):
            streamItem(itemId, .thinking, t)
        case .planDelta(let itemId, let t):
            streamItem(itemId, .plan, t)
        case .commandOutputDelta(let itemId, let t):
            if let i = itemIndex[itemId], entries.indices.contains(i) {
                entries[i].result = (entries[i].result ?? "") + t
            }
        case .itemStarted(let item):
            codexItemStarted(item)
        case .itemCompleted(let item):
            codexItemCompleted(item)
        case .approvalRequest(let a):
            approvals.append(codexApproval(a))
        case .approvalResolved(let requestId):
            approvals.removeAll { $0.id == requestId.compact }
        case .turnCompleted(let r):
            isRunning = false
            approvals.removeAll()
            switch r.status {
            case "interrupted": append(.notice, "Interrupted")
            case "failed": append(.notice, Self.cleanError(r.errorMessage ?? "Turn failed"), isError: true)
            default: break
            }
        case .exited(let status):
            exited(status, name: "Codex")
        case .error, .raw, .stderr:
            break
        }
    }

    private func streamItem(_ itemId: String, _ kind: Entry.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        if let i = itemIndex[itemId], entries.indices.contains(i) {
            entries[i].text += text
        } else {
            var entry = Entry(kind: kind, text: text)
            entry.toolId = itemId
            entries.append(entry)
            itemIndex[itemId] = entries.count - 1
        }
    }

    private func codexItemStarted(_ item: CodexItem) {
        let name: String
        let text: String
        switch item.type {
        case "commandExecution":
            name = "Run"
            text = Self.codexCommand(item.raw) ?? item.command ?? ""
        case "fileChange":
            name = "Edit"
            let paths = (item.raw["changes"]?.array ?? []).compactMap { $0["path"]?.string }
            text = paths.map { Self.relative($0, in: folder) }.joined(separator: ", ")
        case "mcpToolCall":
            name = "\(item.raw["server"]?.string ?? "mcp").\(item.raw["tool"]?.string ?? "tool")"
            text = String((item.raw["arguments"]?.compact ?? "").prefix(160))
        case "webSearch":
            name = "Search"
            text = item.raw["query"]?.string ?? ""
        default:
            return
        }
        var entry = Entry(kind: .tool, text: text)
        entry.toolName = name
        entry.toolId = item.id
        entries.append(entry)
        itemIndex[item.id] = entries.count - 1
    }

    private func codexItemCompleted(_ item: CodexItem) {
        let failed = ["failed", "declined"].contains(item.status ?? "")
        switch item.type {
        case "plan":
            if itemIndex[item.id] == nil, let text = item.text, !text.isEmpty {
                var entry = Entry(kind: .plan, text: text)
                entry.toolId = item.id
                entries.append(entry)
                itemIndex[item.id] = entries.count - 1
            }
            if planMode { offerImplementPlan = true }
        case "agentMessage":
            if itemIndex[item.id] == nil, let text = item.text, !text.isEmpty {
                var entry = Entry(kind: .assistant, text: text)
                entry.toolId = item.id
                entries.append(entry)
                itemIndex[item.id] = entries.count - 1
            }
        case "commandExecution":
            guard let i = itemIndex[item.id], entries.indices.contains(i) else { return }
            let streamed = entries[i].result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let aggregated = item.raw["aggregatedOutput"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            entries[i].result =
                !streamed.isEmpty ? streamed : (!aggregated.isEmpty ? aggregated : "exit \(item.exitCode ?? 0)")
            entries[i].done = true
            entries[i].isError = (item.exitCode != nil && item.exitCode != 0) || failed
        case "fileChange", "mcpToolCall", "webSearch":
            guard let i = itemIndex[item.id], entries.indices.contains(i) else { return }
            entries[i].result = item.status ?? "done"
            entries[i].done = true
            entries[i].isError = failed
        default:
            break
        }
    }

    private func codexApproval(_ a: CodexApproval) -> Approval {
        let id = a.id.compact
        func make(_ title: String, body: String? = nil, always: Bool = false, questions: [Approval.Question] = [])
            -> Approval
        {
            Approval(
                id: id, title: title, detail: a.reason, body: body, canAlwaysAllow: always,
                questions: questions, source: .codex(a))
        }
        switch a.kind {
        case .command:
            return make("Run command?", body: Self.codexCommand(a.params) ?? a.command, always: true)
        case .fileChange:
            let body = a.itemId.flatMap { itemIndex[$0] }.flatMap { entries.indices.contains($0) ? entries[$0].text : nil }
            return make("Apply file changes?", body: body, always: true)
        case .permissions:
            return make("Grant extra permissions?", body: a.params["permissions"]?.compact)
        case .mcpElicitation:
            return make("Allow MCP request?")
        case .userInput:
            let questions = a.questions.map { q in
                Approval.Question(
                    id: q["id"]?.string ?? "", text: q["question"]?.string ?? "",
                    options: Self.options(q["options"]))
            }
            return make("", questions: questions)
        }
    }

    // MARK: - Shared

    private func exited(_ status: Int32, name: String) {
        // The next send restarts the CLI and resumes `resumeId`.
        backend = nil
        isRunning = false
        approvals.removeAll()
        if status != 0 && status != 15 { append(.notice, "\(name) exited (\(status))", isError: true) }
    }

    private func append(_ kind: Entry.Kind, _ text: String, isError: Bool = false) {
        var entry = Entry(kind: kind, text: text)
        entry.isError = isError
        entries.append(entry)
    }

    // MARK: - Formatting

    private static func options(_ json: JSONValue?) -> [Approval.Option] {
        (json?.array ?? []).map {
            Approval.Option(label: $0["label"]?.string ?? "", description: $0["description"]?.string ?? "")
        }
    }

    /// The one input field worth showing for a tool call.
    static func summary(of input: JSONValue, in folder: URL) -> String {
        if let command = input["command"]?.string { return command }
        if let questions = input["questions"]?.array {  // AskUserQuestion
            return questions.compactMap { $0["question"]?.string }.joined(separator: " · ")
        }
        if let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string {
            return relative(path, in: folder)
        }
        for key in ["pattern", "url", "query", "description", "prompt"] {
            if let value = input[key]?.string { return value }
        }
        return String(input.compact.prefix(160))
    }

    static func text(of content: JSONValue) -> String {
        if let s = content.string { return s }
        return content.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? content.compact
    }

    /// Codex wraps a shell command in `bash -lc`; `commandActions` carries the readable form.
    static func codexCommand(_ json: JSONValue) -> String? {
        if let actions = json["commandActions"]?.array, actions.count == 1, let c = actions[0]["command"]?.string {
            return c
        }
        return json["command"]?.string
    }

    static func relative(_ path: String, in folder: URL) -> String {
        let root = folder.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// Codex errors are often a JSON string like {"error":{"message":"..."}}.
    static func cleanError(_ raw: String) -> String {
        guard let json = try? JSONValue.parse(Data(raw.utf8)),
            let message = json["error"]?["message"]?.string
        else { return raw }
        return message
    }
}
