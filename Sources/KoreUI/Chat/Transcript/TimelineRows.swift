import KoreCore
import SwiftUI

/// What the transcript's rows can do. One value shared by every row, so rows compare by content.
struct TranscriptActions {
    var toggleTurn: (String) -> Void = { _ in }
    /// A stalled turn's Retry and Stop (its spinner row's buttons).
    var retry: () -> Void = {}
    var retryTurn: (String) -> Void = { _ in }
    var stop: () -> Void = {}
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
    /// An auth failure's Sign in: Account opens in the chat and the sign-in starts.
    var signIn: () -> Void = {}
    /// The × after "Continues at …": the chat won't continue at its limit's reset.
    var cancelContinue: () -> Void = {}
    /// A slept turn's Continue: sends "Continue".
    var continueTurn: () -> Void = {}
    /// A message row moved (its frame in the scroll view: the bottom for its pinned copy, the
    /// top for keeping the reader's place), or left the built rows (nil).
    var messageMoved: (String, CGRect?) -> Void = { _, _ in }
    /// A long message row opened (true) or closed: the end isn't followed while it's open.
    var messageOpened: (Bool) -> Void = { _ in }
    /// An answer row's top moved, or it left the built rows (nil): a long answer marks the
    /// reader's place where no message is near.
    var answerMoved: (String, CGFloat?) -> Void = { _, _ in }
    /// Opens a link clicked in the transcript: a file in a Kore tab (`Workspace.openLink`).
    var openLink: ((URL) -> Void)?
    var folder: URL?
    /// The chat's CLI, for its notices' words.
    var provider: ProviderDescriptor?
}

/// The failed-turn notice of a refused login, in Kore's words ("Your Claude Code sign-in
/// expired.", or "Claude Code isn't signed in." when the status says so) with the CLI's own
/// line on hover, then one Sign in. It keeps no state of its own.
private struct SignInNotice: View {
    let turn: String
    let said: String
    let provider: ProviderDescriptor?
    let signIn: () -> Void

    var body: some View {
        let product = provider?.usage.product ?? "The CLI"
        let signedOut = provider.map { AccountStore.shared.status($0.id) == .signedOut } ?? false
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(AccountText.expired(product, signedOut: signedOut))
                .font(TextStyle.body)
                .foregroundStyle(Theme.danger)
                .help(said)
                .selectableOnHover()
            Button("Sign in", action: signIn)
                .smallButton(prominent: true)
                .storyID(StoryID.Transcript.signIn(turn).part(.signIn))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A failed turn's notice in the CLI's words. When the turn ended on its plan's limit and Stay
/// awake continues it, one quiet part follows on the same line, or under it when the row is
/// narrow: "Continues at 3:00 PM" and its ×, or, for a message set to go then, "“…” · sends at
/// 3:00 PM" and its ×.
private struct OutcomeLine: View {
    let turn: String
    let text: String
    let continues: Date?
    var sends: String?
    let cancel: () -> Void
    var retry: (() -> Void)?

    var body: some View {
        if let continues {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    notice.fixedSize()
                    quiet(continues)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    notice
                    quiet(continues)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .storyID(StoryID.Transcript.continues(turn))
        } else {
            notice.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notice: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(text)
                .font(TextStyle.body)
                .foregroundStyle(text == "Interrupted" ? Theme.secondary : Theme.danger)
                .selectableOnHover()
            if let retry {
                Button("Retry", action: retry)
                    .smallButton(prominent: true)
                    .storyID(StoryID.Transcript.retry(turn))
                    .help("Continue")
            }
        }
    }

    private func quiet(_ at: Date) -> some View {
        HStack(alignment: .center, spacing: Space.xxs) {
            if let sends {
                Text("\u{201C}\(sends.split(whereSeparator: \.isNewline).first.map(String.init) ?? sends)\u{201D}")
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Size.sendsQuote, alignment: .leading)
                    .help(sends)
                Text("· " + ContinueText.sends(at, now: Date()))
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            } else {
                Text(ContinueText.line(at, now: Date()))
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .help("Continue at reset")
            }
            IconButton(symbol: "xmark", kind: .mini, font: TextStyle.caption, help: sends == nil ? "Don't continue" : "Don't send it, back to the draft", action: cancel)
                .storyID(StoryID.Transcript.continues(turn).part(.cancel))
        }
        .fixedSize()
    }
}

/// The words of a continuation.
enum ContinueText {
    /// "Continues at 3:00 PM" today, else "Continues Thu 9:00 AM".
    static func line(_ at: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = StayAwake.time(at, now: now, calendar: calendar, locale: locale)
        return calendar.isDate(at, inSameDayAs: now) ? "Continues at \(time)" : "Continues \(time)"
    }

