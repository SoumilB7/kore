import Foundation
import HostClient
import Tailnet
import Testing

/// The box node picker and the reconnect card's words (`connection-cases.md`).
struct BoxNodesTests {
    static func peer(_ name: String, _ key: String, _ ip: String, online: Bool = true, user: Int64 = 7, tags: [String] = []) -> TailnetStatus.Peer {
        let tagList = tags.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"PublicKey":"\#(key)","TailscaleIPs":["\#(ip)"],"Online":\#(online),"UserID":\#(user),"HostName":"\#(name)","OS":"linux","Tags":[\#(tagList)]}"#
        return try! JSONDecoder().decode(TailnetStatus.Peer.self, from: Data(json.utf8))
    }

    static func status(_ peers: [TailnetStatus.Peer]) -> TailnetStatus {
        TailnetStatus(backendState: .running, selfNode: .init(publicKey: "me", tailscaleIPs: ["100.64.0.1"], userID: 7, dnsName: "macbook."), peers: peers)
    }

    @Test func knownKeysOnlineFirstInOrder() {
        let s = Self.status([Self.peer("mybox", "k1", "100.91.66.71", online: false), Self.peer("mybox-kore", "k2", "100.113.194.5")])
        let picked = BoxNodes.candidates(keys: ["k1", "k2"], names: ["mybox"], status: s)
        #expect(picked.map(\.key) == ["k2"])
        #expect(picked.first?.known == true && picked.first?.address == "100.113.194.5")
    }

    @Test func aNodeNamedAfterItIsTriedWhenNoKnownOneIsOnline() {
        let s = Self.status([
            Self.peer("mybox", "k1", "100.91.66.71", online: false), Self.peer("mybox-kore", "k9", "100.113.194.5"),
            Self.peer("mybox-kore", "other", "100.1.1.1", user: 8), Self.peer("mybox-1", "tagged", "100.1.1.2", tags: ["tag:ci"]),
            Self.peer("otherbox-kore", "k5", "100.1.1.3"),
        ])
        #expect(BoxNodes.candidates(keys: ["k1"], names: ["mybox"], status: s).map(\.key) == ["k9"])
        // Held by another known device: never this box's.
        #expect(BoxNodes.candidates(keys: ["k1"], names: ["mybox"], status: s, others: ["k9"]).isEmpty)
    }

    @Test func offlineKnownNodeTriedOnceWhenNothingIsOnline() {
        let s = Self.status([Self.peer("mybox", "k1", "100.91.66.71", online: false), Self.peer("mybox-kore", "k2", "100.113.194.5", online: false)])
        #expect(BoxNodes.candidates(keys: ["k1", "k2"], names: ["mybox"], status: s).isEmpty)
        #expect(BoxNodes.candidates(keys: ["k1", "k2"], names: ["mybox"], status: s, offline: true).map(\.key) == ["k1"])
    }

    @Test func names() {
        for host in ["mybox", "MyBox", "mybox-kore", "mybox-1", "mybox-kore-2"] { #expect(BoxNodes.named(host, after: ["mybox.local"]), "\(host)") }
        for host in ["myboxer", "mybox-korea", "mybox-0", "otherbox", "mybox-kore-x"] { #expect(!BoxNodes.named(host, after: ["mybox"]), "\(host)") }
        #expect(BoxNodes.isOwnNode("mybox-kore") && BoxNodes.isOwnNode("mybox-kore-3") && !BoxNodes.isOwnNode("mybox") && !BoxNodes.isOwnNode("mybox-1"))
        #expect(BoxNodes.isTailnetAddress("100.91.66.71") && BoxNodes.isTailnetAddress("fd7a:115c:a1e0::3738:4248"))
        #expect(!BoxNodes.isTailnetAddress("192.168.1.20") && !BoxNodes.isTailnetAddress("100.128.0.1") && !BoxNodes.isTailnetAddress("mybox"))
        #expect(BoxNodes.overTailnet("mybox.tail1234.ts.net") && !BoxNodes.overTailnet("mybox.lan"))
    }

    @Test func sshGivesItsHostName() {
        #expect(SSHTransport.parseHostName("user soumil\nhostname 100.91.66.71\nport 22\n") == "100.91.66.71")
        #expect(SSHTransport.parseHostName("port 22\n") == nil)
    }

    @Test func reconnectLines() {
        func line(_ trying: HostRoute?, node: String? = nil, via: String? = nil, tried: [String] = [], gaveUp: Bool = false, noRoute: Bool = false) -> String {
            ReconnectWords.status(name: "mybox", trying: trying, node: node, via: via, tried: tried, gaveUp: gaveUp, sshNoRoute: noRoute)
        }
        #expect(line(.net, node: "mybox-kore") == "Reconnecting over Kore's tailnet · mybox-kore")
        #expect(line(.net, node: "mybox") == "Reconnecting over Tailscale · mybox")
        #expect(line(.net) == "Reconnecting over the tailnet")
        #expect(line(.ssh(alias: "mybox", grant: "laptop")) == "Reconnecting over SSH")
        #expect(line(.ssh(alias: "mybox", grant: "laptop"), via: "100.70.1.2") == "Reconnecting over SSH · via 100.70.1.2")
        #expect(line(nil) == "Reconnecting…")
        #expect(line(nil, tried: ["net", "ssh"]) == "Reconnecting… · tried the tailnet and SSH")
        #expect(line(nil, tried: ["net", "ssh"], gaveUp: true) == "Can't reach mybox · tried the tailnet and SSH")
        #expect(line(nil, tried: ["net", "ssh"], gaveUp: true, noRoute: true) == "Can't reach mybox · tried the tailnet · SSH needs Tailscale on this Mac")
        #expect(line(.ssh(alias: "mybox", grant: "laptop"), tried: ["net", "ssh"], noRoute: true) == "Reconnecting… · tried the tailnet · SSH needs Tailscale on this Mac")
    }
}
