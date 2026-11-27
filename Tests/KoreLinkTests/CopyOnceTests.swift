import Foundation
import LinkProtocol
import Testing

@testable import KoreLink

/// A phone's copy (`chat.copyVia`) runs once per ask, whatever link hears how it ended.
@MainActor
@Suite("a phone's copy runs once", .serialized)
struct CopyOnceTests {
    static let phone = UUID()

    static func ask(_ id: String, again: Bool? = nil) -> CopyAsk {
        CopyAsk(id: id, again: again, from: .init(windowId: "w_1", chatId: "c1"), to: .init(windowId: "w_2"), provider: "claude", title: "Repos")
    }

    @Test func anAskHeardAgainWaitsForTheOneCopyAndHearsItsEnd() async {
        let was = LinkCopyVia.copy
        defer { LinkCopyVia.copy = was }
        var ran: [String] = []
        var finish: [CheckedContinuation<Void, Never>] = []
        LinkCopyVia.copy = { ask, _ in
            ran.append(ask.id)
            await withCheckedContinuation { finish.append($0) }
            return .failed(.busy, "Lost mybox partway · nothing changed")
        }
        let id = UUID().uuidString
        let first = Task { await LinkCopyVia.run(Self.ask(id), phone: Self.phone) }
        while finish.isEmpty { await Task.yield() }
        // The phone's link went; it asks by the same id while the copy still runs.
        let again = Task { await LinkCopyVia.run(Self.ask(id, again: true), phone: Self.phone) }
        for _ in 0..<20 { await Task.yield() }
        #expect(ran == [id])
        finish[0].resume()
        let (one, two) = (await first.value, await again.value)
        #expect(!one.ok && !two.ok && one.message == "Lost mybox partway · nothing changed" && two.message == one.message)
        // Asked once more after its end: the same end, and it isn't run.
        #expect(await LinkCopyVia.run(Self.ask(id, again: true), phone: Self.phone).message == one.message && ran == [id])
    }

    @Test func anAskThisKoreNeverHadIsNotRunAndSaysToLook() async {
        let was = LinkCopyVia.copy
        defer { LinkCopyVia.copy = was }
        var ran = 0
        LinkCopyVia.copy = { _, _ in ran += 1; return .done }
        let said = await LinkCopyVia.run(Self.ask(UUID().uuidString, again: true), phone: Self.phone)
        #expect(said.code == .goneSession && said.message == "Kore doesn't know if that was copied · look there before copying again" && ran == 0)
        // Two asks are two copies; only the newest are kept.
        for _ in 0..<(LinkCopyVia.kept + 2) { #expect(await LinkCopyVia.run(Self.ask(UUID().uuidString), phone: Self.phone).ok) }
        #expect(ran == LinkCopyVia.kept + 2)
    }
}
