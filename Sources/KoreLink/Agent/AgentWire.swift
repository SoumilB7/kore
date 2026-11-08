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
    /// Until a chat's turn ends or a card asks: its answer and state.
    package static let wait = Self(name: "chat.wait", tier: .watch)

    // Own: the caller's own chat. Each changes it as its composer would; a mode only downwards.
    package static let options = Self(name: "chat.options", tier: .own)
    package static let rename = Self(name: "chat.rename", tier: .own)
    package static let model = Self(name: "chat.model", tier: .own)
    package static let effort = Self(name: "chat.effort", tier: .own)
    package static let fast = Self(name: "chat.fast", tier: .own)
    package static let mode = Self(name: "chat.mode", tier: .own)
    package static let compact = Self(name: "chat.compact", tier: .own)

    // Drive: the caller's window, at or below its own mode. Own's changes reach those chats too.
    package static let new = Self(name: "chat.new", tier: .drive)
    /// A fork of a chat it reaches, in a tab of its own: a new chat for the limits.
    package static let fork = Self(name: "chat.fork", tier: .drive)
    package static let send = Self(name: "chat.send", tier: .drive)
    package static let stop = Self(name: "chat.stop", tier: .drive)
    package static let showTab = Self(name: "tab.show", tier: .drive)
    package static let answer = Self(name: "cards.answer", tier: .drive)

    package static let all: [Self] = [
        whoami, caps, chats, show, read, follow, unfollow, cards, history, wait, options, rename, model, effort, fast, mode, compact,
        new, fork, send, stop, showTab, answer,
    ]

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
    /// Own reaches only the caller's own chat; Drive, chats at or below its mode in its window.
    case notOwn = "not_own"
    /// Over Drive's limits: sends a minute, new chats an hour, chats it made open at once.
    case limit
    /// The chat can't take that now, or only the user may do it (raising a mode).
    case refused
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
    /// Own's: what to set (`chat.rename`'s name, `chat.model`'s model, `chat.effort`'s level,
    /// `chat.mode`'s mode), and `chat.fast` on or off.
    package var to: String?
    package var on: Bool?
    /// Drive's: `chat.new`'s CLI (`claude`, `codex`), model and mode; a message (`chat.new`'s first,
    /// `chat.send`'s); `cards.answer`'s card, an answer per question, or deny.
    package var provider: String?
    package var model: String?
    package var mode: String?
    package var text: String?
    package var card: String?
    package var answers: [String]?
    package var deny: Bool?
    /// `chat.fork`: the user message to fork from (its row id, or its text or a part only it
    /// has); none forks at the end. `chat.wait`: seconds to wait, 300 at most.
    package var at: String?
    package var timeout: Int?
    /// `chat.new` from a chat on a box: `box` (its box and folder, the default) or `mac`.
    package var place: String?

    package init(
        chat: String? = nil, last: Int? = nil, before: String? = nil, folder: String? = nil, query: String? = nil,
        archived: Bool? = nil, offset: Int? = nil, to: String? = nil, on: Bool? = nil
    ) {
        self.provider = nil
        self.model = nil
        self.mode = nil
        self.text = nil
        self.card = nil
        self.answers = nil
        self.deny = nil
        self.at = nil
        self.timeout = nil
        self.place = nil
        self.chat = chat
        self.last = last
        self.before = before
        self.folder = folder
        self.query = query
        self.archived = archived
        self.offset = offset
        self.to = to
        self.on = on
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

/// What Own may set on a chat now.
package struct AgentOptions: Encodable, Sendable {
    package struct Model: Encodable, Sendable {
        package var id: String
        package var name: String
        package var efforts: [String]
    }

    package struct Mode: Encodable, Sendable {
        package var id: String
        package var label: String
        /// At or below the chat's mode now.
        package var allowed: Bool
    }

    package var chat: String
    package var models: [Model]
    package var model: String?
    package var effort: String?
    package var modes: [Mode]
    package var mode: String
    package var fast: Bool?
}

/// What a change did, in a line.
/// `chat.wait`: how the chat stands when the wait ended, and its last answer.
package struct AgentWaited: Encodable, Sendable {
    package var chat: String
    /// `idle`, `needs-you` (a card asks), `failed`, `stuck`, or `working` when it timed out.
    package var state: String
    package var answer: String?
    package var cards: Int
    package var timedOut: Bool
}

package struct AgentDone: Encodable, Sendable {
    package var chat: String
    package var message: String
    /// `chat.new`: the new chat's short id, for the next command.
    package var short: String? = nil
}
