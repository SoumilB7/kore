import Foundation
import KoreCore
import src

// Link 1.5, box parity (`docs/link-1.4-box.md` §1.5): a full grant drives a box's chat as the
// Mac's own chat drives its backend. Every `ChatBackend` call crosses as one `chat.call`, and the
// backend's own `ChatEvent`s come back as `chat.events`, numbered, from a log the box keeps per
// chat. Watch and act grants keep the `tx.*` projection.

/// Client to box: follow a chat's events after `after` of log `log` (nil for the whole retained
/// log). The box answers with what follows, or the whole log with `reset` when the client is
/// behind what it keeps (snapshot required) or names another log.
package struct ChatFollow: Codable, Sendable, Equatable {
    package var t = "chat.follow"
    package var chatId: String
    package var after: Int?
    package var log: String?
    /// 1.6: the chat's Arsenal tier, as with a message (`ChatCall.arsenal`): a chat whose CLI
    /// starts for this follow starts with it.
    package var arsenal: String?

    package init(chatId: String, after: Int?, log: String?, arsenal: String? = nil) {
        self.chatId = chatId
        self.after = after
        self.log = log
        self.arsenal = arsenal
    }
}

/// Client to box: stop sending a chat's events.
package struct ChatUnfollow: Codable, Sendable, Equatable {
    package var t = "chat.unfollow"
    package var chatId: String

    package init(chatId: String) { self.chatId = chatId }
}

/// Client to box: one backend call. `id` is the client's: a repeat of an id the box answered
/// lately gets that first answer again, and the call doesn't run twice.
package struct ChatCall: Codable, Sendable {
    package var t = "chat.call"
    package var id: String
    package var chatId: String
    package var command: ChatCommand
    /// 1.6, with a `send`: the chat's Arsenal tier on the Mac (`watch`, `own`, `drive`; absent
    /// for off), so the box gives its CLI the `kore_app` server or not, and a `KoreReach.note`
    /// the message carries when the tier changed since the agent was last told.
    package var arsenal: String?
    package var note: String?

    package init(id: String, chatId: String, command: ChatCommand, arsenal: String? = nil, note: String? = nil) {
        self.id = id
        self.chatId = chatId
        self.command = command
        self.arsenal = arsenal
        self.note = note
    }

    private enum Key: String, CodingKey { case t, id, chatId, command, arsenal, note }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        chatId = try c.decode(String.self, forKey: .chatId)
        command = ChatCommand.decode(try c.superDecoder(forKey: .command))
        arsenal = try c.decodeIfPresent(String.self, forKey: .arsenal)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// Box to client: a `chat.call`'s answer, a `result` with the call's value.
package struct ChatCallResult: Codable, Sendable {
    package var t = "result"
    package var id: String
    package var ok: Bool
    package var code: ResultCode?
    package var message: String?
    package var value: CallValue?

    package init(id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, value: CallValue? = nil) {
        self.id = id
        self.ok = ok
        self.code = code
        self.message = message
        self.value = value
    }
}

/// Box to client: a chat's events, in order. `reset`: what the client holds of the chat is
/// replaced by these (they start at the log's start).
package struct ChatEvents: Codable, Sendable {
    package var t = "chat.events"
    package var chatId: String
    package var log: String
    package var reset: Bool?
    package var items: [StreamItem]

    package init(chatId: String, log: String, reset: Bool? = nil, items: [StreamItem]) {
        self.chatId = chatId
        self.log = log
        self.reset = reset
        self.items = items
    }

    /// The last seq it brings the client to.
    package var seq: Int? { items.last?.s }
}

/// One line of a chat's event log, as kept and as sent: an event, or the start (`open`, the
/// event's case: "replayed" or "historyReplaced") or end (`close`) of a history sent piece by
/// piece. `by`: the grant whose own call made it (that client already shows it, so it isn't sent
/// back to it live).
package struct StreamItem: Codable, Sendable {
    package var s: Int
    package var e: ChatEvent?
    package var open: String?
    package var close: Bool?
    package var by: String?

    package init(s: Int, e: ChatEvent? = nil, open: String? = nil, close: Bool? = nil, by: String? = nil) {
        self.s = s
        self.e = e
        self.open = open
        self.close = close
        self.by = by
    }

    private enum Key: String, CodingKey { case s, e, open, close, by }

    /// An event this side can't read leaves the item empty: it's skipped, never a failure.
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        s = try c.decode(Int.self, forKey: .s)
        e = try? c.decodeIfPresent(ChatEvent.self, forKey: .e)
        open = try c.decodeIfPresent(String.self, forKey: .open)
        close = try c.decodeIfPresent(Bool.self, forKey: .close)
        by = try c.decodeIfPresent(String.self, forKey: .by)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(s, forKey: .s)
        try c.encodeIfPresent(e, forKey: .e)
        try c.encodeIfPresent(open, forKey: .open)
        try c.encodeIfPresent(close, forKey: .close)
        try c.encodeIfPresent(by, forKey: .by)
    }

    /// The items an event goes as: a history piece by piece (it can be larger than a frame), any
    /// other event as one. Numbered on from `seq`.
    package static func items(_ event: ChatEvent, seq: inout Int, by: String? = nil) -> [StreamItem] {
        func next(_ item: StreamItem) -> StreamItem {
            seq += 1
            var item = item
            item.s = seq
            item.by = by
            return item
        }
        switch event {
        case .replayed(let events), .historyReplaced(let events):
            let open: String = if case .replayed = event { "replayed" } else { "historyReplaced" }
            return [next(StreamItem(s: 0, open: open))] + events.map { next(StreamItem(s: 0, e: $0)) } + [next(StreamItem(s: 0, close: true))]
        default:
            return [next(StreamItem(s: 0, e: event))]
        }
    }
}

