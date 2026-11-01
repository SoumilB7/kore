import CryptoKit
import Foundation

/// One message on the link: its type in `t`, then its fields.
package enum LinkMessage: Sendable, Equatable {
    package enum ByeReason: String, LenientEnum { case quit, disconnected, slow, auth, version, invalid, rateLimited, unknown }
    package enum Field: String, LenientEnum { case text, input, result, unknown }
    package enum AttnOp: String, LenientEnum { case open, clear, turn, unknown }

    package struct Client: Codable, Sendable, Equatable {
        package var name: String
        package var build: String
        package init(name: String, build: String) {
            self.name = name
            self.build = build
        }
    }

    /// A command the companion offers in Kore's "/" menu while it's allowed (at most 6).
    package struct CompanionCommand: Codable, Sendable, Equatable {
        package var id: String
        package var label: String
        package init(id: String, label: String) {
            self.id = id
            self.label = label
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
        package var proto: LinkVersion
        package var epoch: String
        package var host: Host
        package var providers: [ProviderInfo]
        package var policy: Policy
        package var caps: [String]
        package init(proto: LinkVersion, epoch: String, host: Host, providers: [ProviderInfo], policy: Policy, caps: [String]) {
            self.proto = proto
            self.epoch = epoch
            self.host = host
            self.providers = providers
            self.policy = policy
            self.caps = caps
        }
    }

    package struct TxDelta: Sendable, Equatable {
        package var chatId: String
        package var txRev: Int
        package var upserts: [LinkEntry]
        package var removed: [String]
        package var order: [String]?
        package var turns: [LinkTurn]?
        package var hasEarlier: Bool?
        package init(
            chatId: String, txRev: Int, upserts: [LinkEntry], removed: [String], order: [String]? = nil, turns: [LinkTurn]? = nil,
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

    package struct Result: Sendable, Equatable {
        package var id: String
        package var ok: Bool
        package var code: ResultCode?
        package var message: String?
        /// Set on a `chat.new`'s result.
        package var chatId: String?
        package var windowId: String?
        package init(id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, chatId: String? = nil, windowId: String? = nil) {
            self.id = id
            self.ok = ok
            self.code = code
            self.message = message
            self.chatId = chatId
            self.windowId = windowId
        }
    }

    // Session
    case challenge(nonce: String)
    case hello(proto: LinkVersion, client: Client, proof: String, commands: [CompanionCommand]? = nil)
    case welcome(Welcome)
    case bye(ByeReason)
    /// Kore to the client: the user chose one of its commands in "/". No reply.
    case command(id: String)
    // State
    case snapshot(rev: Int, windows: [LinkWindow], chats: [ChatMeta])
    case delta(rev: Int, windows: [LinkWindow]?, chats: [ChatMeta]?, removed: [String]?)
    // Transcripts
    case txOpen(chatId: String, last: Int?)
    case txMore(chatId: String, count: Int)
    case txClose(chatId: String)
    case txPage(chatId: String, txRev: Int, entries: [LinkEntry], turns: [LinkTurn], hasEarlier: Bool)
    case txDelta(TxDelta)
    case txReset(chatId: String)
    case entryMore(id: String, chatId: String, entryId: String, field: Field, offset: Int)
    case entryChunk(id: String, text: String, offset: Int, total: Int)
    case cardMore(id: String, chatId: String, cardId: String, offset: Int)
    case cardChunk(id: String, text: String, offset: Int, total: Int)
    // Commands
    case cmd(id: String, LinkCommand)
    case result(Result)
    // Attention
    case attnState(aid: Int, open: [AttnItem], recent: [AttnTurn])
    case attnEvent(aid: Int, op: AttnOp, item: AttnItem?, key: String?, turn: AttnTurn?)
    /// A type from a newer peer: skipped.
    case unknown(String)

    /// Its type on the wire.
    package var type: String {
        switch self {
        case .challenge: "challenge"
        case .hello: "hello"
        case .welcome: "welcome"
        case .bye: "bye"
        case .command: "command"
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
        case .cardMore: "card.more"
        case .cardChunk: "card.chunk"
        case .cmd: "cmd"
        case .result: "result"
        case .attnState: "attn.state"
        case .attnEvent: "attn.event"
        case .unknown(let t): t
        }
    }

    /// Every type, for the fixture manifest's coverage check.
    package static let types: Set<String> = [
        "challenge", "hello", "welcome", "bye", "command", "snapshot", "delta", "tx.open", "tx.more", "tx.close", "tx.page", "tx.delta", "tx.reset",
        "entry.more", "entry.chunk", "card.more", "card.chunk", "cmd", "result", "attn.state", "attn.event",
    ]
}

extension LinkMessage: Codable {
    private enum Key: String, CodingKey {
        case t, nonce, proto, client, proof, commands, epoch, host, providers, policy, caps, reason, rev, windows, chats, removed, chatId, last,
            count, txRev, entries, turns, hasEarlier, upserts, order, id, entryId, field, offset, text, total, cardId, cmd, ok, code,
            message, windowId, aid, open, recent, op, item, key, turn
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let t = try c.decode(String.self, forKey: .t)
        func d<T: Decodable>(_ key: Key) throws -> T { try c.decode(T.self, forKey: key) }
        func o<T: Decodable>(_ key: Key) throws -> T? { try c.decodeIfPresent(T.self, forKey: key) }
        switch t {
        case "challenge": self = .challenge(nonce: try d(.nonce))
        case "hello": self = .hello(proto: try d(.proto), client: try d(.client), proof: try d(.proof), commands: try o(.commands))
        case "welcome":
            self = .welcome(
                .init(
                    proto: try d(.proto), epoch: try d(.epoch), host: try d(.host), providers: try d(.providers), policy: try d(.policy),
                    caps: try d(.caps)))
        case "bye": self = .bye(try d(.reason))
        case "command": self = .command(id: try d(.id))
        case "snapshot": self = .snapshot(rev: try d(.rev), windows: try d(.windows), chats: try d(.chats))
        case "delta": self = .delta(rev: try d(.rev), windows: try o(.windows), chats: try o(.chats), removed: try o(.removed))
        case "tx.open": self = .txOpen(chatId: try d(.chatId), last: try o(.last))
        case "tx.more": self = .txMore(chatId: try d(.chatId), count: try d(.count))
        case "tx.close": self = .txClose(chatId: try d(.chatId))
        case "tx.page":
            self = .txPage(chatId: try d(.chatId), txRev: try d(.txRev), entries: try d(.entries), turns: try d(.turns), hasEarlier: try d(.hasEarlier))
        case "tx.delta":
            self = .txDelta(
                .init(
                    chatId: try d(.chatId), txRev: try d(.txRev), upserts: try d(.upserts), removed: try d(.removed), order: try o(.order),
                    turns: try o(.turns), hasEarlier: try o(.hasEarlier)))
        case "tx.reset": self = .txReset(chatId: try d(.chatId))
        case "entry.more":
            self = .entryMore(id: try d(.id), chatId: try d(.chatId), entryId: try d(.entryId), field: try d(.field), offset: try d(.offset))
        case "entry.chunk": self = .entryChunk(id: try d(.id), text: try d(.text), offset: try d(.offset), total: try d(.total))
        case "card.more": self = .cardMore(id: try d(.id), chatId: try d(.chatId), cardId: try d(.cardId), offset: try d(.offset))
        case "card.chunk": self = .cardChunk(id: try d(.id), text: try d(.text), offset: try d(.offset), total: try d(.total))
        case "cmd": self = .cmd(id: try d(.id), try d(.cmd))
        case "result":
            self = .result(
                .init(id: try d(.id), ok: try d(.ok), code: try o(.code), message: try o(.message), chatId: try o(.chatId), windowId: try o(.windowId)))
        case "attn.state": self = .attnState(aid: try d(.aid), open: try d(.open), recent: try d(.recent))
        case "attn.event": self = .attnEvent(aid: try d(.aid), op: try d(.op), item: try o(.item), key: try o(.key), turn: try o(.turn))
        default: self = .unknown(t)
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(type, forKey: .t)
        switch self {
        case .challenge(let nonce): try c.encode(nonce, forKey: .nonce)
        case .hello(let proto, let client, let proof, let commands):
            try c.encode(proto, forKey: .proto)
            try c.encode(client, forKey: .client)
            try c.encode(proof, forKey: .proof)
            try c.encodeIfPresent(commands, forKey: .commands)
        case .welcome(let w):
            try c.encode(w.proto, forKey: .proto)
            try c.encode(w.epoch, forKey: .epoch)
            try c.encode(w.host, forKey: .host)
            try c.encode(w.providers, forKey: .providers)
            try c.encode(w.policy, forKey: .policy)
            try c.encode(w.caps, forKey: .caps)
        case .bye(let reason): try c.encode(reason, forKey: .reason)
        case .command(let id): try c.encode(id, forKey: .id)
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
        case .entryChunk(let id, let text, let offset, let total), .cardChunk(let id, let text, let offset, let total):
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encode(offset, forKey: .offset)
            try c.encode(total, forKey: .total)
        case .cardMore(let id, let chatId, let cardId, let offset):
            try c.encode(id, forKey: .id)
            try c.encode(chatId, forKey: .chatId)
            try c.encode(cardId, forKey: .cardId)
            try c.encode(offset, forKey: .offset)
        case .cmd(let id, let command):
            try c.encode(id, forKey: .id)
            try c.encode(command, forKey: .cmd)
        case .result(let r):
            try c.encode(r.id, forKey: .id)
            try c.encode(r.ok, forKey: .ok)
            try c.encodeIfPresent(r.code, forKey: .code)
            try c.encodeIfPresent(r.message, forKey: .message)
            try c.encodeIfPresent(r.chatId, forKey: .chatId)
            try c.encodeIfPresent(r.windowId, forKey: .windowId)
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
        case .unknown:
            break
        }
    }

    /// The bytes of the message: compact JSON with sorted keys (the same message is always the
    /// same bytes).
    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    package static func decode(_ data: Data) throws -> LinkMessage { try JSONDecoder().decode(LinkMessage.self, from: data) }
}

/// Length-prefixed frames: a 4-byte big-endian length, then that many bytes of JSON.
package enum LinkFrame {
    /// The most a client may send in one message.
    package static let inboundMax = 256 * 1024
    /// The most Kore sends in one.
    package static let outboundMax = 1024 * 1024

    package static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    /// Takes whole frames off the front of `buffer`. Throws when one is over `max`.
    package static func take(_ buffer: inout Data, max: Int) throws -> [Data] {
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard length <= max else { throw LinkFrameError.tooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return frames
    }
}

package enum LinkFrameError: Error, Equatable { case tooLarge(Int) }

/// The hello's proof: HMAC-SHA256 over "kore-link/1|" and the challenge's nonce as sent, keyed by
/// the secret from the doorbell's reply. The secret itself never travels on the socket.
package enum LinkProof {
    package static func proof(secret: Data, nonce: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("kore-link/1|\(nonce)".utf8), using: SymmetricKey(data: secret))
        return Data(mac).base64EncodedString()
    }

    /// Compared in constant time.
    package static func check(_ proof: String, secret: Data, nonce: String) -> Bool {
        guard let given = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: Data("kore-link/1|\(nonce)".utf8), using: SymmetricKey(data: secret))
    }

    /// A re-ring's proof within a run: HMAC-SHA256 over "kore-ring/1|" + epoch + "|" + ts, keyed
    /// by the run's secret, base64.
    package static func ringProof(runSecret: Data, epoch: String, ts: Int) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("kore-ring/1|\(epoch)|\(ts)".utf8), using: SymmetricKey(data: runSecret))
        return Data(mac).base64EncodedString()
    }

    /// Compared in constant time.
    package static func checkRing(_ proof: String, runSecret: Data, epoch: String, ts: Int) -> Bool {
        guard let given = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: Data("kore-ring/1|\(epoch)|\(ts)".utf8), using: SymmetricKey(data: runSecret))
    }

    /// Random bytes, base64.
    package static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
