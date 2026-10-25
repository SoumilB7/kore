import SwiftUI

/// Every agent the chat has spawned, over the chat area (phase 10 §6): a graph on the left with
/// the chat as its root O and each agent an O whose wire drops from the bottom of its parent's,
/// and the selected agent on the right with its prompt and its own timeline, live. Grouped by
/// state: every running agent, of both kinds, hangs off the chat, and so does every failed one,
/// red, never folded away; below a hairline, the finished and the stopped wait in two closed
/// groups, Done and Stopped, each naming its split. ↑ ↓ select (a group's
/// row is a stop), Return opens the agent in a tab or toggles the group, ← → fold and unfold, Esc
/// closes. In a narrow tile the graph becomes a menu. An agent running commands in the background
/// says how many in its caption (">_ 2"); a foot line under the tree names those still running
/// after their agents ended, and selecting the chat's own row shows its own.
struct AgentMapView: View {
    let chat: Chat
    let openAgent: (String) -> Void
    /// Kept, never shown: setting them as the map appears doesn't build it again.
    @StateObject private var keyMonitor = Held<Any?>(nil)
    @StateObject private var window = Held<NSWindow?>(nil)

    private var map: AgentMapState { chat.agentMap }

    var body: some View {
        // Reading `agentsVersion` re-renders the map as agents and their work change.
        _ = chat.transcript.agentsVersion
        let rows = layout()
        let selected = rows.selection(map.selected)
        let commands = chat.commands.summary
        let pane = shownPane(rows, commands)
        let highlight = pane == nil ? rows.highlight(selected: selected?.id, cursor: map.foldCursor) : nil
        return GeometryReader { geometry in
            let narrow = geometry.size.width < Size.changesListMinWindow
            ZStack(alignment: .topTrailing) {
                Theme.background
                HStack(spacing: 0) {
                    if !narrow {
                        // Every row counts, its group open or closed: opening one, or an agent
                        // ending, doesn't move the divider.
                        tree(rows, highlight: highlight, commands: commands, pane: pane)
                            .frame(width: paneWidth(rows.all, in: geometry.size.width))
                        Rectangle().fill(Theme.border).frame(width: Stroke.hairline)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        if narrow {
                            treeMenu(rows, selected: selected, commands: commands, pane: pane).padding(Layout.Viewer.closeInset)
                        }
                        switch pane {
                        case .chat?: CommandsPane(chat: chat, pane: .chat)
                        case .outlived?: CommandsPane(chat: chat, pane: .outlived)
                        case nil:
                            if let selected { AgentDetail(chat: chat, info: selected.info, openAgent: openAgent) }
                        }
                    }
                }
                // The tree keeps its place at the left whatever is selected.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                IconButton(symbol: "xmark", help: "Close (Esc)") { map.close() }.storyID(StoryID.AgentMap.close, press: map.close)
                    .padding(Layout.Viewer.closeInset)
            }
        }
        .background(WindowReader { window.value = $0 })
        .transition(.opacity)
        .onAppear {
            map.markSeen(chat.transcript.agentSummary.failed)
            keyMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) }
            reveal()
        }
        .onDisappear {
            if let monitor = keyMonitor.value { NSEvent.removeMonitor(monitor) }
            keyMonitor.value = nil
        }
        .onChange(of: chat.transcript.agentSummary.failed) { _, failed in map.markSeen(failed) }
        .onChange(of: map.reveal) { _, _ in reveal() }
    }

    /// The chat's or the Still running pane in place of an agent's: picked, or the chat's when it
    /// has no agents (the map opened for its commands). Still running gives way once none are.
    private func shownPane(_ rows: AgentMapRows, _ commands: CommandsStore.Summary) -> AgentMapState.Pane? {
        switch map.pane {
        case .outlived? where commands.outlived == 0: rows.all.isEmpty ? .chat : nil
        case let pane?: pane
        case nil: rows.all.isEmpty ? .chat : nil
        }
    }

    private func layout() -> AgentMapRows {
        AgentMapRows(chat.transcript.agentTree(), folded: map.folded, open: map.openEnded)
    }

    /// `map.open(selecting:)`: the group holding the agent opens.
    private func reveal() {
        guard let id = map.reveal else { return }
        map.revealed(in: layout().fold(of: id))
    }

    // MARK: Tree

    private func tree(
        _ rows: AgentMapRows, highlight: AgentMapRows.Stop?, commands: CommandsStore.Summary, pane: AgentMapState.Pane?
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MapHeader(summary: chat.transcript.agentSummary)
                    GraphRootRow(
                        chat: chat, hasChildren: !rows.running.isEmpty, commands: commands.live(.main), selected: pane == .chat
                    ) { map.show(.chat) }
                    agentRows(rows.shownRunning, in: rows.running, highlight: highlight, commands: commands, dimmed: false)
                    if !rows.done.isEmpty || !rows.stopped.isEmpty {
                        Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.top, Layout.AgentMap.groupTop)
                    }
                    group(.done, rows, highlight: highlight, commands: commands)
                    group(.stopped, rows, highlight: highlight, commands: commands)
                }
                .padding(.bottom, Space.xl)
                .padding(.horizontal, Space.sm)
            }
            // The one row commands add, pinned under the tree, only while any outlive their agents.
            if commands.outlived > 0 {
                OutlivedLine(count: commands.outlived, selected: pane == .outlived) { map.show(.outlived) }
                    .padding([.horizontal, .bottom], Space.sm)
            }
        }
    }

    /// A group's closed row, and its agents while it's open.
    @ViewBuilder
    private func group(
        _ fold: AgentMapState.Fold, _ rows: AgentMapRows, highlight: AgentMapRows.Stop?, commands: CommandsStore.Summary
    ) -> some View {
        let nodes = rows.nodes(fold)
        if !nodes.isEmpty {
            ClosedGroupRow(
                fold: fold, nodes: nodes, open: map.openEnded.contains(fold), selected: highlight == .fold(fold)
            ) {
                map.toggle(fold)
                map.foldCursor = nil
            }
            if map.openEnded.contains(fold) {
                agentRows(rows.shown(fold), in: nodes, highlight: highlight, commands: commands, dimmed: true)
            }
        }
    }

    /// One group's rows shown (`shown`, of `all`), without its folded branches' descendants.
    private func agentRows(
        _ shown: [TranscriptStore.AgentNode], in all: [TranscriptStore.AgentNode], highlight: AgentMapRows.Stop?,
        commands: CommandsStore.Summary, dimmed: Bool
    ) -> some View {
        let parents = Set(zip(all, all.dropFirst()).filter { $1.depth > $0.depth }.map(\.0.id))
        return ForEach(shown) { node in
            let hidden = map.folded.contains(node.id) ? AgentMapRows.descendants(of: node.id, in: all) : 0
            AgentGraphRow(
                node: node, selected: highlight == .agent(node.id), waiting: waiting(node.id),
                hasChildren: parents.contains(node.id) && hidden == 0, hidden: hidden, commands: commands.live(.sub(node.id)),
                dimmed: dimmed
            ) {
                map.select(node.id)
            }
        }
    }

    /// Wide enough for the deepest row's label, and never more than its share of the map.
    private func paneWidth(_ nodes: [TranscriptStore.AgentNode], in width: CGFloat) -> CGFloat {
        let depth = CGFloat((nodes.map(\.depth).max() ?? 0) + 1)
        let m = Layout.AgentMap.self
        let needed = m.leading + depth * m.step + m.nodeRadius + m.labelGap + m.labelRoom + Space.sm * 2
        return min(max(needed, m.paneMin), max(m.paneMin, width * m.paneShare))
    }

    /// The chat, the running and the failed agents, then a submenu per group: "Done 20 · 2
    /// foreground · 18 background"; last, while any, the commands still running after their agents.
    private func treeMenu(
        _ rows: AgentMapRows, selected: TranscriptStore.AgentNode?, commands: CommandsStore.Summary, pane: AgentMapState.Pane?
    ) -> some View {
        Menu {
            Button(chat.title + Self.cue(commands.live(.main))) { map.show(.chat) }
            menuItems(rows.running, commands: commands)
            ForEach(AgentMapState.Fold.allCases, id: \.self) { fold in
                let nodes = rows.nodes(fold)
                if !nodes.isEmpty {
                    Menu(AgentMapRows.label(fold, nodes)) { menuItems(nodes, commands: commands) }
                }
            }
            if commands.outlived > 0 {
                Divider()
                Button(OutlivedLine.text(commands.outlived)) { map.show(.outlived) }
            }
        } label: {
            if pane == .chat {
                HStack(spacing: Space.sm) {
                    AgentNodeMark(kind: .root, radius: Size.statusPoint)
                    Text(chat.title).font(TextStyle.labelMedium).foregroundStyle(Theme.text).lineLimit(1)
                }
            } else if pane == .outlived {
                Text("Still running").font(TextStyle.labelMedium).foregroundStyle(Theme.text).lineLimit(1)
            } else if let selected {
                HStack(spacing: Space.sm) {
                    AgentAvatar(index: selected.info.index, name: selected.info.name, status: selected.info.status,
                                background: selected.info.background, place: .crumb)
                    Text(selected.info.name).font(TextStyle.labelMedium).foregroundStyle(Theme.text).lineLimit(1)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// An ended agent says how it ended after its name ("Watch the build — stopped"); one
    /// running commands, how many (" · >_ 2").
    private func menuItems(_ nodes: [TranscriptStore.AgentNode], commands: CommandsStore.Summary) -> some View {
        ForEach(nodes) { node in
            let state = AgentNodeMeter.state(node.info.status).map { " — \($0)" } ?? ""
            Button(String(repeating: "    ", count: node.depth) + node.info.name + state + Self.cue(commands.live(.sub(node.id)))) {
                map.select(node.id)
            }
        }
    }

    /// A menu item's ">_ 2", as the tree's caption mark reads.
    static func cue(_ count: Int) -> String { count > 0 ? "  · >_ \(count)" : "" }

    private func waiting(_ id: String) -> Bool {
        (chat.transcript.agent(id)?.waiting ?? 0) > 0
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard map.isOpen, let window = window.value, event.window === window else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return event }
        let rows = layout()
        let selected = rows.selection(map.selected)?.id
        let highlight = rows.highlight(selected: selected, cursor: map.foldCursor)
        let index = highlight.flatMap { rows.stops.firstIndex(of: $0) }
        func go(_ i: Int) {
            guard rows.stops.indices.contains(i) else { return }
            switch rows.stops[i] {
            case .agent(let id):
                map.select(id)
            case .fold(let fold):
                // The agent stays selected; the group's row takes the highlight.
                if map.selected == nil { map.selected = selected }
                map.foldCursor = fold
            }
        }
        switch event.keyCode {
        case 53: map.close()
        case 36, 76:
            if case .fold(let fold) = highlight {
                map.toggle(fold)
                map.foldCursor = fold
            } else if map.pane != nil {
                // The chat's or Still running pane: no agent to open.
                return event
            } else if let selected {
                openAgent(selected)
            }
        case 126: go(index.map { max($0 - 1, 0) } ?? 0)
        case 125: go(index.map { min($0 + 1, rows.stops.count - 1) } ?? 0)
        case 123:
            switch highlight {
            case .fold(let fold):
                map.openEnded.remove(fold)
                map.foldCursor = fold
            case .agent(let id):
                if rows.hasShownChildren(id) {
                    map.folded.insert(id)
                } else if let fold = rows.fold(of: id) {
                    // Up a level, to its group's row.
                    map.foldCursor = fold
                }
            case nil: break
            }
        case 124:
            switch highlight {
            case .fold(let fold):
                map.openEnded.insert(fold)
                map.foldCursor = fold
            case .agent(let id): map.folded.remove(id)
            case nil: break
            }
        default: return event
        }
        return nil
    }
}

/// The map's rows as ↑ ↓ meet them, grouped by state: the running and the failed agents, the
/// Done row and its agents while it's open, then the Stopped row and its. A group's row is a
/// stop; the chat isn't.
struct AgentMapRows {
    typealias Node = TranscriptStore.AgentNode
    typealias Fold = AgentMapState.Fold
    enum Stop: Equatable { case agent(String), fold(Fold) }

    let running: [Node]
    let done: [Node]
    let stopped: [Node]
    /// Without folded branches' descendants; a closed group shows none.
    let shownRunning: [Node]
    private let shownDone: [Node]
    private let shownStopped: [Node]
    let stops: [Stop]

    init(_ trees: (running: [Node], done: [Node], stopped: [Node]), folded: Set<String>, open: Set<Fold>) {
        running = trees.running
        done = trees.done
        stopped = trees.stopped
        shownRunning = Self.visible(running, folded: folded)
        shownDone = open.contains(.done) ? Self.visible(done, folded: folded) : []
        shownStopped = open.contains(.stopped) ? Self.visible(stopped, folded: folded) : []
        var stops = shownRunning.map { Stop.agent($0.id) }
        for (fold, nodes, shown) in [(Fold.done, done, shownDone), (.stopped, stopped, shownStopped)] where !nodes.isEmpty {
            stops.append(.fold(fold))
            stops += shown.map { .agent($0.id) }
        }
        self.stops = stops
    }

    var all: [Node] { running + done + stopped }

    func nodes(_ fold: Fold) -> [Node] { fold == .done ? done : stopped }
    func shown(_ fold: Fold) -> [Node] { fold == .done ? shownDone : shownStopped }

    /// The group an ended agent waits in.
    func fold(of id: String) -> Fold? {
        if done.contains(where: { $0.id == id }) { return .done }
        if stopped.contains(where: { $0.id == id }) { return .stopped }
        return nil
    }

    /// The agent the detail pane shows: the selected one wherever it is, else the first row
    /// shown, else the newest agent (its group's row takes the highlight), so the pane is never
    /// empty while the chat has agents.
    func selection(_ id: String?) -> Node? {
        if let id, let node = running.first(where: { $0.id == id }) ?? done.first(where: { $0.id == id })
            ?? stopped.first(where: { $0.id == id }) {
            return node
        }
        for stop in stops {
            if case .agent(let first) = stop, let node = shownRunning.first(where: { $0.id == first })
                ?? shownDone.first(where: { $0.id == first }) ?? shownStopped.first(where: { $0.id == first }) {
                return node
            }
        }
        return all.max { $0.info.index < $1.info.index }
    }

    /// What has the selection fill: a group's row reached by keys, else the selected agent's
    /// row, else, while its group is closed, the group's row.
    func highlight(selected: String?, cursor: Fold?) -> Stop? {
        if let cursor, stops.contains(.fold(cursor)) { return .fold(cursor) }
        guard let selected else { return nil }
        if stops.contains(.agent(selected)) { return .agent(selected) }
        return fold(of: selected).map { .fold($0) }
    }

    /// Whether ← would fold the agent's branch: it has children shown.
    func hasShownChildren(_ id: String) -> Bool {
        for shown in [shownRunning, shownDone, shownStopped] {
            if let i = shown.firstIndex(where: { $0.id == id }) {
                return i + 1 < shown.count && shown[i + 1].depth > shown[i].depth
            }
        }
        return false
    }

    /// The tree without the descendants of folded branches.
    static func visible(_ nodes: [Node], folded: Set<String>) -> [Node] {
        guard !folded.isEmpty else { return nodes }
        var hiddenBelow: Int?
        return nodes.filter { node in
            if let depth = hiddenBelow {
                if node.depth > depth { return false }
                hiddenBelow = nil
            }
            if folded.contains(node.id) { hiddenBelow = node.depth }
            return true
        }
    }

    static func descendants(of id: String, in all: [Node]) -> Int {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return 0 }
        return all[(i + 1)...].prefix { $0.depth > all[i].depth }.count
    }

    static func title(_ fold: Fold) -> String { fold == .done ? "Done" : "Stopped" }

    /// "2 foreground · 18 background", a part with none left out.
    static func split(_ nodes: [Node]) -> String {
        let background = nodes.filter(\.background).count
        let foreground = nodes.count - background
        return [foreground > 0 ? "\(foreground) foreground" : nil, background > 0 ? "\(background) background" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "Done 20 · 2 foreground · 18 background": the group's row as it reads.
    static func label(_ fold: Fold, _ nodes: [Node]) -> String {
        let split = split(nodes)
        return "\(title(fold)) \(nodes.count)" + (split.isEmpty ? "" : " · \(split)")
    }
}

/// "Agents  24 · 2 running · 1 failed" over the graph: every agent, the stopped ones included,
/// as the Agents button counts them.
struct MapHeader: View {
    let summary: TranscriptStore.AgentSummary

    /// "24 · 2 running", then the failed part, in red.
    static func counts(_ summary: TranscriptStore.AgentSummary) -> (counts: String, failed: String) {
        ("\(summary.total)" + (summary.running.isEmpty ? "" : " · \(summary.running.count) running"),
         summary.failed.isEmpty ? "" : " · \(summary.failed.count) failed")
    }

    var body: some View {
        let (counts, failed) = Self.counts(summary)
        HStack(spacing: Space.md) {
            Text("Agents").font(TextStyle.labelStrong).foregroundStyle(Theme.text)
            (Text(counts) + Text(failed).foregroundColor(Theme.danger))
                .font(TextStyle.caption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .padding(Inset.row)
        .padding(.top, Space.xs)
    }
}

/// The graph's root: this chat, as a grey O, with its model and how long it has worked, and its
/// own commands' mark. Its click shows the chat's commands.
private struct GraphRootRow: View {
    let chat: Chat
    let hasChildren: Bool
    let commands: Int
    let selected: Bool
    let select: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: select) { content }
            .buttonStyle(.plain)
            .onHover { hovered.value = $0 }
            .storyID(StoryID.AgentMap.chat, press: { select() })
    }

    private var content: some View {
        let m = Layout.AgentMap.self
        return HStack(spacing: m.labelGap) {
            AgentNodeMark(kind: .root, radius: m.rootRadius)
            VStack(alignment: .leading, spacing: 0) {
                Text(chat.title)
                    .font(TextStyle.labelMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text((["this chat"] + [chat.controls.currentModel?.name ?? chat.controls.modelId].compactMap { $0 }
                        + [AgentMeter.clock(chat.transcript.workedFor)]).joined(separator: " · "))
                        .font(TextStyle.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    CommandCue(count: commands)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, m.leading - m.rootRadius)
        .frame(height: m.row * Zoom.shared.scale)
        .background {
            if hasChildren { GraphWires(depth: -1, rails: [], isLast: true, hasChildren: true).canvas(elbow: nil) }
        }
        .hoverFill(selected || hovered.value, selected ? Theme.Row.selected(.window) : Theme.Row.hover(.window))
        .contentShape(Rectangle())
    }
}

/// "Done  20  ·  2 foreground · 18 background" below the running agents, its chevron where the
/// chat's O is: it opens and closes the group, whose rows hang off it as the running ones hang
/// off the chat. It has the selection's fill while the selected agent waits closed inside it.
private struct ClosedGroupRow: View {
    let fold: AgentMapState.Fold
    let nodes: [TranscriptStore.AgentNode]
    let open: Bool
    let selected: Bool
    let toggle: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        let m = Layout.AgentMap.self
        let split = AgentMapRows.split(nodes)
        Button(action: toggle) {
            HStack(spacing: m.labelGap) {
                Disclosure(isOpen: open).foregroundStyle(Theme.tertiary)
                (Text(AgentMapRows.title(fold)).font(TextStyle.labelMedium).foregroundColor(Theme.secondary)
                    + Text("  \(nodes.count)").font(TextStyle.caption.monospacedDigit()).foregroundColor(Theme.tertiary)
                    + Text(split.isEmpty ? "" : "  ·  \(split)").font(TextStyle.caption.monospacedDigit())
                    .foregroundColor(Theme.tertiary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, m.leading - Size.disclosure / 2)
            .frame(height: m.groupRow * Zoom.shared.scale)
            .background {
                if open {
                    GraphWires(depth: -1, rails: [], isLast: true, hasChildren: true, mark: Size.disclosure / 2).canvas(elbow: nil)
                }
            }
            .hoverFill(selected || hovered.value, selected ? Theme.Row.selected(.window) : Theme.Row.hover(.window))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .accessibilityLabel(
            ([AgentMapRows.title(fold), "\(nodes.count)"] + (split.isEmpty ? [] : split.components(separatedBy: " · ")))
                .joined(separator: ", "))
        .storyID(StoryID.AgentMap.ended(fold.rawValue), press: { toggle() })
    }
}

/// One agent in the graph: its O at its depth, then its name and live meter. The wires are
/// drawn behind it (`GraphWires`).
private struct AgentGraphRow: View {
    let node: TranscriptStore.AgentNode
    let selected: Bool
    let waiting: Bool
    let hasChildren: Bool
    /// Descendants folded away under it.
    let hidden: Int
    /// Its own live commands (">_ 2").
    let commands: Int
    /// In an open group: the done or the stopped.
    let dimmed: Bool
    let select: () -> Void
    @StateObject private var hovered = Local(false)

    private var info: TranscriptStore.AgentInfo { node.info }

    var body: some View {
        let m = Layout.AgentMap.self
        let wires = GraphWires(depth: node.depth, rails: node.rails, isLast: node.isLast, hasChildren: hasChildren)
        Button(action: select) {
            HStack(spacing: m.labelGap) {
                AgentNodeMark(kind: .agent(index: info.index, status: info.status, waiting: waiting), background: info.background)
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.name)
                        .font(TextStyle.labelMedium)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        AgentNodeMeter(info: info, waiting: waiting, hidden: hidden, background: node.background)
                        CommandCue(count: commands)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, wires.centre(node.depth) - m.nodeRadius)
            .frame(height: m.row * Zoom.shared.scale)
            .background { wires.canvas(elbow: elbowColour).storyMark(StoryID.AgentMap.wires(info.id)) }
            .opacity(dimmed ? Theme.dimmed : 1)
            .hoverFill(selected || hovered.value, selected ? Theme.Row.selected(.window) : Theme.Row.hover(.window))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(node.background ? "\(info.name) · Background" : info.name)
        .storyID(StoryID.AgentMap.row(info.id), press: { select() })
    }

    private var elbowColour: Color {
        switch info.status {
        case .running: Theme.agentWireLive
        case .failed: Theme.agentWireFailed
        default: Theme.agentWire
        }
    }
}

/// "1:12 · 18.4k", ticking while the agent runs; "background · waiting · 8:15 · 64k"; once it
/// has ended, how: "done · 2:44 · 15.4k", "failed · 0:27", "stopped · 0:15 · 3.2k", or just
/// "stopped" with nothing known. Never empty.
struct AgentNodeMeter: View {
    let info: TranscriptStore.AgentInfo
    let waiting: Bool
    let hidden: Int
    let background: Bool

    var body: some View {
        Group {
            if info.status == .running {
                TimelineView(.periodic(from: info.startedAt, by: 1)) { context in
                    line(context.date.timeIntervalSince(info.startedAt))
                }
            } else {
                line(info.duration)
            }
        }
        .font(TextStyle.caption.monospacedDigit())
        .lineLimit(1)
    }

    private func line(_ duration: TimeInterval?) -> some View {
        let colour = info.status == .failed ? Theme.danger : info.status == .running ? Theme.secondary : Theme.tertiary
        return Text(Self.text(info, duration: duration, waiting: waiting, hidden: hidden, background: background))
            .foregroundStyle(colour)
    }

    /// An ended agent's first word: "done", "failed" or "stopped"; nil while it runs.
    static func state(_ status: TranscriptStore.AgentInfo.Status) -> String? {
        switch status {
        case .running: nil
        case .finished: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }

    static func text(
        _ info: TranscriptStore.AgentInfo, duration: TimeInterval?, waiting: Bool, hidden: Int = 0, background: Bool
    ) -> String {
        var parts: [String] = background ? ["background"] : []
        if let state = state(info.status) { parts.append(state) }
        if waiting { parts.append("waiting") }
        if let duration { parts.append(AgentMeter.clock(duration)) }
        if let tokens = AgentMeter.tokens(of: info), info.status != .failed { parts.append(tokens) }
        if hidden > 0 { parts.append("+\(hidden) folded") }
        return parts.joined(separator: " · ")
    }
}

/// A row's share of the graph's wires (phase 10 §6), in the row's own coordinates. The spine
/// of a parent at level L runs down at `centre(L)`; the root is level −1.
/// - `spine`: neutral lines: the ancestors' spines that continue past this row, the parent's
///   spine down to this row's elbow (and on, if a later sibling follows), and this row's own
///   spine from the bottom of its O when it has children.
/// - `elbow`: the curve off the parent's spine into this row's O, coloured by the agent's state.
struct GraphWires {
    let depth: Int
    let rails: [Bool]
    let isLast: Bool
    let hasChildren: Bool
    /// The radius of what the row's own spine starts below, when not its O.
    var mark: CGFloat?

    private var m: Layout.AgentMap.Type { Layout.AgentMap.self }

    func centre(_ level: Int) -> CGFloat { m.leading + CGFloat(level + 1) * m.step }

    func spine(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        for (level, continues) in rails.enumerated() where continues {
            let x = centre(level - 1)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        if depth >= 0 {
            let x = centre(depth - 1)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: isLast ? mid - m.bend : rect.maxY))
        }
        if hasChildren {
            let x = centre(depth)
            let radius = mark ?? (depth < 0 ? m.rootRadius : m.nodeRadius)
            path.move(to: CGPoint(x: x, y: mid + radius + m.gap))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }

    func elbow(in rect: CGRect) -> Path {
        var path = Path()
        guard depth >= 0 else { return path }
        let x = centre(depth - 1), mid = rect.midY
        path.move(to: CGPoint(x: x, y: mid - m.bend))
        path.addQuadCurve(to: CGPoint(x: x + m.bend, y: mid), control: CGPoint(x: x, y: mid))
        path.addLine(to: CGPoint(x: centre(depth) - m.nodeRadius - m.gap, y: mid))
        return path
    }

    /// The spine and the elbow (in `elbow`'s colour, when there's one) as one drawn view the
    /// size of the row: a view per line made each row several views to build.
    func canvas(elbow colour: Color?) -> some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.stroke(spine(in: rect), with: .color(Theme.agentWire), lineWidth: Stroke.emphasis)
            if let colour {
                context.stroke(
                    elbow(in: rect), with: .color(colour), style: StrokeStyle(lineWidth: Stroke.emphasis, lineCap: .round))
            }
        }
    }
}

/// "0:41", ticking while the agent runs.
struct AgentDuration: View {
    let info: TranscriptStore.AgentInfo

    var body: some View {
        Group {
            if info.status == .running {
                TimelineView(.periodic(from: info.startedAt, by: 1)) { context in
                    Text(AgentMeter.clock(context.date.timeIntervalSince(info.startedAt)))
                }
            } else {
                Text(info.duration.map(AgentMeter.clock) ?? "")
            }
        }
        .font(TextStyle.caption.monospacedDigit())
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: Detail

/// The selected agent: who it is and its meter, Stop and Open in tab; then its prompt; then its
/// own timeline, live.
struct AgentDetail: View {
    let chat: Chat
    let info: TranscriptStore.AgentInfo
    let openAgent: (String) -> Void
    /// The prompt and the timeline come a frame after the rest of the map, which shows as the
    /// map's fade begins: the map's first frame has the graph and this header to build alone.
    @StateObject private var filled = Local(false)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Each of the timeline's rows is a row of this stack, so only those in view are
                // built: an agent's work can run to hundreds of rows.
                Section {
                    if filled.value {
                        Color.clear.frame(height: Space.xl)
                        CommandsSection(chat: chat, rows: chat.commands.rows(of: .sub(info.id)))
                        if let prompt = info.prompt, !prompt.isEmpty { AgentPrompt(prompt: prompt).padding(.bottom, Space.xl) }
                        AgentTimelineRows(chat: chat, id: info.id)
                        Color.clear.frame(height: Layout.Transcript.bottom)
                    }
                } header: {
                    header
                }
            }
            .padding(.horizontal, Layout.Viewer.canvasSide)
        }
        .onAppear {
            chat.loadAgentIfNeeded(info.id)
            let filled = filled
            afterThisFrame { filled.value = true }
        }
        .onChange(of: info.id) { _, id in chat.loadAgentIfNeeded(id) }
    }

    private var header: some View {
        VStack(spacing: 0) {
            // Step down, don't clip: the buttons lose their words before they'd squeeze.
            ViewThatFits(in: .horizontal) {
                headerRow(labelled: true)
                headerRow(labelled: false)
            }
            .padding(.vertical, Space.lg)
            // Room for the map's close button.
            .padding(.trailing, Size.iconButton + Space.md)
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
        }
        .background(Theme.background)
    }

    private func headerRow(labelled: Bool) -> some View {
        HStack(alignment: .center, spacing: Space.md) {
            AgentNodeMark(kind: .agent(index: info.index, status: info.status, waiting: info.waiting > 0),
                          radius: Layout.AgentMap.detailRadius, background: info.background)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(info.name)
                    .font(TextStyle.title)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                AgentMeta(info: info)
            }
            .frame(idealWidth: Layout.AgentMap.detailNameMin, maxWidth: .infinity, alignment: .leading)
            if info.status == .running {
                Button {
                    chat.stopAgent(info.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(labelled ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                }
                .buttonStyle(SubtleButtonStyle())
                .fixedSize()
                .help("Stop agent")
                .storyID(StoryID.AgentMap.stop)
            }
            Button {
                openAgent(info.id)
            } label: {
                Label("Open in tab", systemImage: "arrow.up.forward")
                    .labelStyle(labelled ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            }
            .buttonStyle(SubtleButtonStyle())
            .fixedSize()
            .help("Open in tab (Return)")
            .storyID(StoryID.AgentMap.open)
        }
    }
}

/// `.titleAndIcon` or `.iconOnly`, chosen at run time.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init(_ style: some LabelStyle) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// "Explore · haiku · 0:41 · 18.2k tokens · 6 tools", live; an ended agent's says how it ended
/// before its time ("general-purpose · stopped · 0:15 · 3.2k tokens").
struct AgentMeta: View {
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
        var parts = [info.type, info.model].compactMap { $0 }
        if let state = AgentNodeMeter.state(info.status) { parts.append(state) }
        if let duration { parts.append(AgentMeter.clock(duration)) }
        if let tokens = AgentMeter.tokens(of: info) { parts.append("\(tokens) tokens") }
        if info.tools > 0 { parts.append(info.tools == 1 ? "1 tool" : "\(info.tools) tools") }
        return Text(parts.joined(separator: " · "))
            .font(TextStyle.caption.monospacedDigit())
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
    }
}

/// "PROMPT", then the prompt as a user box, three lines until "Show more".
struct AgentPrompt: View {
    let prompt: String
    @StateObject private var expanded = Local(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("PROMPT").font(TextStyle.eyebrow).foregroundStyle(Theme.tertiary)
            Text(prompt)
                .font(TextStyle.body)
                .foregroundStyle(Theme.text)
                .lineLimit(expanded.value ? nil : 3)
                .textSelection(.enabled)
                .padding(Inset.userBox)
                .panel(.userBox)
            if !expanded.value, prompt.count > 240 || prompt.filter({ $0 == "\n" }).count > 2 {
                TextButton("Show more") { expanded.value = true }
            }
        }
    }
}

/// An agent's own items as its timeline's rows, unwrapped: in a lazy stack, each is a row of it.
struct AgentTimelineRows: View {
    let chat: Chat
    let id: String

    var body: some View {
        let _ = chat.transcript.agentsVersion
        let items = chat.transcript.agentItems(id)
        let info = chat.transcript.agent(id)
        if items.isEmpty, let info {
            Text(info.background && info.status == .running
                ? "Commands appear when this agent finishes"
                : info.status == .running ? "No commands yet" : "No commands recorded")
                .font(TextStyle.body)
                .foregroundStyle(Theme.tertiary)
        }
        ForEach(items) { item in
            TimelineRow(item: item, actions: actions).equatable()
        }
        if let info, let result = TranscriptStore.distinctResult(info, lane: chat.transcript.lane(id)) {
            TimelineItem(dot: info.status == .failed ? .failure : .plain, above: !items.isEmpty) {
                Text(planMarkdown(result))
                    .font(TextStyle.body)
                    .foregroundStyle(info.status == .finished ? Theme.text : Theme.secondary)
                    .lineSpacing(TextStyle.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actions: TranscriptActions {
        let chat = chat
        var actions = TranscriptActions()
        actions.toggle = { chat.transcript.toggle($0) }
        actions.stopAgent = { chat.stopAgent($0) }
        actions.folder = chat.folder
        return actions
    }
}
