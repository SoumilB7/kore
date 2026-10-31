import Foundation

// The phone remote's wire protocol, version 1, as Swift values. `protocol/src/schema.ts` is the
// normative definition; these mirror it by hand, and `KoreRemoteTests/FixtureTests` reads and
// writes every fixture in `protocol/fixtures/v1` to keep the two the same.

package enum Proto {
    package static let major = 1
    package static let minor = 0
    package static var version: WireVersion { WireVersion(major: major, minor: minor) }
}

package struct WireVersion: Codable, Sendable, Equatable {
    package var major: Int
    package var minor: Int
}

// MARK: - Text as a render tree

package struct Span: Codable, Sendable, Equatable {
    package var text: String
    package var code: Bool?
    package var em: Bool?
    package var strong: Bool?
    package var strike: Bool?
    package var link: String?

    package init(_ text: String, code: Bool? = nil, em: Bool? = nil, strong: Bool? = nil, strike: Bool? = nil, link: String? = nil) {
        self.text = text
        self.code = code
        self.em = em
        self.strong = strong
        self.strike = strike
        self.link = link
    }
}

package struct ListItem: Codable, Sendable, Equatable {
    package var task: Bool?
    package var blocks: [Block]

    package init(task: Bool? = nil, blocks: [Block]) {
        self.task = task
        self.blocks = blocks
    }
}

/// One block of formatted text (`schema.ts` `Block`).
package indirect enum Block: Codable, Sendable, Equatable {
    case heading(level: Int, spans: [Span])
    case paragraph([Span])
    case code(lang: String, text: String, open: Bool)
    case list(ordered: Bool, start: Int, items: [ListItem])
    case quote([Block])
    case table(header: [[Span]], rows: [[[Span]]])
    case rule
    /// A kind from a newer host: shown as nothing.
    case unknown

    private enum Key: String, CodingKey { case k, level, spans, lang, text, open, ordered, start, items, blocks, header, rows }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .k) {
        case "heading": self = .heading(level: try c.decode(Int.self, forKey: .level), spans: try c.decode([Span].self, forKey: .spans))
        case "paragraph": self = .paragraph(try c.decode([Span].self, forKey: .spans))
        case "code":
            self = .code(
                lang: try c.decode(String.self, forKey: .lang), text: try c.decode(String.self, forKey: .text),
                open: try c.decodeIfPresent(Bool.self, forKey: .open) ?? false)
        case "list":
            self = .list(
                ordered: try c.decode(Bool.self, forKey: .ordered), start: try c.decode(Int.self, forKey: .start),
                items: try c.decode([ListItem].self, forKey: .items))
        case "quote": self = .quote(try c.decode([Block].self, forKey: .blocks))
        case "table": self = .table(header: try c.decode([[Span]].self, forKey: .header), rows: try c.decode([[[Span]]].self, forKey: .rows))
        case "rule": self = .rule
        default: self = .unknown
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .heading(let level, let spans):
            try c.encode("heading", forKey: .k)
            try c.encode(level, forKey: .level)
            try c.encode(spans, forKey: .spans)
        case .paragraph(let spans):
            try c.encode("paragraph", forKey: .k)
            try c.encode(spans, forKey: .spans)
        case .code(let lang, let text, let open):
            try c.encode("code", forKey: .k)
            try c.encode(lang, forKey: .lang)
            try c.encode(text, forKey: .text)
            if open { try c.encode(true, forKey: .open) }
        case .list(let ordered, let start, let items):
            try c.encode("list", forKey: .k)
            try c.encode(ordered, forKey: .ordered)
            try c.encode(start, forKey: .start)
            try c.encode(items, forKey: .items)
        case .quote(let blocks):
            try c.encode("quote", forKey: .k)
            try c.encode(blocks, forKey: .blocks)
        case .table(let header, let rows):
            try c.encode("table", forKey: .k)
            try c.encode(header, forKey: .header)
            try c.encode(rows, forKey: .rows)
        case .rule: try c.encode("rule", forKey: .k)
        case .unknown: try c.encode("unknown", forKey: .k)
        }
    }
}

// MARK: - Providers and modes

/// How far a mode lets the agent act without asking: the phone may only lower a chat's mode,
/// and sends only to chats at or below the Mac's cap.
package enum ModeLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case plan = 0, manual = 1, edits = 2, auto = 3, danger = 4

    package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        // A level past the known ones is treated as the most permissive.
        self = ModeLevel(rawValue: raw) ?? .danger
    }
}

package struct ModeInfo: Codable, Sendable, Equatable {
    package var id: String
    package var label: String
    package var level: ModeLevel
    package var listed: Bool

    package init(id: String, label: String, level: ModeLevel, listed: Bool) {
        self.id = id
        self.label = label
        self.level = level
        self.listed = listed
    }
}

