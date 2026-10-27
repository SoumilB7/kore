import AppKit
import KoreCore
import SwiftUI

/// Compact plan totals below a login. Missing, loading and inaccessible readings have words,
/// never an empty bar labelled zero; Kore's attributed share stays in the full Usage card.
struct LoginMeters: View {
    let state: LoginUsage.State
    let signedOut: Bool
    let now: Date
    /// The card's longest limit name (`labelWidth`): every login's bars start in one place.
    var labelWidth: CGFloat = Size.usageTitleMax

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if signedOut {
                note("Sign in to see usage")
            } else {
                switch state {
                case .loading: reading
                case .unavailable: note("Usage unavailable")
                case .ready(let reading, let at):
                    let bars = LoginUsage.bars(reading)
                    if bars.isEmpty {
                        switch reading.account.access {
                        case .perToken: note("Billed per token")
                        default: note("Usage unavailable")
                        }
                    } else {
                        ForEach(bars, id: \.title) { bar in
                            // The reset beside its limit's name, "Session (3h)": every login's bars
                            // start and end in the same place, whatever their resets say.
                            HStack(spacing: Space.md) {
                                Text(Self.title(bar, now: now))
                                    .monospacedDigit()
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(width: labelWidth, alignment: .leading)
                                UsageBar(fraction: UsageText.fraction(bar.used), kore: 0, hatch: 0)
                                    .frame(minWidth: Size.usageBarMin, maxWidth: .infinity)
                                // As wide as "100%" whatever it says, so the bars end together.
                                Text("100%").hidden()
                                    .overlay(alignment: .trailing) {
                                        // The fact read: a step brighter than its name.
                                        Text(UsageText.percent(bar.used)).foregroundStyle(Theme.secondary)
                                    }
                                    .monospacedDigit().fixedSize()
                            }
                            .help([UsageText.resetsAt(bar.resetsAt, now: now), UsageText.stamp(at, now: now)].compactMap { $0 }.joined(separator: " · "))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(["\(UsageText.label(bar.title)), \(UsageText.percent(bar.used)) used", UsageText.resets(bar.resetsAt, now: now)].filter { !$0.isEmpty }.joined(separator: ", "))
                        }
                    }
                }
            }
        }
        .font(TextStyle.caption)
        .foregroundStyle(Theme.tertiary)
    }

    /// A limit's name with its reset beside it: "Session (3h)", "Weekly (3d)"; the name alone
    /// without a reset time.
    static func title(_ bar: PlanLimit, now: Date) -> String {
        let reset = UsageText.resetsShort(bar.resetsAt, now: now)
        return UsageText.label(bar.title) + (reset.isEmpty ? "" : " (\(reset))")
    }

    /// While the reading comes: the two rows as they'll stand, their bars hatched.
    private var reading: some View {
        ForEach(["Session", "Weekly"], id: \.self) { title in
            HStack(spacing: Space.md) {
                Text(title).lineLimit(1).frame(width: labelWidth, alignment: .leading)
                UsageBar(fraction: 0, kore: 1, hatch: 1)
                    .frame(minWidth: Size.usageBarMin, maxWidth: .infinity)
                Text("100%").hidden().monospacedDigit().fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), reading usage")
        }
    }

    /// As wide as the longest limit name these logins show, at the caption's size (at most
    /// `Size.usageTitleMax`), so the bars start together and get the rest of the row.
    static func labelWidth(_ states: [LoginUsage.State], now: Date) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let widest = states.flatMap { state -> [PlanLimit] in
            if case .ready(let reading, _) = state { return LoginUsage.bars(reading) }
            return []
        }
        .map { title($0, now: now) }
        // The loading rows' names too, so a card still reading doesn't squeeze them.
        .appending(contentsOf: ["Session", "Weekly"])
        .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(ceil(widest) + 1, Size.usageTitleMax)
    }

    private func note(_ words: String) -> some View {
        Text(words).lineLimit(1).truncationMode(.tail)
    }
}
