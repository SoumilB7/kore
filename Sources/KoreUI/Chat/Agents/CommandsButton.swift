import SwiftUI

/// The title row's ">_ 2" (agents-commands-cue.html, B): the chat's live background commands
/// (running shells, monitors, long foreground commands, armed jobs), beside the Agents button
/// or alone when there are no agents. Opens the map at them: the commands that outlived their
/// agent first, else the chat's own, else the first agent running some.
struct CommandsButton: View {
    let chat: Chat
    let height: CGFloat
    @StateObject private var hovered = Local(false)

    var body: some View {
        let summary = chat.commands.summary
        if summary.total > 0 {
            Button(action: open) {
                CommandCue(count: summary.total, dot: false)
                    .padding(.horizontal, Space.md)
                    .frame(height: height)
                    .hoverFill(hovered.value, Theme.tabHover, radius: Radius.control)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered.value = $0 }
            .help(summary.total == 1 ? "1 command in background" : "\(summary.total) commands in background")
            .accessibilityLabel(Text("Background commands"))
            .accessibilityValue(Text("\(summary.total)"))
            .storyID(StoryID.Titlebar.commands, press: open)
        }
    }

    private func open() {
        let summary = chat.commands.summary
        let map = chat.agentMap
        if summary.outlived > 0 {
            map.show(.outlived)
        } else if summary.live(.main) > 0 {
            map.show(.chat)
        } else if let id = summary.live.keys.lazy.compactMap({ if case .sub(let id) = $0 { id } else { nil } }).first {
            map.select(id)
        }
        map.open()
    }
}
