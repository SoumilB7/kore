import SwiftUI

/// The Stay awake cup in the title row, between Agents and History. Always there: a faint
/// outline while off, a filled cup while it's on and waits for agents, steam while it holds the
/// Mac awake, and the warning point when it's paused for the battery. Every state looks its own,
/// so a click always shows what it did: on in the last mode, or off. A right-click picks the mode.
struct StayAwakeButton: View {
    let awake: StayAwake
    let size: CGFloat
    @StateObject private var hovered = Local(false)

    var body: some View {
        let state = awake.state
        // Worked out each time it's drawn: the pointer coming over it (`hovered`) does, so the
        // minutes it says are now's.
        let line = awake.line
        Button {
            awake.toggle()
        } label: {
            let look = StayAwakeLook(state)
            Image(systemName: look.symbol)
                .font(Chrome.bodyMedium)
                .foregroundStyle(hovered.value ? Theme.text : look.tone.color)
                .frame(width: size, height: size)
                .background(hovered.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(alignment: .topTrailing) {
                    if look.point {
                        Circle().fill(Theme.warning).frame(width: Size.statusPoint, height: Size.statusPoint)
                            .padding(Size.statusPointInset)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .tip(line)
        .koreContextMenu("stay-awake") { StayAwakeModes(awake: awake).items }
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

/// How the cup draws each state: off an outline in tertiary; on and waiting, filled in secondary;
/// holding, steam in secondary; paused, the outline with the warning point.
struct StayAwakeLook: Equatable {
    enum Tone: Equatable {
        case tertiary, secondary

        var color: Color { self == .tertiary ? Theme.tertiary : Theme.secondary }
    }

    let symbol: String
    let tone: Tone
    /// The warning point over its corner: paused for the battery.
    var point = false

    init(symbol: String, tone: Tone, point: Bool = false) {
        self.symbol = symbol
        self.tone = tone
        self.point = point
    }

    init(_ state: StayAwake.State) {
        switch state {
        case .off: (symbol, tone) = ("cup.and.saucer", .tertiary)
        case .waiting: (symbol, tone) = ("cup.and.saucer.fill", .secondary)
        case .holding: (symbol, tone) = ("cup.and.heat.waves", .secondary)
        case .paused: (symbol, tone, point) = ("cup.and.saucer", .tertiary, true)
        }
    }
}

/// The modes, the current one checked and a running timer's time left under it, then Turn Off:
/// the cup's right-click menu and Kore ▸ Stay Awake Mode.
@MainActor struct StayAwakeModes {
    let awake: StayAwake
    var items: [OptionItem] {
        StayAwake.Mode.allCases.map { mode in
            let current = awake.isOn && awake.mode == mode
            let left = current && mode.length != nil ? awake.timeLeft.map { " · " + $0 } ?? "" : ""
            return OptionItem(mode.title + left, checked: current) { awake.choose(mode) }
        } + [.rule, OptionItem("Turn Off", enabled: awake.isOn) { awake.turnOff() }]
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
