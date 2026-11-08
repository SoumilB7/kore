import Foundation
import KoreTrust

/// A device's view of the owner's tailnet (phase 18 §1): installed Tailscale through its LocalAPI
/// (`TailnetLocal`) or Kore's own `kore-tailnet` sidecar (`TailnetSidecar`). Calls block briefly
/// (a local socket round trip); call them off the main actor. Nothing here polls.
package protocol Tailnet: Sendable {
    func status() throws -> TailnetStatus
    /// Who is behind a tailnet address (`ip` or `ip:port`).
    func whois(_ address: String) throws -> TailnetWhoIs
    /// The IPN bus: held only while the stream is iterated, closed when it ends or is dropped.
    func events() -> AsyncStream<TailnetEvent>
    /// Sockets on this node's tailnet addresses and `port`, never a wildcard.
    func listen(port: UInt16) throws -> [TailnetListenSocket]
    /// A connected stream socket to a tailnet peer.
    func dial(_ address: String, port: UInt16) throws -> Int32
}

package enum TailnetError: Error, Equatable, CustomStringConvertible {
    /// No LocalAPI this process can use: Tailscale absent, the App Store build, or a token this
    /// user can't read.
    case unavailable(LocalAPIEndpoint.Missing)
    case unauthorized
    case http(Int)
    case malformed(String)
    case notTailnet(String)
    case sidecar(String)
    case notRunning(BackendState)

    package var description: String {
        switch self {
        case .unavailable(let why): "Tailscale's LocalAPI is unavailable (\(why))"
        case .unauthorized: "Tailscale's LocalAPI refused this user"
        case .http(let code): "Tailscale's LocalAPI answered \(code)"
        case .malformed(let what): "Tailscale's LocalAPI sent bad \(what)"
        case .notTailnet(let address): "\(address) isn't a tailnet address"
        case .sidecar(let why): "kore-tailnet: \(why)"
        case .notRunning(let state): "Tailscale is \(state.rawValue)"
        }
    }
}

package enum BackendState: String, Sendable, Equatable {
    case noState = "NoState"
    case inUseOtherUser = "InUseOtherUser"
    case needsLogin = "NeedsLogin"
    case needsMachineAuth = "NeedsMachineAuth"
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case unknown = "Unknown"

    /// The IPN bus's `State` number (`ipn.State`).
    package init(bus: Int) {
        self = switch bus {
        case 0: .noState
        case 1: .inUseOtherUser
        case 2: .needsLogin
        case 3: .needsMachineAuth
        case 4: .stopped
        case 5: .starting
        case 6: .running
        default: .unknown
        }
    }
}

extension BackendState: Decodable {
    package init(from decoder: any Decoder) throws {
        self = BackendState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// `/localapi/v0/status`, only the fields KoreNet reads.
package struct TailnetStatus: Decodable, Sendable, Equatable {
    package var backendState: BackendState
    package var selfNode: SelfNode?
    package var peers: [Peer]

    package struct SelfNode: Decodable, Sendable, Equatable {
        package var publicKey: String
        package var tailscaleIPs: [String]
        package var userID: Int64?
        /// A tagged node's tags (its `UserID` is then Tailscale's stand-in, never a person).
        package var tags: [String]?

        enum CodingKeys: String, CodingKey {
            case publicKey = "PublicKey", tailscaleIPs = "TailscaleIPs", userID = "UserID", tags = "Tags"
        }

        package init(publicKey: String, tailscaleIPs: [String], userID: Int64?, tags: [String]? = nil) {
            self.publicKey = publicKey
            self.tailscaleIPs = tailscaleIPs
            self.userID = userID
            self.tags = tags
        }

        /// The person this node belongs to; nil for a tagged node.
        package var owner: Int64? { (tags ?? []).isEmpty ? userID : nil }
    }

    package struct Peer: Decodable, Sendable, Equatable {
        package var publicKey: String
        package var tailscaleIPs: [String]
        package var online: Bool
        package var userID: Int64?
        package var tags: [String]

        enum CodingKeys: String, CodingKey {
            case publicKey = "PublicKey", tailscaleIPs = "TailscaleIPs", online = "Online", userID = "UserID", tags = "Tags"
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            publicKey = try c.decode(String.self, forKey: .publicKey)
            tailscaleIPs = try c.decodeIfPresent([String].self, forKey: .tailscaleIPs) ?? []
            online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
            userID = try c.decodeIfPresent(Int64.self, forKey: .userID)
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        }
    }

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState", selfNode = "Self", peers = "Peer"
    }

    package init(backendState: BackendState, selfNode: SelfNode?, peers: [Peer] = []) {
        self.backendState = backendState
        self.selfNode = selfNode
        self.peers = peers
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backendState = try c.decode(BackendState.self, forKey: .backendState)
        selfNode = try c.decodeIfPresent(SelfNode.self, forKey: .selfNode)
        let map = try c.decodeIfPresent([String: Peer].self, forKey: .peers) ?? [:]
        peers = map.keys.sorted().compactMap { map[$0] }
    }
}

/// `/localapi/v0/whois`, only the fields KoreNet reads.
package struct TailnetWhoIs: Decodable, Sendable, Equatable {
    package var node: Node
    package var user: UserProfile
    /// The peer's app capabilities: each key's grants as raw JSON.
    package var capMap: [String: [JSONValue]]

    package struct Node: Decodable, Sendable, Equatable {
        package var key: String
        /// The FQDN, with Tailscale's trailing dot.
        package var name: String
        package var tags: [String]

        enum CodingKeys: String, CodingKey { case key = "Key", name = "Name", tags = "Tags" }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            name = try c.decode(String.self, forKey: .name)
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        }
    }

