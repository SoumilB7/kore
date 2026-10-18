import AppKit
import KoreCore
import Observation
import SwiftUI

/// The usage popup's state in one chat: open or not, and what it shows. Each open reads once
/// through the chat's CLI; nothing runs while it's closed. The last reading of each provider is
/// kept (in memory) and shown at once on the next open, stamped "as of", while the new one loads.
@MainActor @Observable
final class UsageState {
    enum Status: Equatable {
        case loading
        case fresh
        /// The read failed: the last limits show dimmed, under the reason (the CLI's words, if any).
        case unavailable(String?)
    }

    /// Using a full reset (Codex): it never goes on one click.
    enum ResetStep: Hashable {
        /// Its row asks first.
        case asking
        case using
        /// Used; the row says so until the popup closes.
        case reset
        /// What came of it otherwise, in Codex's words; `spent` when the reset is gone.
        case said(String, spent: Bool)
        /// The request failed: a plain line, and it can be tried again.
        case failed(String)
    }

    private(set) var isOpen = false
    private(set) var status = Status.loading
    /// Whether the full resets' section is unfolded; every open starts folded.
    private(set) var resetsOpen = false
    /// Each reset row's step, by credit id (nil: the row of a count alone, where Codex picks).
    /// One row asks at a time; a row's outcome stays until the popup closes.
    private(set) var resetSteps: [String?: ResetStep] = [:]
    /// The limits are being read again after a reset.
    private(set) var rereading = false
    /// The rows as they were when a reset was sent: a used row keeps its place until the popup
    /// closes, though the reading after it no longer lists it, so no row moves under the pointer.
    private var held: [ResetRow] = []
    /// What shows: the reading just made, or the last one while it loads (or after it failed).
    private(set) var reading: PlanReading?
    /// When `reading`'s limits were read.
    private(set) var readAt: Date?
    /// Each open's own number: a read that lands after a close, or after the next open, is
    /// only kept for next time.
    @ObservationIgnored private var serial = 0
    /// When a row last asked (system uptime): a "Yes" within a double-click of it is the
    /// "Use" click's second half, and is ignored.
    @ObservationIgnored private var askedAt: TimeInterval = 0
    @ObservationIgnored private var patienceTimer: Task<Void, Never>?
    @ObservationIgnored private var provider = ""
    @ObservationIgnored private var read: (@MainActor () async throws -> PlanReading)?
    @ObservationIgnored private var consume: (@MainActor (String?, UUID) async throws -> PlanResetOutcome)?

    /// Each provider's last reading, and when it was made.
    private static var kept: [String: (reading: PlanReading, at: Date)] = [:]
    /// A read the CLI never answers stops showing a spinner after this.
    private static let patience: Duration = .seconds(35)