package struct PlanToggleInfo: Codable, Sendable, Equatable {
    package var id: String
    package var label: String

    package init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

package struct ProviderFeatures: Codable, Sendable, Equatable {
    package var effort: Bool
    package var fastMode: Bool

    package init(effort: Bool, fastMode: Bool) {
        self.effort = effort
        self.fastMode = fastMode
    }
}

package struct ProviderInfo: Codable, Sendable, Equatable {
    package var id: String
    package var name: String
    package var modes: [ModeInfo]
    package var planToggle: PlanToggleInfo?
    package var features: ProviderFeatures

    package init(id: String, name: String, modes: [ModeInfo], planToggle: PlanToggleInfo?, features: ProviderFeatures) {
        self.id = id
        self.name = name
        self.modes = modes
        self.planToggle = planToggle
        self.features = features
    }

    private enum Key: String, CodingKey { case id, name, modes, planToggle, features }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        modes = try c.decode([ModeInfo].self, forKey: .modes)
        planToggle = try c.decodeIfPresent(PlanToggleInfo.self, forKey: .planToggle)
        features = try c.decode(ProviderFeatures.self, forKey: .features)
    }

    /// `planToggle` is null, not omitted, when there's none.
    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(modes, forKey: .modes)
        try c.encode(planToggle, forKey: .planToggle)
        try c.encode(features, forKey: .features)
    }
}

// MARK: - Windows, tabs, chats

package struct WireTab: Codable, Sendable, Equatable {
    package enum Kind: String, LenientEnum { case chat, agent, file, board, empty, unknown }

    package struct Section: Codable, Sendable, Equatable {
        package var id: String
        package var name: String
        package var chatIds: [String]

        package init(id: String, name: String, chatIds: [String]) {
            self.id = id
            self.name = name
            self.chatIds = chatIds
        }
    }

    package struct Board: Codable, Sendable, Equatable {
        package var sections: [Section]
        package init(sections: [Section]) { self.sections = sections }
    }

    package var id: String
    package var kind: Kind
    package var title: String
    package var chatId: String?
    package var board: Board?

    package init(id: String, kind: Kind, title: String, chatId: String? = nil, board: Board? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.chatId = chatId
        self.board = board
    }
}

