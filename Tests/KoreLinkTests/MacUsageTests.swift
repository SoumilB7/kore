import Foundation
import HostClient
import KoreCore
import KoreNet
@testable import LinkProtocol
import Testing

@testable import KoreLink
@testable import KoreUI
@testable import src

/// A paired Mac's Kore use counts as Kore's on the other: each Mac keeps a ledger of its own Kore
/// chats' requests (with the login each ran on) and its own plan readings, and serves it to its
/// paired Macs only (`usage.since`). The other pulls it by cursor into its forwarded usage and
/// snapshot log. Nothing that came from another device is served again; a phone gets nothing.
@Suite("usage across devices: paired Macs", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MacUsageTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let acct = "aaaa1111bbbb2222"

    func ledger(_ dir: URL) -> MacUsageLedger {
        let ledger = MacUsageLedger(url: dir.appendingPathComponent("usage/peer-ledger.jsonl"))
        let t0 = t0
        ledger.now = { t0 }
        ledger.known = { .none }
        return ledger
    }

    func reading(_ used: Double, source: String, account: String?, chat: String? = nil, cli: String = "claude") -> PlanSnapshot {
        PlanSnapshot(at: t0, cli: cli, account: account, source: source, windows: [.init(minutes: 300, used: used, resetsAt: t0.addingTimeInterval(3600))], chat: chat)
    }

    func request(_ id: String, account: String? = nil) -> RequestUsage {
        RequestUsage(id: id, at: t0, model: "claude-opus-5-5", input: 10, output: 5, account: account)
    }

    @Test func theLedgerKeepsOnlyThisMacsOwnUseWithItsLogin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-usage-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = ledger(dir)
        ledger.request(session: "s1", provider: "claude", request("r1", account: acct))
        // Sent again (a copy of the message): once.
        ledger.request(session: "s1", provider: "claude", request("r1", account: acct))
        // A request whose login isn't known: left out, never put to a wrong one.
        ledger.request(session: "s2", provider: "codex", request("r2"))
        // Unless Kore noted the chat's login then.
        ledger.known = { KoreSessions.Known(since: nil, ids: [:], accounts: ["codex/s2": [(since: Date(timeIntervalSince1970: 0), acct: "cccc3333dddd4444")]]) }
        ledger.request(session: "s2", provider: "codex", request("r3"))
        // Its own readings only: a turn's report, a read. Not a box's or another Mac's, not one
        // without its login.
        ledger.plan(reading(5, source: "stream", account: acct, chat: "s1"))
        ledger.plan(reading(6, source: "read", account: acct))
        ledger.plan(reading(7, source: "box", account: acct))
        ledger.plan(reading(8, source: "mac", account: acct))
        ledger.plan(reading(9, source: "stream", account: nil))
        ledger.plan(reading(9, source: "stream", account: "plan:max"))
        let all = ledger.since(nil, id: "u1", plan: true)
        #expect(all.lines.map(\.id).filter { !$0.hasPrefix("plan-") } == ["r1", "r3"])
        #expect(all.lines.filter { !$0.isPlan }.map(\.acct) == [acct, "cccc3333dddd4444"])
        #expect(all.lines.compactMap(\.plan).map { $0.first?.used } == [5, 6])
        #expect(all.lines.filter(\.isPlan).map(\.chat) == ["s1", ""])
        // An asker that doesn't take plan lines: requests only, its cursor past the plan lines.
        let requests = ledger.since(nil, id: "u2", plan: false)
        #expect(requests.lines.map(\.id) == ["r1", "r3"] && requests.cursor == all.cursor)
        // A restart reads it back, and numbers on.
        let again = MacUsageLedger(url: dir.appendingPathComponent("usage/peer-ledger.jsonl"))
        again.now = { t0 }
        again.request(session: "s1", provider: "claude", request("r1", account: acct))
        again.request(session: "s1", provider: "claude", request("r4", account: acct))
        #expect(again.since(all.cursor, id: "u3", plan: true).lines.map(\.id) == ["r4"])
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("usage/peer-ledger.jsonl").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    final class Pulled: @unchecked Sendable {
        private let lock = NSLock()
        private var requestsSeen: [ForwardedRequest] = []
        private var readingsSeen: [PlanSnapshot] = []
        func add(_ request: ForwardedRequest) { lock.withLock { requestsSeen.append(request) } }
        func add(_ reading: PlanSnapshot) { lock.withLock { readingsSeen.append(reading) } }
        var requests: [ForwardedRequest] { lock.withLock { requestsSeen } }
        var readings: [PlanSnapshot] { lock.withLock { readingsSeen } }
    }

    @Test func aPairedMacsKoreUseComesHereAsKoresForItsLoginAndResumesByCursor() async throws {
        let macs = try TwoMacs()
        defer { macs.finish() }
        try await macs.pair()
        let dir = macs.a.folder.appendingPathComponent("usage-test", isDirectory: true)
        // B's ledger: two requests on its login, its turn's report before the first, a read.
        let served = ledger(dir.appendingPathComponent("b"))
        served.request(session: "s1", provider: "claude", request("r1", account: acct))
        served.plan(reading(5, source: "stream", account: acct, chat: "s1"))
        served.request(session: "s1", provider: "claude", request("r2", account: acct))
        served.plan(reading(6, source: "read", account: acct))
        let old = MacPeerLink.ledger
        MacPeerLink.ledger = { served }
        defer { MacPeerLink.ledger = old }
        let pulled = Pulled()
        let (oldRequests, oldPlans) = (MacPeers.requestSink, MacPeers.planSink)
        MacPeers.requestSink = { pulled.add($0) }
        MacPeers.planSink = { pulled.add($0) }
        defer { (MacPeers.requestSink, MacPeers.planSink) = (oldRequests, oldPlans) }
        let peers = macs.peers
        peers.cursorsFile = dir.appendingPathComponent("a/peer-cursors.json")
        let b = macs.b.host.device
        let key = LoginMoves.macKey(b)

        await peers.pullUsage(b)
        #expect(pulled.requests.map(\.request) == ["r1", "r2"])
        #expect(pulled.requests.allSatisfy { $0.account == acct && $0.chat == key + "/s1" && $0.units > 0 })
        #expect(pulled.readings.map { $0.windows.first?.used } == [5, 6])
        #expect(pulled.readings.allSatisfy { $0.source == "mac" && $0.account == acct })
        // The report names its chat exactly as that chat's requests are kept; the read none.
        #expect(pulled.readings.map(\.chat) == [key + "/s1", nil])
        // Its caps said it serves usage.
        #expect(peers.paired().first?.capsKnown == true)

        // More on B; a reading B was handed from another device isn't served again.
        served.request(session: "s1", provider: "claude", request("r3", account: acct))
        served.plan(reading(9, source: "mac", account: acct))
        await peers.pullUsage(b)
        #expect(pulled.requests.map(\.request) == ["r1", "r2", "r3"])
        #expect(pulled.readings.count == 2)
        // The cursor was kept: a new MacPeers (a restart) asks from it.
        let restarted = macs.peers
        restarted.cursorsFile = peers.cursorsFile
        await restarted.pullUsage(b)
        #expect(pulled.requests.count == 3)
    }

    @Test func aPhoneGetsNoMacsUsage() async throws {
        let rig = try MacRig()
        defer { rig.finish() }
        let dir = rig.folder.appendingPathComponent("usage-test", isDirectory: true)
        let served = ledger(dir)
        served.request(session: "s1", provider: "claude", request("r1", account: acct))
        let old = MacPeerLink.ledger
        MacPeerLink.ledger = { served }
        defer { MacPeerLink.ledger = old }
        let pixel = Phone()
        try rig.allow(pixel)
        let phone = try rig.dial(pixel)
        await phone.up()
        await phone.next("attn.state")
        phone.send(#"{"t":"usage.since","id":"u1","plan":true}"#)
        let page = await phone.next("usage.page", id: "u1")
        #expect((page["lines"] as? [Any])?.isEmpty == true)
    }
}
