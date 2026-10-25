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
                case .idle: hatched("usage not read").opacity(0.5)
                case .loading: hatched("reading usage")
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
                            // The Usage popup's form: the limit's name, then "↻ 3h" at the row's
                            // end. Every login's bars start and end in the same place, whatever
                            // their resets say.
                            HStack(spacing: Space.md) {
                                Text(UsageText.label(bar.title))
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
                                reset(UsageText.resetsShort(bar.resetsAt, now: now))
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

    /// A limit's reset as its row's end reads: "↻ 3h", "↻ 3d"; nothing without a reset time.
    static func reset(_ bar: PlanLimit, now: Date) -> String {
        let reset = UsageText.resetsShort(bar.resetsAt, now: now)
        return reset.isEmpty ? "" : "↻ \(reset)"
    }

    /// The row's end: ↻ and the reset, as wide as "88m" whatever it says (blank without one), so
    /// every row's bar ends in the same place.
    private func reset(_ short: String) -> some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: "arrow.clockwise").font(Glyph.chevron)
            Text("88m").hidden()
                .overlay(alignment: .leading) { Text(short) }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .opacity(short.isEmpty ? 0 : 1)
    }

    /// While the reading comes: the two rows as they'll stand, their bars hatched. Fainter, a
    /// login not in use that isn't read until its row is hovered: the row's height never moves.
    private func hatched(_ said: String) -> some View {
        ForEach(["Session", "Weekly"], id: \.self) { title in
            HStack(spacing: Space.md) {
                Text(title).lineLimit(1).frame(width: labelWidth, alignment: .leading)
                UsageBar(fraction: 0, kore: 1, hatch: 1)
                    .frame(minWidth: Size.usageBarMin, maxWidth: .infinity)
                Text("100%").hidden().monospacedDigit().fixedSize()
                reset("")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(said)")
        }
    }

    /// As wide as the longest limit name these logins show, at the caption's size (at most
    /// `Size.usageTitleMax`), so the bars start together and get the rest of the row.
    static func labelWidth(_ states: [LoginUsage.State], now: Date) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let names = states.flatMap { state -> [PlanLimit] in
            if case .ready(let reading, _) = state { return LoginUsage.bars(reading) }
            return []
        }
        .map { UsageText.label($0.title) }
        // The loading rows' names too: the column doesn't move as readings arrive.
        let widest = Set(names + ["Session", "Weekly"]).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(ceil(widest) + 2, Size.usageTitleMax)
    }

    private func note(_ words: String) -> some View {
        Text(words).lineLimit(1).truncationMode(.tail)
    }
}
