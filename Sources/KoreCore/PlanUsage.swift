import Foundation

/// The signed-in account and its plan's limits, as the CLI reports them: Claude's `get_usage`
/// control request, Codex's `account/read` and `account/rateLimits/read`. The CLI makes the
/// authenticated calls; Kore only reads what it answers. Both APIs are young, so parsing is
/// lenient: a missing or unknown field leaves a row out and never fails the reading.
public struct PlanReading: Sendable, Equatable {
    public var account: PlanAccount
    /// Nil when the limits couldn't be read.
    public var limits: PlanLimits?
    /// Why not, as the CLI said it, in one plain line; nil when it said nothing readable.
    public var reason: String?

    public init(account: PlanAccount, limits: PlanLimits?, reason: String? = nil) {
        self.account = account
        self.limits = limits
        self.reason = reason
    }
}

public struct PlanAccount: Sendable, Equatable {
    public enum Access: Sendable, Equatable {
        /// A subscription with plan limits.
        case plan
        /// Billed per token (Console, API key, a cloud provider): no plan limits; how, in a line.
        case perToken(String)
        case signedOut
    }

    /// "Claude Max", "ChatGPT Pro Lite".
    public var plan: String?
    public var email: String?
    public var organization: String?
    public var access: Access
    /// Where the plan's usage is managed, in the browser.
    public var manage: URL?

    public init(plan: String? = nil, email: String? = nil, organization: String? = nil, access: Access, manage: URL? = nil) {
        self.plan = plan
        self.email = email
        self.organization = organization
        self.access = access
        self.manage = manage
    }

    public static let signedOut = PlanAccount(access: .signedOut)
}

public struct PlanLimits: Sendable, Equatable {
    public var bars: [PlanLimit]
    /// Information only, in order: extra usage, credits, resets.
    public var extras: [PlanExtra]
    /// Full resets of the limits the account can use (Codex's reset credits); nil when it has none.
    public var resets: PlanResets?

    public init(bars: [PlanLimit], extras: [PlanExtra] = [], resets: PlanResets? = nil) {
        self.bars = bars
        self.extras = extras
        self.resets = resets
    }
}

/// The account's full resets (Codex's rate-limit reset credits): how many, and each one listed.
public struct PlanResets: Sendable, Equatable {
    public var available: Int
    /// Those listed as available or being used, the soonest to expire first and those that never
    /// expire last; nil when Codex counted them without listing them, and then picks. The list
    /// may stop short of `available`.
    public var credits: [PlanReset]?

    public init(available: Int, credits: [PlanReset]?) {
        self.available = available
        self.credits = credits
    }

    /// The one that expires soonest.
    public var next: PlanReset? { credits?.first }

    /// How many are available beyond those listed.
    public var unlisted: Int {
        guard let credits else { return 0 }
        return max(available - credits.filter { !$0.redeeming }.count, 0)
    }
}

public struct PlanReset: Sendable, Equatable {
    /// Codex's opaque id for the credit.
    public let id: String
    /// Its name ("Full reset"); nil when it has none.
    public let title: String?
    public let grantedAt: Date?
    /// Nil: it never expires; `unreadable` when Codex sent a value Kore can't read.
    public let expiresAt: Date?
    /// Being used (from another client): listed, but not offered.
    public let redeeming: Bool

    public init(id: String, title: String? = nil, grantedAt: Date? = nil, expiresAt: Date?, redeeming: Bool = false) {
        self.id = id
        self.title = title
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.redeeming = redeeming
    }

    /// An expiry Kore couldn't read: it sorts with those that never expire.
    public static let unreadable = Date.distantFuture
}

/// What using a full reset did, as Codex answers `account/rateLimitResetCredit/consume`.
public enum PlanResetOutcome: Sendable, Equatable {
    case reset
    /// Nothing was near a limit: the credit stays.
    case nothingToReset
    case noCredit
    /// The credit was used meanwhile (another client, an earlier try).
    case alreadyRedeemed
    /// An outcome newer than Kore.
    case other(String)

    public init(_ result: JSONValue) {
        switch result["outcome"]?.string {
        case "reset": self = .reset
        case "nothingToReset": self = .nothingToReset
        case "noCredit": self = .noCredit
        case "alreadyRedeemed": self = .alreadyRedeemed
        case let other: self = .other(other ?? "")
        }
    }
}

