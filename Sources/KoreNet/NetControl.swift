import Foundation
import KoreTrust

/// The session's own messages, JSON on stream 0 (interactive), told apart by `t`
/// (`Tests/Fixtures/link/v2/control.json`). Bytes are base64; device ids are UUID strings.
package enum NetControl: Equatable, Sendable {
    case challenge(Challenge)
    case hello(Hello)
    case welcome(Welcome)
    /// More stream-queue bytes the sender will take.
    case credit(Int)
    /// Client → server, the first message after the welcome when it has any: the cursors it holds
    /// (chat events `{log,s}`, pty byte seq, revs), opaque here, for the service above. Kept out of
    /// the hello so the pre-auth frame stays small.
    case resume([String: JSONValue])
    case bye(String)

    package static let version = 2

    /// Server → client, first: the route as the server sees it, its device and nonce.
    package struct Challenge: Codable, Equatable, Sendable {
        package var v: Int
        package var route: String
        package var device: UUID
        package var nonce: Data

        package init(route: String, device: UUID, nonce: Data) {
            v = NetControl.version
            self.route = route
            self.device = device
            self.nonce = nonce
        }
    }

    /// Client → server: who it is, the service it wants, its signature over B, the stream credit
    /// it gives, and the last session's ticket when it has one.
    package struct Hello: Codable, Equatable, Sendable {
        package var v: Int
        package var service: String
        package var device: UUID
        package var nonce: Data
        package var sig: Data
        package var credit: Int
        package var ticket: Data?
        /// Only inside the Mac's Add device window (later steps); absent otherwise.
        package var enroll: Enroll?

        package init(service: String, device: UUID, nonce: Data, sig: Data, credit: Int, ticket: Data? = nil, enroll: Enroll? = nil) {
            v = NetControl.version
            self.service = service
            self.device = device
            self.nonce = nonce
            self.sig = sig
            self.credit = credit
            self.ticket = ticket
            self.enroll = enroll
        }
    }

    /// What a client resumes from (its setup, not a message): the ticket goes in the hello, the
    /// cursors in the `resume` message after the welcome.
    package struct Resume: Codable, Equatable, Sendable {
        package var ticket: Data
        package var cursors: [String: JSONValue]

        package init(ticket: Data, cursors: [String: JSONValue]) {
            self.ticket = ticket
            self.cursors = cursors
        }
    }

    package struct Enroll: Codable, Equatable, Sendable {
        package var name: String
        package var model: String
        package var identityKey: Data
        package var raiseKey: Data?
    }

    /// Server → client: its signature over B, the credit it gives, the next resume ticket, whether
    /// the hello's ticket was honoured, and what the client may do.
    package struct Welcome: Codable, Equatable, Sendable {
        package var v: Int
        package var sig: Data
        package var credit: Int
        package var ticket: Data
        package var resumed: Bool
        package var abilities: Ability

        package init(sig: Data, credit: Int, ticket: Data, resumed: Bool, abilities: Ability) {
            v = NetControl.version
            self.sig = sig
            self.credit = credit
            self.ticket = ticket
            self.resumed = resumed
            self.abilities = abilities
        }
    }

    /// Why a session ended, as `bye` says it.
    package enum Reason {
        package static let unknown = "unknown"
        package static let revoked = "revoked"
        package static let replaced = "replaced"
        package static let proof = "proof"
        package static let refused = "refused"
        package static let service = "service"
        package static let version = "version"
        package static let timeout = "timeout"
        package static let limit = "limit"
        package static let protocolError = "protocol"
    }
}

extension NetControl: Codable {
    private enum Key: String, CodingKey { case t, n, reason, cursors }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let t = try c.decode(String.self, forKey: .t)
        switch t {
        case "challenge": self = .challenge(try Challenge(from: decoder))
        case "hello": self = .hello(try Hello(from: decoder))
        case "welcome": self = .welcome(try Welcome(from: decoder))
        case "credit":
            let n = try c.decode(Int.self, forKey: .n)
            guard n > 0 else { throw DecodingError.dataCorruptedError(forKey: .n, in: c, debugDescription: "credit \(n)") }
            self = .credit(n)
        case "bye": self = .bye(try c.decode(String.self, forKey: .reason))
        case "resume": self = .resume(try c.decode([String: JSONValue].self, forKey: .cursors))
        default: throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown control \(t)")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .challenge(let m):
            try c.encode("challenge", forKey: .t)
            try m.encode(to: encoder)
        case .hello(let m):
            try c.encode("hello", forKey: .t)
            try m.encode(to: encoder)
        case .welcome(let m):
            try c.encode("welcome", forKey: .t)
            try m.encode(to: encoder)
        case .credit(let n):
            try c.encode("credit", forKey: .t)
            try c.encode(n, forKey: .n)
        case .bye(let reason):
            try c.encode("bye", forKey: .t)
            try c.encode(reason, forKey: .reason)
        case .resume(let cursors):
            try c.encode("resume", forKey: .t)
            try c.encode(cursors, forKey: .cursors)
        }
    }

    package func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    package static func decode(_ data: Data) throws -> NetControl { try JSONDecoder().decode(NetControl.self, from: data) }
}