    func open(
        provider: String, read: @escaping @MainActor () async throws -> PlanReading,
        useReset: @escaping @MainActor (String?, UUID) async throws -> PlanResetOutcome
    ) {
        serial += 1
        let open = serial
        isOpen = true
        status = .loading
        (resetsOpen, resetSteps, rereading, held) = (false, [:], false, [])
        (self.provider, self.read, self.consume) = (provider, read, useReset)
        let last = Self.kept[provider]
        (reading, readAt) = (last?.reading, last?.at)
        Task { [weak self] in
            let outcome: Result<PlanReading, any Error>
            do { outcome = .success(try await read()) } catch { outcome = .failure(error) }
            if case .success(let new) = outcome, new.limits != nil || new.account.access != .plan {
                Self.kept[provider] = (new, Date())
            }
            guard let self, self.serial == open else { return }
            self.land(outcome, last: last)
        }
        patienceTimer?.cancel()
        patienceTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard let self, !Task.isCancelled, self.serial == open, self.status == .loading else { return }
            self.status = .unavailable(nil)
        }
    }

    func close() {
        guard isOpen else { return }
        serial += 1
        isOpen = false
        patienceTimer?.cancel()
    }

    /// The count of full resets, clicked: unfolds the list, or folds it and drops a question.
    /// A reset being sent goes on; its outcome waits in its row.
    func toggleResets() {
        resetsOpen.toggle()
        if !resetsOpen { cancelReset() }
    }

    /// Esc, one step back: a row's question, then the section. False when there's neither, and
    /// the popup closes.
    func stepBack() -> Bool {
        if resetSteps.values.contains(.asking) {
            cancelReset()
        } else if resetsOpen {
            resetsOpen = false
        } else {
            return false
        }
        return true
    }

    /// A row's "Use": that row asks first, and any other row's question is dropped.
    func askReset(_ id: String?) {
        guard !resetsBusy else { return }
        cancelReset()
        resetSteps[id] = .asking
        askedAt = ProcessInfo.processInfo.systemUptime
    }

    func cancelReset() {
        resetSteps = resetSteps.filter { $0.value != .asking }
    }

    /// Whether "Yes" would go: a double-click's time has passed since the row asked.
    var confirmable: Bool { ProcessInfo.processInfo.systemUptime - askedAt >= NSEvent.doubleClickInterval }

    /// A reset is being sent, or the limits read again after one: no other "Use" goes.
    var resetsBusy: Bool { rereading || resetSteps.values.contains(.using) }

    /// Confirmed: uses the asking row's reset (Codex picks for a count alone), then reads the
    /// limits again so the bars and the count show it. Once sent it's done whether or not the
    /// popup stays open; a read that lands after a close is only kept for next time.
    func useReset() {
        // The asking row's credit; nil (the row of a count alone) lets Codex pick.
        guard let asking = resetSteps.first(where: { $0.value == .asking }), confirmable, !resetsBusy, let consume, let read else { return }
        let credit = asking.key
        if held.isEmpty { held = resetRows }
        resetSteps[credit] = .using
        let (open, provider) = (serial, provider)
        Task { [weak self] in
            let step: ResetStep
            do {
                let outcome = try await consume(credit, UUID())
                let said = UsageText.said(outcome) ?? ""
                switch outcome {
                case .reset: step = .reset
                case .noCredit, .alreadyRedeemed: step = .said(said, spent: true)
                case .nothingToReset, .other: step = .said(said, spent: false)
                }
            } catch {
                step = .failed(UsageText.resetFailed(error))
            }
            guard let self, self.serial == open else {
                if let new = try? await read(), new.limits != nil { Self.kept[provider] = (new, Date()) }
                return
            }
            (self.resetSteps[credit], self.rereading) = (step, true)
            let new = try? await read()
            if let new, new.limits != nil { Self.kept[provider] = (new, Date()) }
            guard self.serial == open else { return }
            if let new, new.limits != nil { (self.reading, self.readAt, self.status) = (new, Date(), .fresh) }
            self.rereading = false
        }
    }

    /// The section's rows: each listed credit, or one row for a count alone. Once a reset is
    /// sent, the rows keep their order and a used one its place.
    var resetRows: [ResetRow] {
        let listed = reading?.limits?.resets.map { resets in resets.credits?.map(ResetRow.init) ?? [ResetRow(credit: nil)] } ?? []
        guard !held.isEmpty else { return listed }
        let kept = held.compactMap { row in listed.first { $0.id == row.id } ?? (resetSteps[row.id] == nil ? nil : row) }
        return kept + listed.filter { row in !held.contains { $0.id == row.id } }
    }

    private func land(_ outcome: Result<PlanReading, any Error>, last: (reading: PlanReading, at: Date)?) {
        switch outcome {
        case .success(let new) where new.limits != nil || new.account.access != .plan:
            (reading, readAt, status) = (new, Date(), .fresh)
        case .success(let new):
            // The account as it is now, over the last limits read.
            reading = PlanReading(account: new.account, limits: last?.reading.limits)
            status = .unavailable(new.reason)
        case .failure(let error):
            status = .unavailable(PlanReading.reason(of: error))
        }
    }

    /// The popup's bars, each as one line, then the unfolded resets' rows, for a storyline's
    /// checks ("Weekly limit · 6% · Resets in 4d", "Full reset · Expires in 6d").
    var lines: [String] {
        let now = Date()
        let bars = (reading?.limits?.bars ?? []).map { bar in
            [bar.title, UsageText.percent(bar.used), UsageText.resets(bar.resetsAt, now: now)].joined(separator: " · ")
        }
        guard resetsOpen else { return bars }
        return bars + resetRows.map { row in [row.title, resetDetail(row, now: now)].joined(separator: " · ") }
    }

    /// What a row says after its title.
    private func resetDetail(_ row: ResetRow, now: Date) -> String {
        switch resetSteps[row.id] {
        case .asking: "Use this reset?"
        case .using: UsageText.resetting
        case .reset: UsageText.didReset
        case .said(let words, _), .failed(let words): words
        case nil where row.credit?.redeeming == true: UsageText.resetting
        case nil: row.credit.map { UsageText.expires($0.expiresAt, now: now) } ?? "\(reading?.limits?.resets?.available ?? 0) available"
        }
    }
}

