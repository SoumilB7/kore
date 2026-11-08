import Foundation
import KoreCore
import Observation
import SwiftUI

/// Each account's usage mark, shared by every window's composers (usage-limit-cues.html,
/// option A). It reads nothing itself: the backends hand it the windows a turn reports, the
/// Usage popup and the Account card the readings they make. Its dismissals live in the defaults,
/// so a click in one window hides the mark in all of them, and after a relaunch.
@MainActor @Observable
final class UsageCues {
    static let shared = UsageCues()

    /// The mark each account shows now, by `account(_:)`'s key; none is no mark.
    private(set) var shown: [String: UsageCueBook.Cue] = [:]
    /// The account each CLI's last reading came from, while the Account store has none.
    private(set) var lastAccount: [String: String] = [:]

    @ObservationIgnored private var book: UsageCueBook
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    /// Wakes as the soonest shown window resets, so its mark goes without a reading.
    @ObservationIgnored private var ending: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = clock
        book = UsageCueBook.load(defaults, now: clock())
    }

    /// The key for a CLI's account: the signed-in email's hash, else the last one read.
    func account(_ cli: String) -> String {
        if case .signedIn(let identity) = AccountStore.shared.status(cli), let hash = PlanSnapshot.account(email: identity.email) {
            return cli + ":" + hash
        }
        return lastAccount[cli] ?? cli
    }

    func cue(_ cli: String) -> UsageCueBook.Cue? { shown[account(cli)] }

    /// A turn's or a read's windows. `account`: the email's hash, nil when the source doesn't
    /// say (Codex's pushed limits), and then the CLI's signed-in one.
    func take(_ cli: String, account: String?, _ readings: [UsageCueBook.Reading]) {
        guard !readings.isEmpty else { return }
        let key = account.map { cli + ":" + $0 } ?? self.account(cli)
        if lastAccount[cli] != key { lastAccount[cli] = key }
        let dismissed = book.dismissed
        for risen in book.take(key, readings) {
            UILog.event("usage-cue-step", ["cli": cli, "limit": risen.limit.kind.rawValue, "step": String(risen.step)])
        }
        // A new window ends what was dismissed in the last: kept that way for every window too.
        if book.dismissed != dismissed { book.save(defaults) }
        update()
    }

    func take(_ cli: String, snapshot: PlanSnapshot?) {
        let account = snapshot?.account.flatMap { $0.hasPrefix("plan:") ? nil : $0 }
        take(cli, account: account, UsageCueBook.Reading.from(snapshot))
    }

    func take(_ cli: String, reading: PlanReading) {
        take(cli, account: PlanSnapshot.account(email: reading.account.email), UsageCueBook.Reading.from(reading))
    }

    /// The mark's click: hidden for this account until the next step or window, everywhere.
    func dismiss(_ cli: String) {
        for hid in book.dismiss(account(cli), now: clock()) {
            UILog.event("usage-cue-dismissed", ["cli": cli, "limit": hid.limit.kind.rawValue, "step": String(hid.step)])
        }
        book.save(defaults)
        update()
    }

    /// Back to nothing read and nothing dismissed (a storyline's start).
    func reset() {
        ending?.cancel()
        book = UsageCueBook()
        book.save(defaults)
        (shown, lastAccount) = ([:], [:])
    }

    private func update() {
        let now = clock()
        var next: [String: UsageCueBook.Cue] = [:]
        for account in book.tracks.keys {
            if let cue = book.cue(account, now: now) { next[account] = cue }
        }
        if next != shown { shown = next }
        ending?.cancel()
        guard let end = book.nextEnd(after: now) else { return }
        ending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(end.timeIntervalSince(now), 0) + 1))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }
}

/// The mark's words.
enum UsageCueText {
    /// "85%".
    static func percent(_ cue: UsageCueBook.Cue) -> String { "\(cue.step)%" }

    /// "5-hour limit", "Weekly limit", "Weekly <model> limit".
    static func limit(_ limit: UsageCueBook.Limit) -> String {
        let kind = limit.kind == .fiveHour ? "5-hour" : "Weekly"
        return [kind, limit.scope, "limit"].compactMap { $0 }.joined(separator: " ")
    }

    /// " · resets 3:40 PM", " · resets Mon 9:00 AM"; nothing without a time.
    static func resets(_ cue: UsageCueBook.Cue, now: Date) -> String {
        cue.resetsAt.map { " · resets " + StayAwake.time($0, now: now) } ?? ""
    }

    /// The hover card's line: "5-hour limit 85% · resets 3:40 PM".
    static func line(_ cue: UsageCueBook.Cue, now: Date) -> String {
        limit(cue.limit) + " " + percent(cue) + resets(cue, now: now)
    }
}

