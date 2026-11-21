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
    /// Tailnet Lock as this node sees it; nil where it can't be read (Kore's own tailnet).
    func lockStatus() throws -> TailnetLock?
    /// Signs a node Tailnet Lock keeps out (`tailscale lock sign`): only when this node holds a
    /// trusted lock key.
    func lockSign(_ nodeKey: String) throws
}

extension Tailnet {
    package func lockStatus() throws -> TailnetLock? { nil }
    package func lockSign(_ nodeKey: String) throws { throw TailnetError.http(404) }
}

/// Tailnet Lock (`/localapi/v0/tka/status`): on or off, this node's lock key and the trusted
/// ones, and the peers kept out for want of a signature.
package struct TailnetLock: Decodable, Sendable, Equatable {
    package var enabled: Bool
    /// This node's own lock key (`tlpub:…`).
    package var publicKey: String
    package var trustedKeys: [String]
    package var filtered: [Filtered]

    package struct Filtered: Decodable, Sendable, Equatable {
        /// Its tailnet name (`kore-pixel-9.tail1234.ts.net.`).
        package var name: String
        package var nodeKey: String

        package init(name: String, nodeKey: String) {
            self.name = name
            self.nodeKey = nodeKey
        }

        enum CodingKeys: String, CodingKey { case name = "Name", nodeKey = "NodeKey" }
    }

    private struct Key: Decodable {
        var key: String
        enum CodingKeys: String, CodingKey { case key = "Key" }
    }

    enum CodingKeys: String, CodingKey { case enabled = "Enabled", publicKey = "PublicKey", trustedKeys = "TrustedKeys", filtered = "FilteredPeers" }

    package init(enabled: Bool, publicKey: String, trustedKeys: [String], filtered: [Filtered]) {
        self.enabled = enabled
        self.publicKey = publicKey
        self.trustedKeys = trustedKeys
        self.filtered = filtered
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        trustedKeys = (try c.decodeIfPresent([Key].self, forKey: .trustedKeys) ?? []).map(\.key)
        filtered = try c.decodeIfPresent([Filtered].self, forKey: .filtered) ?? []
    }

    /// This node holds one of the trusted keys: it may sign.
    package var canSign: Bool { enabled && !publicKey.isEmpty && trustedKeys.contains(publicKey) }
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

    /// kore-tailnet's own words when the state key doesn't open the saved state (`errWrongKey`).
    package static let wrongStateKey = "the state key doesn't open the saved state"

    /// The state on disk was sealed under another key.
    package var wrongKey: Bool { if case .sidecar(let why) = self { why == Self.wrongStateKey } else { false } }

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
    /// The sign-in page while NeedsLogin, for the UI to open; never logged.
    package var authURL: String?

    package struct SelfNode: Decodable, Sendable, Equatable {
        package var publicKey: String
        package var tailscaleIPs: [String]
        package var userID: Int64?
        /// A tagged node's tags (its `UserID` is then Tailscale's stand-in, never a person).
        package var tags: [String]?
        /// Its MagicDNS name, with Tailscale's trailing dot (empty when it has none).
        package var dnsName: String
        /// Its name on the tailnet ("macbook"), for the Devices popup.
        package var hostName: String?
        /// When its node key expires; nil when it never does.
        package var keyExpiry: Date?

        enum CodingKeys: String, CodingKey {
            case publicKey = "PublicKey", tailscaleIPs = "TailscaleIPs", userID = "UserID", tags = "Tags", dnsName = "DNSName"
            case hostName = "HostName", keyExpiry = "KeyExpiry"
        }

        package init(publicKey: String, tailscaleIPs: [String], userID: Int64?, tags: [String]? = nil, dnsName: String = "") {
            self.publicKey = publicKey
            self.tailscaleIPs = tailscaleIPs
            self.userID = userID
            self.tags = tags
            self.dnsName = dnsName
        }

        /// Signed out, Self has no addresses yet (`null`).
        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            publicKey = try c.decode(String.self, forKey: .publicKey)
            tailscaleIPs = try c.decodeIfPresent([String].self, forKey: .tailscaleIPs) ?? []
            userID = try c.decodeIfPresent(Int64.self, forKey: .userID)
            tags = try c.decodeIfPresent([String].self, forKey: .tags)
            dnsName = try c.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
            hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
            keyExpiry = TailnetTime.date(try c.decodeIfPresent(String.self, forKey: .keyExpiry))
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
        /// Its name on the tailnet ("box-1").
        package var hostName: String
        /// Its OS as Tailscale says it ("linux", "macOS", "android").
        package var os: String
        /// Traffic to it goes through a relay (DERP): a relay region and no direct address.
        package var relayed: Bool
        /// When its node key expires; nil when it never does.
        package var keyExpiry: Date?
        /// When it was last online, while it's offline.
        package var lastSeen: Date?
        /// Shared in from another tailnet.
        package var shared: Bool

        enum CodingKeys: String, CodingKey {
            case publicKey = "PublicKey", tailscaleIPs = "TailscaleIPs", online = "Online", userID = "UserID", tags = "Tags"
            case hostName = "HostName", os = "OS", relay = "Relay", curAddr = "CurAddr", keyExpiry = "KeyExpiry", lastSeen = "LastSeen"
            case shareeNode = "ShareeNode"
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            publicKey = try c.decode(String.self, forKey: .publicKey)
            tailscaleIPs = try c.decodeIfPresent([String].self, forKey: .tailscaleIPs) ?? []
            online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
            userID = try c.decodeIfPresent(Int64.self, forKey: .userID)
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            hostName = try c.decodeIfPresent(String.self, forKey: .hostName) ?? ""
            os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
            let relay = try c.decodeIfPresent(String.self, forKey: .relay) ?? ""
            let direct = try c.decodeIfPresent(String.self, forKey: .curAddr) ?? ""
            relayed = online && !relay.isEmpty && direct.isEmpty
            keyExpiry = TailnetTime.date(try c.decodeIfPresent(String.self, forKey: .keyExpiry))
            lastSeen = TailnetTime.date(try c.decodeIfPresent(String.self, forKey: .lastSeen))
            shared = try c.decodeIfPresent(Bool.self, forKey: .shareeNode) ?? false
        }
    }

    /// Tailscale's health warnings for this node.
    package var health: [String] = []
    /// The tailnet's users this node knows, by id: their login names.
    package var logins: [Int64: String] = [:]

    /// The person this node is signed in as ("you@example.com"); nil for a tagged node or before
    /// a sign-in.
    package var login: String? { selfNode?.owner.flatMap { logins[$0] } }

    /// This node waits for a Tailnet Lock signature (its health says it's locked out).
    package var lockedOut: Bool { health.contains { $0.localizedCaseInsensitiveContains("locked out") } }

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState", selfNode = "Self", peers = "Peer", authURL = "AuthURL", health = "Health", users = "User"
    }

    private struct User: Decodable {
        var id: Int64
        var loginName: String?
        enum CodingKeys: String, CodingKey { case id = "ID", loginName = "LoginName" }
    }

    package init(backendState: BackendState, selfNode: SelfNode?, peers: [Peer] = [], authURL: String? = nil) {
        self.backendState = backendState
        self.selfNode = selfNode
        self.peers = peers
        self.authURL = authURL
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backendState = try c.decode(BackendState.self, forKey: .backendState)
        selfNode = try c.decodeIfPresent(SelfNode.self, forKey: .selfNode)
        let map = try c.decodeIfPresent([String: Peer].self, forKey: .peers) ?? [:]
        peers = map.keys.sorted().compactMap { map[$0] }
        authURL = try c.decodeIfPresent(String.self, forKey: .authURL).flatMap { $0.isEmpty ? nil : $0 }
        health = try c.decodeIfPresent([String].self, forKey: .health) ?? []
        let users = (try? c.decodeIfPresent([String: User].self, forKey: .users)) ?? [:]
        for user in users.values { if let name = user.loginName, !name.isEmpty { logins[user.id] = name } }
    }
}

