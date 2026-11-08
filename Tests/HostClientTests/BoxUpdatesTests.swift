import CryptoKit
import Foundation
import Testing

@testable import HostClient
@testable import KoreCore
@testable import LinkProtocol

/// "Keep boxes updated": what a Mac sends a linked box, and when.
@Suite("keep boxes updated")
@MainActor
struct BoxUpdatesTests {
    final class Sent { var messages: [Data] = [] }

    func make(_ defaults: UserDefaults? = nil) -> (BoxUpdates, () -> Date, (TimeInterval) -> Void) {
        let suite = defaults ?? UserDefaults(suiteName: "kore-box-updates-\(UUID().uuidString)")!
        let updates = BoxUpdates(defaults: suite)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        updates.now = { clock }
        updates.macName = { "Soumil's MacBook Air" }
        return (updates, { clock }, { clock += $0 })
    }

    func box(_ version: String = "0.2.3", working: Bool = false, caps: [String] = ["box", UpdateWire.cap], sent: Sent, linked: Linked? = nil) -> BoxUpdates.Box {
        var fresh: (@MainActor () -> BoxUpdates.Box?)?
        if let linked { fresh = { linked.box } }
        return BoxUpdates.Box(
            alias: "devbox", version: version, caps: caps, working: working, send: { sent.messages.append($0); return true }, fresh: fresh)
    }

    /// The link as it is now, for what reads it again later.
    final class Linked { var box: BoxUpdates.Box? }

    func types(_ sent: Sent) -> [String] { sent.messages.compactMap(StreamWire.type) }

    @Test func onByDefaultAndRemembered() {
        let defaults = UserDefaults(suiteName: "kore-box-updates-\(UUID().uuidString)")!
        #expect(BoxUpdates(defaults: defaults).keep)
        BoxUpdates(defaults: defaults).keep = false
        #expect(!BoxUpdates(defaults: defaults).keep)
    }

    @Test func anOlderIdleBoxIsAskedOnceForTheLatest() throws {
        let (updates, _, advance) = make()
        updates.latest = "0.3.0"
        let sent = Sent()
        updates.linkedUp(box(sent: sent))
        #expect(types(sent) == [UpdateWire.keep, UpdateWire.update])
        let keep = try JSONDecoder().decode(UpdateWire.Keep.self, from: sent.messages[0])
        #expect(keep.on && keep.by == "Soumil's MacBook Air")
        let ask = try JSONDecoder().decode(UpdateWire.Update.self, from: sent.messages[1])
        #expect(ask.version == "0.3.0" && ask.by == "Soumil's MacBook Air")
        // Not again on the next idle chat, only after a while.
        updates.consider(box(sent: sent))
        #expect(sent.messages.count == 2)
        advance(BoxUpdates.retryAfter)
        updates.consider(box(sent: sent))
        #expect(sent.messages.count == 3)
    }

    @Test func nothingIsAskedWhenItShouldntBe() {
        let (updates, _, _) = make()
        let sent = Sent()
        // No release found yet.
        updates.consider(box(sent: sent))
        updates.latest = "0.3.0"
        // A chat working, a box as new or newer, one too old to know host.update.
        updates.consider(box(working: true, sent: sent))
        updates.consider(box("0.3.0", sent: sent))
        updates.consider(box("0.4.0", sent: sent))
        updates.consider(box(caps: ["box"], sent: sent))
        updates.linkedUp(box(caps: ["box"], sent: sent))
        #expect(sent.messages.isEmpty)
        // The setting off: the box hears it, and nothing more.
        updates.keep = false
        updates.linkedUp(box(sent: sent))
        #expect(types(sent) == [UpdateWire.keep])
        #expect((try? JSONDecoder().decode(UpdateWire.Keep.self, from: sent.messages[0]))?.on == false)
    }

