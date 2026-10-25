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
    /// Kore's part of each limit, worked out from this Mac's files once a reading lands (the
    /// last one meanwhile); nil until then, and the bars show plain.
    private(set) var shares: KoreShares?
    /// The extended view is open over the chat, showing the picked limit (by title).
    private(set) var extended = false
    private(set) var picked: String?
    /// The chats' names as the extended view found them, by id.
    private(set) var chatNames: [String: String] = [:]
    /// Each open's own number: a read that lands after a close, or after the next open, is
    /// only kept for next time.
    @ObservationIgnored private var serial = 0
    /// A reading's identity survives opening its extended view (which closes the small card).
    @ObservationIgnored private var readingSerial = 0
    /// When a row last asked (system uptime): a "Yes" within a double-click of it is the
    /// "Use reset" click's second half, and is ignored.
    @ObservationIgnored private var askedAt: TimeInterval = 0
    @ObservationIgnored private var patienceTimer: Task<Void, Never>?
    @ObservationIgnored private var provider = ""
    @ObservationIgnored private var cli = ""
    @ObservationIgnored private var read: (@MainActor () async throws -> PlanReading)?
    @ObservationIgnored private var consume: (@MainActor (String?, UUID) async throws -> PlanResetOutcome)?
    @ObservationIgnored private var attribute: (@MainActor (PlanReading) async -> KoreShares?)?
    @ObservationIgnored private var accountCurrent: @MainActor () -> Bool = { true }

    private static func accountScope(_ provider: String) -> String {
        if StoryHost.installed, CLIProfiles.root.value == nil {
            let identity: AccountIdentity? = if case .signedIn(let identity) = AccountStore.shared.status(provider) { identity } else { nil }
            return ["scripted", String(AccountStore.shared.generation(provider)), identity?.email ?? "", identity?.workspace ?? ""].joined(separator: "\u{1F}")
        }
        let id = CLIProfiles.active(provider)
        let login = id.flatMap { id in CLIProfiles.added(provider).first { $0.id == id } }
        let email = id == nil ? CLIProfiles.mainEmail(provider) : login?.email
        let workspace = id == nil ? CLIProfiles.mainWorkspace(provider) : login?.workspace
        return [
            id ?? "main", String(AccountStore.shared.generation(provider)),
            email ?? "", workspace ?? "",
        ].joined(separator: "\u{1F}")
    }

    private static func profileScope(_ provider: String) -> String {
        let login = StoryHost.installed && CLIProfiles.root.value == nil ? "scripted" : CLIProfiles.active(provider) ?? "main"
        return [login, String(AccountStore.shared.generation(provider))].joined(separator: "\u{1F}")
    }

    private static func knownAccount(_ provider: String) -> PlanAccount? {
        if StoryHost.installed, CLIProfiles.root.value == nil {
            guard case .signedIn(let identity) = AccountStore.shared.status(provider) else { return nil }
            return PlanAccount(plan: identity.plan, email: identity.email, organization: identity.organization, access: .plan)
        }
        let id = CLIProfiles.active(provider)
        let login = id.flatMap { id in CLIProfiles.added(provider).first { $0.id == id } }
        guard let email = id == nil ? CLIProfiles.mainEmail(provider) : login?.email, !email.isEmpty else { return nil }
        let workspace = id == nil ? CLIProfiles.mainWorkspace(provider) : login?.workspace
        return PlanAccount(plan: provider == "codex" ? workspace : nil, email: email,
            organization: provider == "claude" ? workspace : nil, access: .plan)
    }

    static func sameAccount(_ actual: PlanAccount, expected: PlanAccount?, provider: String) -> Bool {
        if actual.access == .signedOut { return true }
        guard let expected, let email = expected.email else {
            // A key/platform has no subscription limits or login identity to mix with one.
            if case .perToken = actual.access { return actual.email == nil }
            return false
        }
        guard actual.email?.lowercased() == email.lowercased() else { return false }
        if provider == "claude", let org = expected.organization, !org.isEmpty {
            return (actual.organization ?? actual.plan) == org
        }
        if provider == "codex", let plan = expected.plan, !plan.isEmpty { return actual.plan == plan }
        return true
    }

    /// Each provider's last reading, and when it was made.
    private static var kept: [String: (reading: PlanReading, at: Date)] = [:]
    /// Each provider's last shares.
    private static var keptShares: [String: KoreShares] = [:]
    /// The limit picked last in the extended view, which it opens on next time.
    private static var lastPicked: String?
    /// A read the CLI never answers stops showing a spinner after this.
    private static let patience: Duration = .seconds(35)

    /// `shares`: Kore's part of each limit in a reading, worked out off the main thread.
    func open(
        provider: String, read: @escaping @MainActor () async throws -> PlanReading,
        useReset: @escaping @MainActor (String?, UUID) async throws -> PlanResetOutcome,
        shares: @escaping @MainActor (PlanReading) async -> KoreShares? = { _ in nil },
        cacheScope: String? = nil,
        expectedAccount: PlanAccount? = nil
    ) {
        // Never show the previous login's saved limits or hatch while this login loads.
        let scope = cacheScope ?? Self.accountScope(provider)
        var boundScope = scope
        let cli = provider
        let profile = Self.profileScope(cli)
        let current: @MainActor () -> Bool = { cacheScope != nil || Self.profileScope(cli) == profile && Self.accountScope(cli) == boundScope }
        accountCurrent = current
        self.cli = cli
        let checkIdentity = expectedAccount != nil || cacheScope == nil && Registry.provider(cli) != nil
        var expected = expectedAccount ?? Self.knownAccount(cli)
        let rawRead = read
        let read: @MainActor () async throws -> PlanReading = {
            if checkIdentity, expected == nil {
                // First open on an unrecorded login: learn its identity independently of a
                // chat server that may still be relaunching under the previous login.
                await AccountStore.shared.refresh(cli)
                guard cacheScope != nil || Self.profileScope(cli) == profile else { throw UsageUnavailable() }
                expected = Self.knownAccount(cli)
                boundScope = Self.accountScope(cli)
            }
            guard current() else { throw UsageUnavailable() }
            let new = try await rawRead()
            guard current(), !checkIdentity || Self.sameAccount(new.account, expected: expected, provider: cli) else {
                throw UsageUnavailable()
            }
            return new
        }
        let provider = provider + "\u{1F}" + scope
        serial += 1
        let open = serial
        readingSerial = open
        isOpen = true
        status = .loading
        (resetsOpen, resetSteps, rereading, held) = (false, [:], false, [])
        (self.provider, self.read, self.consume, attribute) = (provider, read, useReset, shares)
        let last = checkIdentity && expected == nil ? nil : Self.kept[provider]
        (reading, readAt) = (last?.reading, last?.at)
        self.shares = last == nil ? nil : Self.keptShares[provider]
        Task { [weak self] in
            let outcome: Result<PlanReading, any Error>
            do { outcome = .success(try await read()) } catch { outcome = .failure(error) }
            guard current() else {
                guard let self, self.serial == open else { return }
                (self.reading, self.readAt, self.shares) = (nil, nil, nil)
                self.status = .unavailable(nil)
                return
            }
            if case .success(let new) = outcome, new.limits != nil || new.account.access != .plan {
                Self.kept[provider] = (new, Date())
            }
            guard let self, self.serial == open else { return }
            self.land(outcome, last: last)
            if case .success(let new) = outcome, new.limits != nil { self.attribute(new, open: open) }
        }
        patienceTimer?.cancel()
        patienceTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard let self, !Task.isCancelled, self.serial == open, self.status == .loading else { return }
            self.status = .unavailable(nil)
        }
    }

    /// Kore's share of `reading`'s limits; it shows when it lands, while that reading shows
    /// (in the popup, or the extended view it opened).
    private func attribute(_ reading: PlanReading, open: Int) {
        guard let attribute else { return }
        let provider = provider
        let current = accountCurrent
        Task { [weak self] in
            guard let shares = await attribute(reading) else { return }
            guard current() else { return }
            Self.keptShares[provider] = shares
            guard let self, self.readingSerial == open, self.provider == provider, self.reading == reading else { return }
            self.shares = shares
        }
    }

    // MARK: Extended view

    /// Opens the extended view (the popup closes): on the limit picked last in this run, else
    /// the first. Only with limits to show.
    func openExtended() {
        let titles = reading?.limits?.bars.map(\.title) ?? []
        guard !titles.isEmpty, reading?.account.access == .plan else { return }
        close()
        picked = Self.lastPicked.flatMap { titles.contains($0) ? $0 : nil } ?? titles.first
        extended = true
    }

    func closeExtended() {
        extended = false
    }

    func pick(_ title: String) {
        picked = title
        Self.lastPicked = title
    }

    /// ↑ ↓ in the extended view: the limit before or after the picked one, stopping at the ends.
    func step(_ by: Int) {
        let titles = reading?.limits?.bars.map(\.title) ?? []
        guard let at = picked.flatMap(titles.firstIndex(of:)) else { return }
        pick(titles[min(max(at + by, 0), titles.count - 1)])
    }

    /// The picked limit, as the reading shows it.
    var pickedLimit: PlanLimit? { reading?.limits?.bars.first { $0.title == picked } ?? reading?.limits?.bars.first }

    /// Names for the extended view's chats, by id, as they were found.
    func named(_ names: [String: String]) {
        guard names != chatNames else { return }
        chatNames = names
    }

    /// The extended view's ledger for the picked limit, one line per row ("In Kore · ~12%",
    /// "Fix the race in LoginTests · ~6%", "Outside Kore · ~31%"), for a storyline's checks;
    /// `current`: this chat's id, whose row reads "This chat".
    func ledger(current: String?) -> [String] {
        guard let limit = pickedLimit, let share = share(limit) else { return [] }
        guard share.kore > 0 else { return [UsageText.nothingFromKore] }
        let chats = share.chats.map { chat in
            [chat.id == current ? "This chat" : chatNames[chat.id] ?? chat.title ?? UsageText.untitled, UsageText.kore(chat.points)]
                .joined(separator: " · ")
        }
        return ["In Kore · " + UsageText.kore(share.kore)] + chats + ["Outside Kore · " + UsageText.kore(share.outside)]
    }

    /// A limit's share of Kore, while a reading of it shows; nil while it's worked out.
    func share(_ limit: PlanLimit) -> KoreShare? {
        guard var share = shares?.limits[limit.title] else { return nil }
        // Never more than the plan says now (the share may be from the reading before).
        let cut = UsageAttribution.clamp(share.kore, chats: share.chats, used: limit.used)
        if cut.clamped { (share.used, share.kore, share.chats, share.clamped) = (limit.used, cut.kore, cut.chats, true) }
        return share
    }

    /// A bar's tooltip: Kore's share of it, else (none, or not worked out yet) when it resets.
    func barHelp(_ limit: PlanLimit, now: Date) -> String {
        guard let kore = share(limit)?.kore, kore > 0 else { return UsageText.resetsAt(limit.resetsAt, now: now) }
        return UsageText.inKore(kore)
    }

    func close() {
        guard isOpen else { return }
        serial += 1
        isOpen = false
        patienceTimer?.cancel()
    }

    /// Another login took over, including in a different window. Its old limits and reset
    /// actions leave with the card; async reads cannot reopen or repopulate it.
    func accountChanged() {
        close()
        closeExtended()
        readingSerial += 1
        (reading, readAt, shares) = (nil, nil, nil)
        resetSteps = [:]
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

    /// A row's "Use reset": that row asks first, and any other row's question is dropped.
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

    /// A reset is being sent, or the limits read again after one: no other "Use reset" goes.
    var resetsBusy: Bool { rereading || resetSteps.values.contains(.using) }

    /// Confirmed: uses the asking row's reset (Codex picks for a count alone), then reads the
    /// limits again so the bars and the count show it. Once sent it's done whether or not the
    /// popup stays open; a read that lands after a close is only kept for next time.
    func useReset() {
        // The asking row's credit; nil (the row of a count alone) lets Codex pick.
        guard accountCurrent(), let confirmed = reading?.account, confirmed.access == .plan,
            let asking = resetSteps.first(where: { $0.value == .asking }), confirmable, !resetsBusy, let consume, let read else { return }
        let credit = asking.key
        if held.isEmpty { held = resetRows }
        resetSteps[credit] = .using
        let (open, provider) = (serial, provider)
        let current = accountCurrent
        let cli = cli
        Task { [weak self] in
            guard current() else { return }
            let step: ResetStep
            do {
                // The server can still have the old login while a relaunch is pending.
                // Verify on that same read path immediately before spending a credit.
                let checked = try await read()
                guard current(), checked.account.access == .plan,
                    Self.sameAccount(checked.account, expected: confirmed, provider: cli)
                else { throw UsageUnavailable() }
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
            guard current() else { return }
            guard let self, self.serial == open else {
                if let new = try? await read(), current(), new.limits != nil { Self.kept[provider] = (new, Date()) }
                return
            }
            (self.resetSteps[credit], self.rereading) = (step, true)
            let new = try? await read()
            if let new, current(), new.limits != nil { Self.kept[provider] = (new, Date()) }
            guard current(), self.serial == open else { return }
            if let new, new.limits != nil {
                (self.reading, self.readAt, self.status) = (new, Date(), .fresh)
                self.attribute(new, open: open)
            }
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
        // Signed out meanwhile: the extended view has nothing to show.
        if reading?.account.access == .signedOut { extended = false }
    }

    /// The popup's bars, each as one line, then the unfolded resets' rows, for a storyline's
    /// checks ("Weekly limit · 6% · Resets in 4d", "Full reset · Expires in 6d").
    var lines: [String] {
        let now = Date()
        let bars = (reading?.limits?.bars ?? []).map { bar in
            let kore = share(bar).flatMap { $0.kore > 0 ? UsageText.inKore($0.kore) : nil }
            return [bar.title, UsageText.percent(bar.used), UsageText.resets(bar.resetsAt, now: now), kore].compactMap { $0 }
                .joined(separator: " · ")
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

    /// One of Kore's figures, which are estimates: whole percents rounded to nearest with "~",
    /// "<1%" under one.
    static func kore(_ points: Double) -> String {
        points <= 0 ? "~0%" : points < 1 ? "<1%" : "~\(Int(points.rounded()))%"
    }

    /// The bar's tooltip with a share of Kore: "~12% in Kore".
    static func inKore(_ points: Double) -> String { kore(points) + " in Kore" }

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

    static func distinct(_ org: String, from email: String) -> Bool {
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

    /// The extended view's ledger for a limit Kore didn't use.
    static let nothingFromKore = "Nothing from Kore in this window."
    /// A chat whose title Kore couldn't find.
    static let untitled = "Untitled chat"

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

/// The / menu's Usage, in the menu's place over the chat (A · Ledger in usage-popup-calm.html),
/// in a `ComposerPopup`: the plan name (the account on hover), the freshness and the ↗ to manage
/// usage, then one row per limit (title, bar, percent, ↻ reset), then one caption of extras.
/// Esc steps back from a reset's question and the unfolded resets, then closes it.
struct UsagePopup: View {
    let chat: Chat
    let state: UsageState
    let wording: UsageWording
    /// The most it may be tall: the room above the composer.
    let room: CGFloat

    var body: some View {
        ComposerPopup(
            chat: chat, id: StoryID.Composer.usage, room: room, isOpen: { state.isOpen }, stepBack: { state.stepBack() },
            close: { state.close() }
        ) {
            content
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
            HStack(spacing: Space.xxs) {
                // With limits to show, fresh or kept: the extended view, over the chat.
                if state.reading?.limits?.bars.isEmpty == false, account?.access == .plan {
                    IconButton(symbol: "rectangle.expand.vertical", kind: .mini, font: TextStyle.caption, help: "Extended view") {
                        state.openExtended()
                    }
                    .storyID(StoryID.Composer.usage.part(.extended))
                    .tabStop(StoryID.Composer.usage.part(.extended)) { state.openExtended() }
                }
                if let url = account?.manage {
                    IconButton(
                        symbol: "arrow.up.right", kind: .mini, font: Glyph.chevron, help: "Manage usage on \(url.host() ?? url.absoluteString)"
                    ) {
                        NSWorkspace.shared.open(url)
                        state.close()
                    }
                    .storyID(StoryID.Composer.usage.part(.open))
                    .tabStop(StoryID.Composer.usage.part(.open)) {
                        NSWorkspace.shared.open(url)
                        state.close()
                    }
                }
            }
            // The glyph, not its box, on the rows' trailing edge.
            .padding(.trailing, account?.manage == nil ? 0 : -Space.sm)
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
                .tabStop(StoryID.Composer.usage.part(.reset)) { state.toggleResets() }
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
    /// time on hover. Nil while loading: the title it usually has, an empty track and "—". Kore's
    /// share starts the bar's fill, hatched, and is the bar's tooltip ("~12% in Kore").
    private func row(_ limit: PlanLimit?, placeholder: String, now: Date) -> some View {
        let reset = limit.map { UsageText.resetsShort($0.resetsAt, now: now) } ?? ""
        let help = limit.map { UsageText.resetsAt($0.resetsAt, now: now) } ?? ""
        let kore = limit.flatMap { state.share($0)?.kore } ?? 0
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
            LimitBar(
                fraction: limit.map { UsageText.fraction($0.used) } ?? 0, kore: UsageText.fraction(kore),
                share: limit.map { StoryID.Composer.usageLimit($0.title).part(.share) })
                .frame(minWidth: Size.usageBarMin, maxWidth: .infinity)
                .storyID(limit.map { StoryID.Composer.usageLimit($0.title).part(.track) })
                .help(limit.map { state.barHelp($0, now: now) } ?? "")
                .accessibilityLabel(kore > 0 ? "about \(UsageText.kore(kore).dropFirst()) in Kore" : "")
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
}

/// A text button in the caption's line: `tint` at rest, `hover` under the pointer. With
/// `unfolds`, a ⌄ after it (tertiary at rest) turned over while what it unfolds is open.
private struct CaptionButton: View {
    let title: String
    let tint: Color
    let hover: Color
    var unfolds: Bool?
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }
}

/// One full reset: its title, when it expires (the exact time on hover) and a small "Use reset"
/// button; that turns the row into the question, "No, go back" where "Use reset" was and "Yes,
/// use reset" before it, so a double click's second half goes back; then a spinner, then what
/// came of it, in place until the popup closes.
private struct ResetRowView: View {
    let row: ResetRow
    let step: UsageState.ResetStep?
    /// The count, for a row that stands for it.
    let available: Int
    /// Another reset is being sent or read after: "Use reset" is off.
    let busy: Bool
    let now: Date
    let state: UsageState
    @StateObject private var hovered = Local(false)

    var body: some View {
        let id = StoryID.Composer.usageReset(row.id)
        HStack(spacing: step == .asking ? Space.md : Space.lg) {
            switch step {
            case .asking:
                Text("Use this reset?").foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Button("Yes, use reset") { state.useReset() }
                    .smallButton(prominent: true)
                    .storyID(id.part(.allow))
                    .tabStop(id.part(.allow)) { state.useReset() }
                // Asked from the keys, the ring lands here: a second Return goes back.
                Button("No, go back") { state.cancelReset() }
                    .smallButton()
                    .storyID(id.part(.cancel))
                    .tabStop(id.part(.cancel), after: id.part(.use)) { state.cancelReset() }
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
        .hoverFill(step == .asking || (hovered.value && step == nil), step == .asking ? Theme.Row.selected(.surface) : Theme.Row.hover(.surface))
        .contentShape(Rectangle())
        .onHover { hovered.value = $0 }
        .help(step == nil ? row.credit.map { UsageText.expiresAt($0.expiresAt, now: now) } ?? "" : "")
        // One element to VoiceOver, its "Use reset" a button on it.
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

    /// Never truncated, at the row's trailing edge.
    private func use(_ id: StoryID) -> some View {
        Button("Use reset") { state.askReset(row.id) }
            .smallButton()
            .accessibilityLabel("Use \(row.title.lowercased()), \(expiry.prefix(1).lowercased() + expiry.dropFirst())")
            .storyID(id.part(.use))
            .tabStop(id.part(.use), after: id.part(.cancel)) { state.askReset(row.id) }
            .disabled(busy)
    }
}

/// Its content as wide as it would be, up to `cap`, never wider: the grid's title column is its
/// longest title's width rather than all it's offered, so the bars take the rest.
struct CappedWidth: SwiftUI.Layout {
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
/// fills the bars in place. Kore's share (`kore`, of the whole bar) moves with it; arriving, or
/// leaving, it fades rather than slides.
struct LimitBar: View {
    let fraction: Double
    let kore: Double
    /// Its hatched stretch's name, for storylines.
    let share: StoryID?
    var height = Size.contextTrack.intent
    @StateObject private var shown: Local<Double>
    @StateObject private var koreShown: Local<Double>
    @StateObject private var hatch: Local<Double>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(fraction: Double, kore: Double, share: StoryID?, height: CGFloat = Size.contextTrack.intent) {
        self.fraction = fraction
        self.kore = kore
        self.share = share
        self.height = height
        _shown = StateObject(wrappedValue: Local(fraction))
        _koreShown = StateObject(wrappedValue: Local(kore))
        _hatch = StateObject(wrappedValue: Local(kore > 0 ? 1 : 0))
    }

    var body: some View {
        UsageBar(fraction: shown.value, kore: koreShown.value, hatch: hatch.value, height: height)
            .overlay(alignment: .leading) {
                if kore > 0, fraction > 0, let share {
                    GeometryReader { geometry in
                        Color.clear
                            .frame(width: UsageHatch.width(fill: UsageHatch.fill(fraction, in: geometry.size), kore: kore, used: fraction))
                            .storyID(share)
                    }
                }
            }
            .onChange(of: fraction) { _, now in
                if reduceMotion { shown.value = now } else { withAnimation(Motion.contextArc) { shown.value = now } }
            }
            .onChange(of: kore) { before, now in
                if reduceMotion {
                    (koreShown.value, hatch.value) = (now, now > 0 ? 1 : 0)
                } else if before <= 0 || now <= 0 {
                    if now > 0 { koreShown.value = now }
                    withAnimation(Motion.fade) { hatch.value = now > 0 ? 1 : 0 }
                } else {
                    withAnimation(Motion.contextArc) { koreShown.value = now }
                }
            }
    }
}

/// Kore's stretch of a bar's fill: from its leading end, in bands of the fill's colour at 45°
/// ("/") with the track showing between them.
enum UsageHatch {
    /// The used fill's width: at least as wide as the bar is tall, so a sliver still shows.
    static func fill(_ fraction: Double, in size: CGSize) -> CGFloat { max(size.width * fraction, size.height) }

    /// Kore's part of `fill`: its share of what's used, at least two bands, never past the fill.
    static func width(fill: CGFloat, kore: Double, used: Double) -> CGFloat {
        guard kore > 0, used > 0 else { return 0 }
        return min(max(fill * min(kore / used, 1), Size.usageHatchMin), fill)
    }

    /// The bands over `rect`, as one path: lines rising to the right, `Size.usageHatch.period`
    /// apart across them, laid from x = 0 so they stay put as the stretch grows.
    static func bands(_ rect: CGRect) -> Path {
        let step = Size.usageHatch.period * 2.squareRoot()
        var path = Path()
        var x = -rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        return path
    }
}

/// The context card's track at its intent height: the used part from the left, coloured by how
/// near the limit it is, at least as wide as it is tall so a sliver still shows; Kore's share
/// hatched at its start (`hatch`: how far it has faded in). Drawn in one canvas; animatable, so a
/// new value moves it as the ring moves.
struct UsageBar: View, @preconcurrency Animatable {
    var fraction: Double
    var kore: Double
    var hatch: Double
    /// The fraction its colour goes by (a chat's mini bar takes its limit's); nil: its own.
    var tint: Double?
    var height = Size.contextTrack.intent

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(fraction, AnimatablePair(kore, hatch)) }
        set { (fraction, kore, hatch) = (newValue.first, newValue.second.first, newValue.second.second) }
    }

    var body: some View {
        let (fraction, kore, hatch, tint) = (fraction, kore, hatch, tint ?? fraction)
        Canvas { canvas, size in
            let line = size.height
            func bar(_ width: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: line), cornerRadius: line / 2)
            }
            canvas.fill(bar(size.width), with: .color(Theme.contextTrack))
            guard fraction > 0 else { return }
            let width = UsageHatch.fill(fraction, in: size)
            let color = Theme.usageFill(tint)
            let stretch = hatch > 0 ? UsageHatch.width(fill: width, kore: kore, used: fraction) : 0
            guard stretch > 0 else {
                canvas.fill(bar(width), with: .color(color))
                return
            }
            canvas.drawLayer { layer in
                layer.clip(to: bar(width))
                layer.fill(Path(CGRect(x: stretch, y: 0, width: width - stretch, height: line)), with: .color(color))
                let hatched = CGRect(x: 0, y: 0, width: stretch, height: line)
                // Fading in, the gaps go from the fill to the track.
                if hatch < 1 { layer.fill(Path(hatched), with: .color(color.opacity(1 - hatch))) }
                layer.clip(to: Path(hatched))
                layer.stroke(UsageHatch.bands(hatched), with: .color(color), lineWidth: Size.usageHatch.band)
            }
        }
        .frame(height: height)
    }
}
