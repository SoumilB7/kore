import SwiftUI

/// While planning, above the composer: one quiet line that lets the agent's commands run without
/// asking, so planning never waits on a card. Off, it's an offer in tertiary; on, it says so in
/// the accent. Plan's own cards (the plan, questions) still ask.
struct PlanAllowLine: View {
    let chat: Chat
    @StateObject private var hovered = Local(false)

    var body: some View {
        let on = chat.controls.planAllow
        Button { chat.setPlanAllow(!on) } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                Text(on ? "Commands run without asking while planning" : "Let commands run without asking while planning")
            }
            .font(Chrome.label)
            .foregroundStyle(on ? Theme.accent : hovered.value ? Theme.text : Theme.tertiary)
            .padding(.horizontal, Space.sm)
            .frame(height: Size.importLine)
            .background(hovered.value ? Theme.toolHover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(on ? "Commands run without asking until you turn this off" : "Runs every command without asking while planning")
        .storyID(StoryID.Composer.planAllow, press: { chat.setPlanAllow(!on) })
        .accessibilityLabel(Text("Allow commands while planning"))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