    @Test func aBusyBoxIsAskedAgainOnceIdle() {
        let (updates, _, _) = make()
        updates.latest = "0.3.0"
        let sent = Sent()
        updates.consider(box(sent: sent))
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .busy, line: "1 chat is working"))
        updates.consider(box(sent: sent))
        #expect(types(sent) == [UpdateWire.update, UpdateWire.update])
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .failed, line: "can't reach github.com"))
        updates.consider(box(sent: sent))
        #expect(sent.messages.count == 2)
    }

    /// Every input of "should this box be asked now", one row each.
    struct Row: CustomTestStringConvertible, Sendable {
        var name: String
        var keep = true
        var latest: String? = "0.3.0"
        var version = "0.2.3"
        var caps = ["box", UpdateWire.cap]
        var working = false
        var askedAgo: TimeInterval?
        var updating = false
        var asks: String?
        var testDescription: String { name }
    }

    nonisolated static let table: [Row] = [
        Row(name: "older and idle", asks: "0.3.0"),
        Row(name: "setting off", keep: false),
        Row(name: "no release found yet", latest: nil),
        Row(name: "a chat working", working: true),
        Row(name: "same version", version: "0.3.0"),
        Row(name: "dev build newer", version: "0.4.0"),
        Row(name: "dev build newer patch", version: "0.3.0.1"),
        Row(name: "too old to take host.update", caps: ["box"]),
        Row(name: "asked a minute ago", askedAgo: 60),
        Row(name: "asked past the retry", askedAgo: BoxUpdates.retryAfter, asks: "0.3.0"),
        Row(name: "an update running there", updating: true),
        Row(name: "older by a minor", latest: "0.10.0", version: "0.9.9", asks: "0.10.0"),
    ]

    @Test(arguments: table) func decides(_ row: Row) {
        let (updates, _, advance) = make()
        let sent = Sent()
        updates.latest = "0.3.0"
        if let ago = row.askedAgo {
            updates.consider(box(sent: sent))
            updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .failed, line: "no"))
            advance(ago)
        }
        if row.updating {
            updates.consider(box(sent: sent))
            updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .started, line: "updating"))
            advance(BoxUpdates.retryAfter)
        }
        updates.keep = row.keep
        updates.latest = row.latest
        #expect(updates.due(box(row.version, working: row.working, caps: row.caps, sent: sent)) == row.asks)
    }

    @Test func theToggleTellsLinkedBoxesAtOnce() throws {
        let (updates, _, _) = make()
        let sent = Sent(), linked = Linked()
        linked.box = box(working: true, sent: sent, linked: linked)
        updates.latest = "0.3.0"
        updates.linkedUp(linked.box!)
        #expect(types(sent) == [UpdateWire.keep])
        updates.keep = false
        linked.box = box(sent: sent, linked: linked)
        #expect(types(sent) == [UpdateWire.keep, UpdateWire.keep])
        #expect(try JSONDecoder().decode(UpdateWire.Keep.self, from: sent.messages[1]).on == false)
        // On again with the box idle: told, then asked.
        updates.keep = true
        #expect(types(sent) == [UpdateWire.keep, UpdateWire.keep, UpdateWire.keep, UpdateWire.update])
    }

    @Test func aReleaseFoundLaterAsksIdleLinkedBoxes() {
        let (updates, _, _) = make()
        let sent = Sent(), linked = Linked()
        linked.box = box(sent: sent, linked: linked)
        updates.linkedUp(linked.box!)
        #expect(types(sent) == [UpdateWire.keep])
        // Never while a chat works: the turn's end asks.
        linked.box = box(working: true, sent: sent, linked: linked)
        updates.latest = "0.3.0"
        #expect(types(sent) == [UpdateWire.keep])
        updates.consider(box(sent: sent))
        #expect(types(sent) == [UpdateWire.keep, UpdateWire.update])
    }

    final class Slept: @unchecked Sendable { var waits: [CheckedContinuation<Void, Never>] = [] }

    @Test func theRowSaysUpdatingThenTheNewVersion() async {
        let (updates, _, _) = make()
        let slept = Slept()
        updates.sleep = { _ in await withCheckedContinuation { slept.waits.append($0) } }
        updates.latest = "0.3.0"
        let sent = Sent()
        updates.linkedUp(box(sent: sent))
        #expect(updates.work["devbox"] == nil)
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .started, line: "updating to 0.3.0"))
        var facts = BoxFacts(key: "devbox", name: "devbox")
        facts.update = updates.work["devbox"]
        #expect(DevicesPicture.updateLine(facts) == "Updating devbox…")
        // A snapshot while it runs: still under way, and not asked again.
        updates.linkedUp(box(sent: sent))
        #expect(updates.work["devbox"]?.done == nil)
        #expect(types(sent).filter { $0 == UpdateWire.update }.count == 1)
        // Back on the new version.
        updates.linkedUp(box("0.3.0", sent: sent))
        facts.update = updates.work["devbox"]
        #expect(DevicesPicture.updateLine(facts) == "updated to 0.3.0")
        var row = DeviceRow(id: "devbox", kind: .box, name: "devbox", status: .connected)
        row.update = DevicesPicture.updateLine(facts)
        #expect(DevicesWords.detail(row, now: Date()) == "updated to 0.3.0")
        await Self.until { !slept.waits.isEmpty }
        slept.waits.removeFirst().resume()
        await Self.until { updates.work["devbox"] == nil }
    }

    @Test func aFailureClearsTheRow() {
        let (updates, _, advance) = make()
        updates.latest = "0.3.0"
        let sent = Sent()
        updates.consider(box(sent: sent))
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .started, line: "updating"))
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .failed, line: "the update didn't finish"))
        #expect(updates.work["devbox"] == nil)
        // One that never came back stops showing once its link is up again.
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .started, line: "updating"))
        advance(BoxUpdates.workingFor + 1)
        updates.linkedUp(box(sent: sent))
        #expect(updates.work["devbox"] == nil)
    }

    // MARK: The Mac's copy

    final class Release: @unchecked Sendable {
        let key = Curve25519.Signing.PrivateKey()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-box-release-\(UUID().uuidString)")
        var files: [String: Data] = [:]
        var fetched: [String] = []

        init(_ version: String, tamper: Bool = false) throws {
            let asset = Data((0..<(UpdateWire.pieceSize + 5)).map { UInt8($0 % 241) })
            let sha = SHA256.hash(data: asset).map { String(format: "%02x", $0) }.joined()
            let text = ReleaseManifest(version: version, commit: String(repeating: "c", count: 40), files: ["kore-host-linux-x86_64.xz": sha]).text
            files = [
                "SHA256SUMS": Data(text.utf8), "SHA256SUMS.sig": try key.signature(for: Data(text.utf8)),
                "kore-host-linux-x86_64.xz": tamper ? asset + Data([1]) : asset,
            ]
        }
    }

    func copying(_ updates: BoxUpdates, _ release: Release) {
        updates.folder = release.folder
        updates.releaseKey = release.key.publicKey.rawRepresentation.base64EncodedString()
        updates.releaseBase = { "https://example.invalid/v\($0)" }
        updates.download = { url, to in
            release.fetched.append(url.absoluteString)
            guard let data = release.files[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            try data.write(to: to)
        }
    }

    @Test func anOfflineBoxGetsTheCheckedReleaseFromThisMac() async throws {
        let (updates, _, _) = make()
        let release = try Release("0.3.0")
        defer { try? FileManager.default.removeItem(at: release.folder) }
        copying(updates, release)
        updates.latest = "0.3.0"
        let sent = Sent(), linked = Linked()
        linked.box = box(sent: sent, linked: linked)
        updates.linkedUp(linked.box!)
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .started, line: "updating"))
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .offline, line: "can't reach github.com", asset: "kore-host-linux-x86_64.xz"))
        await Self.until { sent.messages.count == 3 }
        #expect(release.fetched == ["SHA256SUMS", "SHA256SUMS.sig", "kore-host-linux-x86_64.xz"].map { "https://example.invalid/v0.3.0/" + $0 })
        let ask = try JSONDecoder().decode(UpdateWire.Update.self, from: sent.messages[2])
        #expect(ask.from == UpdateWire.fromMac && ask.version == "0.3.0")
        #expect(updates.work["devbox"]?.done == nil)
        // The box pulls each file whole, piece by piece.
        for (name, want) in release.files {
            var got = Data(), offset = 0
            while true {
                let piece = updates.piece(UpdateWire.Get(id: ask.id, name: name, offset: offset))
                #expect(piece.total == want.count)
                let bytes = try #require(Data(base64Encoded: piece.data))
                got += bytes
                offset += bytes.count
                if offset >= piece.total { break }
            }
            #expect(got == want)
        }
        // Nothing else, nor for another update.
        #expect(updates.piece(UpdateWire.Get(id: ask.id, name: "../secret", offset: 0)).total == 0)
        #expect(updates.piece(UpdateWire.Get(id: "other", name: "SHA256SUMS", offset: 0)).total == 0)
        #expect(updates.piece(UpdateWire.Get(id: ask.id, name: "SHA256SUMS", offset: 1 << 30)).total == 0)
    }

    @Test func aCopyThatDoesntCheckOutIsNeverSent() async throws {
        let (updates, _, _) = make()
        let release = try Release("0.3.0", tamper: true)
        defer { try? FileManager.default.removeItem(at: release.folder) }
        copying(updates, release)
        updates.latest = "0.3.0"
        let sent = Sent(), linked = Linked()
        linked.box = box(sent: sent, linked: linked)
        updates.linkedUp(linked.box!)
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .started, line: "updating"))
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .offline, line: "can't reach github.com", asset: "kore-host-linux-x86_64.xz"))
        await Self.until { updates.work["devbox"] == nil }
        #expect(sent.messages.count == 2)
        #expect(!FileManager.default.fileExists(atPath: release.folder.appendingPathComponent("0.3.0").path))
        // A name a box shouldn't make this Mac fetch.
        updates.answered("devbox", UpdateWire.Result(id: "u", outcome: .offline, line: "x", asset: "../../etc/passwd"))
        #expect(!BoxUpdates.isAsset("../../etc/passwd") && BoxUpdates.isAsset("kore-host-linux-aarch64.xz"))
    }

    /// Lets the main actor run what was started until `check` holds (no clock: bounded yields).
    static func until(_ check: @MainActor () -> Bool) async {
        for _ in 0..<10_000 where !check() { await Task.yield() }
        #expect(check())
    }
}
