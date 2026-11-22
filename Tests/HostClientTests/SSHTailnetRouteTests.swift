import Foundation
import Testing

@testable import HostClient
@testable import Tailnet

/// SSH to a box at a tailnet address follows the tailnet (KoreNet review item 3).
@Suite("ssh over the tailnet")
struct SSHTailnetRouteTests {
    /// A LocalAPI status: this Mac, and peers as (name, ip, online, user).
    static func status(_ peers: [(String, String, Bool, Int)], suffix: String = "tail1.ts.net") throws -> TailnetStatus {
        var map: [String: Any] = [:]
        for (i, p) in peers.enumerated() {
            map["k\(i)"] = ["PublicKey": "nodekey:\(p.0)", "TailscaleIPs": [p.1], "Online": p.2, "UserID": p.3, "HostName": p.0, "OS": "linux"]
        }
        let json: [String: Any] = [
            "BackendState": "Running", "Peer": map,
            "Self": ["PublicKey": "nodekey:mac", "TailscaleIPs": ["100.64.0.9"], "UserID": 1, "DNSName": "mac.\(suffix)."],
        ]
        return try JSONDecoder().decode(TailnetStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    let own = (helper: "/K/kore-tailnet", socket: "/S p/kt.sock")

    @Test func aLANHostIsLeftAsTheUserSetIt() throws {
        let s = try Self.status([("mybox", "100.64.0.2", true, 1)])
        #expect(SSHTailnetRoute.decide(host: "192.168.1.11", jump: false, keyAlias: false, status: s, own: own).isEmpty)
        // A LAN name whose first label is a peer's isn't a MagicDNS name.
        #expect(SSHTailnetRoute.decide(host: "mybox.lan", jump: false, keyAlias: false, status: s, own: nil).isEmpty)
    }

    @Test func itsNodeOnlineOverInstalledTailscaleChangesNothing() throws {
        let s = try Self.status([("mybox", "100.64.0.2", true, 1), ("mybox-kore", "100.64.0.3", false, 1)])
        #expect(SSHTailnetRoute.decide(host: "100.64.0.2", jump: false, keyAlias: false, status: s, own: nil).isEmpty)
    }

    @Test func itsNodeOfflineMovesToTheSameBoxsOtherNode() throws {
        let s = try Self.status([("mybox", "100.64.0.2", false, 1), ("mybox-kore", "100.64.0.3", true, 1), ("other-kore", "100.64.0.4", true, 1)])
        #expect(SSHTailnetRoute.decide(host: "100.64.0.2", jump: false, keyAlias: false, status: s, own: nil) == ["-o", "HostName=100.64.0.3", "-o", "HostKeyAlias=100.64.0.2"])
        // By its MagicDNS name, the same.
        #expect(SSHTailnetRoute.decide(host: "mybox.tail1.ts.net", jump: false, keyAlias: false, status: s, own: nil).prefix(2) == ["-o", "HostName=100.64.0.3"])
        // Its own node offline, back on installed: the plain name.
        let back = try Self.status([("mybox", "100.64.0.2", true, 1), ("mybox-kore", "100.64.0.3", false, 1)])
        #expect(SSHTailnetRoute.decide(host: "100.64.0.3", jump: false, keyAlias: true, status: back, own: nil) == ["-o", "HostName=100.64.0.2"])
    }

    @Test func aBoxsKnownNodesComeFirstInstalledBeforeItsOwn() throws {
        let s = try Self.status([("mybox", "100.64.0.2", false, 1), ("mybox-kore", "100.64.0.3", true, 1), ("renamed", "100.64.0.5", true, 1)])
        let own = BoxNodes.Candidate(key: "nodekey:mybox-kore", address: "100.64.0.3", name: "mybox-kore", known: true)
        let installed = BoxNodes.Candidate(key: "nodekey:renamed", address: "100.64.0.5", name: "renamed", known: true)
        let route = SSHTailnetRoute.route(host: "100.64.0.2", jump: false, keyAlias: false, status: s, own: nil, known: [own, installed])
        #expect(route.target == "100.64.0.5")
        // Only its own node online: that one (its port 22 is the box's sshd).
        #expect(SSHTailnetRoute.route(host: "100.64.0.2", jump: false, keyAlias: false, status: s, own: nil, known: [own]).target == "100.64.0.3")
        // Its node online: as the alias says.
        let up = try Self.status([("mybox", "100.64.0.2", true, 1), ("mybox-kore", "100.64.0.3", true, 1)])
        #expect(SSHTailnetRoute.route(host: "100.64.0.2", jump: false, keyAlias: false, status: up, own: nil, known: [own]).target == nil)
    }

    /// box-ts-stops: the box moved to its own node, the control server still lists its
    /// installed node online (seconds late), and the box's KoreNet link is up on its own node:
    /// SSH goes there, the node proven reachable this moment.
    @Test func theNodeTheLinkIsOnBeatsAStaleOnlineList() throws {
        let stale = try Self.status([("mybox", "100.64.0.2", true, 1), ("mybox-kore", "100.64.0.3", false, 1)])
        #expect(SSHTailnetRoute.decide(host: "100.64.0.2", jump: false, keyAlias: false, status: stale, own: nil, live: "nodekey:mybox-kore")
            == ["-o", "HostName=100.64.0.3", "-o", "HostKeyAlias=100.64.0.2"])
        // On the alias's own node: as it is.
        #expect(SSHTailnetRoute.decide(host: "100.64.0.2", jump: false, keyAlias: false, status: stale, own: nil, live: "nodekey:mybox").isEmpty)
        // A link node the status doesn't list (gone): the status decides, as before.
        #expect(SSHTailnetRoute.decide(host: "100.64.0.2", jump: false, keyAlias: false, status: stale, own: nil, live: "nodekey:gone").isEmpty)
    }

    @Test func anotherUsersNodeByTheNameIsNeverTaken() throws {
        let s = try Self.status([("mybox", "100.64.0.2", false, 1), ("mybox-kore", "100.64.0.3", true, 2)])
        #expect(SSHTailnetRoute.decide(host: "100.64.0.2", jump: false, keyAlias: false, status: s, own: nil).isEmpty)
    }

    @Test func onKoresOwnTailnetSSHGoesThroughIt() throws {
        let s = try Self.status([("mybox", "100.64.0.2", true, 1)])
        #expect(SSHTailnetRoute.decide(host: "100.64.0.2", jump: false, keyAlias: false, status: s, own: own) == [
            "-o", "HostName=100.64.0.2", "-o", "HostKeyAlias=100.64.0.2", "-o", "ProxyCommand='/K/kore-tailnet' nc -socket '/S p/kt.sock' %h %p",
        ])
    }

    @Test func aJumpHostsRouteAndAnUnreadTailnetAreLeftAlone() throws {
        let s = try Self.status([("mybox", "100.64.0.2", false, 1), ("mybox-kore", "100.64.0.3", true, 1)])
        #expect(SSHTailnetRoute.decide(host: "100.64.0.2", jump: true, keyAlias: false, status: s, own: own).isEmpty)
        #expect(SSHTailnetRoute.decide(host: "100.64.0.2", jump: false, keyAlias: false, status: nil, own: own).isEmpty)
    }
}
