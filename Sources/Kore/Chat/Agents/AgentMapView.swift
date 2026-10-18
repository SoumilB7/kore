import SwiftUI

/// Every agent the chat has spawned, over the chat area (look.md §10): a tree on the left with
/// the chat at its root, the selected agent on the right with its prompt and its own timeline,
/// live. ↑ ↓ select, Return opens the agent in a tab, Esc closes. In a narrow tile the tree
/// becomes a menu.
struct AgentMapView: View {
    let chat: Chat
    let openAgent: (String) -> Void
    @StateObject private var keyMonitor = Local<Any?>(nil)
    @StateObject private var window = Local<NSWindow?>(nil)

    private var map: AgentMapState { chat.agentMap }

    var body: some View {
        // Reading `tail` re-renders the map as agents and their work change.
        _ = chat.transcript.tail
        let nodes = visible(chat.transcript.agentTree())
        let selected = nodes.first { $0.id == map.selected } ?? nodes.first
        return GeometryReader { geometry in
            let narrow = geometry.size.width < Size.changesListMinWindow
            ZStack(alignment: .topTrailing) {
                Theme.background
                HStack(spacing: 0) {
                    if !narrow {
                        tree(nodes, selected: selected?.id)
                            .frame(width: Size.mapTree)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                RootRow(chat: chat)
                ForEach(nodes) { node in
                    AgentTreeRow(
                        node: node, selected: node.id == selected, waiting: waiting(node.id),
                        folded: map.folded.contains(node.id), hasChildren: hasChildren(node, in: nodes)
                    ) {
                        map.selected = node.id
                    }
                }
            }
            .padding(.vertical, Space.xl)
            .padding(.horizontal, Space.sm)
        }
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
        chat.transcript.agentTree().contains { $0.info.parent == node.id }
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

/// The tree's root: this chat, with its provider's logo.
private struct RootRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: Space.md) {
            ProviderLogo(provider: chat.provider, size: Size.logoTab)
                .frame(width: AgentAvatar.Place.mapRow.box, height: AgentAvatar.Place.mapRow.box)
            VStack(alignment: .leading, spacing: 0) {
                Text(chat.title)
                    .font(TextStyle.labelMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text((["this chat"] + [chat.controls.currentModel?.name ?? chat.controls.modelId].compactMap { $0 })
                    .joined(separator: " · "))
                    .font(TextStyle.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Text(AgentMeter.clock(chat.transcript.workedFor))
                .font(TextStyle.caption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
        .padding(Inset.row)
    }
}

/// One agent in the tree: connectors to its parent, its avatar, name and "type · status", and
/// its duration.
private struct AgentTreeRow: View {
    let node: TranscriptStore.AgentNode
    let selected: Bool
    let waiting: Bool
    let folded: Bool
    let hasChildren: Bool
    let select: () -> Void
    @StateObject private var hovered = Local(false)

    private var info: TranscriptStore.AgentInfo { node.info }

    var body: some View {
        Button(action: select) {
            HStack(spacing: Space.md) {
                if folded && hasChildren {
                    Image(systemName: "chevron.right").font(Glyph.chevron).foregroundStyle(Theme.tertiary)
                }
                AgentAvatar(index: info.index, name: info.name, status: info.status, waiting: waiting, place: .mapRow)
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.name)
                        .font(TextStyle.labelMedium)
                        .foregroundStyle(AgentAvatar.hue(info.index))
                        .lineLimit(1)
                    subtitle
                }
                Spacer(minLength: Space.sm)
                AgentDuration(info: info)
            }
            .padding(.leading, CGFloat(node.depth + 1) * Size.treeIndent)
            .padding(Inset.row)
            .background(alignment: .leading) {
                TreeConnector(node: node).fill(Theme.timelineLine).padding(.leading, Inset.row.leading)
            }
            .hoverFill(selected || hovered.value, selected ? Theme.surfaceHover : Theme.toolHover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(info.name)
    }

    private var subtitle: some View {
        let status: String? = switch info.status {
        case .running: waiting ? "waiting" : info.model
        case .finished: "finished"
        case .failed: "failed"
        case .stopped: "stopped"
        }
        return HStack(spacing: 0) {
            Text([info.type, status].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(info.status == .failed ? Theme.danger : waiting ? Theme.secondary : Theme.tertiary)
        }
        .font(TextStyle.caption)
        .lineLimit(1)
    }
}

/// The tree's lines: down from each ancestor that has more children below, and an elbow (├ or
/// └) into this row's avatar.
private struct TreeConnector: Shape {
    let node: TranscriptStore.AgentNode

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let half = AgentAvatar.Place.mapRow.box / 2
        let x = { (level: Int) in CGFloat(level) * Size.treeIndent + half }
        let mid = rect.midY
        // Ancestors' rails, then this row's own level.
        for (level, continues) in node.rails.enumerated() where continues {
            path.addRect(CGRect(x: x(level + 1), y: rect.minY, width: Stroke.hairline, height: rect.height))
        }
        let own = x(node.depth)
        // ├ or └: down from the parent's mark, then across to this row's shape.
        path.addRect(CGRect(x: own, y: rect.minY, width: Stroke.hairline, height: node.isLast ? mid - rect.minY : rect.height))
        let shapeEdge = x(node.depth + 1) - AgentAvatar.Place.mapRow.shape / 2
        path.addRect(CGRect(x: own, y: mid, width: shapeEdge - own, height: Stroke.hairline))
        return path
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
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Space.md) {
                AgentAvatar(index: info.index, name: info.name, status: info.status, place: .mapDetail)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(info.name)
                        .font(TextStyle.title)
                        .foregroundStyle(AgentAvatar.hue(info.index))
                        .lineLimit(1)
                    AgentMeta(info: info)
                }
                .layoutPriority(1)
                Spacer(minLength: Space.md)
                if info.status == .running {
                    Button {
                        chat.stopAgent(info.id)
                    } label: {
                        Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                Button {
                    openAgent(info.id)
                } label: {
                    Label("Open in tab", systemImage: "arrow.up.forward").labelStyle(.titleAndIcon)
                }
                .buttonStyle(SubtleButtonStyle())
                .help("Open this agent in its own tab (Return)")
            }
            .padding(.vertical, Space.lg)
            // Room for the map's close button.
            .padding(.trailing, Size.iconButton + Space.md)
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
        }
        .background(Theme.background)
    }
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
        _ = chat.transcript.tail
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
            if let result = info?.result, !result.isEmpty {
                TimelineItem(dot: info?.status == .failed ? .failure : .plain, above: !items.isEmpty) {
                    Text(planMarkdown(result))
                        .font(TextStyle.body)
                        .foregroundStyle(info?.status == .finished ? Theme.text : Theme.secondary)
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
