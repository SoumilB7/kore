import SwiftUI

/// Every agent the chat has spawned, over the chat area (phase 10 §6): a graph on the left with
/// the chat as its root O and each agent an O whose wire drops from the bottom of its parent's,
/// and the selected agent on the right with its prompt and its own timeline, live. ↑ ↓ select,
/// Return opens the agent in a tab, ← → fold and unfold, Esc closes. In a narrow tile the
/// graph becomes a menu.
struct AgentMapView: View {
    let chat: Chat
    let openAgent: (String) -> Void
    @StateObject private var keyMonitor = Local<Any?>(nil)
    @StateObject private var window = Local<NSWindow?>(nil)

    private var map: AgentMapState { chat.agentMap }

    var body: some View {
        // Reading `tail` re-renders the map as agents and their work change.
        _ = chat.transcript.agentsVersion
        let nodes = visible(chat.transcript.agentTree())
        let selected = nodes.first { $0.id == map.selected } ?? nodes.first
        return GeometryReader { geometry in
            let narrow = geometry.size.width < Size.changesListMinWindow
            ZStack(alignment: .topTrailing) {
                Theme.background
                HStack(spacing: 0) {
                    if !narrow {
                        tree(nodes, selected: selected?.id)
                            .frame(width: paneWidth(nodes, in: geometry.size.width))
                        Rectangle().fill(Theme.border).frame(width: Stroke.hairline)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        if narrow { treeMenu(nodes, selected: selected).padding(Layout.Viewer.closeInset) }
                        if let selected {
                            AgentDetail(chat: chat, info: selected.info, openAgent: openAgent)
                        }
                    }
                }
                IconButton(symbol: "xmark", help: "Close (Esc)") { map.close() }
                    .padding(Layout.Viewer.closeInset)
            }
        }
        .background(WindowReader { window.value = $0 })
        .transition(.opacity)
        .onAppear {
            if map.selected == nil { map.selected = nodes.first?.id }
            map.markSeen(chat.transcript.agentSummary.failed)
            keyMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) }
        }
        .onDisappear {
            if let monitor = keyMonitor.value { NSEvent.removeMonitor(monitor) }
            keyMonitor.value = nil
        }
        .onChange(of: chat.transcript.agentSummary.failed) { _, failed in map.markSeen(failed) }
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

    private func tree(_ nodes: [TranscriptStore.AgentNode], selected: String?) -> some View {
        let all = chat.transcript.agentTree()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                MapHeader(summary: chat.transcript.agentSummary)
                GraphRootRow(chat: chat, hasChildren: !nodes.isEmpty)
                ForEach(nodes) { node in
                    let hidden = map.folded.contains(node.id) ? descendants(of: node.id, in: all) : 0
                    AgentGraphRow(
                        node: node, selected: node.id == selected, waiting: waiting(node.id),
                        hasChildren: hasChildren(node, in: all) && hidden == 0, hidden: hidden
                    ) {
                        map.selected = node.id
                    }
                }
            }
            .padding(.bottom, Space.xl)
            .padding(.horizontal, Space.sm)
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

    private func treeMenu(_ nodes: [TranscriptStore.AgentNode], selected: TranscriptStore.AgentNode?) -> some View {
        Menu {
            ForEach(nodes) { node in
                Button(String(repeating: "    ", count: node.depth) + node.info.name) { map.selected = node.id }
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

    private func hasChildren(_ node: TranscriptStore.AgentNode, in nodes: [TranscriptStore.AgentNode]) -> Bool {
        nodes.contains { $0.info.parent == node.id }
    }

    private func waiting(_ id: String) -> Bool {
        (chat.transcript.agent(id)?.waiting ?? 0) > 0
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return event }
        let nodes = visible(chat.transcript.agentTree())
        let index = nodes.firstIndex { $0.id == map.selected } ?? 0
        switch event.keyCode {
        case 53: map.close()
        case 36, 76: if let id = map.selected { openAgent(id) }
        case 126: if index > 0 { map.selected = nodes[index - 1].id }
        case 125: if index + 1 < nodes.count { map.selected = nodes[index + 1].id }
        case 123: if let id = map.selected { map.folded.insert(id) }
        case 124: if let id = map.selected { map.folded.remove(id) }
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
        .background(alignment: .leading) {
            if hasChildren { GraphWires(depth: -1, rails: [], isLast: true, hasChildren: true).spine.stroke(Theme.agentWire, lineWidth: Stroke.emphasis) }
        }
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
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    wires.spine.stroke(Theme.agentWire, lineWidth: Stroke.emphasis)
                    wires.elbow.stroke(elbowColour, style: StrokeStyle(lineWidth: Stroke.emphasis, lineCap: .round))
                }
            }
            .hoverFill(selected || hovered.value, selected ? Theme.surfaceHover : Theme.toolHover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(info.name)
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

    private var m: Layout.AgentMap.Type { Layout.AgentMap.self }

    func centre(_ level: Int) -> CGFloat { m.leading + CGFloat(level + 1) * m.step }

    var spine: GraphShape {
        GraphShape { rect in
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
                let radius = depth < 0 ? m.rootRadius : m.nodeRadius
                path.move(to: CGPoint(x: x, y: mid + radius + m.gap))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            return path
        }
    }

    var elbow: GraphShape {
        GraphShape { rect in
            var path = Path()
            guard depth >= 0 else { return path }
            let x = centre(depth - 1), mid = rect.midY
            path.move(to: CGPoint(x: x, y: mid - m.bend))
            path.addQuadCurve(to: CGPoint(x: x + m.bend, y: mid), control: CGPoint(x: x, y: mid))
            path.addLine(to: CGPoint(x: centre(depth) - m.nodeRadius - m.gap, y: mid))
            return path
        }
    }
}

struct GraphShape: Shape {
    let draw: @Sendable (CGRect) -> Path
    func path(in rect: CGRect) -> Path { draw(rect) }
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        if let prompt = info.prompt, !prompt.isEmpty { AgentPrompt(prompt: prompt) }
                        AgentTimeline(chat: chat, id: info.id)
                    }
                    .padding(.top, Space.xl)
                    .padding(.bottom, Layout.Transcript.bottom)
                } header: {
                    header
                }
            }
            .padding(.horizontal, Layout.Viewer.canvasSide)
        }
        .onAppear { chat.loadAgentIfNeeded(info.id) }
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

/// An agent's own items as a top-level timeline.
struct AgentTimeline: View {
    let chat: Chat
    let id: String

    var body: some View {
        _ = chat.transcript.agentsVersion
        let items = chat.transcript.agentItems(id)
        let info = chat.transcript.agent(id)
        return VStack(alignment: .leading, spacing: 0) {
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
