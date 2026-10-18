import KoreCore
import SwiftUI

/// What the transcript's rows can do. One value shared by every row, so rows compare by content.
struct TranscriptActions {
    var toggleTurn: (String) -> Void = { _ in }
    /// Opens or closes a tool body, thinking, a file inside an edit ("id/path"), or an agent.
    var toggle: (String) -> Void = { _ in }
    var openImage: (Attachment) -> Void = { _ in }
    var viewChanges: (String) -> Void = { _ in }
    var stopAgent: (String) -> Void = { _ in }
    /// Opens a sub-agent in its own tab.
    var openAgent: (String) -> Void = { _ in }
    /// Scrolls back to a sticky user message.
    var reveal: (String) -> Void = { _ in }
    var folder: URL?
}

/// One row: on the timeline (with its dot and line) or off it.
struct TimelineRow: View, Equatable {
    let item: TranscriptStore.Item
    let actions: TranscriptActions

    nonisolated static func == (a: Self, b: Self) -> Bool { a.item == b.item }

    var body: some View {
        if let dot = item.dot {
            let rule = if case .rule = item.row { true } else { false }
            TimelineItem(
                dot: dot, above: item.above, below: item.below,
                top: rule ? Space.xs : Layout.Timeline.itemPadding, bottom: rule ? 0 : Layout.Timeline.itemPadding
            ) {
                RowContent(row: item.row, actions: actions)
            }
        } else {
            RowContent(row: item.row, actions: actions)
                .padding(.vertical, Layout.Timeline.itemPadding)
        }
    }
}

/// A row's content, without its place on the timeline. Agent cards use it for their own rows.
struct RowContent: View {
    let row: TranscriptStore.Row
    let actions: TranscriptActions

    var body: some View {
        switch row {
        case .entry(let entry):
            EntryContent(entry: entry, actions: actions)
        case .tool(let entry, let open):
            ToolItem(entry: entry, open: open, actions: actions)
        case .thinking(let entry, let open):
            ThoughtItem(entry: entry, open: open) { actions.toggle(entry.id.uuidString) }
        case .file(let entry, _, _):
            EditItem(entry: entry, actions: actions)
        case .agent(let entry, let lane, let open):
            AgentItem(entry: entry, lane: lane, open: open, actions: actions)
        case .fold(let fold):
            WorkedFor(label: fold.label, outcome: fold.outcome, denied: fold.denied, isOpen: fold.open) {
                actions.toggleTurn(fold.turn)
            }
        case .rule:
            Rule()
        case .outcome(_, let text):
            Text(text)
                .font(TextStyle.body)
                .foregroundStyle(text == "Interrupted" ? Theme.secondary : Theme.danger)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .changes(let turn, let files, let added, let removed):
            ChangesLine(files: files, added: added, removed: removed) { actions.viewChanges(turn) }
        }
    }
}

/// Text items: the answer, a plan, a notice.
private struct EntryContent: View {
    let entry: TranscriptStore.Entry
    let actions: TranscriptActions

    var body: some View {
        switch entry.kind {
        case .plan:
            PlanText(text: entry.text)
        case .notice:
            Text(entry.text)
                .font(TextStyle.body)
                .foregroundStyle(entry.isError ? Theme.danger : Theme.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .user, .peer:
            MessageHeader(entry: entry, actions: actions)
        default:
            Text(planMarkdown(entry.text))
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .lineSpacing(TextStyle.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Messages (off the timeline)

/// The user's message (or a peer's), at the head of its section. It sticks to the top while its
/// turn scrolls by, over the background with a faded lower edge; a click scrolls back to it.
struct MessageHeader: View {
    let entry: TranscriptStore.Entry
    let actions: TranscriptActions

    var body: some View {
        Group {
            if entry.kind == .peer {
                peer
            } else {
                user
            }
        }
        .padding(.top, Layout.Timeline.itemPadding)
        .padding(.bottom, Layout.Timeline.itemPadding + Layout.Timeline.stickyFade)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Solid behind the message, fading over its last points only. A gradient fill, not a
        // mask: a mask costs an offscreen layer per header.
        .background {
            VStack(spacing: 0) {
                Theme.background
                LinearGradient(colors: [Theme.background, Theme.background.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Layout.Timeline.stickyFade)
            }
        }
        .padding(.bottom, -Layout.Timeline.stickyFade)
        .contentShape(Rectangle())
        .onTapGesture { actions.reveal(entry.id.uuidString) }
    }

    private var user: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !entry.attachments.isEmpty {
                HStack(spacing: Space.md) {
                    ForEach(entry.attachments) { attachment in
                        AttachmentChip(attachment: attachment, open: { actions.openImage(attachment) })
                    }
                }
            }
            if !entry.text.isEmpty {
                Text(entry.text)
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(Inset.userBox)
                    .panel(.userBox)
            }
        }
    }

    private var peer: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label("From \(entry.from ?? "another session")", systemImage: "bubble.left")
                .font(TextStyle.labelMedium)
                .foregroundStyle(Theme.secondary)
            Text(entry.text)
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
        }
        .padding(Inset.bubble)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.outline)
        .help("A message from another Claude session")
    }
}

// MARK: Tools

/// "Bash  List JSON literals…", then an IN / OUT box (look.md §3).
struct ToolItem: View {
    let entry: TranscriptStore.Entry
    let open: Bool
    let actions: TranscriptActions