package struct WireWindow: Codable, Sendable, Equatable {
    package var id: String
    package var name: String
    package var path: String
    package var tabs: [WireTab]
    package var activeTabId: String?

    package init(id: String, name: String, path: String, tabs: [WireTab], activeTabId: String?) {
        self.id = id
        self.name = name
        self.path = path
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
}

package struct CardAction: Codable, Sendable, Equatable {
    package enum ID: String, LenientEnum {
        case allow, allowAlways, deny, approvePlan, approvePlanAcceptEdits, keepPlanning, implement, stay, submitAnswers, unknown
    }

    package enum Style: String, LenientEnum { case primary, neutral, destructive, unknown }

    package var id: ID
    package var label: String
    package var style: Style
    package var refused: Bool?

    package init(id: ID, label: String, style: Style, refused: Bool? = nil) {
        self.id = id
        self.label = label
        self.style = style
        self.refused = refused
    }
}

package struct WireQuestion: Codable, Sendable, Equatable {
    package struct Option: Codable, Sendable, Equatable {
        package var label: String
        package var description: String
        package var preview: String?

        package init(label: String, description: String, preview: String?) {
            self.label = label
            self.description = description
            self.preview = preview
        }
    }

    package var id: String
    package var text: String
    package var header: String
    package var options: [Option]
    package var multiple: Bool
    package var secret: Bool
    package var other: Bool

    package init(id: String, text: String, header: String, options: [Option], multiple: Bool, secret: Bool, other: Bool) {
        self.id = id
        self.text = text
        self.header = header
        self.options = options
        self.multiple = multiple
        self.secret = secret
        self.other = other
    }
}

package struct WireCard: Codable, Sendable, Equatable {
    package enum Kind: String, LenientEnum { case permission, questions, plan, planReady, signIn, unknown }

    package var id: String
    package var kind: Kind
    package var title: String
    package var detail: String?
    package var body: String?
    package var bodyLen: Int?
    package var plan: [Block]?
    package var questions: [WireQuestion]?
    package var agent: String?
    package var actions: [CardAction]

    package init(
        id: String, kind: Kind, title: String, detail: String? = nil, body: String? = nil, bodyLen: Int? = nil,
        plan: [Block]? = nil, questions: [WireQuestion]? = nil, agent: String? = nil, actions: [CardAction]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.body = body
        self.bodyLen = bodyLen
        self.plan = plan
        self.questions = questions
        self.agent = agent
        self.actions = actions
    }
}

package struct ChatMeta: Codable, Sendable, Equatable {
    package enum State: String, LenientEnum { case needsYou, failed, stuck, working, idle, unknown }

    package struct Mode: Codable, Sendable, Equatable {
        package var id: String
        package var level: ModeLevel
        package var planOn: Bool?

        package init(id: String, level: ModeLevel, planOn: Bool? = nil) {
            self.id = id
            self.level = level
            self.planOn = planOn
        }
    }

    package struct Can: Codable, Sendable, Equatable {
        package var send: Bool
        package var stop: Bool

        package init(send: Bool, stop: Bool) {
            self.send = send
            self.stop = stop
        }
    }

    package var id: String
    package var provider: String
    package var title: String
    package var state: State
    package var mode: Mode
    package var modeIds: [String]
    package var allowedModeIds: [String]
    package var model: String?
    package var queued: Int
    package var running: Bool
    package var cards: [WireCard]
    package var can: Can

    package init(
        id: String, provider: String, title: String, state: State, mode: Mode, modeIds: [String], allowedModeIds: [String],
        model: String?, queued: Int, running: Bool, cards: [WireCard], can: Can
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.state = state
        self.mode = mode
        self.modeIds = modeIds
        self.allowedModeIds = allowedModeIds
        self.model = model
        self.queued = queued
        self.running = running
        self.cards = cards
        self.can = can
    }
}

// MARK: - Transcript

package struct WireEntry: Codable, Sendable, Equatable {
    package enum Kind: String, LenientEnum {
        case user, answer, thinking, plan, tool, agent, notice, peer, divider, mode, summary, unknown
    }

    package struct Tool: Codable, Sendable, Equatable {
        package var name: String
        package var summary: String?
        package var input: String?
        package var inputLen: Int
        package var path: String?
        package var readOnly: Bool
        package var result: String?
        package var resultLen: Int

        package init(
            name: String, summary: String?, input: String?, inputLen: Int, path: String?, readOnly: Bool, result: String?,
            resultLen: Int
        ) {
            self.name = name
            self.summary = summary
            self.input = input
            self.inputLen = inputLen
            self.path = path
            self.readOnly = readOnly
            self.result = result
            self.resultLen = resultLen
        }
    }

    package struct Change: Codable, Sendable, Equatable {
        package var path: String
        package var added: Int
        package var removed: Int

        package init(path: String, added: Int, removed: Int) {
            self.path = path
            self.added = added
            self.removed = removed
        }
    }

    package struct Agent: Codable, Sendable, Equatable {
        package var id: String
        package var name: String
        package var status: String

        package init(id: String, name: String, status: String) {
            self.id = id
            self.name = name
            self.status = status
        }
    }

    package var id: String
    package var kind: Kind
    package var turn: String?
    package var text: String?
    package var doc: [Block]?
    package var textLen: Int
    package var done: Bool
    package var isError: Bool
    package var stopped: Bool
    package var inTurn: Bool
    package var tool: Tool?
    package var changes: [Change]?
    package var agent: Agent?

    package init(
        id: String, kind: Kind, turn: String? = nil, text: String? = nil, doc: [Block]? = nil, textLen: Int, done: Bool,
        isError: Bool = false, stopped: Bool = false, inTurn: Bool = false, tool: Tool? = nil, changes: [Change]? = nil,
        agent: Agent? = nil
    ) {
        self.id = id
        self.kind = kind
        self.turn = turn
        self.text = text
        self.doc = doc
        self.textLen = textLen
        self.done = done
        self.isError = isError
        self.stopped = stopped
        self.inTurn = inTurn
        self.tool = tool
        self.changes = changes
        self.agent = agent
    }
}

package struct WireTurn: Codable, Sendable, Equatable {
    package enum Outcome: String, LenientEnum { case completed, interrupted, failed, authFailed, slept, unknown }

    package var id: String
    package var startedAt: Double
    package var duration: Double?
    package var finished: Bool
    package var outcome: Outcome

    package init(id: String, startedAt: Double, duration: Double?, finished: Bool, outcome: Outcome) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.finished = finished
        self.outcome = outcome
    }
}

// MARK: - Attention

package struct AttnItem: Codable, Sendable, Equatable {
    package enum Kind: String, LenientEnum { case approval, question, plan, planReady, signIn, unknown }

    package var key: String
    package var chatId: String
    package var provider: String
    package var window: String
    package var chatTitle: String
    package var kind: Kind
    package var cardId: String

    package init(chatId: String, provider: String, window: String, chatTitle: String, kind: Kind, cardId: String) {
        self.key = "\(chatId)/\(cardId)"
        self.chatId = chatId
        self.provider = provider
        self.window = window
        self.chatTitle = chatTitle
        self.kind = kind
        self.cardId = cardId
    }
}

