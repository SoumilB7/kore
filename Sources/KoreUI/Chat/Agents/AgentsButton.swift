import SwiftUI

/// The title row's Agents button (look.md §10, §11): the chat's agents as a stack of avatars, or
/// one track round the running ones, a count, and a point when one waits for the user (amber) or
/// has failed unseen (red). It counts every agent, the stopped ones too, as the map's header
/// does: a number, as ">_ 2" beside it, the noun in its hover name. Hidden until the chat has
/// spawned an agent; its background commands have their own button beside it (`CommandsButton`).
/// Opens and closes the agent map (⇧⌘A).
struct AgentsButton: View {
    let chat: Chat
    let height: CGFloat
    @StateObject private var hovered = Local(false)

    var body: some View {
        let summary = chat.transcript.agentSummary
        let agents = summary.total > 0
        if agents {
            let running = !summary.running.isEmpty
            let filled = hovered.value || chat.agentMap.isOpen
            let stack = Array((running ? summary.running : summary.first).prefix(3))
            Button {
                chat.agentMap.toggle()
            } label: {
                HStack(spacing: Space.sm) {
                    if running {
                        // On the button's fill the marks stand alone, no capsule within it.
                        RunningTrack(indexes: stack.map(\.index), background: stack.allSatisfy(\.background), bare: filled)
                    } else {
                        HStack(spacing: -Size.avatarOverlap) {
                            ForEach(stack) { agent in
                                AgentAvatar(
                                    index: agent.index, name: agent.name, status: agent.status,
                                    background: agent.background, place: .title)
                                    .opacity(Theme.dimmed)
                            }
                        }
                    }
                    Text("\(Self.count(summary))")
                        .font(Chrome.labelDigits)
                        .foregroundStyle(running ? Theme.text : Theme.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, Space.md)
                .frame(height: height)
                .hoverFill(filled, chat.agentMap.isOpen ? Theme.surface : Theme.tabHover,
                           radius: Radius.control)
                .overlay(alignment: .topTrailing) {
                    if let point = point(summary) {
                        Circle().fill(point).frame(width: Size.statusPoint, height: Size.statusPoint)
                            .padding(Size.statusPointInset)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered.value = $0 }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("\(Self.label(summary)) (⇧⌘A)")
            .accessibilityLabel(Text("Agent map"))
            .accessibilityValue(Text(help(summary)))
        }
    }

    private func unseenFailure(_ summary: TranscriptStore.AgentSummary) -> Bool {
        summary.failed.contains { !chat.agentMap.seenFailures.contains($0) }
    }

    /// Waiting wins over failed.
    private func point(_ summary: TranscriptStore.AgentSummary) -> Color? {
        if summary.waiting { return Theme.warning }
        return unseenFailure(summary) ? Theme.danger : nil
    }

    /// The Claude extension's indicator wording.
    private func help(_ summary: TranscriptStore.AgentSummary) -> String {
        if summary.waiting { return "An agent is waiting for your permission" }
        if unseenFailure(summary) { return "An agent failed" }
        return summary.running.isEmpty ? Self.label(summary) : "Agents are working"
    }

    /// The number the button shows: the running agents; else every one, or the stopped ones
    /// when every agent stopped.
    static func count(_ summary: TranscriptStore.AgentSummary) -> Int {
        if !summary.running.isEmpty { return summary.running.count }
        return summary.count == 0 ? summary.stopped : summary.total
    }

    /// Its hover name: "2 running"; else "3 agents", every one, or "2 stopped" when every agent
    /// stopped.
    static func label(_ summary: TranscriptStore.AgentSummary) -> String {
        if !summary.running.isEmpty { return "\(summary.running.count) running" }
        if summary.count == 0 { return "\(summary.stopped) stopped" }
        return summary.total == 1 ? "1 agent" : "\(summary.total) agents"
    }
}
