import Foundation

/// The relay's own framing: one WebSocket binary message each, its first byte the kind. The
/// relay reads only this byte, a phone's slot, and a token's hash; what follows `data` is the
/// encrypted session's bytes, opaque to it. `relay/src` speaks the same, and
/// `protocol/fixtures/relay` holds the cases both sides are checked against.
package enum RelayFrame: Equatable, Sendable {
    /// Bytes for (to the host: from) the phone in `slot`; a phone's own carry no slot.
    case data(slot: UInt8?, Data)
    /// To the host: a phone joined in `slot`. To a phone: the host is there.
    case open(slot: UInt8?)
    /// To the host: the phone in `slot` left (from the host: put it out). To a phone: the host is
    /// gone.
    case close(slot: UInt8?)
    /// From the host: a phone may join with the token whose SHA-256 this is.
    case allow(Data)
    /// From the host: it no longer may; phones joined with it are put out.
    case revoke(Data)

    package enum Kind: UInt8 {
        case data = 0x01, open = 0x02, close = 0x03, allow = 0x10, revoke = 0x11
    }

    /// The most payload a data frame carries: 64 KiB.
    package static let maxPayload = 65536
    /// The most a frame may be: a payload and its header (the host's has a slot byte too).
    package static func maxSize(host: Bool) -> Int { maxPayload + (host ? 2 : 1) }
    package static let maxSize = maxSize(host: true)
    /// Phones in one mailbox at once.
    package static let maxPhones = 2

    /// Its bytes; `host`: on the host's socket (frames carry a slot).
    package func encoded(host: Bool) -> Data {
        switch self {
        case .data(let slot, let payload): Data([Kind.data.rawValue]) + (host ? Data([slot ?? 0]) : Data()) + payload
        case .open(let slot): Data([Kind.open.rawValue]) + (host ? Data([slot ?? 0]) : Data())
        case .close(let slot): Data([Kind.close.rawValue]) + (host ? Data([slot ?? 0]) : Data())
        case .allow(let hash): Data([Kind.allow.rawValue]) + hash
        case .revoke(let hash): Data([Kind.revoke.rawValue]) + hash
        }
    }

    /// A frame read off a socket; nil for anything malformed (the socket closes).
    package init?(_ bytes: Data, host: Bool) {
        guard let first = bytes.first, bytes.count <= Self.maxSize(host: host), let kind = Kind(rawValue: first) else { return nil }
        let rest = bytes.dropFirst()
        func slot() -> UInt8? { host ? rest.first : nil }
        switch kind {
        case .data:
            if host {
                guard let s = rest.first, s < Self.maxPhones else { return nil }
                self = .data(slot: s, Data(rest.dropFirst()))
            } else {
                self = .data(slot: nil, Data(rest))
            }
        case .open:
            guard rest.count == (host ? 1 : 0) else { return nil }
            self = .open(slot: slot())
        case .close:
            guard rest.count == (host ? 1 : 0) else { return nil }
            self = .close(slot: slot())
        case .allow:
            guard host, rest.count == 32 else { return nil }
            self = .allow(Data(rest))
        case .revoke:
            guard host, rest.count == 32 else { return nil }
            self = .revoke(Data(rest))
        }
    }
}

/// How a socket joins a mailbox: the role, the token, and the answer it may get.
package enum RelayJoin {
    package enum Role: String, Sendable { case host, phone }

    /// Why the relay turned a socket away (as HTTP statuses on the upgrade).
    package enum Refusal: Int, Error, Sendable {
        /// No such token for the mailbox (or the host's doesn't make its id).
        case unauthorized = 401
        case notFound = 404
        /// The mailbox has a host already, with another token.
        case conflict = 409
        /// Two phones are in already.
        case full = 429
    }

    /// `/m/<32 hex>`.
    package static func path(_ mailbox: Data) -> String { "/m/" + mailbox.hexString }
}
