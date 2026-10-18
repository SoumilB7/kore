import SwiftUI

/// The Stay awake cup in the title row, between Agents and History. Always there: faint while
/// off, steam while it holds the Mac awake, a cold cup while it waits for agents, and the
/// warning point when it's paused for the battery. A click turns it on in the last mode or off;
/// a right-click picks the mode.
struct StayAwakeButton: View {
    let awake: StayAwake
    let size: CGFloat
    @StateObject private var hovered = Local(false)

    var body: some View {
        let state = awake.state
        let line = awake.line
        Button {
            awake.toggle()
        } label: {
            Image(systemName: state == .holding ? "cup.and.heat.waves" : "cup.and.saucer")
                .font(Chrome.bodyMedium)
                .foregroundStyle(hovered.value ? Theme.text : state == .holding ? Theme.secondary : Theme.tertiary)
                .frame(width: size, height: size)
                .background(hovered.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(alignment: .topTrailing) {
                    if case .paused = state {
                        Circle().fill(Theme.warning).frame(width: Size.statusPoint, height: Size.statusPoint)
                            .padding(Size.statusPointInset)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(line)
        .contextMenu { StayAwakeModes(awake: awake) }
        .accessibilityLabel(Text("Stay awake"))
        .accessibilityValue(Text(line))
        .background {
            // The menu's items, for storylines (a native menu has no views of its own to press).
            ForEach(StayAwake.Mode.allCases) { mode in
                Color.clear.storyAction(StoryID.Titlebar.awakeMode(mode.id)) { awake.choose(mode) }
            }
            Color.clear.storyAction(StoryID.Titlebar.awakeMode("off")) { awake.turnOff() }
        }
    }
}

/// The modes, the current one checked and a running timer's time left under it, then Turn Off:
/// the cup's right-click menu and Kore ▸ Stay Awake Mode.
struct StayAwakeModes: View {
    let awake: StayAwake

    var body: some View {
        ForEach(StayAwake.Mode.allCases) { mode in
            let current = awake.isOn && awake.mode == mode
            Toggle(isOn: Binding(get: { current }, set: { _ in awake.choose(mode) })) {
                Text(mode.title)
                if current, mode.length != nil, let left = awake.timeLeft { Text(left) }
            }
        }
        Divider()
        Button("Turn Off") { awake.turnOff() }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(!awake.isOn)
    }
}

/// Kore ▸ Stay Awake ⌥⌘A, checked while on, and its modes, right after About Kore.
struct StayAwakeCommands: View {
    var body: some View {
        if let awake = StayAwake.current {
            Divider()
            Toggle("Stay Awake", isOn: Binding(get: { awake.isOn }, set: { _ in awake.toggle() }))
                .keyboardShortcut("a", modifiers: [.command, .option])
            Menu("Stay Awake Mode") {
                ForEach(StayAwake.Mode.allCases) { mode in
                    Toggle(mode.title, isOn: Binding(get: { awake.isOn && awake.mode == mode }, set: { _ in awake.choose(mode) }))
                }
            }
        }
    }
}
