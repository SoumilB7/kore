import SwiftUI

/// A sub-agent in its own tab (look.md §10): a crumb back to its parent chat, its prompt and
/// its own timeline (live, the same items as in the chat), and a footer where the composer
/// would be. It reads the parent chat's stores, so it can't drift from it.
struct AgentTabView: View {
    let chat: Chat
    let id: String
    let workspace: Workspace
    @Environment(\.chatColumn) private var column

    var body: some View {
        _ = chat.transcript.agentsVersion
        let info = chat.transcript.agent(id)
        return VStack(spacing: 0) {
            if let info {
                crumb(info)
                    .storyID(StoryID.AgentTab.crumb)
                AgentTabTimeline(chat: chat, id: id, prompt: info.prompt)
                    .onAppear { chat.loadAgentIfNeeded(id) }
                    // Its tools' files open in Kore, as the chat's do.
                    .environment(\.openURL, OpenURLAction { [workspace, chat] url in
                        workspace.openLink(url, from: chat.folder)
                        return .handled
                    })
                footer(info)
                    .padding(.horizontal, column.composerPadding)
                    .padding(.bottom, Space.xxxl)
                    .frame(maxWidth: column.composerMaxWidth)
            } else {
                Text("This agent isn't in the chat any more.")
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Crumb

    /// "✳ Parent chat › (MR) Map reads of entries          0:41 · 18.2k · 6 tools"
    private func crumb(_ info: TranscriptStore.AgentInfo) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                CrumbLink(chat: chat) { backToChat() }
                ForEach(ancestors(of: info), id: \.id) { parent in
                    chevron
                    Button {
                        workspace.openAgent(parent.id, of: chat)
                    } label: {
                        HStack(spacing: Space.xs) {
                            AgentAvatar(
                                index: parent.index, name: parent.name, status: parent.status, background: parent.background,
                                place: .crumb)
                            Text(parent.name).font(TextStyle.label).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                chevron
                AgentAvatar(index: info.index, name: info.name, status: info.status, background: info.background, place: .crumb)
                Text(info.name)
                    .font(TextStyle.labelMedium)
                    .foregroundStyle(AgentAvatar.hue(info.index))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Space.md)
                AgentMeter(info: info)
            }
            .padding(.horizontal, column.padding)
            .frame(height: Size.crumb)
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(Glyph.chevron).foregroundStyle(Theme.tertiary)
    }

    /// The agents between the chat and this one (for a nested agent).
    private func ancestors(of info: TranscriptStore.AgentInfo) -> [TranscriptStore.AgentInfo] {
        var chain: [TranscriptStore.AgentInfo] = []
        var parent = info.parent
        while let id = parent, let agent = chat.transcript.agent(id) {
            chain.insert(agent, at: 0)
            parent = agent.parent
        }
        return chain
    }

    // MARK: Footer

    private func footer(_ info: TranscriptStore.AgentInfo) -> some View {
        HStack(spacing: Space.md) {
            AgentAvatar(index: info.index, name: info.name, status: info.status, background: info.background, place: .approval)
            Group {
                switch info.status {
                case .running, .stopped:
                    Text("A sub-agent of “\(chat.title)”. It answers to that chat.")
                        .foregroundStyle(Theme.secondary)
                case .finished:
                    Text("Finished · \(info.duration.map(AgentMeter.clock) ?? "")")
                        .foregroundStyle(Theme.secondary)
                case .failed:
                    Text("Failed · \(info.result ?? "")")
                        .foregroundStyle(Theme.danger)
                }
            }
            .font(TextStyle.label)
            .lineLimit(2)
            Spacer(minLength: Space.md)
            AdaptiveButtons {
                if info.status == .running {
                    Button {
                        chat.stopAgent(info.id)
                    } label: {
                        Label("Stop agent", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                Button("Back to chat") { backToChat() }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
            }
            .fixedSize()
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.lg)
        .panel(.panel)
    }

    private func backToChat() {
        if let tab = workspace.tab(of: chat) { workspace.select(tab) }
    }
}

/// The agent's own timeline, shown as the chat's transcript is: it opens at the end on the latest
/// commands and follows the end while new ones come in, until the reader scrolls up. Each command
/// is a row of the lazy stack, so only those in view are built: an agent's work can run to
/// hundreds of commands.
private struct AgentTabTimeline: View {
    let chat: Chat
    let id: String
    let prompt: String?
    @Environment(\.chatColumn) private var column
    @StateObject private var following = Held(true)
    /// A scroll gesture is under way (from its phase): the geometry rules leave following to it.
    @StateObject private var gesturing = Held(false)
    /// The last content height and offset.
    @StateObject private var geometry = Held((height: CGFloat(0), offset: CGFloat(0)))

    private static let end = "agent-end"
    /// "At the bottom" within this, as in the chat.
    private static let atBottom: CGFloat = 50

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The prompt is the timeline's first row, as a user's message is the chat's:
                    // it scrolls away with the rest, and a long one folds like a long message.
                    if let prompt, !prompt.isEmpty {
                        AgentTabPrompt(text: prompt)
                            .padding(.vertical, Layout.Timeline.itemPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: Layout.Timeline.itemPadding)
                    AgentTimelineRows(chat: chat, id: id)
                    Color.clear.frame(height: Stroke.hairline).id(Self.end)
                        .storyID(StoryID.AgentTab.end)
                }
                .padding(.horizontal, column.padding)
                .padding(.top, Layout.Transcript.top)
                .padding(.bottom, Layout.Transcript.bottom)
                .frame(maxWidth: column.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollPhaseChange { old, new, context in
                gesturing.value = new != .idle
                if new == .interacting {
                    following.value = false
                } else if new == .idle, old == .interacting || old == .decelerating {
                    let g = context.geometry
                    following.value = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - Self.atBottom
                }
            }
            .onScrollGeometryChange(for: [CGFloat].self) {
                [$0.contentSize.height, $0.contentOffset.y, $0.containerSize.height]
            } action: { _, new in
                scrolled(new, proxy)
            }
        }
    }

    /// The chat transcript's rules, for a timeline that only grows: follow the end while at it,
    /// stop once the reader moves up.
    private func scrolled(_ new: [CGFloat], _ proxy: ScrollViewProxy) {
        let (height, offset, visible) = (new[0], new[1], new[2])
        // Moved up, away from the end, with no new content (the scroll bar, Page Up): stop
        // following. And back down to the end the same way: follow again.
        if following.value, height == geometry.value.height, height > visible + Self.atBottom,
            offset < geometry.value.offset - 1, offset + visible < height - 3 * Self.atBottom
        {
            following.value = false
        }
        if !following.value, !gesturing.value, offset > geometry.value.offset + 1, offset + visible >= height - Self.atBottom {
            following.value = true
        }
        // New rows (a loaded history, a running agent's), or rows measured after they were
        // placed: stay at the end while following.
        if following.value, height != geometry.value.height { proxy.scrollTo(Self.end, anchor: .bottom) }
        geometry.value = (height, offset)
    }
}

/// The agent's prompt in the user's box. A long one (from `collapseFrom` lines) shows
/// `collapsedLines` with "Show full prompt" under it, as a long message does in the chat. It starts
/// clipped, so a long brief never lays out whole until it's opened.
private struct AgentTabPrompt: View {
    let text: String
    /// The laid-out lines of the clipped text: enough to tell a long prompt from a short one.
    @StateObject private var lines = Local(0)
    @StateObject private var expanded = Local(false)

    private var long: Bool { lines.value >= Layout.Timeline.collapseFrom }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !expanded.value && (lines.value == 0 || long) {
                MessageText(
                    text: text, lines: Layout.Timeline.collapsedLines, fade: Size.collapseFade * Zoom.shared.scale,
                    ground: PanelStyle.userBox.fill ?? Theme.surface, selectable: false,
                    click: long ? { expanded.value = true } : nil
                ) { lines.value = $0 }
            } else {
                Text(text)
                    .font(TextStyle.body)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if long {
                HStack {
                    Spacer(minLength: 0)
                    MessageToggle(expanded: expanded.value, title: "Show full prompt") { expanded.value.toggle() }
                        .storyID(StoryID.AgentTab.promptToggle)
                }
                .padding(.top, Space.messageToggle)
            }
        }
        .padding(Inset.userBox)
        .panel(.userBox)
        .storyID(StoryID.AgentTab.prompt)
    }
}

/// The crumb's first link: the parent chat's logo and title.
private struct CrumbLink: View {
    let chat: Chat
    let action: () -> Void
    @StateObject private var hovered = Local(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                ProviderLogo(provider: chat.provider, size: Size.logoRow)
                Text(chat.title)
                    .font(TextStyle.label)
                    .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                    .underline(hovered.value)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Back to the chat")
    }
}
