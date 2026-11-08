import Foundation

/// Phase 18 §4: what a box's chats spent, pulled by the Mac on link-up (`usage.since{cursor}`)
/// into its forwarded usage, keyed `<node>/<chat>`; each request's `id` stops double counting.
package enum UsageWire {
    package static let since = "usage.since"
    package static let page = "usage.page"

    /// Mac → box: the lines after `cursor` (nil: all the box keeps).
    package struct Since: Codable, Equatable, Sendable {
        package var t = UsageWire.since
        package var id: String
        package var cursor: Int?

        package init(id: String, cursor: Int?) {
            self.id = id
            self.cursor = cursor
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

/// One model request a box chat made: its ledger number, when (ms since 1970), the chat and CLI,
/// the request's own id, and its tokens.
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

    package init(
        n: Int, at: Int64, chat: String, provider: String, id: String, model: String?, agent: String?, input: Int, output: Int, cacheRead: Int,
        cacheWrite5m: Int, cacheWrite1h: Int
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
    }
}