/// Left of the mode pill from 80%: the two limits' bars (5-hour over weekly) and the step, amber,
/// red at 100%. Under the pointer the bars become × and its card names the limit and its reset;
/// a click hides it until the next step.
struct UsageCueMark: View {
    let provider: String
    @StateObject private var hovered = Local(false)
    @StateObject private var carded = Local(false)

    var body: some View {
        if let cue = UsageCues.shared.cue(provider) {
            let dismiss: @MainActor () -> Void = { UsageCues.shared.dismiss(provider) }
            Button(action: dismiss) {
                HStack(spacing: Space.sm) {
                    ZStack {
                        if hovered.value {
                            Image(systemName: "xmark")
                                .font(Glyph.usageCueClose)
                                .foregroundStyle(Theme.text)
                                .storyMark(StoryID.Composer.usageCue.part(.close))
                        } else {
                            UsageCueBars(cue: cue)
                        }
                    }
                    .frame(width: Size.usageCueBars.width, height: Size.usageCueBars.height)
                    Text(UsageCueText.percent(cue))
                        .font(TextStyle.label.monospacedDigit())
                        .foregroundStyle(Theme.usageCue(cue.step))
                        .lineLimit(1)
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xs)
                .background(hovered.value ? Theme.surfaceRaised : Theme.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .onHover(perform: hover)
            .anchorPreference(key: UsageCueCardAnchor.self, value: .bounds) { carded.value ? UsageCueCardAnchor.Shown(anchor: $0, cue: cue) : nil }
            .accessibilityLabel(Text(UsageCueText.line(cue, now: Date())))
            .accessibilityHint(Text("Hides until the next 5%"))
            .storyID(StoryID.Composer.usageCue, press: dismiss)
            .storyAction(StoryID.Composer.usageCue.part(.hover)) {
                hovered.value = true
                carded.value = true
            }
            .onDisappear {
                hovered.value = false
                carded.value = false
            }
        }
    }

    private func hover(_ inside: Bool) {
        hovered.value = inside
        guard inside else {
            carded.value = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.cardDelay) { [hovered, carded] in
            MainActor.assumeIsolated { if hovered.value { carded.value = true } }
        }
    }
}

/// Two hairline bars, the 5-hour limit's over the week's, each filled as far as it's used.
private struct UsageCueBars: View {
    let cue: UsageCueBook.Cue

    var body: some View {
        VStack(spacing: Size.usageCueBarGap) {
            bar(cue.fiveHour)
            bar(cue.weekly)
        }
    }

    private func bar(_ used: Double?) -> some View {
        ZStack {
            Capsule().fill(Theme.usageCueTrack)
            if let used, used > 0 {
                SizedPath { size in
                    Path(
                        roundedRect: CGRect(x: 0, y: 0, width: max(size.width * used, size.height), height: size.height),
                        cornerRadius: size.height / 2)
                }
                .fill(Theme.usageCueBar(used))
            }
        }
        .frame(height: Size.usageCueBar)
    }
}

/// Where the mark is while its card shows, and what the card says.
struct UsageCueCardAnchor: PreferenceKey {
    struct Shown {
        let anchor: Anchor<CGRect>
        let cue: UsageCueBook.Cue
    }

    static let defaultValue: Shown? = nil
    static func reduce(value: inout Shown?, nextValue: () -> Shown?) { value = value ?? nextValue() }
}

extension View {
    /// The usage mark's card above the mark, from this view (the composer's column), so the box
    /// doesn't clip it: one opaque line, its trailing edge on the mark's.
    func usageCueCard() -> some View {
        overlayPreferenceValue(UsageCueCardAnchor.self) { shown in
            GeometryReader { geometry in
                if let shown {
                    let mark = geometry[shown.anchor]
                    UsageCueCard(cue: shown.cue)
                        .padding(.trailing, max(geometry.size.width - mark.maxX, 0))
                        .padding(.bottom, max(geometry.size.height - mark.minY + Size.contextCardGap, 0))
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// "5-hour limit 85% · resets 3:40 PM", the percent in the mark's colour.
private struct UsageCueCard: View {
    let cue: UsageCueBook.Cue

    var body: some View {
        let now = Date()
        HStack(spacing: 0) {
            Text(UsageCueText.limit(cue.limit) + " ")
            Text(UsageCueText.percent(cue)).foregroundStyle(Theme.usageCue(cue.step))
            Text(UsageCueText.resets(cue, now: now))
        }
        .font(TextStyle.label.monospacedDigit())
        .foregroundStyle(Theme.text)
        .lineLimit(1)
        .fixedSize()
        .padding(Inset.row)
        .panel(.panel)
        .storyMark(StoryID.Composer.usageCue.part(.card))
    }
}
