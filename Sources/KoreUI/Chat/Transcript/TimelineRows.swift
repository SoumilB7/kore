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
    /// Forks the conversation from a user message (its action menu).
    var fork: (TranscriptStore.Entry) -> Void = { _ in }
    /// Forks the conversation through an answer's turn (its actions), into a new tab.
    var forkAfter: (TranscriptStore.Entry) -> Void = { _ in }
    /// Loads the conversation before a compaction.
    var loadEarlierConversation: () -> Void = {}
    /// A fork's "Forked from" line: switches to the original chat's tab; nil when there's none.
    var openOriginal: (() -> Void)?
    /// A message row moved (its frame in the scroll view: the bottom for its pinned copy, the
    /// top for keeping the reader's place), or left the built rows (nil).
    var messageMoved: (String, CGRect?) -> Void = { _, _ in }
    /// An answer row's top moved, or it left the built rows (nil): a long answer marks the
    /// reader's place where no message is near.
    var answerMoved: (String, CGFloat?) -> Void = { _, _ in }
    var folder: URL?
}

/// One row: on the timeline (with its dot and line) or off it.
struct TimelineRow: View, Equatable {
    let item: TranscriptStore.Item
    let actions: TranscriptActions

    nonisolated static func == (a: Self, b: Self) -> Bool { a.item == b.item }

    var body: some View {
        if case .entry(let entry) = item.row, entry.kind == .answer {
            let (id, actions) = (item.id, actions)
            row
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { actions.answerMoved(id, $0) }
                .onDisappear { actions.answerMoved(id, nil) }
        } else {
            row
        }
    }

    private var row: some View { content.storyID(Self.story(item.row), press: press) }

    /// What pressing the row does, where its name and a click on its middle could differ:
    /// open or close it.
    private var press: (@MainActor () -> Void)? {
        let actions = actions
        switch item.row {
        case .fold(let fold): return { actions.toggleTurn(fold.turn) }
        case .tool(let e, _), .agent(let e, _, _): return { actions.toggle(e.id.uuidString) }
        case .explored(let calls, _):
            guard let first = calls.first else { return nil }
            return { actions.toggle("explored-\(first.id.uuidString)") }
        default: return nil
        }
    }

    /// The row's storyline name, by its entry, tool, agent or turn id (phase 12 plan §3).
    static func story(_ row: TranscriptStore.Row) -> StoryID? {
        switch row {
        case .message(let e, _, _):
            return e.kind == .peer ? StoryID.Transcript.peer(e.id) : StoryID.Transcript.user(e.id)
        case .entry(let e):
            switch e.kind {
            case .answer: return StoryID.Transcript.answer(e.id)
            case .divider where e.source != TranscriptStore.forkSource: return StoryID.Transcript.compacted(e.id)
            default: return nil
            }
        case .tool(let e, _), .file(let e, _, _):
            return StoryID.Transcript.tool(e.toolId ?? e.id.uuidString)
        case .agent(let e, _, _):
            return StoryID.Transcript.agent(e.agent?.id ?? e.id.uuidString)
        case .fold(let fold):
            return StoryID.Transcript.fold(fold.turn)
        case .changes(let turn, _, _, _):
            return StoryID.Transcript.changes(turn)
        case .explored(let calls, _):
            return calls.first.map { StoryID.Transcript.explored($0.toolId ?? $0.id.uuidString) }
        case .thinking, .rule, .outcome, .summary, .queued, .spinner:
            return nil
        }
    }

