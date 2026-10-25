import KoreCore
import SwiftUI

/// Compact plan totals below a login. Missing, loading and inaccessible readings have words,
/// never an empty bar labelled zero; Kore's attributed share stays in the full Usage card.
struct LoginMeters: View {
    let state: LoginUsage.State
    let signedOut: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if signedOut {
                note("Sign in to see usage")
            } else {
                switch state {
                case .loading: note("Reading usage…")
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
                            let reset = UsageText.resets(bar.resetsAt, now: now)
                            HStack(spacing: Space.sm) {
                                Text(UsageText.label(bar.title))
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(maxWidth: Size.usageTitleMax, alignment: .leading)
                                UsageBar(fraction: UsageText.fraction(bar.used), kore: 0, hatch: 0)
                                    .frame(minWidth: Size.usageBarMin, maxWidth: .infinity)
                                Text(UsageText.percent(bar.used))
                                    .monospacedDigit().fixedSize()
                                if !reset.isEmpty {
                                    Text(reset).monospacedDigit().fixedSize()
                                }
                            }
                            .help([UsageText.resetsAt(bar.resetsAt, now: now), UsageText.stamp(at, now: now)].compactMap { $0 }.joined(separator: " · "))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(["\(UsageText.label(bar.title)), \(UsageText.percent(bar.used)) used", reset].filter { !$0.isEmpty }.joined(separator: ", "))
                        }
                    }
                }
            }
        }
        .font(TextStyle.caption)
        .foregroundStyle(Theme.tertiary)
    }

    private func note(_ words: String) -> some View {
        Text(words).lineLimit(1).truncationMode(.tail)
    }
}
