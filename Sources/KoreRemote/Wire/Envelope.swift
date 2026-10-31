import Foundation

/// One message on the wire: its type in `t`, the host's sequence number in `seq` (host messages
/// only; the phone acknowledges them with `ack`).
package enum WireMessage: Sendable, Equatable {
    package enum Presence: String, LenientEnum { case foreground, background, unknown }
    package enum ByeReason: String, LenientEnum { case sleep, off, removed, quit, replaced, unknown }
    package enum Field: String, LenientEnum { case text, input, result, unknown }
    package enum AttnOp: String, LenientEnum { case open, clear, turn, unknown }

    package struct Device: Codable, Sendable, Equatable {
        package var name: String
        package var build: String
        package init(name: String, build: String) {
            self.name = name
            self.build = build
        }
    }

    package struct Resume: Codable, Sendable, Equatable {
        package struct Sub: Codable, Sendable, Equatable {
            package var chatId: String
            package var txRev: Int
            package init(chatId: String, txRev: Int) {
                self.chatId = chatId
                self.txRev = txRev
            }
        }

        package var hostEpoch: String
        package var rev: Int
        package var subs: [Sub]
        package init(hostEpoch: String, rev: Int, subs: [Sub]) {
            self.hostEpoch = hostEpoch
            self.rev = rev
            self.subs = subs
        }
    }

    package struct Host: Codable, Sendable, Equatable {
        package var name: String
        package var koreVersion: String
        package init(name: String, koreVersion: String) {
            self.name = name
            self.koreVersion = koreVersion
        }
    }

    package struct Policy: Codable, Sendable, Equatable {
        package var sendMaxLevel: ModeLevel
        package init(sendMaxLevel: ModeLevel) { self.sendMaxLevel = sendMaxLevel }
    }

    package struct Welcome: Sendable, Equatable {
        package var proto: WireVersion
        package var hostEpoch: String
        package var host: Host
        package var providers: [ProviderInfo]
        package var policy: Policy
        package var caps: [String]
        package init(proto: WireVersion, hostEpoch: String, host: Host, providers: [ProviderInfo], policy: Policy, caps: [String]) {
            self.proto = proto
            self.hostEpoch = hostEpoch
            self.host = host
            self.providers = providers
            self.policy = policy
            self.caps = caps
        }
    }

    package struct TxDelta: Sendable, Equatable {
        package var chatId: String
        package var txRev: Int
        package var upserts: [WireEntry]
        package var removed: [String]
        package var order: [String]?
        package var turns: [WireTurn]?
        package var hasEarlier: Bool?
        package init(
            chatId: String, txRev: Int, upserts: [WireEntry], removed: [String], order: [String]? = nil, turns: [WireTurn]? = nil,
            hasEarlier: Bool? = nil
        ) {
            self.chatId = chatId
            self.txRev = txRev
            self.upserts = upserts
            self.removed = removed
            self.order = order
            self.turns = turns
            self.hasEarlier = hasEarlier
        }
    }

    // Session
    case hello(proto: WireVersion, device: Device, mode: Presence, attnAfter: Int?, resume: Resume?)
    case welcome(Welcome)
    case presence(mode: Presence, visibleChat: String?)
    case ack(Int)
    case bye(ByeReason)
    // State
    case snapshot(rev: Int, windows: [WireWindow], chats: [ChatMeta])
    case delta(rev: Int, windows: [WireWindow]?, chats: [ChatMeta]?, removed: [String]?)
    // Transcripts
    case txOpen(chatId: String, last: Int?)
    case txMore(chatId: String, count: Int)
    case txClose(chatId: String)
    case txPage(chatId: String, txRev: Int, entries: [WireEntry], turns: [WireTurn], hasEarlier: Bool)
    case txDelta(TxDelta)
    case txReset(chatId: String)
    case entryMore(id: String, chatId: String, entryId: String, field: Field, offset: Int)
    case entryChunk(id: String, text: String, offset: Int, total: Int)
    // Commands
    case cmd(id: String, RemoteCommand)
    case result(id: String, ok: Bool, code: ResultCode?, message: String?)
    // Attention
    case attnState(aid: Int, open: [AttnItem], recent: [AttnTurn])
    case attnEvent(aid: Int, op: AttnOp, item: AttnItem?, key: String?, turn: AttnTurn?)

    /// Its type on the wire.
    package var type: String {
        switch self {
        case .hello: "hello"
        case .welcome: "welcome"
        case .presence: "presence"
        case .ack: "ack"
        case .bye: "bye"
        case .snapshot: "snapshot"
        case .delta: "delta"
        case .txOpen: "tx.open"
        case .txMore: "tx.more"
        case .txClose: "tx.close"
        case .txPage: "tx.page"
        case .txDelta: "tx.delta"
        case .txReset: "tx.reset"
        case .entryMore: "entry.more"
        case .entryChunk: "entry.chunk"
        case .cmd: "cmd"
        case .result: "result"
        case .attnState: "attn.state"
        case .attnEvent: "attn.event"
        }
    }

    /// Every type, for the fixture manifest's coverage check.
    package static let types: Set<String> = [
        "hello", "welcome", "presence", "ack", "bye", "snapshot", "delta", "tx.open", "tx.more", "tx.close", "tx.page", "tx.delta",
        "tx.reset", "entry.more", "entry.chunk", "cmd", "result", "attn.state", "attn.event",
    ]
}

