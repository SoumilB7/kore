import AppKit
import KoreCore
import SwiftUI

/// The Usage popup's extended view (usage-monitor.html §10), a card centred over the chat: the
/// plan's limits on top, as in the popup but roomier (a 6pt bar with Kore's hatch, the plan's %,
/// Kore's ~%), which pick the limit shown below; then that limit's distribution: In Kore, every
/// chat that made it, largest first, Outside Kore, and on Claude's week the plan's own split.
/// Esc, Return, the × or a click outside close it; ↑ ↓ (k j) step through the limits; a click
/// on a chat closes it and goes to that chat.
struct UsageModal: View {
    let chat: Chat
    let state: UsageState
    let wording: UsageWording
    @StateObject private var keyMonitor = Local<Any?>(nil)
    @StateObject private var window = Local<NSWindow?>(nil)

    private static let row = Size.usageResetRow

    var body: some View {
        GeometryReader { geometry in
            let width = max(min(Size.usageModalWidth, geometry.size.width - Size.QuickOpen.windowMargin), 0)
            ZStack {
                Color.clear.contentShape(Rectangle()).onTapGesture { state.closeExtended() }
                card(width: width, room: max(geometry.size.height - Size.QuickOpen.windowMargin, 0))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(WindowReader { window.value = $0 })
        .transition(.opacity)
        .onAppear {
            keyMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) }
        }
        .onDisappear {
            if let monitor = keyMonitor.value { NSEvent.removeMonitor(monitor) }
            keyMonitor.value = nil
        }
        .task(id: state.shares?.at) { await nameChats() }
    }

    // MARK: Card

    private func card(width: CGFloat, room: CGFloat) -> some View {
        let reading = state.reading
        let stale: String?? = if case .unavailable(let detail) = state.status { .some(detail) } else { nil }
        let bars = reading?.limits?.bars ?? []
        let limit = state.pickedLimit
        let share = limit.flatMap { state.share($0) }
        let lines = (share?.surfaces.isEmpty == false ? 1 : 0) + (quality(limit, share) == nil ? 0 : 1)
        // What doesn't scroll: the insets, the header, the limits, the rules, In Kore, Outside
        // Kore and the lines under it. The chats get the rest, whole rows and a half.
        var fixed = Inset.card.top + Inset.card.bottom + Size.iconButtonSmall + CGFloat(bars.count) * Self.row
        fixed += Space.md * 2 + Space.xs * 2 + Stroke.hairline * 2 + Self.row * 2 + CGFloat(lines) * (Size.contextCardLine + Space.sm)
        if stale != nil { fixed += Size.contextCardLine * 2 + Space.xs }
        let space = room - fixed
        let chats = share?.chats.count ?? 0
        let list: CGFloat? = CGFloat(chats) * Self.row <= space ? nil : max((space / Self.row - 0.5).rounded(.down), 1) * Self.row + Self.row / 2
        let all = space < Self.row * 1.5
        return VStack(alignment: .leading, spacing: 0) {
            header(reading?.account)
            if let detail = stale {
                Text(wording.failed(detail))
                    .font(TextStyle.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
            }
            Group {
                if all {
                    // Not even a row and a half for the chats: everything under the header scrolls.
                    ScrollView { below(bars, limit, share, width: width, list: nil) }
                        .scrollIndicators(.automatic)
                        .frame(maxHeight: max(room - Inset.card.top - Inset.card.bottom - Size.iconButtonSmall, Self.row))
                } else {
                    below(bars, limit, share, width: width, list: list)
                }
            }
            .opacity(stale == nil ? 1 : Theme.dimmed)
        }
        .padding(Inset.card)
        .frame(width: width, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
        .shadow(color: Elevation.floating.color, radius: Elevation.floating.radius, y: Elevation.floating.y)  // lint:allow the one shadow (Elevation.floating)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(reading?.account.plan ?? "Usage")
        .accessibilityAddTraits(.isModal)
        .storyID(StoryID.UsageModal.card)
    }

    private func below(_ bars: [PlanLimit], _ limit: PlanLimit?, _ share: KoreShare?, width: CGFloat, list: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            limits(bars)
                .padding(.top, Space.sm)
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.md)
            if let limit { ledger(limit, share, width: width, list: list) }
        }
    }

    // MARK: Header

