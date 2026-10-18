import Foundation
import Testing

import KoreCore
@testable import KoreStorylines
@testable import KoreUI

/// A typed /compact compacts as the context wheel does, on the scripted CLI.
@MainActor
@Suite("Typing /compact", .serialized)
final class CompactCommandTests {
    /// Kept for the run: the seam it installs refers to it.
    static let world = ScriptedWorld()
    var world: ScriptedWorld { Self.world }

    /// Waits (on run-loop passes, as storylines do) until `done`.
    private func until(_ what: String, _ done: () -> Bool) async throws {
        for _ in 0..<2000 {
            if done() { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting for \(what)")
        throw CancellationError()
    }

    private func userTexts(_ chat: Chat) -> [String] {
        chat.transcript.entries.filter { $0.kind == .user }.map(\.text)
    }

    @Test func theCommandsWords() {
        #expect(Chat.compactCommand("/compact") == "")
        #expect(Chat.compactCommand("/compact  keep the file names\n") == "keep the file names")
        #expect(Chat.compactCommand("/compacting") == nil)
        #expect(Chat.compactCommand("compact") == nil)
    }

    @Test func compactsWithoutAMessage() async throws {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp"))
        // No session yet: it can't compact, and the command waits in the composer.
        chat.draft = "/compact"
        chat.send()
        #expect(chat.draft == "/compact")
        #expect(world.backends.isEmpty)

        chat.draft = "Say something"
        // Installed just before the chat makes its backend: other suites install their own.
        world.install()
        chat.send()
        try await until("the first turn") { chat.status.sessionId != nil && !chat.status.isRunning }
        chat.draft = "/compact keep the names"
        chat.send()
        #expect(chat.draft.isEmpty)
        try await until("the compaction") {
            !chat.context.compacting && chat.transcript.entries.contains { $0.kind == .summary }
        }
        #expect(world.backends.last?.log.contains(.compact) == true)
        #expect(world.backends.last?.log.contains { if case .send(let text) = $0 { text.hasPrefix("/compact") } else { false } } == false)
        #expect(userTexts(chat) == ["Say something"])
        chat.close()
    }
}