public struct PlanLimit: Sendable, Equatable {
    public let title: String
    /// Percent of the limit used, 0–100 (past 100 once over).
    public let used: Double
    public let resetsAt: Date?

    public init(title: String, used: Double, resetsAt: Date?) {
        self.title = title
        self.used = used
        self.resetsAt = resetsAt
    }
}

/// "Credits 47,162"; a nil key for a value that reads alone ("2 full resets available").
public struct PlanExtra: Sendable, Equatable {
    public let key: String?
    public let value: String
    /// The count of full resets, which the popup offers to use.
    public let isResets: Bool

    public init(_ key: String?, _ value: String, isResets: Bool = false) {
        self.key = key
        self.value = value
        self.isResets = isResets
    }
}

// MARK: - Claude

extension PlanReading {
    static let claudeUsage = URL(string: "https://claude.ai/settings/usage")
    static let claudeAdminUsage = URL(string: "https://claude.ai/admin-settings/usage")

    /// From `initialize`'s `account` and `get_usage`'s answer. Rows and labels as the CLI's own
    /// panel has them: the session and the week, one weekly model limit for max, team and
    /// unknown plans, then each `model_scoped` week; rows without a utilization are left out.
    public static func claude(account: JSONValue?, usage: JSONValue, locale: Locale = .current) -> PlanReading {
        let subscription = usage["subscription_type"]?.string
        var reading = PlanReading(account: claudeAccount(account, subscription: subscription), limits: nil)
        if usage["rate_limits_available"]?.bool == false {
            reading.account.access = .perToken(perTokenLine(account?["apiProvider"]?.string))
            reading.account.plan = perTokenPlan(account?["apiProvider"]?.string)
            reading.account.manage = nil
            return reading
        }
        let limits = usage["rate_limits"]
        var bars: [PlanLimit] = []
        func add(_ title: String, _ window: JSONValue?) {
            guard let used = window?["utilization"]?.double else { return }
            bars.append(PlanLimit(title: title, used: used, resetsAt: date(window?["resets_at"])))
        }
        add("Session (5hr)", limits?["five_hour"])
        add("Weekly (7 day)", limits?["seven_day"])
        if subscription == nil || subscription == "max" || subscription == "team" {
            add("Weekly Sonnet", limits?["seven_day_sonnet"])
        }
        for scoped in limits?["model_scoped"]?.array ?? [] {
            if let name = scoped["display_name"]?.string, !name.isEmpty { add("Weekly \(name)", scoped) }
        }
        reading.limits = PlanLimits(bars: bars, extras: extraUsage(limits?["extra_usage"], locale: locale).map { [$0] } ?? [])
        return reading
    }

    /// The account alone: `get_usage` failed, saying `reason`.
    public static func claude(account: JSONValue?, failure reason: String?) -> PlanReading {
        PlanReading(account: claudeAccount(account, subscription: nil), limits: nil, reason: plainReason(reason))
    }

    /// Whether `initialize`'s account names anyone: logged out, it doesn't.
    public static func claudeSignedIn(_ account: JSONValue?) -> Bool {
        [account?["email"], account?["subscriptionType"], account?["organization"]].contains { !($0?.string ?? "").isEmpty }
    }

    private static func claudeAccount(_ account: JSONValue?, subscription: String?) -> PlanAccount {
        let named = account?["subscriptionType"]?.string
        let kind = (subscription ?? named ?? "").lowercased()
        let admin = kind.contains("team") || kind.contains("enterprise")
        return PlanAccount(
            plan: claudePlan(named ?? subscription), email: nonEmpty(account?["email"]?.string),
            organization: nonEmpty(account?["organization"]?.string), access: .plan,
            manage: admin ? claudeAdminUsage : claudeUsage)
    }