/// Items back into events: a history's pieces become its one event again.
package struct StreamAssembler: Sendable {
    private var open: (kind: String, events: [ChatEvent])?

    package init() {}

    /// Starts again (a reset): a history half read is dropped.
    package mutating func reset() { open = nil }

    package mutating func take(_ item: StreamItem) -> ChatEvent? {
        if let kind = item.open {
            open = (kind, [])
            return nil
        }
        if item.close == true {
            guard let done = open else { return nil }
            open = nil
            return done.kind == "historyReplaced" ? .historyReplaced(done.events) : .replayed(done.events)
        }
        guard let event = item.e else { return nil }
        if open != nil {
            open?.events.append(event)
            return nil
        }
        return event
    }

    package mutating func take(_ items: [StreamItem]) -> [ChatEvent] { items.compactMap { take($0) } }
}

/// Bytes of the stream's messages.
package enum StreamWire {
    /// A frame of events stays under this (the client reads up to `LinkFrame.outboundMax`).
    package static let frameBudget = 512 * 1024
    /// An item larger than this has its long text cut (`trimmed`).
    package static let itemMax = 640 * 1024

    package static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    /// The message's type (`t`), read without the rest.
    package static func type(_ data: Data) -> String? {
        struct Peek: Decodable { var t: String? }
        return (try? JSONDecoder().decode(Peek.self, from: data))?.t
    }

    /// Frames of `items`, each under `frameBudget`; the first says `reset` when asked.
    package static func frames(chatId: String, log: String, reset: Bool, items: [StreamItem]) -> [Data] {
        var frames: [Data] = []
        var batch: [Data] = []
        var size = 0
        for item in items {
            let data = encoded(item)
            if !batch.isEmpty, size + data.count > frameBudget {
                frames.append(frame(chatId: chatId, log: log, reset: reset && frames.isEmpty, encoded: batch))
                (batch, size) = ([], 0)
            }
            batch.append(data)
            size += data.count + 1
        }
        if !batch.isEmpty || (reset && frames.isEmpty) { frames.append(frame(chatId: chatId, log: log, reset: reset && frames.isEmpty, encoded: batch)) }
        return frames
    }

    /// An item's bytes, its long text cut when it's too large for a frame.
    package static func encoded(_ item: StreamItem) -> Data {
        let data = encode(item)
        return data.count > itemMax ? encode(trimmed(item)) : data
    }

    /// One `chat.events` frame of items already encoded.
    package static func frame(chatId: String, log: String, reset: Bool, encoded items: [Data]) -> Data {
        // `{"chatId":…,"items":[],…}` with the items spliced in.
        var data = StreamWire.encode(ChatEvents(chatId: chatId, log: log, reset: reset ? true : nil, items: []))
        if let range = data.range(of: Data("\"items\":[]".utf8)) {
            var list = Data("\"items\":[".utf8)
            for (i, item) in items.enumerated() {
                if i > 0 { list.append(UInt8(ascii: ",")) }
                list.append(item)
            }
            list.append(Data("]".utf8))
            data.replaceSubrange(range, with: list)
        }
        return data
    }

    /// An event too large for a frame, with its long text cut to fit.
    static func trimmed(_ item: StreamItem) -> StreamItem {
        func cut(_ text: String) -> String {
            text.utf8.count > 256 * 1024 ? String(text.prefix(200 * 1024)) + "\n… (cut: too long to send)" : text
        }
        var item = item
        switch item.e {
        case .text(let id, let kind, let text, let agent)?: item.e = .text(id, kind, cut(text), agent: agent)
        case .toolOutput(let id, let text, let agent)?: item.e = .toolOutput(id: id, cut(text), agent: agent)
        case .toolFinished(let id, let output, let isError, let agent)?:
            item.e = .toolFinished(id: id, output: output.map(cut), isError: isError, agent: agent)
        case .commandOutput(let id, let text)?: item.e = .commandOutput(id: id, cut(text))
        case .compactionSummary(let text)?: item.e = .compactionSummary(cut(text))
        case .userMessage(let text, _, let id)?: item.e = .userMessage(text: cut(text), attachments: [], id: id)
        default: break
        }
        if encode(item).count > itemMax { item.e = .notice("An event too large to send was left out.", isError: true) }
        return item
    }
}