    /// "sends at 3:00 PM" today, else "sends Thu 9:00 AM".
    static func sends(_ at: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = StayAwake.time(at, now: now, calendar: calendar, locale: locale)
        return calendar.isDate(at, inSameDayAs: now) ? "sends at \(time)" : "sends \(time)"
    }
}

/// A turn that failed while the Mac slept, in Kore's words with the CLI's own line on hover,
/// then one Continue: the Sign in notice's pattern. Not a failure: it's in secondary, as
/// "Interrupted" is.
private struct SleptNotice: View {
    let turn: String
    let said: String
    let resume: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text("Stopped while the Mac slept")
                .font(TextStyle.body)
                .foregroundStyle(Theme.secondary)
                .help(said)
                .selectableOnHover()
            Button("Continue", action: resume)
                .smallButton(prominent: true)
                .storyID(StoryID.Transcript.slept(turn).part(.continue))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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

    private var row: some View {
        content.storyID(Self.story(item.row), press: press).modifier(RowSelection(entry: Self.selectable(item.row)))
    }

    /// The entry whose texts this row shows for the transcript's selection; nil for rows with
    /// none (folds, rules, agent cards, the spinner). A tool or thinking row takes part only
    /// while open (its texts say so), so opening one doesn't rebuild it.
    static func selectable(_ row: TranscriptStore.Row) -> UUID? {
        switch row {
        case .message(let e, _, _), .summary(let e, _), .tool(let e, _), .thinking(let e, _): e.id
        case .entry(let e): [.answer, .plan, .notice, .user, .peer].contains(e.kind) ? e.id : nil
        default: nil
        }
    }

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
        case .signIn(let turn, _):
            return StoryID.Transcript.signIn(turn)
        case .slept(let turn, _):
            return StoryID.Transcript.slept(turn)
        case .thinking, .rule, .outcome, .summary, .queued, .spinner:
            return nil
        }
    }

    @ViewBuilder private var content: some View {
        if case .entry(let entry) = item.row, entry.kind == .divider {
            DividerRow(text: entry.text, open: entry.source == TranscriptStore.forkSource ? actions.openOriginal : nil, help: entry.result)
        } else if case .entry(let entry) = item.row, entry.kind == .mode, entry.modeLead == nil, let mode = entry.mode {
            ModeDivider(mode: mode)
        } else if case .message(let entry, let open, let expanded) = item.row {
            MessageHeader(entry: entry, open: open, expanded: expanded, messageActions: item.actions, actions: actions)
        } else if case .summary(let entry, let expanded) = item.row {
            CompactionSummary(entry: entry, expanded: expanded, actions: actions)
        } else if case .spinner(_, let since, let claude, let word, let connection) = item.row {
            // Not a timeline item: no dot, and the line doesn't run into it.
            SpinnerRow(since: since, claude: claude, word: word, connection: connection, retry: actions.retry, stop: actions.stop)
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

/// Applies `selectionRow` for a row with selectable texts.
private struct RowSelection: ViewModifier {
    let entry: UUID?

    func body(content: Content) -> some View {
        if let entry { content.selectionRow(entry) } else { content }
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
        case .spinner(_, let since, let claude, let word, let connection):
            SpinnerRow(since: since, claude: claude, word: word, connection: connection, retry: actions.retry, stop: actions.stop)
        case .summary(let entry, let expanded):
            CompactionSummary(entry: entry, expanded: expanded, actions: actions)
        case .queued(let entry):
            QueuedMessage(entry: entry, actions: actions)
        case .message(let entry, let open, let expanded):
            MessageHeader(entry: entry, open: open, expanded: expanded, actions: actions)
        case .rule:
            Rule()
        case .outcome(let turn, let text, let continues, let sends, let retry):
            OutcomeLine(turn: turn, text: text, continues: continues, sends: sends, cancel: actions.cancelContinue,
                        retry: retry ? { actions.retryTurn(turn) } : nil)
        case .signIn(let turn, let said):
            SignInNotice(turn: turn, said: said, provider: actions.provider, signIn: actions.signIn)
        case .slept(let turn, let said):
            SleptNotice(turn: turn, said: said, resume: actions.continueTurn)
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
                .selectableText([0], entry.text, .body)
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
/// `collapsedLines` laid-out lines with its text fading out; a click on it or "Show full message"
/// opens it a little (`OpenedMessageText`). While its turn scrolls by, `StickyMessage` keeps its
/// first lines pinned at the top; a click there opens a long one the same way, and scrolls back
/// to a short one.
struct MessageHeader: View {
    enum Place { case row, sticky }

    let entry: TranscriptStore.Entry
    /// A peer's message is one line until opened.
    var open = true
    /// A long message opened (`OpenedMessageText`); a pinned copy keeps its own.
    var expanded = false
    var place = Place.row
    /// Its Copy / Fork row (look §11); nil for none (a pinned copy, a queued message).
    var messageActions: TranscriptStore.MessageActions?
    let actions: TranscriptActions
    /// The text's laid-out lines at the current width. It starts from an estimate, so a long
    /// message is collapsed from its first layout: laid out whole first, it would shrink by many
    /// screens and leave the view scrolled past the end.
    @StateObject private var lines: Local<Int>
    /// Under the pointer: its action button shows.
    @StateObject private var hovered = Local(false)
    /// The pinned copy opened.
    @StateObject private var pinnedOpen = Local(false)
    /// The box while it's open, global: a press outside it closes it.
    @StateObject private var box = Held(CGRect.zero)
    @Environment(\.transcriptSelection) private var selection

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

    /// The `toggle` key for opening a long message.
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
        .onTapGesture(perform: tapped)
        // The row's name is its row's (`TimelineRow`); the pinned copy names itself.
        .storyID(place == .sticky ? story : nil, press: tapped)
        .messageActions(text: place == .row && messageActions != nil ? entry.text : nil, canFork: messageActions?.canFork == true) {
            actions.fork(entry)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
            guard place == .row else { return }
            actions.messageMoved(entry.id.uuidString, frame)
        }
        .onDisappear { if place == .row { actions.messageMoved(entry.id.uuidString, nil) } }
    }

    /// A click on it: a peer's row opens or closes, a long message opens a little or closes, and
    /// a short pinned one scrolls back to its row.
    private func tapped() {
        if entry.kind == .peer && place == .row {
            actions.toggle(entry.id.uuidString)
        } else if openable {
            open(!opened)
        } else {
            actions.reveal(entry.id.uuidString)
        }
    }

    /// Long enough to clip: from `collapseFrom` lines up, so a clip always hides a few.
    private var collapsible: Bool { lines.value >= Layout.Timeline.collapseFrom }

    /// More than it shows: a clipped row, or a pinned copy past its three lines.
    private var openable: Bool { place == .sticky ? lines.value > Layout.Timeline.stickyLines : collapsible }

    private var opened: Bool { openable && (place == .sticky ? pinnedOpen.value : expanded) }

    /// The row's in the store (it's still open when built again); the pinned copy's its own.
    private func open(_ on: Bool) {
        guard on != opened else { return }
        if on { OpenedMessageText.opening = openKey }
        if place == .sticky {
            pinnedOpen.value = on
        } else {
            actions.messageOpened(on)
            actions.toggle(Self.expandKey(entry))
        }
    }

    private var openKey: String { Self.expandKey(entry) + (place == .sticky ? "/pinned" : "") }

    private var story: StoryID {
        place == .sticky ? StoryID.Transcript.pinned(entry.id) : entry.kind == .peer ? StoryID.Transcript.peer(entry.id) : StoryID.Transcript.user(entry.id)
    }

    /// The lines shown: three when pinned, `collapsedLines` when clipped, else all.
    private var shown: Int? {
        if place == .sticky { return Layout.Timeline.stickyLines }
        return collapsible ? Layout.Timeline.collapsedLines : nil
    }

    @ViewBuilder private var text: some View {
        if opened {
            OpenedMessageText(text: entry.text, key: openKey, box: box) { open(false) }
                .storyID(story.part(.open))
                // Its texts are the text view's now: the clipped one's place is no text's.
                .onAppear { if place == .row { selection?.textGone(entry.id, [0]) } }
        } else {
            MessageText(
                text: entry.text, lines: shown,
                fade: place == .sticky ? MessageText.lineHeight : Size.collapseFade * Zoom.shared.scale,
                // A user's message sits in its filled box; a peer's in an outline on the ground.
                ground: entry.kind == .peer ? Theme.background : PanelStyle.userBox.fill ?? Theme.surface,
                // Pinned, a click is the copy's (it opens), not a selection's.
                selectable: place == .row, click: openable ? { open(true) } : nil
            ) { lines.value = $0 }
        }
    }

    /// Under the text, inside the box: "Show full message" / "Show less".
    @ViewBuilder private var toggle: some View {
        if collapsible && place == .row {
            HStack {
                Spacer(minLength: 0)
                MessageToggle(expanded: opened) { open(!opened) }
                    .storyID(story.part(.toggle))
            }
            .padding(.top, Space.messageToggle)
        }
    }

    /// A chip's file in a Kore tab; a picture known only from history, in the image viewer.
    static func openInKore(_ attachment: Attachment, _ actions: TranscriptActions) -> (() -> Void)? {
        if let url = attachment.url, let openLink = actions.openLink { return { openLink(url) } }
        return attachment.kind == .image && attachment.thumbnail != nil ? { actions.openImage(attachment) } : nil
    }

    private var user: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !entry.attachments.isEmpty && place == .row {
                HStack(spacing: Space.md) {
                    ForEach(entry.attachments) { attachment in
                        AttachmentChip(attachment: attachment, open: { actions.openImage(attachment) })
                            .koreContextMenu("attachment") { MediaMenu.items(.init(attachment), openInKore: Self.openInKore(attachment, actions)) }
                            .storyID(StoryID.Transcript.attachment(attachment.name))
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
                .modifier(OpenBox(on: opened, box: box))
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
        .modifier(OpenBox(on: opened, box: box))
        .help(open ? "" : "Show all")
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// An opened message's box notes where it is (global), for `OpenedMessageText`'s outside
/// presses; a closed one reports nothing, so scrolling costs no more per message.
private struct OpenBox: ViewModifier {
    let on: Bool
    let box: Held<CGRect>

    func body(content: Content) -> some View {
        if on {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.value = $0 }
        } else {
            content
        }
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
    @Environment(\.transcriptSelection) private var selection

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
                    let (id, selection) = (entry.id.uuidString, selection)
                    MessageHeader(entry: entry, open: open, place: .sticky, actions: actions)
                        .fixedSize(horizontal: false, vertical: true)
                        // Pinned over the rows: a press on it isn't a selection of what's under it.
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TranscriptSelection.space)) } action: {
                            selection?.blocker(id, $0)
                        }
                        .onDisappear { selection?.blocker(id, nil) }
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

    /// A row's bottom; nil once it's gone from the list. A jump (a long output arriving, a
    /// fling) can take it off screen with no frame reported past its header: gone, it's above.
    func row(_ id: String, _ y: CGFloat?) {
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
                .hitTarget(Size.messageToggleReach)
        }
        .buttonStyle(.plain)
        .hitTargetRoom(Size.messageToggleReach)
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
    /// Takes part in the transcript's selection (a pinned copy's click opens it instead).
    var selectable = true
    /// What a plain click on a stopped text does.
    var click: (() -> Void)?
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
        let base = Text(shown).font(TextStyle.body).foregroundStyle(color)
        Group {
            // Selectable as far as it shows: the toggle under a stopped text is the toggle's.
            if selectable { base.selectableText([0], shown, .body, shown: height, click: click) } else { base }
        }
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
        .messageActions(text: entry.text, canFork: messageActions.canFork) { actions.forkAfter(entry) }
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
        Self.copy(text)
        copied.value = true
        Task {
            try? await Task.sleep(for: .seconds(Motion.copied))
            copied.value = false
        }
    }
}

extension MessageActionsRow {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension View {
    /// Copy and Fork as the message's accessibility actions: shown under it only on hover, they
    /// reach VoiceOver and Full Keyboard Access from the message itself. Nil text: none.
    func messageActions(text: String?, canFork: Bool, fork: @escaping () -> Void) -> some View {
        accessibilityActions {
            if let text {
                Button("Copy") { MessageActionsRow.copy(text) }
                if canFork { Button("Fork", action: fork) }
            }
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
            ToolHeader(name: entry.toolName ?? "Tool", path: entry.path, text: secondary, folder: actions.folder,
                       selectionPath: Self.isShell(entry) ? [-1] : nil)
            if !parts.isEmpty {
                ToolBody(parts: parts, open: open) { actions.toggle(entry.id.uuidString) }
            }
        }
    }

    private var secondary: String {
        if entry.path != nil { return entry.summary ?? "" }
        return entry.summary ?? entry.text
    }

    /// The visible header, independent of whether its IN/OUT box is expanded.
    static func headerText(_ entry: TranscriptStore.Entry) -> String {
        let name = entry.toolName ?? "Tool"
        let text = entry.summary ?? entry.text
        let rest = entry.path.map { ($0 as NSString).lastPathComponent + (text.isEmpty ? "" : " " + text) } ?? text
        return name + (rest.isEmpty ? "" : " " + rest)
    }

    /// Tools whose header says it all; they get a box only for an error.
    private static let quiet: Set<String> = ["Read", "Glob", "LS", "NotebookRead", "TodoWrite"]

    private var parts: [ToolBody.Part] { Self.parts(entry) }

    /// A shell command: its IN copies as a `bash` block.
    static func isShell(_ entry: TranscriptStore.Entry) -> Bool { ["Bash", "Run", "BashOutput"].contains(entry.toolName ?? "") }

    /// The rows of its IN / OUT box (the selection's paths [0] and [1]).
    static func parts(_ entry: TranscriptStore.Entry) -> [ToolBody.Part] {
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
    /// File-change paths keep the same semantic hue as their operation.
    var textColor = Theme.secondary
    var path: String?
    var text: String
    var folder: URL?
    var added = 0
    var removed = 0
    /// " · failed" after the secondary text, in its own colour.
    var status: (text: String, color: Color)?
    var selectionPath: [Int]?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            // A file link opens in a Kore tab, through the transcript's openURL.
            if let selectionPath {
                Text(line).lineLimit(2).tint(textColor).help(path ?? "")
                    .selectableText(selectionPath, selectionLine, .toolHeader)
            } else {
                Text(line).lineLimit(2).tint(textColor).help(path ?? "")
            }
            if added > 0 || removed > 0 { ChangeCounts(added: added, removed: removed) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(FileMenu(url: path.map { OpenInEditor.url($0, in: folder) }))
    }

    private var selectionLine: AttributedString {
        var selected = line
        for run in selected.runs {
            selected[run.range].inlinePresentationIntent = run.font == TextStyle.codeSmall ? .code : .stronglyEmphasized
        }
        return selected
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
            rest.foregroundColor = textColor
            rest += suffix
        }
        rest.font = TextStyle.codeSmall
        if status == nil { rest.foregroundColor = textColor }
        guard !rest.characters.isEmpty else { return name }
        var gap = AttributedString(" ")
        gap.font = TextStyle.codeSmall
        return name + gap + rest
    }
}

/// A tool's file: right-click for its menu (`MediaMenu`), when the file is there. Resolved at
/// the click, so a row costs no file check while it draws.
private struct FileMenu: ViewModifier {
    let url: URL?
    @Environment(\.transcriptSelection) private var selection

    func body(content: Content) -> some View {
        if let url {
            content.koreContextMenu("file") { selection?.fileMenu(url) ?? [] }
        } else {
            content
        }
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
                    .selectableText([0], entry.text, .running)
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
                    name: Self.verb(change, tool: entry.toolName), nameColor: Theme.Git.color(change.kind),
                    textColor: Theme.Git.color(change.kind), path: change.path, text: Self.move(change),
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
                        name: Self.verb(change, tool: nil), nameColor: Theme.Git.color(change.kind), nameFont: TextStyle.labelStrong,
                        textColor: Theme.Git.color(change.kind), path: change.path,
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
                    text: info.background ? "Commands appear when this agent finishes" : "No commands")
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
    /// Full Keyboard Access is on the card's line: "Open in tab" shows as on hover.
    @FocusState private var focused: Bool

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
                    if hovered.value || focused {
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
            .focused($focused)
            .onHover { hovered.value = $0 }
            .accessibilityHint(Text(open ? "Hides the agent's work" : "Shows the agent's work"))
            .accessibilityAction(named: "Open in tab") { actions.openAgent(info.id) }
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
                .selectableOnHover()
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
    @Environment(\.hiddenTab) private var hidden

    var body: some View {
        if info.status == .running, !hidden {
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
        if let tokens = Self.tokens(of: info) { parts.append(tokens) }
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

    /// Its tokens, "~239k" when read from its transcript rather than reported.
    static func tokens(of info: TranscriptStore.AgentInfo) -> String? {
        info.tokens.map { (info.approximate ? "~" : "") + ContextStore.tokens($0) }
    }
}
