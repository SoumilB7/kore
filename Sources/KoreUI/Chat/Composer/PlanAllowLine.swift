import SwiftUI

/// While planning, above the composer: one quiet line that lets the agent's commands run without
/// asking, so planning never waits on a card. Off, it's an offer in tertiary; on, it says so in
/// the accent (secondary while a question card is up). Plan's own cards (the plan, questions) still ask.
struct PlanAllowLine: View {
    let chat: Chat
    @StateObject private var hovered = Local(false)

    var body: some View {
        let on = chat.controls.planAllow
        // While a question card is up its ticks are the only accent ones: this line goes quiet.
        let asking = chat.approvals.pending.contains { !$0.questions.isEmpty }
        Button { chat.setPlanAllow(!on) } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                Text(on ? "Commands run without asking while planning" : "Let commands run without asking while planning")
            }
            .font(Chrome.label)
            .foregroundStyle(on ? (asking ? Theme.secondary : Theme.accent) : hovered.value ? Theme.text : Theme.tertiary)
            .padding(.horizontal, Space.sm)
            .frame(height: Size.importLine)
            .background(hovered.value ? Theme.toolHover : .clear, in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("Allow commands in Plan")
        .storyID(StoryID.Composer.planAllow, press: { chat.setPlanAllow(!on) })
        .accessibilityLabel(Text("Allow commands while planning"))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