package struct AttnTurn: Codable, Sendable, Equatable {
    package enum Outcome: String, LenientEnum { case finished, failed, unknown }

    package var chatId: String
    package var provider: String
    package var window: String
    package var chatTitle: String
    package var turnId: String
    package var outcome: Outcome
    package var at: Double

    package init(chatId: String, provider: String, window: String, chatTitle: String, turnId: String, outcome: Outcome, at: Double) {
        self.chatId = chatId
        self.provider = provider
        self.window = window
        self.chatTitle = chatTitle
        self.turnId = turnId
        self.outcome = outcome
        self.at = at
    }
}

// MARK: - Commands

package enum RemoteCommand: Codable, Sendable, Equatable {
    package enum PlanChoice: String, LenientEnum { case implement, stay, unknown }

    case send(chatId: String, text: String)
    case stop(chatId: String)
    case answer(chatId: String, cardId: String, action: CardAction.ID, answers: [String: [String]]?)
    case setMode(chatId: String, modeId: String)
    case setPlan(chatId: String, on: Bool)
    case planReady(chatId: String, choice: PlanChoice)
    case new(windowId: String, provider: String)

    /// The chat it acts on; nil for a new chat.
    package var chatId: String? {
        switch self {
        case .send(let id, _), .stop(let id), .answer(let id, _, _, _), .setMode(let id, _), .setPlan(let id, _), .planReady(let id, _): id
        case .new: nil
        }
    }

    /// Its name on the wire, also the Activity log's.
    package var type: String {
        switch self {
        case .send: "chat.send"
        case .stop: "chat.stop"
        case .answer: "chat.answer"
        case .setMode: "chat.setMode"
        case .setPlan: "chat.setPlan"
        case .planReady: "chat.planReady"
        case .new: "chat.new"
        }
    }

    private enum Key: String, CodingKey { case type, chatId, text, cardId, action, answers, modeId, on, choice, windowId, provider }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        func chat() throws -> String { try c.decode(String.self, forKey: .chatId) }
        switch type {
        case "chat.send": self = .send(chatId: try chat(), text: try c.decode(String.self, forKey: .text))
        case "chat.stop": self = .stop(chatId: try chat())
        case "chat.answer":
            self = .answer(
                chatId: try chat(), cardId: try c.decode(String.self, forKey: .cardId),
                action: try c.decode(CardAction.ID.self, forKey: .action),
                answers: try c.decodeIfPresent([String: [String]].self, forKey: .answers))
        case "chat.setMode": self = .setMode(chatId: try chat(), modeId: try c.decode(String.self, forKey: .modeId))
        case "chat.setPlan": self = .setPlan(chatId: try chat(), on: try c.decode(Bool.self, forKey: .on))
        case "chat.planReady": self = .planReady(chatId: try chat(), choice: try c.decode(PlanChoice.self, forKey: .choice))
        case "chat.new": self = .new(windowId: try c.decode(String.self, forKey: .windowId), provider: try c.decode(String.self, forKey: .provider))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown command \(type)")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .send(let chatId, let text):
            try c.encode(chatId, forKey: .chatId)
            try c.encode(text, forKey: .text)
        case .stop(let chatId):
            try c.encode(chatId, forKey: .chatId)
        case .answer(let chatId, let cardId, let action, let answers):
            try c.encode(chatId, forKey: .chatId)
            try c.encode(cardId, forKey: .cardId)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(answers, forKey: .answers)
        case .setMode(let chatId, let modeId):
            try c.encode(chatId, forKey: .chatId)
            try c.encode(modeId, forKey: .modeId)
        case .setPlan(let chatId, let on):
            try c.encode(chatId, forKey: .chatId)
            try c.encode(on, forKey: .on)
        case .planReady(let chatId, let choice):
            try c.encode(chatId, forKey: .chatId)
            try c.encode(choice, forKey: .choice)
        case .new(let windowId, let provider):
            try c.encode(windowId, forKey: .windowId)
            try c.encode(provider, forKey: .provider)
        }
    }
}

/// Why a command didn't go through (`schema.ts` `ResultCode`).
package enum ResultCode: String, LenientEnum {
    case sendCap = "denied.sendCap"
    case raiseMode = "denied.raiseMode"
    case alwaysAllow = "denied.alwaysAllow"
    case command = "denied.command"
    case signIn = "denied.signIn"
    case action = "denied.action"
    case goneChat = "gone.chat"
    case goneCard = "gone.card"
    case goneWindow = "gone.window"
    case busy
    case invalid
    case rateLimited
    case unknown
}
