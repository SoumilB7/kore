import CryptoKit
import Foundation

// The local link's protocol, version 1.0, as Swift values. `z-docs/link-protocol.md` is the
// definition; `Tests/Fixtures/link/v1` holds one JSON file per message, and `LinkFixtureTests`
// decodes and re-encodes every one.

package enum LinkProto {
    package static let major = 1
    package static let minor = 1
    package static var version: LinkVersion { LinkVersion(major: major, minor: minor) }
}

package struct LinkVersion: Codable, Sendable, Equatable {
    package var major: Int
    package var minor: Int

    package init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }
}

/// An enum read from text, where a value from a newer peer reads as `unknown`.
package protocol LenientEnum: RawRepresentable, Codable, Sendable, Equatable where RawValue == String {
    static var unknown: Self { get }
}

extension LenientEnum {
    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A short id that stays the same for the same text (a window's folder).
package enum StableID {
    package static func of(_ text: String, prefix: String = "") -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return prefix + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
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

package indirect enum Block: Codable, Sendable, Equatable {
    case heading(level: Int, spans: [Span])
    case paragraph([Span])
    case code(lang: String, text: String, open: Bool)
    case list(ordered: Bool, start: Int, items: [ListItem])
    case quote([Block])
    case table(header: [[Span]], rows: [[[Span]]])
    case rule
    /// A kind from a newer Kore: shown as nothing.
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

/// How far a mode lets the agent act without asking: the link may only lower a chat's mode, and
/// sends only to chats at or below Kore's cap.
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

package struct LinkTab: Codable, Sendable, Equatable {
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

package struct LinkWindow: Codable, Sendable, Equatable {
    package var id: String
    package var name: String
    package var path: String
    package var tabs: [LinkTab]
    package var activeTabId: String?

    package init(id: String, name: String, path: String, tabs: [LinkTab], activeTabId: String?) {
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

package struct LinkQuestion: Codable, Sendable, Equatable {
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

package struct LinkCard: Codable, Sendable, Equatable {
    package enum Kind: String, LenientEnum { case permission, questions, plan, planReady, signIn, unknown }

    package var id: String
    package var kind: Kind
    package var title: String
    package var detail: String?
    package var body: String?
    package var bodyLen: Int?
    package var plan: [Block]?
    package var questions: [LinkQuestion]?
    package var agent: String?
    package var actions: [CardAction]
    /// Base64 SHA-256 of the card's canonical encoding (`LinkCardDigest`), over its full content.
    package var digest: String

    package init(
        id: String, kind: Kind, title: String, detail: String? = nil, body: String? = nil, bodyLen: Int? = nil,
        plan: [Block]? = nil, questions: [LinkQuestion]? = nil, agent: String? = nil, actions: [CardAction], digest: String
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
        self.digest = digest
    }
}

/// What a card's digest covers: its full content, not what is shown of it. Encoded as UTF-8 JSON
/// with sorted keys, no whitespace and unescaped slashes; absent values are `null`.
package struct LinkCardDigest: Encodable, Sendable, Equatable {
    package var kind: LinkCard.Kind
    package var title: String
    package var detail: String?
    /// The card's whole content (the command, or the file and its change).
    package var body: String?
    /// A plan card's whole plan, as markdown text.
    package var plan: String?
    package var questions: [LinkQuestion]?
    package var actions: [CardAction]

    package init(
        kind: LinkCard.Kind, title: String, detail: String?, body: String?, plan: String?, questions: [LinkQuestion]?, actions: [CardAction]
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.body = body
        self.plan = plan
        self.questions = questions
        self.actions = actions
    }

    private enum Key: String, CodingKey { case actions, body, detail, kind, plan, questions, title }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(actions, forKey: .actions)
        try c.encode(body, forKey: .body)
        try c.encode(detail, forKey: .detail)
        try c.encode(kind, forKey: .kind)
        try c.encode(plan, forKey: .plan)
        try c.encode(questions, forKey: .questions)
        try c.encode(title, forKey: .title)
    }

    /// The canonical bytes.
    package var canonical: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Base64 SHA-256 of the canonical bytes.
    package var digest: String { Data(SHA256.hash(data: canonical)).base64EncodedString() }
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
    package var cards: [LinkCard]
    package var can: Can
    /// The "/" commands the chat offers that the link may send (1.1). Kore's own entries are left
    /// out: they open Kore's popups and send the CLI nothing.
    package var commands: [LinkSlash]?

    package init(
        id: String, provider: String, title: String, state: State, mode: Mode, modeIds: [String], allowedModeIds: [String],
        model: String?, queued: Int, running: Bool, cards: [LinkCard], can: Can, commands: [LinkSlash]? = nil
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
        self.commands = commands
    }
}

/// One "/" command a chat offers: a CLI command (sent as `/name`) or a skill (Codex, `$name`).
package struct LinkSlash: Codable, Sendable, Equatable {
    package enum Kind: String, LenientEnum { case command, skill, unknown }
    package var name: String
    package var description: String
    package var kind: Kind
    package init(name: String, description: String, kind: Kind) {
        self.name = name
        self.description = description
        self.kind = kind
    }
}

/// A file attached to a user message (1.1). `ref` is opaque and only means something with its chat:
/// `blob.get` serves it, and only refs in that chat's transcript.
package struct LinkAttachment: Codable, Sendable, Equatable {
    package enum Kind: String, LenientEnum { case image, text, pdf, other, unknown }
    package var ref: String
    package var name: String
    package var kind: Kind
    package init(ref: String, name: String, kind: Kind) {
        self.ref = ref
        self.name = name
        self.kind = kind
    }
}

// MARK: - Transcript

package struct LinkEntry: Codable, Sendable, Equatable {
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
    /// A user message's files (1.1).
    package var attachments: [LinkAttachment]?

    package init(
        id: String, kind: Kind, turn: String? = nil, text: String? = nil, doc: [Block]? = nil, textLen: Int, done: Bool,
        isError: Bool = false, stopped: Bool = false, inTurn: Bool = false, tool: Tool? = nil, changes: [Change]? = nil,
        agent: Agent? = nil, attachments: [LinkAttachment]? = nil
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
        self.attachments = attachments
    }
}

package struct LinkTurn: Codable, Sendable, Equatable {
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
    package enum Kind: String, LenientEnum { case permission, question, plan, planReady, signIn, unknown }

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

    /// A card's kind as an attention item's.
    package static func kind(_ card: LinkCard.Kind) -> Kind {
        switch card {
        case .permission: .permission
        case .questions: .question
        case .plan: .plan
        case .planReady: .planReady
        case .signIn, .unknown: .signIn
        }
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

package enum LinkCommand: Codable, Sendable, Equatable {
    package enum PlanChoice: String, LenientEnum { case implement, stay, unknown }

    /// `blobs`: finished uploads to attach (1.1).
    case send(chatId: String, text: String, blobs: [String] = [])
    case stop(chatId: String)
    case answer(chatId: String, cardId: String, action: CardAction.ID, digest: String, answers: [String: [String]]?)
    case setMode(chatId: String, modeId: String)
    case setPlan(chatId: String, on: Bool)
    case planReady(chatId: String, choice: PlanChoice)
    case new(windowId: String, provider: String)
    /// A command type this Kore doesn't know: answered `invalid`.
    case unknown(String)

    /// The chat it acts on; nil for a new chat.
    package var chatId: String? {
        switch self {
        case .send(let id, _, _), .stop(let id), .answer(let id, _, _, _, _), .setMode(let id, _), .setPlan(let id, _), .planReady(let id, _): id
        case .new, .unknown: nil
        }
    }

    /// Its name on the wire, also what the log and Kore's mark record.
    package var type: String {
        switch self {
        case .send: "chat.send"
        case .stop: "chat.stop"
        case .answer: "chat.answer"
        case .setMode: "chat.setMode"
        case .setPlan: "chat.setPlan"
        case .planReady: "chat.planReady"
        case .new: "chat.new"
        case .unknown(let type): type
        }
    }

    private enum Key: String, CodingKey { case type, chatId, text, blobs, cardId, action, digest, answers, modeId, on, choice, windowId, provider }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        func chat() throws -> String { try c.decode(String.self, forKey: .chatId) }
        switch type {
        case "chat.send":
            self = .send(
                chatId: try chat(), text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                blobs: try c.decodeIfPresent([String].self, forKey: .blobs) ?? [])
        case "chat.stop": self = .stop(chatId: try chat())
        case "chat.answer":
            self = .answer(
                chatId: try chat(), cardId: try c.decode(String.self, forKey: .cardId),
                action: try c.decode(CardAction.ID.self, forKey: .action), digest: try c.decode(String.self, forKey: .digest),
                answers: try c.decodeIfPresent([String: [String]].self, forKey: .answers))
        case "chat.setMode": self = .setMode(chatId: try chat(), modeId: try c.decode(String.self, forKey: .modeId))
        case "chat.setPlan": self = .setPlan(chatId: try chat(), on: try c.decode(Bool.self, forKey: .on))
        case "chat.planReady": self = .planReady(chatId: try chat(), choice: try c.decode(PlanChoice.self, forKey: .choice))
        case "chat.new": self = .new(windowId: try c.decode(String.self, forKey: .windowId), provider: try c.decode(String.self, forKey: .provider))
        default: self = .unknown(type)
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .send(let chatId, let text, let blobs):
            try c.encode(chatId, forKey: .chatId)
            try c.encode(text, forKey: .text)
            if !blobs.isEmpty { try c.encode(blobs, forKey: .blobs) }
        case .stop(let chatId):
            try c.encode(chatId, forKey: .chatId)
        case .answer(let chatId, let cardId, let action, let digest, let answers):
            try c.encode(chatId, forKey: .chatId)
            try c.encode(cardId, forKey: .cardId)
            try c.encode(action, forKey: .action)
            try c.encode(digest, forKey: .digest)
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
        case .unknown:
            break
        }
    }
}

/// Why a command didn't go through.
package enum ResultCode: String, LenientEnum {
    case sendCap = "denied.sendCap"
    case raiseMode = "denied.raiseMode"
    case alwaysAllow = "denied.alwaysAllow"
    case command = "denied.command"
    case signIn = "denied.signIn"
    case action = "denied.action"
    /// The card changed since the client showed it.
    case staleCard = "stale.card"
    case goneChat = "gone.chat"
    case goneCard = "gone.card"
    case goneWindow = "gone.window"
    /// Uploads and downloads (1.1).
    case tooLarge = "blob.tooLarge"
    case badHash = "blob.badHash"
    case badType = "blob.badType"
    case goneBlob = "gone.blob"
    case deniedRef = "denied.ref"
    case busy
    case invalid
    case rateLimited
    case unknown
}
