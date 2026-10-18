import SwiftUI

/// The title row's Agents button (look.md §10, §11): the chat's agents as a stack of avatars, or
/// one track round the running ones, a count, and a point when one waits for the user (amber) or
/// has failed unseen (red). Hidden until the chat has spawned an agent. Opens and closes the
/// agent map (⇧⌘A).
struct AgentsButton: View {
    let chat: Chat
    let height: CGFloat
    @StateObject private var hovered = Local(false)

    var body: some View {
        let summary = chat.transcript.agentSummary
        if summary.count > 0 {
            let running = !summary.running.isEmpty
            let stack = Array((running ? summary.running : summary.first).prefix(3))
            Button {
                chat.agentMap.toggle()
            } label: {
                HStack(spacing: Space.sm) {
                    if running {
                        RunningTrack(indexes: stack.map(\.index))
                    } else {
                        HStack(spacing: -Size.avatarOverlap) {
                            ForEach(stack) { agent in
                                AgentAvatar(
                                    index: agent.index, name: agent.name, status: agent.status, place: .stack)
                                    .opacity(Theme.dimmed)
                            }
                        }
                    }
                    Text(running ? "\(summary.running.count) running" : summary.count == 1 ? "1 agent" : "\(summary.count) agents")
                        .font(Chrome.labelDigits)
                        .foregroundStyle(running ? Theme.text : Theme.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, Space.md)
                .frame(height: height)
                .hoverFill(hovered.value || chat.agentMap.isOpen, chat.agentMap.isOpen ? Theme.surface : Theme.tabHover,
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
            .help("Agent map (⇧⌘A)")
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
        return summary.running.isEmpty ? (summary.count == 1 ? "1 agent" : "\(summary.count) agents") : "Agents are working"
    }
}
