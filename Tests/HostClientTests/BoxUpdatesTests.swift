import Foundation
import Testing

@testable import HostClient
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

    func box(_ version: String = "0.2.3", working: Bool = false, caps: [String] = ["box", UpdateWire.cap], sent: Sent) -> BoxUpdates.Box {
        BoxUpdates.Box(alias: "devbox", version: version, caps: caps, working: working) { sent.messages.append($0); return true }
    }

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
}
