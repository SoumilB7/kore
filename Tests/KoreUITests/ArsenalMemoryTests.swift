import Foundation
import KoreCore
import Testing
import src
@testable import KoreUI

@MainActor
@Suite("Arsenal tiers kept across restarts", .serialized)
struct ArsenalMemoryTests {
    init() {
        ArsenalMemory.defaults = UserDefaults(suiteName: "arsenal-memory-tests")!
        ArsenalMemory.clear()
    }

    @Test func keptByCLIAndSessionUntilOff() {
        ArsenalMemory.keep(.drive, under: "claude:s1")
        ArsenalMemory.keep(.watch, under: "codex:s1")
        #expect(ArsenalMemory.tier(key: "claude:s1") == .drive)
        #expect(ArsenalMemory.tier(key: "codex:s1") == .watch)
        ArsenalMemory.keep(.own, under: "claude:s1")
        #expect(ArsenalMemory.tier(key: "claude:s1") == .own)
        ArsenalMemory.keep(nil, under: "claude:s1")
        #expect(ArsenalMemory.tier(key: "claude:s1") == nil)
        #expect(ArsenalMemory.tier(key: "codex:s1") == .watch)
    }

    @Test func aRenamedSessionLetsTheOldKeyGo() {
        let kept = ArsenalMemory.keep(.drive, under: "claude:old")
        ArsenalMemory.keep(.drive, under: "claude:new", replacing: kept)
        #expect(ArsenalMemory.tier(key: "claude:old") == nil)
        #expect(ArsenalMemory.tier(key: "claude:new") == .drive)
    }

    @Test func survivesANewProcessReadingTheSameDefaults() {
        ArsenalMemory.keep(.own, under: "claude:s2")
        // What a restarted Kore reads: the same domain, read afresh.
        let reread = UserDefaults(suiteName: "arsenal-memory-tests")!
        #expect((reread.array(forKey: ArsenalMemory.defaultsKey) as? [[String]])?.contains(["claude:s2", "own"]) == true)
    }

    @Test func stopAgentControlForgetsEveryChat() {
        ArsenalMemory.keep(.drive, under: "claude:a")
        ArsenalMemory.keep(.watch, under: "codex:b")
        ArsenalMemory.clear()
        #expect(ArsenalMemory.tier(key: "claude:a") == nil && ArsenalMemory.tier(key: "codex:b") == nil)
    }

    @Test func theOldestGiveWayPastTheLimit() {
        for n in 0...ArsenalMemory.limit { ArsenalMemory.keep(.watch, under: "claude:\(n)") }
        #expect(ArsenalMemory.tier(key: "claude:0") == nil)
        #expect(ArsenalMemory.tier(key: "claude:\(ArsenalMemory.limit)") == .watch)
    }

    /// The note is a text block of its own before the user's, and where blocks are read as one text
    /// it ends its own line: it can't run into what the user typed.
    @Test func claudesNoteEndsItsOwnLine() {
        let note = KoreReach.note(tier: "Act unlimited", chat: "1a2b3c4d")
        let blocks = [ClaudeBackend.noteBlock(note), .object(["type": "text", "text": .string("how long will it take?")])]
        let joined = blocks.compactMap { $0["text"]?.string }.joined()
        #expect(joined == note + "\n\nhow long will it take?")
        #expect(KoreReach.isNote(blocks[0]["text"]?.string ?? ""))
    }
}
