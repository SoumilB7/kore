import SwiftUI

/// Beside Send while the chat is at its plan's limit, the reset still ahead, and something is
/// typed (send-at-reset.html, option C reversed): the arrow in a ring of dots, nothing else. A
/// click sets the draft to go when the limit resets and turns Stay awake on until then; set, the
/// ring starts all blue and loses a dot as each twelfth of the wait goes by (the notice says
/// when), and a click takes the message back to the draft. Otherwise there's nothing here.
struct ResetSendButton: View {
    let chat: Chat
    @StateObject private var hovered = Local(false)

    var body: some View {
        let waiting = chat.sendsAtReset
        if let at = waiting != nil ? (chat.continuesAt ?? chat.limitReset?.at) : chat.limitReset?.at,
            waiting != nil || chat.canSendAtReset
        {
            TimelineView(.periodic(from: .now, by: Self.tick)) { context in
                let now = context.date
                // A reset that has passed leaves nothing to wait for.
                if waiting != nil || at > now {
                    button(at: at, now: now, waiting: waiting?.since)
                }
            }
        }
    }

    private func button(at: Date, now: Date, waiting since: Date?) -> some View {
        let time = StayAwake.time(at, now: now)
        let press = { since == nil ? chat.sendAtReset() : chat.cancelContinue() }
        return Button(action: press) {
            ResetRing(lit: since.map { Self.left(since: $0, at: at, now: now) } ?? 0)
                .foregroundStyle(since != nil ? Theme.accent : hovered.value ? Theme.text : Theme.secondary)
                .frame(width: Size.iconButton, height: Size.iconButton)
                .hoverFill(hovered.value)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help(since == nil ? "Send at \(time), when the limit resets\nKeeps the Mac awake until then" : "Sends at \(time) · click to take it back")
        .accessibilityLabel(Text(since == nil ? "Send when the limit resets" : "Waiting to send"))
        .accessibilityValue(Text(time))
        .storyID(StoryID.Composer.sendAtReset, press: press)
        .padding(.trailing, Space.md)
    }

    /// Often enough for the dots: a twelfth of an hour's wait is five minutes.
    private static let tick: TimeInterval = 15

    /// The dots still blue, of the ring's twelve: all at the start, none at the reset.
    static func left(since: Date, at: Date, now: Date) -> Int {
        let whole = at.timeIntervalSince(since)
        guard whole > 0 else { return 0 }
        let left = min(max(at.timeIntervalSince(now) / whole, 0), 1)
        return Int((left * Double(Size.resetRingDots)).rounded(.up))
    }
}

/// Twelve dots round the arrow, the first `lit` of them (clockwise from the top) in the accent:
/// an unset timer when none are.
private struct ResetRing: View {
    let lit: Int

    var body: some View {
        ZStack {
            ForEach(0..<Size.resetRingDots, id: \.self) { i in
                Circle()
                    .fill(i < lit ? Theme.accent : Theme.tertiary)
                    .frame(width: Size.resetRingDot, height: Size.resetRingDot)
                    .offset(y: -(Size.resetRing - Size.resetRingDot) / 2)
                    .rotationEffect(.degrees(Double(i) * 360 / Double(Size.resetRingDots)))
            }
            Image(systemName: "arrow.up").font(Glyph.resetArrow)
        }
        .frame(width: Size.resetRing, height: Size.resetRing)
        .accessibilityHidden(true)
    }
}