    @ViewBuilder private var content: some View {
        if case .entry(let entry) = item.row, entry.kind == .divider {
            DividerRow(text: entry.text, open: entry.source == TranscriptStore.forkSource ? actions.openOriginal : nil)
        } else if case .entry(let entry) = item.row, entry.kind == .mode, entry.modeLead == nil, let mode = entry.mode {
            ModeDivider(mode: mode)
        } else if case .message(let entry, let open, let expanded) = item.row {
            MessageHeader(entry: entry, open: open, expanded: expanded, messageActions: item.actions, actions: actions)
        } else if case .summary(let entry, let expanded) = item.row {
            CompactionSummary(entry: entry, expanded: expanded, actions: actions)
        } else if case .spinner(_, let since, let claude, let word) = item.row {
            // Not a timeline item: no dot, and the line doesn't run into it.
            SpinnerRow(since: since, claude: claude, word: word)
        } else if let dot = item.dot {
            let rule = if case .rule = item.row { true } else { false }
            TimelineItem(
                dot: dot, above: item.above, below: item.below,
                top: rule ? Space.xs : Layout.Timeline.itemPadding, bottom: rule ? 0 : Layout.Timeline.itemPadding
            ) {
                if case .entry(let entry) = item.row, let messageActions = item.actions {
                    AnswerWithActions(entry: entry, messageActions: messageActions, actions: actions)
                } else {
                    RowContent(row: item.row, actions: actions)
                }
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
            WorkedFor(
                label: fold.label, outcome: fold.outcome, denied: fold.denied, isOpen: fold.open, live: fold.live,
                count: fold.count, now: fold.now
            ) {
                actions.toggleTurn(fold.turn)
            }
        case .explored(let calls, let open):
            ExploredItem(calls: calls.count, open: open) { actions.toggle("explored-\(calls[0].id.uuidString)") }
        case .spinner(_, let since, let claude, let word):
            SpinnerRow(since: since, claude: claude, word: word)
        case .summary(let entry, let expanded):
            CompactionSummary(entry: entry, expanded: expanded, actions: actions)
        case .queued(let entry):
            QueuedMessage(entry: entry, actions: actions)
        case .message(let entry, let open, let expanded):
            MessageHeader(entry: entry, open: open, expanded: expanded, actions: actions)
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
            MessageHeader(entry: entry, open: true, actions: actions)
        case .mode:
            if let mode = entry.mode { ModeItemText(lead: entry.modeLead ?? "", mode: mode) }
        default:
            // While it streams, whole blocks only (the row's text already stops at the last one).
            MarkdownView(text: entry.text, streaming: !entry.done, key: entry.id.uuidString)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Messages (off the timeline)

/// The user's message (or a peer's), first in its section (look.md §15). A long one stops at
/// `collapsedLines` laid-out lines with its text fading out, and "Show full message" opens it.
/// While its turn scrolls by, `StickyMessage` keeps its first lines pinned at the top; a click
/// there scrolls back to it.
struct MessageHeader: View {
    enum Place { case row, sticky }

    let entry: TranscriptStore.Entry
    /// A peer's message is one line until opened.
    var open = true
    /// A long message shown whole.
    var expanded = false
    var place = Place.row
    /// Its Copy / Fork row (look §11); nil for none (a pinned copy, a queued message).
    var messageActions: TranscriptStore.MessageActions?
    let actions: TranscriptActions
    /// The text's laid-out lines at the current width. It starts from an estimate, so a long
    /// message is collapsed from its first layout: laid out whole first, it would shrink by many
    /// screens and leave the view scrolled past the end.
    @StateObject private var lines: Local<Int>
    /// The row's top in the visible area (for "Show less"), held without re-rendering.
    @StateObject private var top = Held(CGFloat(0))
    /// Under the pointer: its action button shows.
    @StateObject private var hovered = Local(false)

    init(
        entry: TranscriptStore.Entry, open: Bool = true, expanded: Bool = false, place: Place = .row,
        messageActions: TranscriptStore.MessageActions? = nil, actions: TranscriptActions
    ) {
        self.entry = entry
        self.open = open
        self.expanded = expanded
        self.place = place
        self.messageActions = messageActions
        self.actions = actions
        _lines = StateObject(wrappedValue: Local(Self.estimatedLines(entry.text)))
    }

    /// The `toggle` key for showing a long message whole.
    static func expandKey(_ entry: TranscriptStore.Entry) -> String { entry.id.uuidString + "/all" }

    /// Lines before measuring: its line breaks, or its length over a typical line's characters.
    private static func estimatedLines(_ text: String) -> Int {
        max(text.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }, text.utf8.count / Layout.Timeline.charsPerLine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.kind == .peer {
                peer
            } else {
                user
            }
            if place == .row, let messageActions {
                MessageActionsRow(
                    text: entry.text, shown: messageActions.always || hovered.value, canFork: messageActions.canFork,
                    story: entry.kind == .peer ? StoryID.Transcript.peer(entry.id) : StoryID.Transcript.user(entry.id)
                ) { actions.fork(entry) }
            }
        }
        .padding(.vertical, Layout.Timeline.itemPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StickyBackground(on: place == .sticky))
        .contentShape(Rectangle())
        .onHover { if place == .row { hovered.value = $0 } }
        .onTapGesture {
            if entry.kind == .peer && place == .row {
                actions.toggle(entry.id.uuidString)
            } else {
                actions.reveal(entry.id.uuidString)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
            guard place == .row else { return }
            top.value = frame.minY
            actions.messageMoved(entry.id.uuidString, frame)
        }
        .onDisappear { if place == .row { actions.messageMoved(entry.id.uuidString, nil) } }
    }

    /// Long enough to clip: from `collapseFrom` lines up, so a clip always hides a few.
    private var collapsible: Bool { lines.value >= Layout.Timeline.collapseFrom }

    /// The lines shown: three when pinned, `collapsedLines` when clipped, else all.
    private var shown: Int? {
        if place == .sticky { return Layout.Timeline.stickyLines }
        return collapsible && !expanded ? Layout.Timeline.collapsedLines : nil
    }

    private var text: some View {
        MessageText(
            text: entry.text, lines: shown,
            fade: place == .sticky ? MessageText.lineHeight : Size.collapseFade * Zoom.shared.scale,
            // A user's message sits in its filled box; a peer's in an outline on the ground.
            ground: entry.kind == .peer ? Theme.background : PanelStyle.userBox.fill ?? Theme.surface
        ) { lines.value = $0 }
    }

    /// Under the text, inside the box: "Show full message" / "Show less".
    @ViewBuilder private var toggle: some View {
        if collapsible && place == .row {
            HStack {
                Spacer(minLength: 0)
                MessageToggle(expanded: expanded) {
                    let above = top.value < 0
                    actions.toggle(Self.expandKey(entry))
                    // Closing a long message from below: bring its top back into view.
                    if expanded && above { actions.reveal(entry.id.uuidString) }
                }
            }
            .padding(.top, Space.messageToggle)
        }
    }

    private var user: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !entry.attachments.isEmpty && place == .row {
                HStack(spacing: Space.md) {
                    ForEach(entry.attachments) { attachment in
                        AttachmentChip(attachment: attachment, open: { actions.openImage(attachment) })
                    }
                }
            }
            if !entry.text.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    text
                    toggle
                }
                .padding(Inset.userBox)
                .panel(.userBox)
            }
        }
    }