    /// Tools whose input is worth an IN row even when the CLI gives only a summary.
    private static let commands: Set<String> = ["Bash", "Run", "BashOutput", "Search", "WebSearch"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolHeader(name: entry.toolName ?? "Tool", path: entry.path, text: secondary, folder: actions.folder)
            if !parts.isEmpty {
                ToolBody(parts: parts, open: open) { actions.toggle(entry.id.uuidString) }
            }
        }
    }

    private var secondary: String {
        if entry.path != nil { return entry.summary ?? "" }
        return entry.summary ?? entry.text
    }

    /// Tools whose header says it all; they get a box only for an error.
    private static let quiet: Set<String> = ["Read", "Glob", "LS", "NotebookRead", "TodoWrite"]

    private var parts: [ToolBody.Part] {
        if Self.quiet.contains(entry.toolName ?? "") {
            guard entry.isError, let result = entry.result, !result.isEmpty else { return [] }
            return [.init(label: "OUT", text: result, isError: true)]
        }
        let isCommand = Self.commands.contains(entry.toolName ?? "") || entry.input != nil
        var parts: [ToolBody.Part] = []
        if let input = entry.input ?? (isCommand && entry.summary != nil ? entry.text : nil), !input.isEmpty {
            parts.append(.init(label: "IN", text: input))
        }
        if let result = entry.result?.trimmingCharacters(in: .newlines), !result.isEmpty, isCommand || entry.isError {
            parts.append(.init(label: "OUT", text: result, isError: entry.isError))
        }
        return parts
    }
}

/// A tool's name in bold, then its secondary text in small code; a file path shows only its
/// last part, as a link that opens it. Up to two lines.
struct ToolHeader: View {
    let name: String
    /// An agent's name is in its hue.
    var nameColor = Theme.text
    /// `labelStrong` for a file inside a multi-file edit, a step quieter than its parent.
    var nameFont = TextStyle.toolName
    var path: String?
    var text: String
    var folder: URL?
    var added = 0
    var removed = 0
    /// " · failed" after the secondary text, in its own colour.
    var status: (text: String, color: Color)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(line)
                .lineLimit(2)
                .tint(Theme.secondary)
                .environment(\.openURL, OpenURLAction { url in
                    NSWorkspace.shared.open(url)
                    return .handled
                })
                .help(path ?? "")
            if added > 0 || removed > 0 { ChangeCounts(added: added, removed: removed) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var line: AttributedString {
        var name = AttributedString(name)
        name.font = nameFont
        name.foregroundColor = nameColor
        var rest = AttributedString("")
        if let path {
            var link = AttributedString((path as NSString).lastPathComponent)
            link.link = OpenInEditor.url(path, in: folder)
            rest += link
            if !text.isEmpty { rest += AttributedString(" " + text) }
        } else {
            rest = AttributedString(text)
        }
        if let status {
            var suffix = AttributedString(text.isEmpty && path == nil ? status.text : " · " + status.text)
            suffix.foregroundColor = status.color
            rest.foregroundColor = Theme.secondary
            rest += suffix
        }
        rest.font = TextStyle.codeSmall
        if status == nil { rest.foregroundColor = Theme.secondary }
        guard !rest.characters.isEmpty else { return name }
        var gap = AttributedString(" ")
        gap.font = TextStyle.codeSmall
        return name + gap + rest
    }
}

/// "Thought for 3s ›", opened to the thinking in secondary.
struct ThoughtItem: View {
    let entry: TranscriptStore.Entry
    let open: Bool
    let toggle: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button(action: toggle) {
                HStack(spacing: Space.xs) {
                    Text(label)
                    Disclosure(isOpen: open)
                }
                .font(TextStyle.body)
                .foregroundStyle(hovered.value || open ? Theme.secondary : Theme.thinkingSummary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered.value = $0 }
            if open {
                Text(entry.text)
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(TextStyle.leading)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: String {
        if let duration = entry.duration { return "Thought for \(WorkedFor.duration(duration))" }
        return entry.done ? "Thought" : "Thinking…"
    }
}

// MARK: File edits

/// "Edit notes.txt +3 −1" with the diff as its body (look.md §4). Several files in one call read
/// "Edit 3 files" and list a header and diff per file.
struct EditItem: View {
    let entry: TranscriptStore.Entry
    let actions: TranscriptActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.changes.count == 1, let change = entry.changes[0] as FileChange? {
                ToolHeader(
                    name: Self.verb(change, tool: entry.toolName), path: change.path, text: Self.move(change),
                    folder: actions.folder, added: change.added, removed: change.removed)
                if !Self.isPureMove(change) {
                    DiffView(change: change, folder: actions.folder).padding(.vertical, Space.bodyMargin)
                }
            } else {
                ToolHeader(
                    name: "Edit", text: "\(entry.changes.count) files", folder: actions.folder,
                    added: entry.changes.reduce(0) { $0 + $1.added }, removed: entry.changes.reduce(0) { $0 + $1.removed })
                ForEach(entry.changes) { change in
                    ToolHeader(
                        name: Self.verb(change, tool: nil), nameFont: TextStyle.labelStrong, path: change.path,
                        text: Self.move(change), folder: actions.folder, added: change.added, removed: change.removed)
                        .padding(.top, Space.md)
                    if !Self.isPureMove(change) {
                        DiffView(change: change, folder: actions.folder).padding(.top, Space.xs)
                    }
                }
            }
            if entry.isError, let result = entry.result {
                Text(result)
                    .font(TextStyle.codeSmall)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
            }
        }
    }

