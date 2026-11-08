import Foundation
import KoreCore

/// A CLI login's plan windows as the link pushes them (`clis[].usage`, 1.14): what the Mac or
/// the box already knows of them (a turn's `rate_limit_event`, Codex's pushed limits, a usage
/// read), never a read made for the push. It rides the extras, so it goes only while a client is
/// on screen and only when it changed. A phone gets it too (its extras keep no `account`); a
/// phone's `account.usage` without a login asks the node to read its logins again, at most once
/// a minute each, and the answer comes back here. Read-only: nothing in it switches or signs in.
package struct AccountUsage: Codable, Sendable, Equatable {
    /// One plan window: "5h" or "7d", the percent used (whole, 0 up, past 100 once over), and when
    /// it resets (ms since 1970; nil when the CLI didn't say). A window whose reset has passed
    /// reads as reset: the client shows it empty, with no push at the reset.
    package struct Limit: Codable, Sendable, Equatable {
        package var kind: String
        package var used: Int
        package var resetsAt: Int64?

        package init(kind: String, used: Int, resetsAt: Int64?) {
            self.kind = kind
            self.used = used
            self.resetsAt = resetsAt
        }
    }

    /// "main", or the added login's id (a box's account folder).
    package var login: String
    /// Masked where privacy says (`mask`); a box masks always.
    package var email: String?
    /// The login the CLI's chats start on (a box: its default account).
    package var active: Bool
    /// The plan's short name ("Max", "Pro"; "API" billed per token); nil when not read.
    package var plan: String?
    /// The 5-hour window, then the week's; empty before anything was read.
    package var limits: [Limit]

    package init(login: String, email: String?, active: Bool, plan: String?, limits: [Limit]) {
        self.login = login
        self.email = email
        self.active = active
        self.plan = plan
        self.limits = limits
    }

    /// The account-wide 5-hour and weekly windows (no model's own), 5-hour first.
    package static func limits(_ readings: [UsageCueBook.Reading]) -> [Limit] {
        var out: [String: Limit] = [:]
        for reading in readings where reading.limit.scope == nil {
            let limit = Limit(kind: reading.limit.kind.rawValue, used: whole(reading.used), resetsAt: reading.resetsAt.map(ms))
            out[limit.kind] = merge(out[limit.kind], limit)
        }
        return ordered(out)
    }

    /// A usage mark's windows as it tracks them (the highest reading of each window).
    package static func limits(_ tracks: [UsageCueBook.Limit: UsageCueBook.Track]) -> [Limit] {
        limits(tracks.map { UsageCueBook.Reading($0.key, used: $0.value.used, resetsAt: $0.value.resetsAt) })
    }

    /// Two sources' windows together: per kind, the later window, or within one window the
    /// higher reading (a limit never falls inside its window).
    package static func merge(_ a: [Limit], _ b: [Limit]) -> [Limit] {
        var out: [String: Limit] = [:]
        for limit in a + b { out[limit.kind] = merge(out[limit.kind], limit) }
        return ordered(out)
    }

    private static func merge(_ old: Limit?, _ new: Limit) -> Limit {
        guard let old else { return new }
        switch (old.resetsAt, new.resetsAt) {
        case (let a?, let b?) where abs(a - b) > slack: return a > b ? old : new
        default:
            var kept = old.used >= new.used ? old : new
            kept.resetsAt = kept.resetsAt ?? old.resetsAt ?? new.resetsAt
            return kept
        }
    }

    /// Two readings of one window can give its reset a few minutes apart (`UsageCueBook.slack`).
    static let slack = Int64(UsageCueBook.slack * 1000)

    private static func ordered(_ limits: [String: Limit]) -> [Limit] {
        [UsageCueBook.Kind.fiveHour.rawValue, UsageCueBook.Kind.weekly.rawValue].compactMap { limits[$0] }
    }

    /// Whole percent, so a push doesn't follow every tenth.
    static func whole(_ used: Double) -> Int { used.isFinite ? max(Int(used.rounded()), 0) : 0 }

    /// To the second: two sources rounding a reset differently don't make a change.
    static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded()) * 1000 }

    /// The name's first two letters and the domain's last two before its ending:
    /// "ku••••@••il.com". Always the same dots, so no length is given away (the Account card's
    /// privacy mode, `AccountPrivacy`).
    package static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return String(email.prefix(2)) + "••••" }
        let domain = email[email.index(after: at)...]
        guard let dot = domain.lastIndex(of: "."), dot > domain.startIndex else {
            return String(email[..<at].prefix(2)) + "••••@••" + String(domain.suffix(2))
        }
        return String(email[..<at].prefix(2)) + "••••@••" + String(domain[..<dot].suffix(2)) + domain[dot...]
    }

    /// A plan's short name: without its product's name ("Claude Max" → "Max", "ChatGPT Pro
    /// Lite" → "Pro Lite"); "API" for a login billed per token.
    package static func pill(plan: String?, perToken: Bool) -> String? {
        if perToken { return "API" }
        guard var plan = plan?.trimmingCharacters(in: .whitespaces), !plan.isEmpty else { return nil }
        for product in ["Claude ", "ChatGPT "] where plan.hasPrefix(product) { plan.removeFirst(product.count) }
        return plan.isEmpty ? nil : plan
    }

    /// A reading's plan as a pill.
    package static func pill(_ reading: PlanReading) -> String? {
        if case .perToken = reading.account.access { return pill(plan: reading.account.plan, perToken: true) }
        return pill(plan: reading.account.plan, perToken: false)
    }
}
