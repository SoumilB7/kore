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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            AgentTimeline(chat: chat, id: id)
                                .padding(.top, Layout.Timeline.itemPadding)
                        } header: {
                            if let prompt = info.prompt, !prompt.isEmpty {
                                Text(prompt)
                                    .font(TextStyle.body)
                                    .foregroundStyle(Theme.text)
                                    .textSelection(.enabled)
                                    .padding(Inset.userBox)
                                    .panel(.userBox)
                                    .padding(.vertical, Layout.Timeline.itemPadding)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.background)
                            }
                        }
                    }
                    .padding(.horizontal, column.padding)
                    .padding(.top, Layout.Transcript.top)
                    .padding(.bottom, Layout.Transcript.bottom)
                    .frame(maxWidth: column.maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom, for: .alignment)
                .onAppear { chat.loadAgentIfNeeded(id) }
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
                            AgentAvatar(index: parent.index, name: parent.name, status: parent.status, place: .crumb)
                            Text(parent.name).font(TextStyle.label).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                chevron
                AgentAvatar(index: info.index, name: info.name, status: info.status, place: .crumb)
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
            AgentAvatar(index: info.index, name: info.name, status: info.status, place: .approval)
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