/// One row of the full resets: a listed credit, or (nil) the one Codex picks from a count alone.
struct ResetRow: Equatable {
    let credit: PlanReset?

    var id: String? { credit?.id }
    var title: String { credit?.title ?? "Full reset" }
}

extension PlanReading {
    /// An error as the reason line's words: a readable message, never raw JSON.
    static func reason(of error: any Error) -> String? {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        guard let line = message.split(whereSeparator: \.isNewline).first.map(String.init),
            !line.hasPrefix("{"), !line.hasPrefix("[")
        else { return nil }
        return line
    }
}

/// The popup's wording.
enum UsageText {
    /// Whole percents, rounded down: 29.9% used is "29%".
    static func percent(_ used: Double) -> String { "\(Int(max(used, 0).rounded(.down)))%" }

    /// How much of the bar fills.
    static func fraction(_ used: Double) -> Double { min(max(used / 100, 0), 1) }

    /// "Resets in 3h", "Resets in 12m", "Resets in 6d", "Resets soon"; nothing without a time.
    static func resets(_ date: Date?, now: Date) -> String {
        let short = resetsShort(date, now: now)
        return short.isEmpty ? "" : short == "now" ? "Resets soon" : "Resets in \(short)"
    }

    /// The row's reset after its ↻: "12m", "3h", "6d", "now" under a minute; nothing without a time.
    static func resetsShort(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return "\(hours)h" }
        return "\(Int((seconds / 86400).rounded()))d"
    }

    /// The row's tooltip, the reset as a clock time: "Resets today 4:10 PM", "Resets Thu 9:00 AM"
    /// within the week, "Resets Nov 10" past it; nothing without a time.
    static func resetsAt(_ date: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent)
        -> String
    {
        guard let date else { return "" }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Resets today \(time)" }
        let week = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now
        if date > now, date < week { return "Resets \(date.formatted(style.weekday(.abbreviated))) \(time)" }
        return "Resets \(date.formatted(style.month(.abbreviated).day()))"
    }

    /// "as of 4 min ago"; nil for a reading under a minute old.
    static func stamp(_ readAt: Date?, now: Date) -> String? {
        guard let readAt else { return nil }
        let minutes = Int(now.timeIntervalSince(readAt) / 60)
        if minutes < 1 { return nil }
        if minutes < 60 { return "as of \(minutes) min ago" }
        if minutes < 24 * 60 { return "as of \(minutes / 60) h ago" }
        return "as of \(minutes / (24 * 60)) d ago"
    }

    /// The plan name's tooltip: "you@example.com", with " · Acme Labs" only for an org that says
    /// more than the address (not a personal "you@example.com's Organization").
    static func who(_ account: PlanAccount) -> String {
        let email = account.email ?? ""
        let org = account.organization.flatMap { distinct($0, from: email) ? $0 : nil }
        return [email, org ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func distinct(_ org: String, from email: String) -> Bool {
        let org = org.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let email = email.lowercased()
        return !org.isEmpty && org != email && org != email + "'s organization"
    }

    /// A limit's title as the row shows it, without its window in brackets or the word "limit":
    /// "Session (5hr)" is "Session", "Weekly limit · gpt-6-luna" "Weekly · gpt-6-luna". Codex's
    /// bare "Limit" stays.
    static func label(_ title: String) -> String {
        var label = title
        if let open = label.range(of: " ("), let close = label[open.upperBound...].firstIndex(of: ")") {
            label.removeSubrange(open.lowerBound...close)
        }
        if label.hasSuffix(" limit") {
            label.removeLast(" limit".count)
        } else if let limit = label.range(of: " limit · ") {
            label.replaceSubrange(limit, with: " · ")
        }
        return label.isEmpty ? title : label
    }

    /// A full reset's expiry: "Expires in 6d" within the week (rounded as `resetsShort` rounds),
    /// "Expires Nov 7, 5:07 AM" past it (with the year when it isn't this one); Codex's words
    /// for one that never expires and for one Kore can't read.
    static func expires(_ date: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent)
        -> String
    {
        guard let date else { return "Does not expire" }
        guard date != PlanReset.unreadable else { return "Expiration unavailable" }
        if date.timeIntervalSince(now) < 7 * 86400 {
            let short = resetsShort(date, now: now)
            return short == "now" ? "Expires soon" : "Expires in \(short)"
        }
        return "Expires " + day(date, now: now, calendar: calendar, locale: locale, weekday: false)
    }

    /// A full reset's row tooltip, the exact time in local time: "Expires Fri, Oct 30, 12:41 AM".
    static func expiresAt(_ date: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent)
        -> String
    {
        guard let date, date != PlanReset.unreadable else { return expires(date, now: now) }
        return "Expires " + day(date, now: now, calendar: calendar, locale: locale, weekday: true)
    }

    /// "Nov 7, 5:07 AM", "Sat, Nov 7, 5:07 AM", "Nov 7, 2027, 5:07 AM".
    private static func day(_ date: Date, now: Date, calendar: Calendar, locale: Locale, weekday: Bool) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        var day = style.month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return [weekday ? date.formatted(style.weekday(.abbreviated)) : nil, date.formatted(day), date.formatted(style.hour().minute())]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// A reset's row while it's sent.
    static let resetting = "Resetting your usage…"
    /// A reset's row once the limits were reset.
    static let didReset = "Usage reset."

    /// A reset's outcome in Codex's own words; nil when the limits were reset.
    static func said(_ outcome: PlanResetOutcome) -> String? {
        switch outcome {
        case .reset: nil
        case .nothingToReset: "Your usage does not need a reset right now."
        case .noCredit: "No usage limit resets are available."
        case .alreadyRedeemed: "That reset is no longer available."
        case .other: "Couldn't reset usage. Please try again."
        }
    }

    /// A reset that failed: the CLI's reason in a line, never raw JSON.
    static func resetFailed(_ error: any Error) -> String {
        PlanReading.reason(of: error).map { "Couldn't reset usage: \($0)" } ?? "Couldn't reset usage. Please try again."
    }

    /// "Credits 47,162 · 2 full resets available".
    static func extras(_ extras: [PlanExtra]) -> String {
        extras.map { [$0.key, $0.value].compactMap { $0 }.joined(separator: " ") }.joined(separator: " · ")
    }
}

/// The / menu's Usage, in the menu's place over the chat (A · Ledger in usage-popup-calm.html):
/// a card at most `usagePopupMax` wide at the composer's leading edge. The plan name (the account
/// on hover), the freshness and the ↗ to manage usage, then one row per limit (title, bar,
/// percent, ↻ reset), then one caption of extras. Opaque, no shadow. Esc closes it and goes no
/// further; a click outside or typing closes it and goes on, so the composer keeps focus
/// throughout (the context card's monitor pattern).
struct UsagePopup: View {
    let state: UsageState
    let wording: UsageWording
    /// The most it may be tall: the room above the composer.
    let room: CGFloat
    @StateObject private var frame = Held(CGRect.zero)
    @StateObject private var window = Held<NSWindow?>(nil)
    @StateObject private var monitor = Held<Any?>(nil)

    var body: some View {
        ScrollView {
            content
                .padding(Inset.well)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: room)
        .fixedSize(horizontal: false, vertical: true)
        .panel(.panel)
        .frame(maxWidth: Size.usagePopupMax)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .background(WindowReader { window.value = $0 })
        .storyID(StoryID.Composer.usage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { handle($0) }
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
        }
    }

    @ViewBuilder private var content: some View {
        let account = state.reading?.account
        switch account?.access {
        case .signedOut:
            Text(wording.signedOut).font(TextStyle.label).foregroundStyle(Theme.text)
        case .perToken(let line):
            VStack(alignment: .leading, spacing: Space.md) {
                header(account)
                Text(line).font(TextStyle.caption).foregroundStyle(Theme.secondary)
            }
        case .plan, nil:
            VStack(alignment: .leading, spacing: 0) {
                // Before any reading the header waits for one; with none ever read, only the reason shows.
                if account != nil || state.status == .loading { header(account) }
                limits
            }
        }
    }

    // MARK: Header

    /// The plan, the freshness and the ↗, as high as the ↗.
    private func header(_ account: PlanAccount?) -> some View {
        HStack(spacing: Space.md) {
            Text(account?.plan ?? " ")
                .font(TextStyle.title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(account.map(UsageText.who) ?? "")
            Spacer(minLength: 0)
            freshness
            if let url = account?.manage {
                IconButton(
                    symbol: "arrow.up.right", kind: .mini, font: Glyph.chevron, help: "Manage usage on \(url.host() ?? url.absoluteString)"
                ) {
                    NSWorkspace.shared.open(url)
                    state.close()
                }
                // The glyph, not its box, on the rows' trailing edge.
                .padding(.trailing, -Space.sm)
                .storyID(StoryID.Composer.usage.part(.open))
            }
        }
        .frame(minHeight: Size.MessageActions.button)
    }

    /// The spinner while the first reading loads; "as of …" while an older one shows.
    @ViewBuilder private var freshness: some View {
        if state.status == .loading, state.reading?.limits == nil {
            SpinningArc().frame(width: Size.spinner, height: Size.spinner)
        } else if state.status != .fresh, let stamp = UsageText.stamp(state.readAt, now: Date()) {
            Text(stamp).font(TextStyle.caption).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
        }
    }

    // MARK: Limits

    @ViewBuilder private var limits: some View {
        let unavailable: String?? = if case .unavailable(let detail) = state.status { .some(detail) } else { nil }
        if let detail = unavailable {
            Text(wording.failed(detail))
                .font(TextStyle.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, state.reading == nil ? 0 : Space.xs)
        }
        let bars = state.reading?.limits?.bars
        // Loading with nothing kept: the usual rows, empty.
        let rows = bars.map { $0.map(Optional.some) } ?? (state.status == .loading ? wording.rows.map { _ in nil } : [])
        if !rows.isEmpty {
            let now = Date()
            Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: Space.sm) {
                ForEach(rows.indices, id: \.self) { index in
                    row(rows[index], placeholder: wording.rows.indices.contains(index) ? wording.rows[index] : "", now: now)
                }
            }
            .padding(.top, Space.sm)
            .opacity(unavailable == nil ? 1 : Theme.dimmed)
        }
        let extras = state.reading?.limits?.extras ?? []
        if !extras.isEmpty {
            extrasLine(extras, live: unavailable == nil && state.status != .loading)
                .font(TextStyle.caption)
                .foregroundStyle(Theme.secondary)
                .padding(.top, Space.md)
                .opacity(unavailable == nil ? 1 : Theme.dimmed)
        }
        if state.resetsOpen, let caption = wording.resetsCaption {
            let rows = state.resetRows
            if !rows.isEmpty {
                resets(rows, caption: caption).transition(.opacity.animation(Motion.fade))
            }
        }
    }

    /// One caption. Its count of full resets is a quiet button with a ⌄ while the reading is
    /// current, for a CLI that lists them: a click unfolds them below.
    @ViewBuilder private func extrasLine(_ extras: [PlanExtra], live: Bool) -> some View {
        let line = UsageText.extras(extras)
        if let resets = extras.first(where: \.isResets), live, wording.resetsCaption != nil {
            let rest = UsageText.extras(extras.filter { !$0.isResets })
            HStack(spacing: 0) {
                if !rest.isEmpty { Text(rest + " · ").lineLimit(1).truncationMode(.tail) }
                CaptionButton(title: resets.value, tint: Theme.secondary, hover: Theme.accent, unfolds: state.resetsOpen) {
                    state.toggleResets()
                }
                .storyID(StoryID.Composer.usage.part(.reset))
            }
        } else {
            Text(line).lineLimit(1).truncationMode(.tail).help(line)
        }
    }

    /// The unfolded full resets, under a hairline: the CLI's caption (a spinner while the limits
    /// are read again after a reset), then one row each, soonest to expire first; past five
    /// lines the list scrolls on its own.
    private func resets(_ rows: [ResetRow], caption: String) -> some View {
        let now = Date()
        let unlisted = state.reading?.limits?.resets?.unlisted ?? 0
        let list = VStack(spacing: 0) {
            ForEach(rows, id: \.id) { row in
                ResetRowView(
                    row: row, step: state.resetSteps[row.id], available: state.reading?.limits?.resets?.available ?? 0,
                    busy: state.resetsBusy, now: now, state: state)
            }
            if unlisted > 0 {
                Text("\(unlisted) more")
                    .font(TextStyle.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Space.sm)
                    .frame(maxWidth: .infinity, minHeight: Size.usageResetRow, alignment: .leading)
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: Stroke.hairline).padding(.vertical, Space.md)
            HStack(spacing: Space.xs) {
                Text(caption).lineLimit(1).truncationMode(.tail).help(caption)
                Spacer(minLength: 0)
                if state.rereading { SpinningArc().frame(width: Size.spinner, height: Size.spinner) }
            }
            .font(TextStyle.caption)
            .foregroundStyle(Theme.tertiary)
            .frame(height: Size.spinner)
            .padding(.bottom, Space.xs)
            Group {
                if rows.count + (unlisted > 0 ? 1 : 0) > 5 {
                    ScrollView { list }.scrollIndicators(.automatic).frame(height: Size.usageResetsMax)
                } else {
                    list
                }
            }
            // The rows' text on the limits' edge, their hover fill past it (as the ↗ is).
            .padding(.horizontal, -Space.sm)
        }
    }

    /// One limit: its shortened title, the bar, the percent and the ↻ reset, the reset's clock
    /// time on hover. Nil while loading: the title it usually has, an empty track and "—".
    private func row(_ limit: PlanLimit?, placeholder: String, now: Date) -> some View {
        let reset = limit.map { UsageText.resetsShort($0.resetsAt, now: now) } ?? ""
        let help = limit.map { UsageText.resetsAt($0.resetsAt, now: now) } ?? ""
        return GridRow {
            CappedWidth(cap: Size.usageTitleMax) {
                Text(UsageText.label(limit?.title ?? placeholder))
                    .font(TextStyle.label)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minHeight: Size.contextCardLine)
            .help(help)
                .storyID(limit.map { StoryID.Composer.usageLimit($0.title) })
            LimitBar(fraction: limit.map { UsageText.fraction($0.used) } ?? 0)
                .frame(minWidth: Size.usageBarMin, maxWidth: .infinity)
                .help(help)
            Text(limit.map { UsageText.percent($0.used) } ?? "—")
                .font(TextStyle.label.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .gridColumnAlignment(.trailing)
                .help(help)
            // Blank while loading or without a time, still as wide as a short time.
            HStack(spacing: Space.xxs) {
                Image(systemName: "arrow.clockwise").font(Glyph.chevron).foregroundStyle(Theme.tertiary)
                Text(reset.isEmpty ? "00m" : reset).font(TextStyle.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .opacity(reset.isEmpty ? 0 : 1)
            .help(help)
        }
    }

    // MARK: Dismissal

    /// Esc and Return close it and go no further (Return never sends nor confirms); any other
    /// key closes it and goes on to the field; a click outside it closes it and goes on. What
    /// reaches the draft without a key here (a paste the composer takes first, a menu's Paste,
    /// dictation) closes it from the composer, as the draft changes.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = window.value, event.window === window else { return event }
        if event.type == .keyDown, event.keyCode == 53, state.stepBack() {
            // Esc steps back one at a time: a reset's question, then the resets, then the popup.
            return nil
        }
        if event.type == .keyDown {
            state.close()
            // Esc, Return, keypad Enter.
            return [53, 36, 76].contains(event.keyCode) ? nil : event
        }
        guard let content = window.contentView else { return event }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !frame.value.contains(point) { state.close() }
        return event
    }
}

/// A text button in the caption's line: `tint` at rest, `hover` under the pointer. With
/// `unfolds`, a ⌄ after it (tertiary at rest) turned over while what it unfolds is open; `tall`,
/// it takes clicks over its row's height and a little before the word.
private struct CaptionButton: View {
    let title: String
    let tint: Color
    let hover: Color
    var unfolds: Bool?
    var tall = false
    let action: () -> Void
    @StateObject private var hovered = Local(false)
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lit = hovered.value && isEnabled
        Button(action: action) {
            HStack(spacing: Space.xxs) {
                Text(title).lineLimit(1).fixedSize()
                if let unfolds {
                    Image(systemName: "chevron.down")
                        .font(Glyph.chevron)
                        .foregroundStyle(lit ? hover : Theme.tertiary)
                        .rotationEffect(.degrees(unfolds ? 180 : 0))
                        .animation(reduceMotion ? nil : Motion.fade, value: unfolds)
                }
            }
            .foregroundStyle(isEnabled ? (lit ? hover : tint) : Theme.tertiary)
            .padding(.leading, tall ? Space.sm : 0)
            .frame(maxHeight: tall ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }
}

/// One full reset: its title, when it expires (the exact time on hover) and a quiet "Use"; "Use"
/// turns the row into the question, with "Yes" at its leading end so a double click's second
/// half lands on nothing; then a spinner, then what came of it, in place until the popup closes.
private struct ResetRowView: View {
    let row: ResetRow
    let step: UsageState.ResetStep?
    /// The count, for a row that stands for it.
    let available: Int
    /// Another reset is being sent or read after: "Use" is off.
    let busy: Bool
    let now: Date
    let state: UsageState
    @StateObject private var hovered = Local(false)

    var body: some View {
        let id = StoryID.Composer.usageReset(row.id)
        HStack(spacing: step == .asking ? Space.md : Space.lg) {
            switch step {
            case .asking:
                Text("Use this reset?").foregroundStyle(Theme.text).lineLimit(1)
                CaptionButton(title: "Yes, use reset", tint: Theme.accent, hover: Theme.accent) { state.useReset() }
                    .storyID(id.part(.allow))
                CaptionButton(title: "No, go back", tint: Theme.secondary, hover: Theme.text) { state.cancelReset() }
                    .storyID(id.part(.cancel))
                Spacer(minLength: 0)
            case .using:
                title(Theme.text)
                sending
            case .reset:
                title(Theme.text)
                HStack(spacing: Space.xs) {
                    Image(systemName: "checkmark").font(Glyph.chevron)
                    said(UsageText.didReset, Theme.secondary)
                }
                Spacer(minLength: 0)
            case .said(let words, let spent):
                title(spent ? Theme.secondary : Theme.text)
                said(words, Theme.secondary)
                Spacer(minLength: 0)
            case .failed(let words):
                title(Theme.text)
                said(words, Theme.danger)
                Spacer(minLength: 0)
                use(id)
            case nil:
                title(Theme.text)
                if row.credit?.redeeming == true {
                    sending
                } else {
                    Text(expiry)
                        .font(TextStyle.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    use(id)
                }
            }
        }
        .font(TextStyle.caption)
        .foregroundStyle(Theme.secondary)
        .id(step)
        .transition(.opacity.animation(Motion.fade))
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, minHeight: Size.usageResetRow, maxHeight: Size.usageResetRow, alignment: .leading)
        .hoverFill(step == .asking || (hovered.value && step == nil), step == .asking ? Theme.surfaceHover : Theme.toolHover)
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .help(step == nil ? row.credit.map { UsageText.expiresAt($0.expiresAt, now: now) } ?? "" : "")
        // One element to VoiceOver, its "Use" a button on it.
        .accessibilityElement(children: .combine)
        .storyID(id)
    }

    /// "Expires in 6d"; for a count alone, how many.
    private var expiry: String {
        row.credit.map { UsageText.expires($0.expiresAt, now: now) } ?? "\(available) available"
    }

    private func title(_ color: Color) -> some View {
        CappedWidth(cap: Size.usageTitleMax) {
            Text(row.title).font(TextStyle.label).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
        }
    }

    private var sending: some View {
        HStack(spacing: Space.xs) {
            SpinningArc().frame(width: Size.spinner, height: Size.spinner)
            Text(UsageText.resetting).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func said(_ words: String, _ color: Color) -> some View {
        Text(words).foregroundStyle(color).lineLimit(1).truncationMode(.tail).help(words)
    }

    /// Never truncated; it takes the row's height and a little before the word.
    private func use(_ id: StoryID) -> some View {
        CaptionButton(title: "Use", tint: Theme.secondary, hover: Theme.accent, tall: true) { state.askReset(row.id) }
            .disabled(busy)
            .accessibilityLabel("Use \(row.title.lowercased()), \(expiry.prefix(1).lowercased() + expiry.dropFirst())")
            .storyID(id.part(.use))
    }
}

/// Its content as wide as it would be, up to `cap`, never wider: the grid's title column is its
/// longest title's width rather than all it's offered, so the bars take the rest.
private struct CappedWidth: SwiftUI.Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(content.sizeThatFits(.unspecified).width, cap, proposal.width ?? .infinity)
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(bounds.size))
    }
}

/// A limit's bar, its fill as drawn: it moves to a new value on its own, so a reading landing
/// fills the bars in place.
private struct LimitBar: View {
    let fraction: Double
    @StateObject private var shown: Local<Double>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(fraction: Double) {
        self.fraction = fraction
        _shown = StateObject(wrappedValue: Local(fraction))
    }

    var body: some View {
        UsageBar(fraction: shown.value)
            .onChange(of: fraction) { _, now in
                if reduceMotion { shown.value = now } else { withAnimation(Motion.contextArc) { shown.value = now } }
            }
    }
}

/// The context card's track at its intent height: the used part from the left, coloured by how
/// near the limit it is, at least as wide as it is tall so a sliver still shows. Drawn in one
/// canvas; animatable, so a new value moves it as the ring moves.
private struct UsageBar: View, @preconcurrency Animatable {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        let fraction = fraction
        Canvas { canvas, size in
            let line = size.height
            func bar(_ width: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: line), cornerRadius: line / 2)
            }
            canvas.fill(bar(size.width), with: .color(Theme.contextTrack))
            if fraction > 0 { canvas.fill(bar(max(size.width * fraction, line)), with: .color(Theme.usageFill(fraction))) }
        }
        .frame(height: Size.contextTrack.intent)
    }
}