/// A message with the host's sequence number, as it travels.
package struct Envelope: Codable, Sendable, Equatable {
    package var seq: Int?
    package var message: WireMessage

    package init(_ message: WireMessage, seq: Int? = nil) {
        self.message = message
        self.seq = seq
    }

    private enum Key: String, CodingKey {
        case t, seq, proto, device, mode, attnAfter, resume, hostEpoch, host, providers, policy, caps, visibleChat, reason, rev,
            windows, chats, removed, chatId, last, count, txRev, entries, turns, hasEarlier, upserts, order, id, entryId, field,
            offset, text, total, cmd, ok, code, message, aid, open, recent, op, item, key, turn
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let t = try c.decode(String.self, forKey: .t)
        func d<T: Decodable>(_ key: Key) throws -> T { try c.decode(T.self, forKey: key) }
        func o<T: Decodable>(_ key: Key) throws -> T? { try c.decodeIfPresent(T.self, forKey: key) }
        // `ack` carries the phone's acknowledged number in `seq`; it has no sequence of its own.
        seq = t == "ack" ? nil : try o(.seq)
        switch t {
        case "hello":
            message = .hello(proto: try d(.proto), device: try d(.device), mode: try d(.mode), attnAfter: try o(.attnAfter), resume: try o(.resume))
        case "welcome":
            message = .welcome(
                .init(
                    proto: try d(.proto), hostEpoch: try d(.hostEpoch), host: try d(.host), providers: try d(.providers),
                    policy: try d(.policy), caps: try d(.caps)))
        case "presence": message = .presence(mode: try d(.mode), visibleChat: try o(.visibleChat))
        case "ack": message = .ack(try d(.seq))
        case "bye": message = .bye(try d(.reason))
        case "snapshot": message = .snapshot(rev: try d(.rev), windows: try d(.windows), chats: try d(.chats))
        case "delta": message = .delta(rev: try d(.rev), windows: try o(.windows), chats: try o(.chats), removed: try o(.removed))
        case "tx.open": message = .txOpen(chatId: try d(.chatId), last: try o(.last))
        case "tx.more": message = .txMore(chatId: try d(.chatId), count: try d(.count))
        case "tx.close": message = .txClose(chatId: try d(.chatId))
        case "tx.page":
            message = .txPage(
                chatId: try d(.chatId), txRev: try d(.txRev), entries: try d(.entries), turns: try d(.turns), hasEarlier: try d(.hasEarlier))
        case "tx.delta":
            message = .txDelta(
                .init(
                    chatId: try d(.chatId), txRev: try d(.txRev), upserts: try d(.upserts), removed: try d(.removed), order: try o(.order),
                    turns: try o(.turns), hasEarlier: try o(.hasEarlier)))
        case "tx.reset": message = .txReset(chatId: try d(.chatId))
        case "entry.more":
            message = .entryMore(id: try d(.id), chatId: try d(.chatId), entryId: try d(.entryId), field: try d(.field), offset: try d(.offset))
        case "entry.chunk": message = .entryChunk(id: try d(.id), text: try d(.text), offset: try d(.offset), total: try d(.total))
        case "cmd": message = .cmd(id: try d(.id), try d(.cmd))
        case "result": message = .result(id: try d(.id), ok: try d(.ok), code: try o(.code), message: try o(.message))
        case "attn.state": message = .attnState(aid: try d(.aid), open: try d(.open), recent: try d(.recent))
        case "attn.event": message = .attnEvent(aid: try d(.aid), op: try d(.op), item: try o(.item), key: try o(.key), turn: try o(.turn))
        default: throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown message type \(t)")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(message.type, forKey: .t)
        if case .ack = message {} else { try c.encodeIfPresent(seq, forKey: .seq) }
        switch message {
        case .hello(let proto, let device, let mode, let attnAfter, let resume):
            try c.encode(proto, forKey: .proto)
            try c.encode(device, forKey: .device)
            try c.encode(mode, forKey: .mode)
            try c.encodeIfPresent(attnAfter, forKey: .attnAfter)
            try c.encodeIfPresent(resume, forKey: .resume)
        case .welcome(let w):
            try c.encode(w.proto, forKey: .proto)
            try c.encode(w.hostEpoch, forKey: .hostEpoch)
            try c.encode(w.host, forKey: .host)
            try c.encode(w.providers, forKey: .providers)
            try c.encode(w.policy, forKey: .policy)
            try c.encode(w.caps, forKey: .caps)
        case .presence(let mode, let visibleChat):
            try c.encode(mode, forKey: .mode)
            try c.encodeIfPresent(visibleChat, forKey: .visibleChat)
        case .ack(let n): try c.encode(n, forKey: .seq)
        case .bye(let reason): try c.encode(reason, forKey: .reason)
        case .snapshot(let rev, let windows, let chats):
            try c.encode(rev, forKey: .rev)
            try c.encode(windows, forKey: .windows)
            try c.encode(chats, forKey: .chats)
        case .delta(let rev, let windows, let chats, let removed):
            try c.encode(rev, forKey: .rev)
            try c.encodeIfPresent(windows, forKey: .windows)
            try c.encodeIfPresent(chats, forKey: .chats)
            try c.encodeIfPresent(removed, forKey: .removed)
        case .txOpen(let chatId, let last):
            try c.encode(chatId, forKey: .chatId)
            try c.encodeIfPresent(last, forKey: .last)
        case .txMore(let chatId, let count):
            try c.encode(chatId, forKey: .chatId)
            try c.encode(count, forKey: .count)
        case .txClose(let chatId), .txReset(let chatId):
            try c.encode(chatId, forKey: .chatId)
        case .txPage(let chatId, let txRev, let entries, let turns, let hasEarlier):
            try c.encode(chatId, forKey: .chatId)
            try c.encode(txRev, forKey: .txRev)
            try c.encode(entries, forKey: .entries)
            try c.encode(turns, forKey: .turns)
            try c.encode(hasEarlier, forKey: .hasEarlier)
        case .txDelta(let x):
            try c.encode(x.chatId, forKey: .chatId)
            try c.encode(x.txRev, forKey: .txRev)
            try c.encode(x.upserts, forKey: .upserts)
            try c.encode(x.removed, forKey: .removed)
            try c.encodeIfPresent(x.order, forKey: .order)
            try c.encodeIfPresent(x.turns, forKey: .turns)
            try c.encodeIfPresent(x.hasEarlier, forKey: .hasEarlier)
        case .entryMore(let id, let chatId, let entryId, let field, let offset):
            try c.encode(id, forKey: .id)
            try c.encode(chatId, forKey: .chatId)
            try c.encode(entryId, forKey: .entryId)
            try c.encode(field, forKey: .field)
            try c.encode(offset, forKey: .offset)
        case .entryChunk(let id, let text, let offset, let total):
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encode(offset, forKey: .offset)
            try c.encode(total, forKey: .total)
        case .cmd(let id, let command):
            try c.encode(id, forKey: .id)
            try c.encode(command, forKey: .cmd)
        case .result(let id, let ok, let code, let message):
            try c.encode(id, forKey: .id)
            try c.encode(ok, forKey: .ok)
            try c.encodeIfPresent(code, forKey: .code)
            try c.encodeIfPresent(message, forKey: .message)
        case .attnState(let aid, let open, let recent):
            try c.encode(aid, forKey: .aid)
            try c.encode(open, forKey: .open)
            try c.encode(recent, forKey: .recent)
        case .attnEvent(let aid, let op, let item, let key, let turn):
            try c.encode(aid, forKey: .aid)
            try c.encode(op, forKey: .op)
            try c.encodeIfPresent(item, forKey: .item)
            try c.encodeIfPresent(key, forKey: .key)
            try c.encodeIfPresent(turn, forKey: .turn)
        }
    }

    /// The bytes on the wire: compact JSON with sorted keys (the same message is always the same bytes).
    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    package static func decode(_ data: Data) throws -> Envelope { try JSONDecoder().decode(Envelope.self, from: data) }
}
