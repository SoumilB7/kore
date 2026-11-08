import Foundation
@testable import src
import Testing

@testable import KoreUI

/// A chat nobody sees builds no rows while it streams; what other views read of it (its agents)
/// still follows, and as it shows again its rows are built once, the same as if it had shown all
/// along.
@MainActor
@Suite("Transcript: an unseen chat builds its rows as it shows")
struct HiddenStreamTests {
    private func shown(_ store: TranscriptStore) -> [TranscriptStore.Section] {
        store.sections.map { .init(id: $0.id, header: $0.header, headerOpen: $0.headerOpen, items: $0.items) }
    }

    /// Every section built from scratch: what showing it all along would have built.
    private func fromScratch(_ store: TranscriptStore) -> [TranscriptStore.Section] {
        store.sectionsFromScratch().map { .init(id: $0.id, header: $0.header, headerOpen: $0.headerOpen, items: $0.items) }
    }

    /// Whether a scheduled draw built any rows.
    private func drawBuilds(_ store: TranscriptStore) -> Bool {
        let before = store.sections.map(ObjectIdentifier.init)
        let tail = store.tail
        store.drawChange()
        return store.sections.map(ObjectIdentifier.init) != before || store.tail != tail
    }

    @Test(arguments: Recorded.claude + Recorded.codex)
    func shownAgainItEqualsOneThatShowedAllAlong(_ name: String) throws {
        let events = try Recorded.events(name)
        let seen = TranscriptStore()
        let unseen = TranscriptStore()
        unseen.hidden = true
        var builtWhileUnseen = 0
        for event in events {
            seen.apply(event)
            unseen.apply(event)
            seen.drawChange()
            if drawBuilds(unseen) { builtWhileUnseen += 1 }
            #expect(unseen.agentSummary == seen.agentSummary, "\(name): agents follow while unseen")
        }
        #expect(builtWhileUnseen == 0, "\(name): no rows built while unseen")
        unseen.hidden = false
        #expect(shown(unseen) == fromScratch(unseen), "\(name): shown again, every row built")
        #expect(shown(unseen).count == shown(seen).count, "\(name): as many sections as one that showed")
    }

    @Test func aBoardTileOnItKeepsItsRowsFollowing() throws {
        let events = try Recorded.events(Recorded.claude[0])
        let store = TranscriptStore()
        store.hidden = true
        store.viewsOnScreen = 1
        for event in events { store.apply(event); store.drawChange() }
        #expect(!store.sections.isEmpty)
        #expect(shown(store) == fromScratch(store), "the tile's rows follow")
    }

    @Test func aCoveredWindowsChatCatchesUpWhenUncovered() throws {
        let events = try Recorded.events(Recorded.claude[0])
        let store = TranscriptStore()
        store.viewsOnScreen = 1
        store.covered = true
        store.hidden = true
        var built = 0
        for event in events { store.apply(event); if drawBuilds(store) { built += 1 } }
        #expect(built == 0, "covered, its draws build nothing")
        store.hidden = false
        store.covered = false
        #expect(!store.sections.isEmpty)
        #expect(shown(store) == fromScratch(store), "uncovered, every row built")
    }

    @Test func aChatWhoseViewWentBuildsNoRowsUntilOneShowsItAgain() throws {
        let events = try Recorded.events(Recorded.codex[0])
        let store = TranscriptStore()
        store.viewsOnScreen = 1
        store.viewsOnScreen = 0
        var built = 0
        for event in events { store.apply(event); if drawBuilds(store) { built += 1 } }
        #expect(built == 0, "no view on it, its draws build nothing")
        store.viewsOnScreen = 1
        #expect(shown(store) == fromScratch(store), "shown again, every row built")
    }

    @Test func aStoreNoViewEverShowedDrawsAsBefore() throws {
        let events = try Recorded.events(Recorded.claude[0])
        let store = TranscriptStore()
        var built = 0
        for event in events { store.apply(event); if drawBuilds(store) { built += 1 } }
        #expect(built > 0)
        #expect(shown(store) == fromScratch(store))
    }

    /// One window switches away from a chat another window (or a split, or a tile) still shows:
    /// marked hidden by the first, it still draws for the second.
    @Test func hiddenByOneWindowItStillDrawsForTheOneShowingIt() throws {
        let events = try Recorded.events(Recorded.codex[0])
        let store = TranscriptStore()
        store.viewsOnScreen = 1
        store.hidden = true
        var built = 0
        for event in events { store.apply(event); if drawBuilds(store) { built += 1 } }
        #expect(built > 0, "a view still on it, its draws build")
        #expect(shown(store) == fromScratch(store))
    }
}