    /// "From Kore-fe  The first line of it… ›"; opened, the whole message.
    private var peer: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Label("From \(entry.from ?? "another session")", systemImage: "bubble.left")
                    .font(TextStyle.labelMedium)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                if !open {
                    Text(Self.firstLine(entry.text))
                        .font(TextStyle.body)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Space.sm)
                Disclosure(isOpen: open).foregroundStyle(Theme.tertiary)
            }
            if open {
                text
                toggle
            }
        }
        .padding(open ? Inset.bubble : Inset.control)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(.outline)
        .help(open ? "" : "Show all")
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// A pinned message is solid behind, then fades just below (an overlay, so it doesn't change
/// the size the lazy stack places it by).
private struct StickyBackground: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content
                .background(Theme.background)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [Theme.background, Theme.background.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Layout.Timeline.stickyFade)
                        .offset(y: Layout.Timeline.stickyFade)
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

/// The section's pinned header: no height of its own, so its message row scrolls normally; once
/// that row has gone fully above the top (its bottom too), the message's first three lines hang
/// from here. While any of the row shows, the row itself names the turn (look.md §15).
struct StickyMessage: View, Equatable {
    let entry: TranscriptStore.Entry
    var open: Bool
    let actions: TranscriptActions
    @ObservedObject var tracker: StickyTracker

    /// By content, like the rows: the actions are one shared value, and the tracker redraws it
    /// when a message crosses.
    nonisolated static func == (a: Self, b: Self) -> Bool { a.entry == b.entry && a.open == b.open }