    /// "Claude Max" as the CLI names it; a bare "max" becomes that too.
    public static func claudePlan(_ raw: String?) -> String? {
        guard let raw = nonEmpty(raw) else { return nil }
        let words = raw.split(whereSeparator: { $0 == " " || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let name = words.joined(separator: " ")
        return name.hasPrefix("Claude") ? name : "Claude " + name
    }

    private static func perTokenPlan(_ provider: String?) -> String {
        switch provider {
        case nil, "firstParty": "Claude Console"
        case "bedrock": "Amazon Bedrock"
        case "vertex": "Google Vertex AI"
        case "foundry": "Microsoft Foundry"
        case let other?: other.prefix(1).uppercased() + other.dropFirst()
        }
    }

    private static func perTokenLine(_ provider: String?) -> String {
        switch provider {
        case nil, "firstParty": "Billed per token through the Console: no plan limits."
        default: "Billed per token through \(perTokenPlan(provider)): no plan limits."
        }
    }

    /// "On · $12.40 of $50 this month", while extra usage is on. Amounts are in cents (minor
    /// units, `decimal_places` of them).
    static func extraUsage(_ extra: JSONValue?, locale: Locale) -> PlanExtra? {
        guard extra?["is_enabled"]?.bool == true else { return nil }
        let places = extra?["decimal_places"]?.int ?? 2
        let currency = extra?["currency"]?.string ?? "USD"
        func money(_ value: JSONValue?) -> String? {
            guard let minor = value?.double else { return nil }
            return amount(minor / pow(10, Double(places)), currency: currency, locale: locale)
        }
        var line = "On"
        if let used = money(extra?["used_credits"]) {
            line += " · " + used + (money(extra?["monthly_limit"]).map { " of " + $0 } ?? "") + " this month"
        }
        return PlanExtra("Extra usage", line)
    }

    /// "$12.40", "$50": cents only when there are some.
    static func amount(_ value: Double, currency: String, locale: Locale) -> String {
        let whole = value.rounded() == value
        let format = FloatingPointFormatStyle<Double>.Currency(code: currency, locale: locale)
            .precision(.fractionLength(whole ? 0 : 2))
        return value.formatted(format)
    }
}

// MARK: - Codex

extension PlanReading {
    static let codexUsage = URL(string: "https://chatgpt.com/codex/settings/usage")

    /// From `account/read`'s answer and `account/rateLimits/read`'s (nil when that failed,
    /// saying `reason`). Each limit id's windows, Codex's own first; its credits and full resets.
    public static func codex(account: JSONValue, rateLimits: JSONValue?, failure reason: String? = nil, locale: Locale = .current)
        -> PlanReading
    {
        guard let user = account["account"], user != .null else { return PlanReading(account: .signedOut, limits: nil) }
        let access: PlanAccount
        switch user["type"]?.string {
        case "apiKey":
            access = PlanAccount(plan: "API key", access: .perToken("Billed per token with an API key: no plan limits."))
        case "amazonBedrock":
            access = PlanAccount(plan: "Amazon Bedrock", access: .perToken("Billed per token through Amazon Bedrock: no plan limits."))
        default:
            access = PlanAccount(
                plan: codexPlan(user["planType"]?.string), email: nonEmpty(user["email"]?.string), access: .plan, manage: codexUsage)
        }
        guard access.access == .plan else { return PlanReading(account: access, limits: nil) }
        guard let rateLimits else { return PlanReading(account: access, limits: nil, reason: plainReason(reason)) }
        return PlanReading(account: access, limits: codexLimits(rateLimits, locale: locale))
    }

    static func codexLimits(_ result: JSONValue, locale: Locale) -> PlanLimits {
        var snapshots: [(id: String, snapshot: JSONValue)] = []
        if let byId = result["rateLimitsByLimitId"]?.object, !byId.isEmpty {
            snapshots = byId.sorted { a, b in a.key == "codex" ? b.key != "codex" : b.key != "codex" && a.key < b.key }
                .map { ($0.key, $0.value) }
        } else if let single = result["rateLimits"], single != .null {
            snapshots = [(single["limitId"]?.string ?? "codex", single)]
        }
        var bars: [PlanLimit] = []
        for (id, snapshot) in snapshots {
            let name = id == "codex" ? nil : nonEmpty(snapshot["limitName"]?.string) ?? nonEmpty(snapshot["normalModelSlug"]?.string) ?? id
            for window in [snapshot["primary"], snapshot["secondary"]] {
                guard let window, let used = window["usedPercent"]?.double else { continue }
                let title = windowLabel(window["windowDurationMins"]?.int) + (name.map { " · " + $0 } ?? "")
                bars.append(PlanLimit(title: title, used: used, resetsAt: date(window["resetsAt"])))
            }
        }
        var extras: [PlanExtra] = []
        let credits = (snapshots.first { $0.id == "codex" } ?? snapshots.first)?.snapshot["credits"]
        if credits?["hasCredits"]?.bool == true, credits?["unlimited"]?.bool != true,
            let balance = credits?["balance"]?.string.flatMap(Double.init)
        {
            extras.append(PlanExtra("Credits", balance.formatted(.number.precision(.fractionLength(0)).locale(locale))))
        }
        let resets = codexResets(result["rateLimitResetCredits"])
        if let resets {
            let count = resets.available
            extras.append(PlanExtra(nil, count == 1 ? "1 full reset available" : "\(count) full resets available", isResets: true))
        }
        return PlanLimits(bars: bars, extras: extras, resets: resets)
    }

    /// The available count, and the credits listed as available or being used, the soonest to
    /// expire first (one that never expires goes last). None listed reads as a count alone.
    static func codexResets(_ summary: JSONValue?) -> PlanResets? {
        guard let count = summary?["availableCount"]?.int, count > 0 else { return nil }
        let credits = (summary?["credits"]?.array ?? []).compactMap { credit -> PlanReset? in
            let status = credit["status"]?.string ?? "available"
            guard let id = nonEmpty(credit["id"]?.string), status == "available" || status == "redeeming" else { return nil }
            let expires = credit["expiresAt"] ?? .null
            return PlanReset(
                id: id, title: nonEmpty(credit["title"]?.string), grantedAt: date(credit["grantedAt"]),
                expiresAt: expires == .null ? nil : date(expires) ?? PlanReset.unreadable, redeeming: status == "redeeming")
        }
        return PlanResets(available: count, credits: credits.isEmpty ? nil : soonestFirst(credits))
    }

    /// By expiry, those that never expire last; in Codex's order where they tie.
    static func soonestFirst(_ credits: [PlanReset]) -> [PlanReset] {
        credits.enumerated()
            .sorted { a, b in
                let (x, y) = (a.element.expiresAt ?? .distantFuture, b.element.expiresAt ?? .distantFuture)
                return x == y ? a.offset < b.offset : x < y
            }
            .map(\.element)
    }

    /// Codex's names for its windows; others from their length.
    static func windowLabel(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Limit" }
        switch minutes {
        case 300: return "5h limit"
        case 1440: return "Daily limit"
        case 10080: return "Weekly limit"
        case 43200: return "Monthly limit"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)d limit" }
            if minutes % 60 == 0 { return "\(minutes / 60)h limit" }
            return "\(minutes)m limit"
        }
    }

    /// "ChatGPT Pro Lite" from `prolite`; "ChatGPT" when the plan isn't known.
    public static func codexPlan(_ raw: String?) -> String {
        let named: [String: String] = [
            "prolite": "Pro Lite", "promax": "Pro Max", "ent26": "Enterprise", "enterprise_cbp_automation": "Enterprise",
            "enterprise_cbp_usage_based": "Enterprise", "self_serve_business_prolite": "Business",
            "self_serve_business_usage_based": "Business", "edu_plus": "Edu Plus", "edu_pro": "Edu Pro",
        ]
        guard let raw = nonEmpty(raw), raw != "unknown" else { return "ChatGPT" }
        let name = named[raw] ?? raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return "ChatGPT " + name
    }
}

// MARK: - Shared

extension PlanReading {
    /// An ISO 8601 string (fractions of a second to any length) or seconds since 1970.
    static func date(_ value: JSONValue?) -> Date? {
        if let seconds = value?.double { return Date(timeIntervalSince1970: seconds) }
        guard let text = value?.string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text.replacing(/\.\d+/, with: ""))
    }