    static func verb(_ change: FileChange, tool: String?) -> String {
        switch change.kind {
        case .add: "Write"
        case .update: tool == "Write" ? "Write" : "Edit"
        case .delete: "Delete"
        case .move: "Move"
        }
    }

    /// A move's "from → " part; the header's link is the new name.
    static func move(_ change: FileChange) -> String {
        guard case .move(let from) = change.kind else { return "" }
        return "← \((from as NSString).lastPathComponent)"
    }

    static func isPureMove(_ change: FileChange) -> Bool {
        if case .move = change.kind { return change.hunks.isEmpty }
        return false
    }
}

/// After a turn that changed files: "⊞ 3 files changed +24 −7 · View changes" (look.md §8).
/// In a narrow tile "View changes" wraps to its own line.
struct ChangesLine: View {
    let files: Int
    let added: Int
    let removed: Int
    let view: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.sm) {
                summary
                Text("·").font(TextStyle.label).foregroundStyle(Theme.tertiary)
                TextButton("View changes", action: view)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                summary
                TextButton("View changes", action: view)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "plus.forwardslash.minus")
                .font(Glyph.rowIcon)
                .foregroundStyle(Theme.secondary)
            HStack(spacing: Space.md) {
                Text(files == 1 ? "1 file changed" : "\(files) files changed")
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .fixedSize()
                ChangeCounts(added: added, removed: removed)
            }
        }
    }
}

// MARK: Sub-agents

/// A sub-agent where it was spawned (look.md §7, §11): its avatar is the dot and its name is in
/// its hue. Open, its own items hang off a rail in that hue, ending with its result. On hover
/// the header offers "Open in tab"; ⌘-click does the same.
struct AgentItem: View {
    let entry: TranscriptStore.Entry
    let lane: [TranscriptStore.Row]
    let open: Bool
    let actions: TranscriptActions
    @StateObject private var hovered = Local(false)
    @StateObject private var showEarlier = Local(false)
    @StateObject private var showAllResult = Local(false)

    /// Items shown before "N earlier".
    private static let recent = 8

    var body: some View {
        if let info = entry.agent {
            VStack(alignment: .leading, spacing: 0) {
                header(info)
                if open {
                    nested(info)
                } else if info.status == .running, let last = lane.last {
                    NestedTimeline(rows: [last], actions: actions, rail: rail(info))
                }
            }
        }
    }