    var body: some View {
        Color.clear
            .frame(height: Size.stickyAnchor)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { y in
                tracker.header(entry.id.uuidString, y)
            }
            .overlay(alignment: .top) {
                if tracker.stuck.contains(entry.id.uuidString) {
                    MessageHeader(entry: entry, open: open, place: .sticky, actions: actions)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
    }
}

/// Which sections' messages have scrolled fully above their pinned header. Headers report their
/// tops and rows their bottoms as they move; `stuck` changes only when one crosses.
@MainActor
final class StickyTracker: ObservableObject {
    @Published private(set) var stuck: Set<String> = []
    private var headers: [String: CGFloat] = [:]
    private var rows: [String: CGFloat] = [:]

    func header(_ id: String, _ y: CGFloat) {
        headers[id] = y
        update(id)
    }

    func row(_ id: String, _ y: CGFloat) {
        rows[id] = y
        update(id)
    }

    private func update(_ id: String) {
        guard let header = headers[id] else { return }
        // A header on screen whose row never laid out: the row is above (the chat opened below it).
        let past = rows[id].map { $0 < header - 0.5 } ?? true
        if past != stuck.contains(id) {
            if past { stuck.insert(id) } else { stuck.remove(id) }
        }
    }
}

/// "Show full message" / "Show less": label text in secondary, filled on hover (look.md §15).
struct MessageToggle: View {
    let expanded: Bool
    /// What opens it: "Show full message", "Show full summary".
    var title = "Show full message"
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            Text(expanded ? "Show less" : title)
                .font(TextStyle.label)
                .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                .padding(Inset.messageToggle)
                .background(
                    hovered.value ? Theme.surfaceHover : Color.clear, in: RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }
}

/// A message's text, whole or stopped at `lines` laid-out lines, its last part fading into the
/// box's fill (an overlay, not a mask: a mask costs an offscreen pass). Stopped, it lays out
/// only the text's start, enough to fill the lines and to tell a long message from a short one;
/// selection then takes what shows. Reports how many lines it lays out to at this width.
struct MessageText: View {
    let text: String
    let lines: Int?
    let fade: CGFloat
    /// What's behind the text: the fade ends in it.
    let ground: Color
    var color = Theme.text
    let measured: (Int) -> Void

    /// The body font's line height, worked out once per zoom.
    static var lineHeight: CGFloat {
        let zoom = Zoom.shared.scale
        if let height = lineHeights[zoom] { return height }
        let height = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 13 * zoom))
        lineHeights[zoom] = height
        return height
    }

    private static var lineHeights: [CGFloat: CGFloat] = [:]

    /// A stopped message lays out this much: past `collapseFrom` lines whatever the width (a
    /// laid-out line holds at most about twice `charsPerLine`).
    private static let prefixLines = Layout.Timeline.collapseFrom + 1
    private static let prefixBytes = prefixLines * Layout.Timeline.charsPerLine * 2