    /// The first line of a CLI's message, unless it's JSON or empty.
    static func plainReason(_ message: String?) -> String? {
        guard let line = message?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
            !line.isEmpty, !line.hasPrefix("{"), !line.hasPrefix("[")
        else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Reading

/// One reading per call, from the chat's own CLI when it runs, else from a short-lived one that
/// is sent nothing but the requests below and closed after.
public enum PlanUsage {
    /// How long a short-lived CLI may take to answer before it's closed.
    static let deadline: Duration = .seconds(30)

    /// From a running Claude session (`get_usage`, without the behaviour breakdown). Throws
    /// only when the session's process has gone.
    public static func claude(_ session: ClaudeSession, executable: URL? = nil) async throws -> PlanReading {
        let account = await session.capabilities["account"]
        do {
            let usage = try await session.usage()
            if !PlanReading.claudeSignedIn(account), !(await claudeLoggedIn(executable)) {
                return PlanReading(account: .signedOut, limits: nil)
            }
            PlanSnapshotLog.shared.append(PlanSnapshot.claude(usage: usage, account: PlanSnapshot.account(email: account?["email"]?.string)))
            return PlanReading.claude(account: account, usage: usage)
        } catch ClaudeSession.Failure.notRunning {
            throw ClaudeSession.Failure.notRunning
        } catch {
            if !PlanReading.claudeSignedIn(account), !(await claudeLoggedIn(executable)) {
                return PlanReading(account: .signedOut, limits: nil)
            }
            let message = if case ClaudeSession.Failure.controlError(let text) = error { text } else { "\(error)" }
            return PlanReading.claude(account: account, failure: message)
        }
    }

    /// From a short-lived `claude -p` that is never sent a message.
    public static func claude(executable: URL? = nil) async throws -> PlanReading {
        let session = try await ClaudeSession.start(
            .init(cwd: FileManager.default.homeDirectoryForCurrentUser, thinkingSummaries: false, executable: executable))
        let deadline = Task {
            try await Task.sleep(for: Self.deadline)
            await session.close()
        }
        defer {
            deadline.cancel()
            Task { await session.close() }
        }
        return try await claude(session, executable: executable)
    }

    /// From a running Codex app-server. Read-only: `account/read` and `account/rateLimits/read`.
    public static func codex(_ server: CodexAppServer) async throws -> PlanReading {
        let replies = await server.requests([
            ("account/read", [:]),
            // With the reset credits' details (a lookup of their own), so a reset can name the
            // one to use.
            ("account/rateLimits/read", [:]),
        ])
        guard replies.count == 2 else { throw CodexAppServer.Failure.notRunning }
        let account = try replies[0].get()
        switch replies[1] {
        case .success(let limits):
            let email = PlanSnapshot.account(email: account["account"]?["email"]?.string)
            PlanSnapshotLog.shared.append(PlanSnapshot.codex(rateLimits: limits, account: email, source: "read"))
            return PlanReading.codex(account: account, rateLimits: limits)
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return PlanReading.codex(account: account, rateLimits: nil, failure: message)
        }
    }

    /// From a short-lived `codex app-server`.
    public static func codex(executable: URL? = nil) async throws -> PlanReading {
        let server = try await CodexAppServer.start(cwd: FileManager.default.homeDirectoryForCurrentUser, executable: executable)
        let deadline = Task {
            try await Task.sleep(for: Self.deadline)
            await server.close()
        }
        defer {
            deadline.cancel()
            Task { await server.close() }
        }
        return try await codex(server)
    }

    /// `account/rateLimitResetCredit/consume`'s params: the attempt's key (the same on a retry of
    /// that attempt, so a credit is never used twice), and the credit (nil: Codex picks).
    public static func resetParams(credit: String?, attempt: UUID) -> JSONValue {
        var params: [String: JSONValue] = ["idempotencyKey": .string(attempt.uuidString.lowercased())]
        if let credit { params["creditId"] = .string(credit) }
        return .object(params)
    }

    /// Uses one full reset of the account's limits, through a running Codex app-server. Not
    /// read-only: it spends the credit.
    public static func useReset(_ server: CodexAppServer, credit: String?, attempt: UUID) async throws -> PlanResetOutcome {
        PlanResetOutcome(try await server.request("account/rateLimitResetCredit/consume", resetParams(credit: credit, attempt: attempt)))
    }

    /// The same through a short-lived `codex app-server`.
    public static func useReset(credit: String?, attempt: UUID, executable: URL? = nil) async throws -> PlanResetOutcome {
        let server = try await CodexAppServer.start(cwd: FileManager.default.homeDirectoryForCurrentUser, executable: executable)
        let deadline = Task {
            try await Task.sleep(for: Self.deadline)
            await server.close()
        }
        defer {
            deadline.cancel()
            Task { await server.close() }
        }
        return try await useReset(server, credit: credit, attempt: attempt)
    }

    /// `initialize` names no account: logged out, or signed in another way (an API key).
    private static func claudeLoggedIn(_ executable: URL?) async -> Bool {
        (try? await ClaudeAuth.status(executable: executable).loggedIn) ?? true
    }
}