/// Tailscale's times (Go's RFC 3339, fractions or not); its zero time ("0001-…") is none.
package enum TailnetTime {
    package static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty, !text.hasPrefix("0001-") else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // Nanoseconds: more digits than the formatter reads.
        guard let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) else { return nil }
        let trimmed = String(text[..<dot]) + String(text[dot...].prefix(4)) + String(text[end...])
        return fractional.date(from: trimmed)
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
    /// `PeerChangedPatch`: narrow per-peer patches (Online among them), the peer-patches bit's.
    var peerChanges: [PeerChange]?
    var errMessage: String?
    /// The interactive sign-in page is ready (`BrowseToURL`): never kept here, only its news.
    var browseToURL: String?

    struct PeerChange: Decodable {
        var nodeID: Int64
        var key: String?
        var online: Bool?
        enum CodingKeys: String, CodingKey { case nodeID = "NodeID", key = "Key", online = "Online" }
    }

    enum CodingKeys: String, CodingKey {
        case state = "State", initialStatus = "InitialStatus", peerChanges = "PeerChangedPatch", errMessage = "ErrMessage",
            browseToURL = "BrowseToURL"
    }

    /// The bus's watch mask: initial state + initial status + peer patches, never engine updates
    /// or the netmap (spike 0h).
    static let mask = 49154

    /// Whether a bus line names a field read here: the `Engine` lines Tailscale sends every 2 s
    /// regardless of the mask are skipped without decoding.
    static func mayCarry(_ line: [UInt8]) -> Bool {
        keys.contains { key in line.withUnsafeBufferPointer { contains($0, key) } }
    }

    private static let keys: [[UInt8]] = ["\"State\"", "\"InitialStatus\"", "\"PeerChangedPatch\"", "\"ErrMessage\""].map { Array($0.utf8) }

    private static func contains(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard hay.count >= needle.count, let first = needle.first else { return false }
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    var events: [TailnetEvent] {
        var out: [TailnetEvent] = []
        if let state { out.append(.state(BackendState(bus: state))) }
        // The sign-in page came: the node waits for its login (the page itself comes with the
        // next status read, never through here or a log).
        if state == nil, let browseToURL, !browseToURL.isEmpty { out.append(.state(.needsLogin)) }
        if let initialStatus { out.append(.status(initialStatus)) }
        for change in peerChanges ?? [] { out.append(.peer(nodeID: change.nodeID, key: change.key, online: change.online)) }
        if let errMessage, !errMessage.isEmpty { out.append(.error(errMessage)) }
        return out
    }
}

/// A status as text (a log line, an error, a test's message) never carries the sign-in page:
/// whoever holds that link can add a machine to the owner's tailnet.
extension TailnetStatus: CustomStringConvertible, CustomDebugStringConvertible {
    package var description: String {
        let me = selfNode.map { " self=\($0.publicKey) \($0.tailscaleIPs.joined(separator: ","))" } ?? ""
        return "TailnetStatus(\(backendState.rawValue)\(me) peers=\(peers.count)\(authURL == nil ? "" : " authURL=<hidden>"))"
    }

    package var debugDescription: String { description }
}
