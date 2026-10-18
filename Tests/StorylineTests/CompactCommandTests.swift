import Foundation
import Testing

import KoreCore
@testable import KoreStorylines
@testable import KoreUI

/// A typed /compact compacts as the context wheel does, on the scripted CLI, and every
/// compaction shows in the transcript: a live row, then its divider or a failure line.
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

    /// The ids of the rows the transcript shows, in order.
    private func rowIDs(_ chat: Chat) -> [String] {
        chat.transcript.sections.flatMap { $0.items.map(\.id) }
    }

    private var liveRow: String { "spinner-" + TranscriptStore.compactionRow }

    /// A chat whose first turn has ended, on a script whose compaction, once started, waits for
    /// the test's `release()` and then ends with `end`.
    private func chatAfterATurn(compaction end: ChatEvent...) async throws -> Chat {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp"))
        world.script = CLIScript(compact: [.event(.compactionStarted(auto: false)), .wait(.release)] + end.map(Beat.event))
        // Installed just before the chat makes its backend: other suites install their own.
        world.install()
        chat.draft = "Say something"
        chat.send()
        try await until("the first turn") { chat.status.sessionId != nil && !chat.status.isRunning }
        return chat
    }

    @Test func showsTheCommandThenALiveRowThenTheDivider() async throws {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp"))
        // No session yet: it can't compact, and the command waits in the composer.
        chat.draft = "/compact"
        chat.send()
        #expect(chat.draft == "/compact")
        #expect(world.backends.isEmpty)
        chat.close()

        let compacting = try await chatAfterATurn(
            compaction: .compacted(at: Date(), auto: false), .compactionSummary("The conversation so far, in brief."))
        compacting.draft = "/compact keep the names"
        compacting.send()
        #expect(compacting.draft.isEmpty)
        #expect(userTexts(compacting) == ["Say something", "/compact keep the names"])
        try await until("the live row") { rowIDs(compacting).last == liveRow }
        // Sending waits while it compacts.
        compacting.draft = "Next"
        #expect(!compacting.canSend)

        world.backends.last?.release()
        try await until("the compaction") {
            !compacting.context.compacting && compacting.transcript.entries.contains { $0.kind == .summary }
        }
        try await until("the divider in the live row's place") { !rowIDs(compacting).contains(liveRow) }
        #expect(compacting.transcript.entries.suffix(3).map(\.kind) == [.user, .divider, .summary])
        #expect(world.backends.last?.log.contains(.compact) == true)
        #expect(world.backends.last?.log.contains { if case .send(let text) = $0 { text.hasPrefix("/compact") } else { false } } == false)
        compacting.close()
    }

    @Test func theWheelShowsTheRowAndAFailureLine() async throws {
        let chat = try await chatAfterATurn(compaction: .compactionFailed("Not enough messages to compact.\nDetails"))
        chat.compact()
        // The wheel's click adds no message.
        #expect(userTexts(chat) == ["Say something"])
        try await until("the live row") { rowIDs(chat).last == liveRow }

        world.backends.last?.release()
        try await until("the failure") { !chat.context.compacting && !rowIDs(chat).contains(liveRow) }
        let notices = chat.transcript.entries.filter { $0.kind == .notice }.map(\.text)
        #expect(notices == ["Couldn't compact: Not enough messages to compact."])
        chat.close()
    }

    @Test func theRowGoesWhenTheCLIExits() async throws {
        let chat = try await chatAfterATurn(compaction: .exited(status: 0))
        chat.compact()
        try await until("the live row") { rowIDs(chat).last == liveRow }
        world.backends.last?.release()
        try await until("the row to go") { !chat.context.compacting && !rowIDs(chat).contains(liveRow) }
        let kinds = chat.transcript.entries.map(\.kind)
        #expect(!kinds.contains(.divider) && !kinds.contains(.notice))
        chat.close()
    }

    // MARK: Auto-compact

    /// A Claude chat on a script whose every turn ends at 85% of a 200k window, its compaction
    /// ending with `end`, its auto-compact point kept in `memory`.
    private func autoCompactChat(_ memory: AutoCompactMemory, compaction end: [ChatEvent]) -> Chat {
        world.script = CLIScript(
            turns: [[.startTurn] + Beat.answer("Done.") + [.context(used: 170_000, window: 200_000), .finishTurn(.completed)]],
            compact: [.event(.compactionStarted(auto: false))] + end.map(Beat.event))
        world.install()
        return Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp"), compactMemory: memory)
    }

    private func compactions(_ chat: Chat) -> Int {
        world.backends.last?.log.count { $0 == .compact } ?? 0
    }

    /// Sends `text` and waits for its turn, and any compaction after it, to end.
    private func turn(_ chat: Chat, _ text: String) async throws {
        chat.draft = text
        chat.send()
        try await until("the turn") { chat.status.sessionId != nil && !chat.status.isRunning && !chat.context.compacting }
        // A few more passes: nothing else follows.
        for _ in 0..<20 { await Task.yield() }
        #expect(!chat.context.compacting)
    }

    /// A point is the chat's own: setting it leaves other chats, open or new, as they were.
    @Test func thePointIsOnlyThatChats() {
        let memory = AutoCompactMemory(defaults: ScratchDefaults())
        let folder = URL(fileURLWithPath: "/tmp")
        let first = Chat(provider: .claude, folder: folder, compactMemory: memory)
        let other = Chat(provider: .claude, folder: folder, compactMemory: memory)
        #expect(first.context.autoCompactAt == nil)
        first.setAutoCompact(80)
        #expect(first.context.autoCompactAt == 80)
        #expect(other.context.autoCompactAt == nil)
        #expect(Chat(provider: .claude, folder: folder, compactMemory: memory).context.autoCompactAt == nil)
        #expect(Chat(provider: .codex, folder: folder, compactMemory: memory).context.autoCompactAt == nil)
    }

    private func reopened(_ id: String, _ memory: AutoCompactMemory, _ provider: ProviderDescriptor = .claude) -> Chat {
        let session = SessionSummary(id: id, agent: provider.historyAgent, title: "Kept", updated: .now)
        return Chat(provider: provider, folder: URL(fileURLWithPath: "/tmp"), resume: session, compactMemory: memory)
    }

    /// Each chat keeps its own point, Off included, by its session id; one with none starts Off.
    /// A new chat's id comes with its first turn, and its point is kept then.
    @Test func eachChatKeepsItsPoint() async throws {
        let memory = AutoCompactMemory(defaults: ScratchDefaults())
        let codex = reopened("thread-1", memory, .codex)
        #expect(codex.context.autoCompactAt == nil)
        codex.setAutoCompact(nil)
        #expect(reopened("thread-1", memory, .codex).context.autoCompactAt == nil)
        codex.setAutoCompact(90)
        #expect(reopened("thread-1", memory, .codex).context.autoCompactAt == 90)
        // Never set in a chat: Off, whatever another chat has.
        #expect(reopened("thread-2", memory, .codex).context.autoCompactAt == nil)
        #expect(memory.point(chat: "thread-2") == nil)

        // Set before the CLI has said the session's id.
        let chat = autoCompactChat(memory, compaction: [.compacted(at: Date(), auto: false)])
        chat.setAutoCompact(90)
        #expect(chat.sessionId == nil)
        try await turn(chat, "Hi")
        let id = try #require(chat.sessionId)
        #expect(memory.point(chat: id) == .some(90))
        #expect(reopened(id, memory).context.autoCompactAt == 90)

        // A fork starts at its original's point, and keeps it under its own id.
        let fork = Chat(
            provider: .claude, folder: URL(fileURLWithPath: "/tmp"),
            resume: SessionSummary(id: id, agent: .claude, title: "Fork", updated: .now),
            fork: ForkPoint(from: id, at: "m1"), compactMemory: memory)
        #expect(fork.context.autoCompactAt == nil)
        fork.inheritAutoCompact(from: chat)
        #expect(fork.context.autoCompactAt == 90)
        try await turn(fork, "Hi again")
        let forkId = try #require(fork.sessionId)
        #expect(forkId != id)
        #expect(memory.point(chat: forkId) == .some(90))
        chat.close()
        fork.close()
    }

    @Test func aTurnPastThePointCompactsOnceAfterIt() async throws {
        let memory = AutoCompactMemory(defaults: ScratchDefaults())
        // Usage stays past the point after compacting: it isn't tried again until the next turn.
        let chat = autoCompactChat(
            memory, compaction: [.compacted(at: Date(), auto: false), .contextUsage(ContextUsage(used: 175_000, window: 200_000, autoCompacts: true, at: Date()))])
        chat.setAutoCompact(80)
        try await turn(chat, "First")
        #expect(compactions(chat) == 1)
        #expect(chat.transcript.entries.contains { $0.kind == .divider && $0.text.hasPrefix("Compacted at 80% · ") })
        try await turn(chat, "Second")
        #expect(compactions(chat) == 2)
        chat.close()
    }

    @Test func aFailedCompactionIsntRetried() async throws {
        let chat = autoCompactChat(AutoCompactMemory(defaults: ScratchDefaults()), compaction: [.compactionFailed("Busy")])
        chat.setAutoCompact(80)
        try await turn(chat, "First")
        #expect(compactions(chat) == 1)
        #expect(chat.transcript.entries.filter { $0.kind == .notice }.map(\.text) == ["Couldn't compact: Busy"])
        chat.close()
    }

    @Test func offDoesNothing() async throws {
        let chat = autoCompactChat(AutoCompactMemory(defaults: ScratchDefaults()), compaction: [.compacted(at: Date(), auto: false)])
        try await turn(chat, "First")
        #expect(compactions(chat) == 0)
        chat.close()
    }
}

/// Defaults kept in memory, so a test never touches the app's.
private final class ScratchDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}
