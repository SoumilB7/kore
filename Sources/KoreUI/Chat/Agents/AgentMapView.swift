import SwiftUI

/// Every agent the chat has spawned, over the chat area (phase 10 §6): a graph on the left with
/// the chat as its root O and each agent an O whose wire drops from the bottom of its parent's,
/// and the selected agent on the right with its prompt and its own timeline, live. Stopped agents
/// wait apart in a closed group below the tree. ↑ ↓ select, Return opens the agent in a tab,
/// ← → fold and unfold, Esc closes. In a narrow tile the graph becomes a menu.
struct AgentMapView: View {
    let chat: Chat
    let openAgent: (String) -> Void
    /// Kept, never shown: setting them as the map appears doesn't build it again.
    @StateObject private var keyMonitor = Held<Any?>(nil)
    @StateObject private var window = Held<NSWindow?>(nil)

    private var map: AgentMapState { chat.agentMap }

    var body: some View {
        // Reading `tail` re-renders the map as agents and their work change.
        _ = chat.transcript.agentsVersion
        let all = chat.transcript.agentTree()
        let nodes = shown(all)
        // A stopped agent stays selected while its group is closed.
        let selected = nodes.first { $0.id == map.selected } ?? all.stopped.first { $0.id == map.selected } ?? nodes.first
        return GeometryReader { geometry in
            let narrow = geometry.size.width < Size.changesListMinWindow
            ZStack(alignment: .topTrailing) {
                Theme.background
                HStack(spacing: 0) {
                    if !narrow {
                        // The stopped group's rows count whether it's open or not: opening it
                        // doesn't move the divider.
                        tree(all, selected: selected?.id)
                            .frame(width: paneWidth(visible(all.tree) + all.stopped, in: geometry.size.width))
                        Rectangle().fill(Theme.border).frame(width: Stroke.hairline)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        if narrow { treeMenu(all, selected: selected).padding(Layout.Viewer.closeInset) }
                        if let selected {
                            AgentDetail(chat: chat, info: selected.info, openAgent: openAgent)
                        }
                    }
                }
                // The tree keeps its place at the left with nothing selected (every agent
                // stopped, the group closed), rather than sliding over to the close button.
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
        }
        .onDisappear {
            if let monitor = keyMonitor.value { NSEvent.removeMonitor(monitor) }
            keyMonitor.value = nil
        }
        .onChange(of: chat.transcript.agentSummary.failed) { _, failed in map.markSeen(failed) }
    }

    typealias Trees = (tree: [TranscriptStore.AgentNode], stopped: [TranscriptStore.AgentNode])

    /// The rows ↑ ↓ move through: the tree's, then the stopped group's while it's open.
    private func shown(_ all: Trees) -> [TranscriptStore.AgentNode] {
        visible(all.tree) + (map.stoppedOpen ? visible(all.stopped) : [])
    }

    /// The tree without the descendants of folded branches.
    private func visible(_ nodes: [TranscriptStore.AgentNode]) -> [TranscriptStore.AgentNode] {
        var hiddenBelow: Int?
        return nodes.filter { node in
            if let depth = hiddenBelow {
                if node.depth > depth { return false }
                hiddenBelow = nil
            }
            if map.folded.contains(node.id) { hiddenBelow = node.depth }
            return true
        }
    }

    // MARK: Tree

    private func tree(_ all: Trees, selected: String?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                MapHeader(summary: chat.transcript.agentSummary)
                GraphRootRow(chat: chat, hasChildren: !all.tree.isEmpty)
                rows(all.tree, selected: selected, dimmed: false)
                if !all.stopped.isEmpty {
                    StoppedGroupRow(count: all.stopped.count, open: map.stoppedOpen) { map.stoppedOpen.toggle() }
                        .padding(.top, Layout.AgentMap.groupTop)
                    if map.stoppedOpen { rows(all.stopped, selected: selected, dimmed: true) }
                }
            }
            .padding(.bottom, Space.xl)
            .padding(.horizontal, Space.sm)
        }
    }

    /// One tree's rows, without its folded branches' descendants.
    private func rows(_ all: [TranscriptStore.AgentNode], selected: String?, dimmed: Bool) -> some View {
        let parents = Set(zip(all, all.dropFirst()).filter { $1.depth > $0.depth }.map(\.0.id))
        return ForEach(visible(all)) { node in
            let hidden = map.folded.contains(node.id) ? descendants(of: node.id, in: all) : 0
            AgentGraphRow(
                node: node, selected: node.id == selected, waiting: waiting(node.id),
                hasChildren: parents.contains(node.id) && hidden == 0, hidden: hidden, dimmed: dimmed
            ) {
                map.selected = node.id
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

    private func descendants(of id: String, in all: [TranscriptStore.AgentNode]) -> Int {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return 0 }
        return all[(i + 1)...].prefix { $0.depth > all[i].depth }.count
    }

    private func treeMenu(_ all: Trees, selected: TranscriptStore.AgentNode?) -> some View {
        Menu {
            menuItems(all.tree)
            if !all.stopped.isEmpty {
                Section("Stopped") { menuItems(all.stopped) }
            }
        } label: {
            if let selected {
                HStack(spacing: Space.sm) {
                    AgentAvatar(index: selected.info.index, name: selected.info.name, status: selected.info.status,
                                place: .crumb)
                    Text(selected.info.name).font(TextStyle.labelMedium).foregroundStyle(Theme.text).lineLimit(1)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func menuItems(_ nodes: [TranscriptStore.AgentNode]) -> some View {
        ForEach(nodes) { node in
            Button(String(repeating: "    ", count: node.depth) + node.info.name) { map.selected = node.id }
        }
    }

    private func waiting(_ id: String) -> Bool {
        (chat.transcript.agent(id)?.waiting ?? 0) > 0
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return event }
        let nodes = shown(chat.transcript.agentTree())
        // Nothing picked yet shows the first agent.
        let selected = nodes.first { $0.id == map.selected }?.id ?? nodes.first?.id
        let index = nodes.firstIndex { $0.id == selected } ?? 0
        switch event.keyCode {
        case 53: map.close()
        case 36, 76: if let selected { openAgent(selected) }
        case 126: if index > 0 { map.selected = nodes[index - 1].id }
        case 125: if index + 1 < nodes.count { map.selected = nodes[index + 1].id }
        case 123: if let selected { map.folded.insert(selected) }
        case 124: if let selected { map.folded.remove(selected) }
        default: return event
        }
        return nil
    }
}

/// "Agents  4 · 2 running · 1 failed" over the graph.
private struct MapHeader: View {
    let summary: TranscriptStore.AgentSummary

    var body: some View {
        HStack(spacing: Space.md) {
            Text("Agents").font(TextStyle.labelStrong).foregroundStyle(Theme.text)
            (Text("\(summary.count)")
                + Text(summary.running.isEmpty ? "" : " · \(summary.running.count) running")
                + Text(summary.failed.isEmpty ? "" : " · \(summary.failed.count) failed").foregroundColor(Theme.danger))
                .font(TextStyle.caption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .padding(Inset.row)
        .padding(.top, Space.xs)
    }
}

/// The graph's root: this chat, as a grey O, with its model and how long it has worked.
private struct GraphRootRow: View {
    let chat: Chat
    let hasChildren: Bool

    var body: some View {
        let m = Layout.AgentMap.self
        HStack(spacing: m.labelGap) {
            AgentNodeMark(kind: .root, radius: m.rootRadius)
            VStack(alignment: .leading, spacing: 0) {
                Text(chat.title)
                    .font(TextStyle.labelMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text((["this chat"] + [chat.controls.currentModel?.name ?? chat.controls.modelId].compactMap { $0 }
                    + [AgentMeter.clock(chat.transcript.workedFor)]).joined(separator: " · "))
                    .font(TextStyle.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, m.leading - m.rootRadius)
        .frame(height: m.row * Zoom.shared.scale)
        .background {
            if hasChildren { GraphWires(depth: -1, rails: [], isLast: true, hasChildren: true).canvas(elbow: nil) }
        }
    }
}

/// "Stopped  3" below the tree, its chevron where the chat's O is: it opens and closes the group,
/// whose rows hang off it as the tree's hang off the chat.
private struct StoppedGroupRow: View {
    let count: Int
    let open: Bool
    let toggle: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        let m = Layout.AgentMap.self
        Button(action: toggle) {
            HStack(spacing: m.labelGap) {
                Disclosure(isOpen: open).foregroundStyle(Theme.tertiary)
                (Text("Stopped").font(TextStyle.labelMedium).foregroundColor(Theme.secondary)
                    + Text("  \(count)").font(TextStyle.caption.monospacedDigit()).foregroundColor(Theme.tertiary))
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
            .hoverFill(hovered.value, Theme.toolHover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .storyID(StoryID.AgentMap.stopped)
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
    /// In the stopped group.
    let dimmed: Bool
    let select: () -> Void
    @StateObject private var hovered = Local(false)

    private var info: TranscriptStore.AgentInfo { node.info }

    var body: some View {
        let m = Layout.AgentMap.self
        let wires = GraphWires(depth: node.depth, rails: node.rails, isLast: node.isLast, hasChildren: hasChildren)
        Button(action: select) {
            HStack(spacing: m.labelGap) {
                AgentNodeMark(kind: .agent(index: info.index, status: info.status, waiting: waiting))
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.name)
                        .font(TextStyle.labelMedium)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    AgentNodeMeter(info: info, waiting: waiting, hidden: hidden)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, wires.centre(node.depth) - m.nodeRadius)
            .frame(height: m.row * Zoom.shared.scale)
            .background { wires.canvas(elbow: elbowColour).storyMark(StoryID.AgentMap.wires(info.id)) }
            .opacity(dimmed ? Theme.dimmed : 1)
            .hoverFill(selected || hovered.value, selected ? Theme.surfaceHover : Theme.toolHover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(info.name)
        .storyID(StoryID.AgentMap.row(info.id))
    }

    private var elbowColour: Color {
        switch info.status {
        case .running: Theme.agentWireLive
        case .failed: Theme.agentWireFailed
        default: Theme.agentWire
        }
    }
}

/// "0:41 · 12.8k", ticking while the agent runs; "failed · 0:27"; "waiting · 0:31".
private struct AgentNodeMeter: View {
    let info: TranscriptStore.AgentInfo
    let waiting: Bool
    let hidden: Int

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
        var parts: [String] = []
        if info.status == .failed { parts.append("failed") } else if info.status == .stopped { parts.append("stopped") }
        if waiting { parts.append("waiting") }
        if let duration { parts.append(AgentMeter.clock(duration)) }
        if let tokens = info.tokens, info.status != .failed { parts.append(AgentMeter.tokens(tokens)) }
        if hidden > 0 { parts.append("+\(hidden) folded") }
        let colour = info.status == .failed ? Theme.danger : info.status == .running ? Theme.secondary : Theme.tertiary
        return Text(parts.joined(separator: " · ")).foregroundStyle(colour)
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
                          radius: Layout.AgentMap.detailRadius)
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

/// "Explore · haiku · 0:41 · 18.2k tokens · 6 tools", live.
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
        if let duration { parts.append(AgentMeter.clock(duration)) }
        if let tokens = info.tokens { parts.append("\(AgentMeter.tokens(tokens)) tokens") }
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
