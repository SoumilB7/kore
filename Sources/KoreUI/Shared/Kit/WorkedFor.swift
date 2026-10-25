import SwiftUI

/// A finished turn's work, folded into one line: "Worked for 1m 12s ›" (Codex's
/// collapsed-turn disclosure). The chevron turns down while the work is open. An outcome
/// ("Interrupted") follows the label, and a denied-actions count sits at the right end.
/// Only the chevron animates; the work itself appears and goes at once, so the answer below
/// doesn't move.
struct WorkedFor: View {
    let label: String
    var outcome: Outcome?
    var denied = 0
    let isOpen: Bool
    /// The turn still works: the label says what's happening (look.md §12), pulsing.
    var live = false
    /// "3 tool calls · 1 failed", after a live label.
    var count: String?
    /// The agent left the turn in another mode: " · now {mode}", the mode in its rung's colour.
    var now: ModeMark?
    let toggle: () -> Void
    @StateObject private var hovered = Local(false)

    enum Outcome: Equatable { case interrupted, failed }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.xs) {
                if live {
                    Text(label)
                        .font(TextStyle.body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .pulse(low: Motion.livePulseLow, period: Motion.livePulsePeriod, easing: .easeInEaseOut)
                    if let count {
                        Text(count).font(TextStyle.toolName).foregroundStyle(Theme.liveCount).lineLimit(1)
                            .padding(.leading, Space.sm - Space.xs)
                    }
                } else {
                    Text(label)
                        .foregroundStyle(hovered.value ? Theme.text : Theme.secondary)
                        .lineLimit(1)
                }
                Disclosure(isOpen: isOpen)
                    .foregroundStyle(hovered.value || isOpen ? Theme.secondary : Theme.tertiary)
                if let outcome {
                    Text(outcome == .interrupted ? "· Interrupted" : "· Failed")
                        .foregroundStyle(outcome == .interrupted ? Theme.secondary : Theme.danger)
                        .lineLimit(1)
                }
                if let now {
                    (Text("· now ").foregroundStyle(Theme.tertiary) + Text(now.label).foregroundStyle(now.tint ?? Theme.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: Space.xs)
                if denied > 0 {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "hand.raised").font(Glyph.small)
                        Text(denied == 1 ? "1 denied action" : "\(denied) denied actions")
                            .font(TextStyle.label)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.secondary)
                    .help("Denied this turn")
                }
            }
            .font(TextStyle.body)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .accessibilityHint(Text(isOpen ? "Hides the work" : "Shows the work"))
    }

    /// "Worked for 1m 12s"; without a duration, "N previous messages".
    static func label(duration: TimeInterval?, items: Int) -> String {
        guard let duration else { return items == 1 ? "1 previous message" : "\(items) previous messages" }
        return "Worked for \(Self.duration(duration))"
    }

    /// 40s · 1m 12s · 1h 3m; at least 1s.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// The disclosure chevron: right when closed, down when open, turning over `Motion.fade`.
struct Disclosure: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(Glyph.chevron)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .frame(width: Size.disclosure, height: Size.disclosure)
            .animation(Motion.fade, value: isOpen)
    }
}

/// A horizontal hairline: between a turn's work and its answer, above a card's lane.
struct Rule: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: Stroke.hairline)
    }
}