    private func header(_ info: TranscriptStore.AgentInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Button {
                if NSEvent.modifierFlags.contains(.command) {
                    actions.openAgent(info.id)
                } else {
                    actions.toggle(entry.id.uuidString)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    ToolHeader(
                        name: info.name, nameColor: AgentAvatar.hue(info.index), text: subtitle(info),
                        status: statusSuffix(info))
                        .layoutPriority(1)
                    if hovered.value {
                        // Built only on hover: a hidden view wouldn't take the click.
                        Button {
                            actions.openAgent(info.id)
                        } label: {
                            Label("Open in tab", systemImage: "arrow.up.forward")
                                .font(TextStyle.labelMedium)
                                .foregroundStyle(Theme.accent)
                                .labelStyle(.titleAndIcon)
                                .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .help("Open this agent in its own tab (⌘-click)")
                    }
                    AgentMeter(info: info)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered.value = $0 }
            .help(open ? "Hide this agent's work" : "Show this agent's work")
            if info.status == .running {
                IconButton(symbol: "stop.fill", kind: .small, font: Glyph.stop, help: "Stop agent") {
                    actions.stopAgent(info.id)
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            Button {
                actions.toggle(entry.id.uuidString)
            } label: {
                Disclosure(isOpen: open).foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
    }

    /// "Explore · haiku" while running; then the type, with its status after it.
    private func subtitle(_ info: TranscriptStore.AgentInfo) -> String {
        let model = info.status == .running && info.waiting == 0 ? info.model : nil
        return [info.type, model].compactMap { $0 }.joined(separator: " · ")
    }

    /// "waiting" in secondary, "failed" in red, "finished" / "stopped" in secondary.
    private func statusSuffix(_ info: TranscriptStore.AgentInfo) -> (text: String, color: Color)? {
        switch info.status {
        case .running: info.waiting > 0 ? ("waiting", Theme.secondary) : nil
        case .finished: ("finished", Theme.secondary)
        case .failed: ("failed", Theme.danger)
        case .stopped: ("stopped", Theme.secondary)
        }
    }

    @ViewBuilder
    private func nested(_ info: TranscriptStore.AgentInfo) -> some View {
        let hidden = showEarlier.value ? 0 : max(0, lane.count - Self.recent)
        VStack(alignment: .leading, spacing: 0) {
            if hidden > 0 {
                TextButton("\(hidden) earlier", font: TextStyle.caption, color: Theme.tertiary) {
                    showEarlier.value = true
                }
                .padding(.top, Space.xs)
            }
            if lane.isEmpty, info.status == .running {
                NestedNote(
                    text: info.background ? "Commands appear when this agent finishes" : "No commands yet")
            }
            NestedTimeline(
                rows: Array(lane.suffix(lane.count - hidden)), actions: actions, result: result(info), rail: rail(info))
        }
    }

    private func rail(_ info: TranscriptStore.AgentInfo) -> Color { Theme.agentRail(AgentAvatar.hue(info.index)) }

    private func result(_ info: TranscriptStore.AgentInfo) -> AnyView? {
        guard let result = info.result, !result.isEmpty else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: Space.xs) {
            Text(planMarkdown(result))
                .font(TextStyle.body)
                .foregroundStyle(info.status == .finished ? Theme.text : Theme.secondary)
                .lineSpacing(TextStyle.leading)
                .lineLimit(showAllResult.value ? nil : 4)
                .textSelection(.enabled)
            if !showAllResult.value, result.count > 280 || result.filter({ $0 == "\n" }).count > 3 {
                TextButton("Show all") { showAllResult.value = true }
            }
        })
    }
}

/// An agent's own items on their own line, set in at the card's text column.
private struct NestedTimeline: View {
    let rows: [TranscriptStore.Row]
    let actions: TranscriptActions
    var result: AnyView?
    var rail: Color?

    var body: some View {
        let dots = rows.map { TranscriptStore.dot($0) ?? .plain } + (result == nil ? [] : [.plain])
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                TimelineItem(dot: dots[i], above: i > 0, below: i + 1 < dots.count, rail: rail) {
                    RowContent(row: row, actions: actions)
                }
            }
            if let result {
                TimelineItem(dot: .plain, above: !rows.isEmpty, rail: rail) { result }
            }
        }
    }
}

private struct NestedNote: View {
    let text: String

    var body: some View {
        TimelineItem(dot: .plain) {
            Text(text).font(TextStyle.body).foregroundStyle(Theme.tertiary)
        }
    }
}

/// "0:41 · 18.2k · 9 tools"; the time ticks while the agent runs.
struct AgentMeter: View {
    let info: TranscriptStore.AgentInfo

    var body: some View {
        if info.status == .running {
            TimelineView(.periodic(from: info.startedAt, by: 1)) { context in
                line(context.date.timeIntervalSince(info.startedAt))
            }
        } else {
            line(info.duration)
        }
    }

    private func line(_ duration: TimeInterval?) -> some View {
        var parts: [String] = []
        if let duration { parts.append(Self.clock(duration)) }
        if let tokens = info.tokens { parts.append(Self.tokens(tokens)) }
        if info.tools > 0 { parts.append(info.tools == 1 ? "1 tool" : "\(info.tools) tools") }
        return Text(parts.joined(separator: " · "))
            .font(TextStyle.caption.monospacedDigit())
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// m:ss, or h:mm:ss over an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 940 · 18.2k · 1.3M.
    static func tokens(_ n: Int) -> String {
        func one(_ v: Double, _ unit: String) -> String {
            let s = String(format: "%.1f", v)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
        }
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return one(Double(n) / 1000, "k") }
        return one(Double(n) / 1_000_000, "M")
    }
}
