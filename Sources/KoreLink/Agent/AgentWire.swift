import Foundation

/// The agent channel's messages (`z-docs/agent-protocol.md`): one JSON object per line, each way.
/// A caller says `hello` first; every line after it is a command, answered by one `result` with
/// its id (and, for `tx.follow`, `event` lines carrying that id until it's closed).
package enum AgentProto {
    package static let version = 1
    /// The longest line Kore reads; a longer one ends the connection.
    package static let lineMax = 64 * 1024
    /// How long a new connection has to say hello.
    package static let helloWithin: TimeInterval = 5
}

/// A chat's Kore access, lowest first. Each adds to the one before (`kore-access.html`); step 1
/// serves Watch's reads, and the higher tiers hold the same reads until their commands exist.
package enum AgentTier: String, Codable, Sendable, CaseIterable, Comparable {
    case off, watch, own, drive, full

    package static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A command and the lowest tier that may run it.
package struct AgentCommand: Sendable, Equatable {
    package let name: String
    package let tier: AgentTier

    package static let whoami = Self(name: "agent.whoami", tier: .watch)
    package static let caps = Self(name: "agent.caps", tier: .watch)
    package static let chats = Self(name: "chats.list", tier: .watch)
    package static let show = Self(name: "chat.show", tier: .watch)
    package static let read = Self(name: "tx.read", tier: .watch)
    package static let follow = Self(name: "tx.follow", tier: .watch)
    package static let unfollow = Self(name: "tx.unfollow", tier: .watch)
    package static let cards = Self(name: "cards.list", tier: .watch)
    package static let history = Self(name: "history.list", tier: .watch)

    package static let all: [Self] = [whoami, caps, chats, show, read, follow, unfollow, cards, history]

    /// Why `tier` may not run `name`; nil when it may.
    package static func refusal(_ name: String, tier: AgentTier, among commands: [Self] = all) -> AgentCode? {
        guard let command = commands.first(where: { $0.name == name }) else { return .unknownCommand }
        return command.tier <= tier ? nil : .tier
    }

    /// What `tier` may run, in the order above.
    package static func allowed(_ tier: AgentTier) -> [Self] { tier == .off ? [] : all.filter { $0.tier <= tier } }
}

/// Why Kore said no, as `code` on a failed result or a `bye`.
package enum AgentCode: String, Codable, Sendable {
    /// The first line wasn't a hello, or a line wasn't JSON.
    case invalid
    /// A hello for another major version.
    case version
    /// The caller isn't a chat that has Kore access (and external callers aren't served yet).
    case denied
    /// The pass and the process tree name different chats, or the pass names none.
    case mismatch
    /// Above the caller's tier.
    case tier
    case unknownCommand = "unknown_command"
    case rateLimited = "rate_limited"
    case noChat = "no_chat"
    case ambiguous
    case noWindow = "no_window"
    /// Agent control was stopped, or this chat's access turned off.
    case stopped
}

// MARK: Lines in

package struct AgentIn: Decodable, Sendable {
    package var type: String
    package var proto: Int?
    package var client: String?
    package var pass: String?
    package var id: String?
    package var cmd: String?
    package var args: AgentArgs?
}

/// Every command's arguments: each reads the ones it takes.
package struct AgentArgs: Codable, Sendable, Equatable {
    /// A chat: its id, short id, a unique part of its title, or `.` for the caller's own.
    package var chat: String?
    /// Rows to read (`tx.read`, `tx.follow`), and the row to read back from.
    package var last: Int?
    package var before: String?
    /// `history.list`: the folder asked for, which has to be the caller's own chat's.
    package var folder: String?
    package var query: String?
    package var archived: Bool?
    package var offset: Int?

    package init(
        chat: String? = nil, last: Int? = nil, before: String? = nil, folder: String? = nil, query: String? = nil,
        archived: Bool? = nil, offset: Int? = nil
    ) {
        self.chat = chat
        self.last = last
        self.before = before
        self.folder = folder
        self.query = query
        self.archived = archived
        self.offset = offset
    }
}

// MARK: Lines out

package struct AgentWelcome: Encodable, Sendable {
    package var type = "welcome"
    package var proto = AgentProto.version
    package var caller: AgentCallerInfo
    package var tier: AgentTier
    package var commands: [String]
}

package struct AgentCallerInfo: Codable, Sendable, Equatable {
    /// `chat` or `external`.
    package var `class`: String
    package var chat: String?
    package var short: String?
    package var title: String?
}

package struct AgentBye: Encodable, Sendable {
    package var type = "bye"
    package var code: AgentCode
    package var message: String
}

package struct AgentResult<Data: Encodable & Sendable>: Encodable, Sendable {
    package var type = "result"
    package var id: String
    package var ok: Bool
    package var data: Data?
    package var code: AgentCode?
    package var message: String?
}

package struct AgentEvent: Encodable, Sendable {
    package var type = "event"
    /// The `tx.follow` it belongs to.
    package var id: String
    package var chat: String
    /// `row` (new or changed), `state` (the chat's status changed) or `gone` (the chat closed).
    package var event: String
    package var row: AgentRow?
    package var state: String?
}

/// Nothing to say beyond `ok`.
package struct AgentEmpty: Encodable, Sendable {}

// MARK: Values

package struct AgentWhoami: Encodable, Sendable {
    package var caller: AgentCallerInfo
    package var tier: AgentTier
    package var proto = AgentProto.version
}

package struct AgentCaps: Encodable, Sendable {
    package var tier: AgentTier
    package var commands: [String]
}

package struct AgentChat: Encodable, Sendable, Equatable {
    package var id: String
    package var short: String
    package var title: String
    package var provider: String
    /// The window's folder, home-relative.
    package var folder: String
    package var window: String
    /// `working`, `idle`, `needs-you`, `failed` or `stuck`.
    package var state: String
    package var mode: String
    package var modeLabel: String?
    package var planOn: Bool?
    package var model: String?
    package var queued: Int
    package var cards: Int
    /// The caller's own chat.
    package var own: Bool?
}

package struct AgentChatDetail: Encodable, Sendable {
    package var chat: AgentChat
    package var session: String?
    package var effort: String?
    package var context: Context?
    package var rows: Int
    package var pending: [AgentCard]

    package struct Context: Encodable, Sendable, Equatable {
        package var used: Int
        package var window: Int?
        package var pct: Int?
    }
}

package struct AgentRow: Encodable, Sendable, Equatable {
    package var id: String
    /// `user`, `answer`, `thinking`, `plan`, `tool`, `agent`, `notice`, `peer`, `divider`, `mode`, `summary`.
    package var kind: String
    package var turn: String?
    package var text: String?
    /// The whole text's length, when `text` was cut.
    package var textLen: Int?
    package var tool: Tool?
    package var agent: String?
    package var done: Bool
    package var error: Bool?
    package var stopped: Bool?

    package struct Tool: Encodable, Sendable, Equatable {
        package var name: String
        package var summary: String?
        package var path: String?
        package var input: String?
        package var result: String?
    }
}

package struct AgentRows: Encodable, Sendable {
    package var chat: String
    package var rows: [AgentRow]
    /// Rows before the first one here.
    package var more: Bool
}

package struct AgentCard: Encodable, Sendable, Equatable {
    package var chat: String
    package var chatShort: String
    package var chatTitle: String
    package var id: String
    /// `permission`, `questions`, `plan`, `planReady` or `signIn`.
    package var kind: String
    package var title: String
    package var detail: String?
    package var body: String?
    package var questions: [Question]?

    package struct Question: Encodable, Sendable, Equatable {
        package var text: String
        package var options: [String]
    }
}

package struct AgentCards: Encodable, Sendable {
    package var cards: [AgentCard]
}

package struct AgentChats: Encodable, Sendable {
    package var chats: [AgentChat]
}

package struct AgentSession: Encodable, Sendable {
    package var id: String
    package var provider: String
    package var title: String
    /// ISO 8601.
    package var updated: String
    package var archived: Bool
    /// Open in a tab now.
    package var open: Bool
}

package struct AgentHistory: Encodable, Sendable {
    package var folder: String
    package var sessions: [AgentSession]
    package var more: Bool
}
