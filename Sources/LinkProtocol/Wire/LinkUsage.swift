import Foundation

/// Phase 18 §4: what a box's chats spent, pulled by the Mac on link-up (`usage.since{cursor}`)
/// into its forwarded usage, keyed `<node>/<chat>`; each request's `id` stops double counting.
/// A paired Mac serves its own Kore chats' the same way. Each line names the login it ran on
/// (`acct`); an asker that says `plan` also gets the plan's readings the device heard, as their
/// own lines, so its usage card splits each login's limits by every device's evidence.
package enum UsageWire {
    package static let since = "usage.since"
    package static let page = "usage.page"

    /// Mac → box: the lines after `cursor` (nil: all the box keeps).
    package struct Since: Codable, Equatable, Sendable {
        package var t = UsageWire.since
        package var id: String
        package var cursor: Int?
        /// It takes plan lines (`UsageLine.plan`); an older asker doesn't, and gets none.
        package var plan: Bool?

        package init(id: String, cursor: Int?, plan: Bool? = nil) {
            self.id = id
            self.cursor = cursor
            self.plan = plan
        }
    }

    /// Box → Mac: lines in order, the cursor to ask from next, and whether more wait.
    package struct Page: Codable, Equatable, Sendable {
        package var t = UsageWire.page
        package var id: String
        package var lines: [UsageLine]
        package var cursor: Int
        package var more: Bool

        package init(id: String, lines: [UsageLine], cursor: Int, more: Bool) {
            self.id = id
            self.lines = lines
            self.cursor = cursor
            self.more = more
        }
    }
}

/// One plan window as a device heard it (a turn's report, a read): its length in minutes, percent
/// used, when it resets (ms since 1970), and its own limit (Claude's model week, Codex's id).
package struct PlanWindowWire: Codable, Equatable, Sendable {
    package var minutes: Int
    package var used: Double
    package var resets: Int64?
    package var limit: String?

    package init(minutes: Int, used: Double, resets: Int64?, limit: String? = nil) {
        (self.minutes, self.used, self.resets, self.limit) = (minutes, used, resets, limit)
    }
}

/// One model request a device's chat made: its ledger number, when (ms since 1970), the chat and
/// CLI, the request's own id, its tokens, and the login it ran on (`acct`: the email's short hash,
/// never the email; absent from older boxes). A plan line instead carries `plan`, the readings
/// the device heard then for `acct`, and no tokens: it is never a request. Its `chat`, when not
/// empty, is the chat whose request the report came before (Claude's turn report), named as that
/// chat's request lines name it; empty for a read.
package struct UsageLine: Codable, Equatable, Sendable {
    package var n: Int
    package var at: Int64
    package var chat: String
    package var provider: String
    package var id: String
    package var model: String?
    package var agent: String?
    package var input: Int
    package var output: Int
    package var cacheRead: Int
    package var cacheWrite5m: Int
    package var cacheWrite1h: Int
    /// The login it ran on (`PlanSnapshot.account`); nil from a box that doesn't say.
    package var acct: String?
    /// A plan line's readings; nil for a request.
    package var plan: [PlanWindowWire]?

    package var isPlan: Bool { plan != nil }

    package init(
        n: Int, at: Int64, chat: String, provider: String, id: String, model: String?, agent: String?, input: Int, output: Int, cacheRead: Int,
        cacheWrite5m: Int, cacheWrite1h: Int, acct: String? = nil, plan: [PlanWindowWire]? = nil
    ) {
        self.n = n
        self.at = at
        self.chat = chat
        self.provider = provider
        self.id = id
        self.model = model
        self.agent = agent
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.acct = acct
        self.plan = plan
    }

    /// A plan line: `readings` of `acct`'s windows at `at`.
    package static func plan(n: Int, at: Int64, provider: String, acct: String, readings: [PlanWindowWire], chat: String? = nil) -> UsageLine {
        UsageLine(
            n: n, at: at, chat: chat ?? "", provider: provider, id: "plan-\(at)-\(n)", model: nil, agent: nil, input: 0, output: 0, cacheRead: 0,
            cacheWrite5m: 0, cacheWrite1h: 0, acct: acct, plan: readings)
    }
}