    /// The plan (the account on hover), when the reading was made, ↗ and ×.
    private func header(_ account: PlanAccount?) -> some View {
        HStack(spacing: Space.md) {
            Text(account?.plan ?? " ")
                .font(TextStyle.title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(account.map(UsageText.who) ?? "")
            Spacer(minLength: 0)
            if let readAt = state.readAt {
                Text("as of " + readAt.formatted(date: .omitted, time: .shortened))
                    .font(TextStyle.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: Space.xxs) {
                if let url = account?.manage {
                    IconButton(symbol: "arrow.up.right", kind: .small, font: Glyph.chevron, help: "Manage usage on \(url.host() ?? url.absoluteString)") {
                        NSWorkspace.shared.open(url)
                        state.closeExtended()
                    }
                }
                IconButton(symbol: "xmark", kind: .small, help: "Close (Esc)") { state.closeExtended() }
                    .storyID(StoryID.UsageModal.card.part(.close))
            }
        }
        .frame(height: Size.iconButtonSmall)
    }

    // MARK: Limits

    /// One row per limit, the picked one filled: title, bar, the plan's %, Kore's ~%, ↻ reset.
    /// A row is a button laid under the grid, so the grid's columns stay its titles' width.
    private func limits(_ bars: [PlanLimit]) -> some View {
        let now = Date()
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(bars, id: \.title) { bar in
                    let kore = state.share(bar)?.kore ?? 0
                    let reset = UsageText.resetsShort(bar.resetsAt, now: now)
                    let spoken = [
                        UsageText.label(bar.title), UsageText.percent(bar.used), kore > 0 ? "about \(UsageText.kore(kore).dropFirst()) in Kore" : nil,
                        reset.isEmpty ? nil : UsageText.resets(bar.resetsAt, now: now).lowercased(),
                    ]
                    UsagePickRow(
                        selected: bar.title == state.pickedLimit?.title, help: state.barHelp(bar, now: now),
                        label: spoken.compactMap { $0 }.joined(separator: ", ")
                    ) { state.pick(bar.title) }
                    .storyID(StoryID.UsageModal.limit(bar.title), press: { state.pick(bar.title) })
                }
            }
            // The fill past the text on both sides, as the popup's rows have it.
            .padding(.horizontal, -Space.sm)
            Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: 0) {
                ForEach(bars, id: \.title) { bar in
                    let kore = state.share(bar)?.kore ?? 0
                    let reset = UsageText.resetsShort(bar.resetsAt, now: now)
                    GridRow {
                        CappedWidth(cap: Size.usageTitleMax) {
                            Text(UsageText.label(bar.title))
                                .font(TextStyle.label)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        LimitBar(
                            fraction: UsageText.fraction(bar.used), kore: UsageText.fraction(kore), share: nil, height: Size.usageModalBar
                        )
                        .frame(minWidth: Size.usageBarMin, maxWidth: .infinity)
                        Text(UsageText.percent(bar.used))
                            .font(TextStyle.label.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .frame(width: Size.usageModalColumn, alignment: .trailing)
                        Text(kore > 0 ? UsageText.kore(kore) : "")
                            .font(TextStyle.caption.monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .frame(width: Size.usageModalColumn, alignment: .trailing)
                        HStack(spacing: Space.xxs) {
                            Image(systemName: "arrow.clockwise").font(Glyph.chevron).foregroundStyle(Theme.tertiary)
                            Text(reset).font(TextStyle.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                        .lineLimit(1)
                        .opacity(reset.isEmpty ? 0 : 1)
                        .frame(width: Size.usageModalColumn, alignment: .leading)
                    }
                    .frame(height: Self.row)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Ledger

    /// The picked limit's distribution. While Kore's share is worked out, a spinner; with none,
    /// one line; else In Kore, the chats (scrolling past `list`), Outside Kore and its lines.
    @ViewBuilder private func ledger(_ limit: PlanLimit, _ share: KoreShare?, width: CGFloat, list: CGFloat?) -> some View {
        if let share {
            if share.kore > 0 {
                let bar = width >= Size.usageModalWide ? Size.usageShareBarWide : Size.usageShareBar
                let folders = Set(share.chats.map { $0.folder ?? "" })
                let showFolders = folders.count > 1 && width >= Size.usageModalFolders
                UsageShareRow(title: "In Kore", points: share.kore, used: limit.used, bar: bar, hatched: true)
                let rows = LazyVStack(spacing: 0) {
                    ForEach(share.chats) { chatShare in
                        let current = chatShare.id == chat.sessionId
                        let name = state.chatNames[chatShare.id] ?? chatShare.title ?? UsageText.untitled
                        let go: @MainActor () -> Void = { [state, provider = chat.provider.id] in
                            state.closeExtended()
                            UsageChats.go(to: chatShare, provider: provider, name: name)
                        }
                        UsageChatRow(
                            name: current ? "This chat" : name,
                            folder: showFolders ? chatShare.folder.map { ($0 as NSString).lastPathComponent } : nil, share: chatShare,
                            used: limit.used, bar: bar, current: current, go: go
                        )
                        .storyID(StoryID.UsageModal.chat(chatShare.id), press: current ? nil : go)
                    }
                }
                if let list {
                    ScrollView { rows }.scrollIndicators(.automatic).frame(height: list)
                } else {
                    rows
                }
                Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.xs)
                UsageShareRow(title: "Outside Kore", points: share.outside, used: limit.used, bar: bar, hatched: false)
                    .storyID(StoryID.UsageModal.card.part(.outside))
                if !share.surfaces.isEmpty {
                    let split = share.surfaces
                        .map { "\($0.name) \($0.estimated ? UsageText.kore($0.points) : UsageText.percent($0.points))" }
                        .joined(separator: " · ")
                    note(split).help(split)
                }
                if let quality = quality(limit, share) { note(quality) }
            } else {
                Text(UsageText.nothingFromKore)
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .frame(height: Self.row)
            }
        } else {
            SpinningArc()
                .frame(width: Size.spinner, height: Size.spinner)
                .frame(height: Self.row)
        }
    }

    /// One tertiary line under the ledger.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(TextStyle.caption)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minHeight: Size.contextCardLine)
            .padding(.top, Space.sm)
    }

    /// Says how much to trust the figure, only when it matters: cut down to the plan's, or with
    /// nothing from the plan to check it against (Claude's session and model weeks; Codex with
    /// no readings in its rollouts for the window).
    private func quality(_ limit: PlanLimit?, _ share: KoreShare?) -> String? {
        guard let limit, let share, share.kore > 0 else { return nil }
        if share.clamped { return "~ scaled down to the plan's \(UsageText.percent(limit.used))" }
        let checked = chat.provider.id == "codex" ? share.measured : !share.surfaces.isEmpty
        return checked ? nil : "~ estimated from this Mac's records"
    }

    // MARK: Names

    /// Each chat's name: from an open window's tabs and history, a Codex thread's first prompt,
    /// else (Claude) its transcript's title, read off the main thread.
    private func nameChats() async {
        guard let shares = state.shares else { return }
        var names = state.chatNames
        var missing: [(id: String, folder: String)] = []
        var seen: Set<String> = []
        for share in shares.limits.values {
            for chat in share.chats where seen.insert(chat.id).inserted && names[chat.id] == nil {
                if let name = UsageChats.name(chat.id) {
                    names[chat.id] = name
                } else if chat.title == nil, self.chat.provider.id == "claude", let folder = chat.folder {
                    missing.append((chat.id, folder))
                }
            }
        }
        state.named(names)
        guard !missing.isEmpty else { return }
        let found = await Task.detached(priority: .utility) {
            missing.compactMap { chat in ClaudeHistory.title(sessionId: chat.id, in: URL(fileURLWithPath: chat.folder)).map { (chat.id, $0) } }
        }.value
        for (id, name) in found { names[id] = name }
        state.named(names)
    }

    // MARK: Keys

    /// While open it has this window's keys: Esc and Return close, ↑ ↓ / k j step through the
    /// limits. Other plain keys are swallowed; ⌘ shortcuts pass through.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window else { return event }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) { return event }
        switch event.keyCode {
        case 53, 36, 76: state.closeExtended()
        case 126: state.step(-1)
        case 125: state.step(1)
        default:
            switch event.charactersIgnoringModifiers {
            case "k": state.step(-1)
            case "j": state.step(1)
            default: break
            }
        }
        return nil
    }
}

/// A limit row's button, under its grid row: the row hover under the pointer, selected while picked.
private struct UsagePickRow: View {
    let selected: Bool
    let help: String
    let label: String
    let pick: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: pick) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Size.usageResetRow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(selected || hovered.value, selected ? Theme.Row.selected(.surface) : Theme.Row.hover(.surface))
        .onHover { hovered.value = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// In Kore or Outside Kore: its name, a mini bar (hatched for Kore's, solid for the rest) and its ~%.
private struct UsageShareRow: View {
    let title: String
    let points: Double
    let used: Double
    let bar: CGFloat
    let hatched: Bool

    var body: some View {
        HStack(spacing: Space.lg) {
            HStack(spacing: Space.sm) {
                Text(title).font(TextStyle.label).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: Space.sm)
                UsageMiniBar(points: points, used: used, hatched: hatched).frame(width: bar)
            }
            Text(UsageText.kore(points))
                .font(TextStyle.caption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .frame(width: Size.usageModalColumn, alignment: .trailing)
            Color.clear.frame(width: Size.usageModalColumn)
        }
        .frame(height: Size.usageResetRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), about \(UsageText.kore(points).dropFirst())")
    }
}

/// A part of a limit as long as its share of what's used: the chats' bars and Outside Kore's
/// make up the limit's fill. In the limit's colour.
private struct UsageMiniBar: View {
    let points: Double
    let used: Double
    let hatched: Bool

    var body: some View {
        let fraction = used > 0 ? min(max(points / used, 0), 1) : 0
        UsageBar(fraction: fraction, kore: hatched ? fraction : 0, hatch: hatched ? 1 : 0, tint: UsageText.fraction(used))
    }
}

/// One chat in the ledger: its name (accent on hover, a link), the folder when the chats span
/// several, its mini bar, ~% and agents. A click goes to it; the chat the card is over can't.
private struct UsageChatRow: View {
    let name: String
    let folder: String?
    let share: ChatShare
    let used: Double
    let bar: CGFloat
    let current: Bool
    let go: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        let lit = hovered.value && !current
        Button {
            if !current { go() }
        } label: {
            HStack(spacing: Space.lg) {
                HStack(spacing: Space.sm) {
                    Text(name)
                        .font(TextStyle.label)
                        .foregroundStyle(lit ? Theme.accent : Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if let folder {
                        Text(folder).font(TextStyle.caption).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: Space.sm)
                    UsageMiniBar(points: share.points, used: used, hatched: true).frame(width: bar)
                }
                Text(UsageText.kore(share.points))
                    .font(TextStyle.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .frame(width: Size.usageModalColumn, alignment: .trailing)
                agents.frame(width: Size.usageModalColumn, alignment: .leading)
            }
            .frame(height: Size.usageResetRow)
            .padding(.horizontal, Space.sm)
            .hoverFill(lit, Theme.Row.hover(.surface))
            .padding(.horizontal, -Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [name, "about \(UsageText.kore(share.points).dropFirst())", share.agents > 0 ? "\(share.agents) agents" : nil]
                .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(current ? [] : .isButton)
    }

    /// Two rings and the count, with their part on hover.
    private var agents: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if share.agents > 0 { rings }
        }
    }

    @ViewBuilder private var rings: some View {
        if share.agents > 0 {
            HStack(spacing: Space.xxs) {
                AgentRings().frame(width: Size.usageAgentsGlyph.width, height: Size.usageAgentsGlyph.height)
                Text("\(share.agents)").font(TextStyle.caption.monospacedDigit())
            }
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .help("\(share.agents) \(share.agents == 1 ? "agent" : "agents") · \(UsageText.kore(share.agentPoints))")
        }
    }
}

/// Two rings side by side: a chat's agents.
private struct AgentRings: View {
    var body: some View {
        Canvas { canvas, size in
            let radius = size.height / 2 - Stroke.hairline / 2
            for x in [size.height / 2, size.width - size.height / 2] {
                let ring = Path(ellipseIn: CGRect(x: x - radius, y: size.height / 2 - radius, width: radius * 2, height: radius * 2))
                canvas.stroke(ring, with: .foreground, lineWidth: Stroke.hairline)
            }
        }
    }
}

/// Finding and opening the chats the extended view lists.
@MainActor
enum UsageChats {
    /// A chat's name from an open window: its tab's, else its folder's history.
    static func name(_ id: String) -> String? {
        for workspace in Workspace.all.allObjects {
            if let chat = workspace.tabs.first(where: { $0.agent == nil && $0.chat?.sessionId == id })?.chat { return chat.title }
            if let summary = workspace.chats.first(where: { $0.id == id }) { return summary.title }
        }
        return nil
    }

    /// Its tab in an open window; else opened in its folder's window (opened for it), from the
    /// history.
    static func go(to share: ChatShare, provider: String, name: String) {
        for workspace in Workspace.all.allObjects {
            if let tab = workspace.tabs.first(where: { $0.agent == nil && $0.chat?.sessionId == share.id }) {
                workspace.select(tab)
                workspace.window?.makeKeyAndOrderFront(nil)
                return
            }
        }
        let summary = SessionSummary(id: share.id, agent: provider == "codex" ? .codex : .claude, title: name, updated: Date())
        func open(in workspace: Workspace) {
            workspace.open(workspace.chats.first { $0.id == share.id } ?? summary)
            workspace.window?.makeKeyAndOrderFront(nil)
        }
        guard let folder = share.folder.map({ URL(fileURLWithPath: $0).standardizedFileURL }) else { return }
        let match = { Workspace.all.allObjects.first { $0.folder.standardizedFileURL.path == folder.path } }
        if let workspace = match() {
            open(in: workspace)
            return
        }
        AppModel.shared?.openFolder(folder)
        Task {
            for _ in 0..<40 {
                if let workspace = match() {
                    open(in: workspace)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