    package struct UserProfile: Decodable, Sendable, Equatable {
        package var id: Int64
        package var loginName: String

        enum CodingKeys: String, CodingKey { case id = "ID", loginName = "LoginName" }
    }

    enum CodingKeys: String, CodingKey { case node = "Node", user = "UserProfile", capMap = "CapMap" }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        node = try c.decode(Node.self, forKey: .node)
        user = try c.decode(UserProfile.self, forKey: .user)
        let raw = try c.decodeIfPresent([String: JSONValue].self, forKey: .capMap) ?? [:]
        capMap = raw.mapValues { if case .array(let list) = $0 { list } else { [] } }
    }

    /// A tagged node's user is Tailscale's "tagged-devices" stand-in, never a person.
    package var userId: Int64? { node.tags.isEmpty ? user.id : nil }
}

package enum TailnetEvent: Equatable, Sendable {
    case state(BackendState)
    case status(TailnetStatus)
    /// A peer came online or went (`PeerChanges`).
    case peer(nodeID: Int64, key: String?, online: Bool?)
    case error(String)
}

/// A listening end: a TCP socket to `accept` (installed Tailscale), or the sidecar's Unix socket
/// on which each accepted connection arrives as a descriptor.
package enum TailnetListenSocket: Equatable, Sendable {
    case tcp(Int32)
    case handoff(Int32)

    package var fd: Int32 {
        switch self {
        case .tcp(let fd), .handoff(let fd): fd
        }
    }
}

/// One IPN bus message, the parts read: `Engine` messages (every 2 s on a Mac) give nothing.
struct BusNotify: Decodable {
    var state: Int?
    var initialStatus: TailnetStatus?
    var peerChanges: [PeerChange]?
    var errMessage: String?

    struct PeerChange: Decodable {
        var nodeID: Int64
        var key: String?
        var online: Bool?
        enum CodingKeys: String, CodingKey { case nodeID = "NodeID", key = "Key", online = "Online" }
    }

    enum CodingKeys: String, CodingKey {
        case state = "State", initialStatus = "InitialStatus", peerChanges = "PeerChanges", errMessage = "ErrMessage"
    }

    /// The bus's watch mask: initial state + initial status + peer patches, never engine updates
    /// or the netmap (spike 0h).
    static let mask = 49154

    var events: [TailnetEvent] {
        var out: [TailnetEvent] = []
        if let state { out.append(.state(BackendState(bus: state))) }
        if let initialStatus { out.append(.status(initialStatus)) }
        for change in peerChanges ?? [] { out.append(.peer(nodeID: change.nodeID, key: change.key, online: change.online)) }
        if let errMessage, !errMessage.isEmpty { out.append(.error(errMessage)) }
        return out
    }
}