    var body: some View {
        let line = Self.lineHeight
        let height = lines.map { CGFloat($0) * line }
        let shown = lines == nil ? text : TextPrefix.of(text, lines: Self.prefixLines, bytes: Self.prefixBytes).text
        Text(shown)
            .font(TextStyle.body)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: Int.self) { Int(($0.size.height / line).rounded()) } action: { measured($0) }
            .frame(height: height, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                if let height, height > 0 {
                    LinearGradient(colors: [ground.opacity(0), ground], startPoint: .top, endPoint: .bottom)
                        .frame(height: min(fade, height))
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: Message actions

/// A turn's final answer with its Copy / Fork row under it (look §11). The hover is its own,
/// so the pointer crossing an answer redraws this, not the answer's text.
private struct AnswerWithActions: View {
    let entry: TranscriptStore.Entry
    let messageActions: TranscriptStore.MessageActions
    let actions: TranscriptActions
    @StateObject private var hovered = Local(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowContent(row: .entry(entry), actions: actions)
            MessageActionsRow(
                text: entry.text, shown: messageActions.always || hovered.value, canFork: messageActions.canFork,
                story: StoryID.Transcript.answer(entry.id)
            ) {
                actions.forkAfter(entry)
            }
        }
        .onHover { if hovered.value != $0 { hovered.value = $0 } }
    }
}

/// Copy and Fork under a message (look §11): a reserved 22pt row, so showing it never moves
/// anything. Hidden but kept in place until the message is under the pointer (always shown
/// under the chat's last answer). Nothing here measures or animates while it's hidden.
struct MessageActionsRow: View {
    let text: String
    let shown: Bool
    let canFork: Bool
    /// The message's or answer's storyline name; Copy and Fork are its `.copy` and `.fork`.
    let story: StoryID
    let fork: () -> Void
    @StateObject private var copied = Local(false)

    var body: some View {
        HStack(spacing: Size.MessageActions.gap) {
            if shown {
                IconButton(symbol: copied.value ? "checkmark" : "doc.on.doc", kind: .mini, font: Chrome.label, help: "Copy", action: copy)
                    .storyID(story.part(.copy))
                IconButton(symbol: "arrow.triangle.branch", kind: .mini, font: Chrome.label, help: "Fork", action: fork)
                    .disabled(!canFork)
                    .storyID(story.part(.fork))
            }
        }
        .frame(height: Size.MessageActions.row, alignment: .leading)
        .padding(.top, Size.MessageActions.top)
        // Hidden until hover: pressed through their actions meanwhile.
        .storyAction(story.part(.copy)) { copy() }
        .storyAction(story.part(.fork)) { if canFork { fork() } }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied.value = true
        Task {
            try? await Task.sleep(for: .seconds(Motion.copied))
            copied.value = false
        }
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
        // Not trimmed here: that copies the whole output on every body. The box trims what it shows.
        if let result = entry.result, isCommand || entry.isError, TextPrefix.hasContent(result) {
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
            // A file link opens through the default action (NSWorkspace), in the user's editor.
            Text(line)
                .lineLimit(2)
                .tint(Theme.secondary)
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
    @StateObject private var showEarlier = Local(false)

    /// Items shown before "N earlier".
    private static let recent = 8

    var body: some View {
        if let info = entry.agent {
            VStack(alignment: .leading, spacing: 0) {
                AgentHeader(entry: entry, info: info, open: open, actions: actions)
                if open {
                    nested(info)
                } else if info.status == .running, let last = lane.last {
                    NestedTimeline(rows: [last], actions: actions, rail: rail(info))
                }
            }
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
        let laneEntries = lane.compactMap { row -> TranscriptStore.Entry? in
            if case .entry(let e) = row { return e }
            return nil
        }
        guard let result = TranscriptStore.distinctResult(info, lane: laneEntries) else { return nil }
        return AnyView(AgentResult(text: result, finished: info.status == .finished))
    }
}

/// An agent card's top line. Its hover state is its own, so the pointer crossing it redraws
/// this line, not the card's nested timeline.
private struct AgentHeader: View {
    let entry: TranscriptStore.Entry
    let info: TranscriptStore.AgentInfo
    let open: Bool
    let actions: TranscriptActions
    @StateObject private var hovered = Local(false)

    var body: some View {
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
                        name: info.name, nameColor: AgentAvatar.hue(info.index), text: subtitle,
                        status: statusSuffix)
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
                        .help("Open in tab (⌘-click)")
                        .storyID(StoryID.Transcript.agent(info.id).part(.open))
                    }
                    AgentMeter(info: info)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered.value = $0 }
            .accessibilityHint(Text(open ? "Hides the agent's work" : "Shows the agent's work"))
            // "Open in tab" is built only on hover: pressed through its action meanwhile.
            .storyAction(StoryID.Transcript.agent(info.id).part(.open)) { actions.openAgent(info.id) }
            if info.status == .running {
                IconButton(symbol: "stop.fill", kind: .small, font: Glyph.stop, help: "Stop agent") {
                    actions.stopAgent(info.id)
                }
                .storyID(StoryID.Transcript.agent(info.id).part(.stop))
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
    private var subtitle: String {
        let model = info.status == .running && info.waiting == 0 ? info.model : nil
        return [info.type, model].compactMap { $0 }.joined(separator: " · ")
    }

    /// "waiting" in secondary, "failed" in red, "finished" / "stopped" in secondary.
    private var statusSuffix: (text: String, color: Color)? {
        switch info.status {
        case .running: info.waiting > 0 ? ("waiting", Theme.secondary) : nil
        case .finished: ("finished", Theme.secondary)
        case .failed: ("failed", Theme.danger)
        case .stopped: ("stopped", Theme.secondary)
        }
    }
}

/// An agent's answer under its work: four lines until "Show all", parsed once.
private struct AgentResult: View {
    let text: String
    let finished: Bool
    @StateObject private var showAll = Local(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(planMarkdown(text))
                .font(TextStyle.body)
                .foregroundStyle(finished ? Theme.text : Theme.secondary)
                .lineSpacing(TextStyle.leading)
                .lineLimit(showAll.value ? nil : 4)
                .textSelection(.enabled)
            if !showAll.value, Self.long(text) {
                TextButton("Show all") { showAll.value = true }
            }
        }
    }

    /// Over 280 characters or four lines; read only as far as needed.
    private static func long(_ text: String) -> Bool {
        let prefix = TextPrefix.of(text, lines: 5, bytes: 1200)
        return prefix.lines > 4 || prefix.text.count > 280
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
