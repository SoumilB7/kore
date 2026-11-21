import Foundation
import Testing

@testable import KoreHost
@testable import src

/// A turn can end before the chat holds a single entry: a box chat's first message is still
/// held (queued, not yet settled) when the CLI starts the turn and refuses it.
@MainActor
struct TurnFinishedEmptyTests {
    @Test(arguments: [TurnOutcome.completed, .interrupted, .failed("no"), .authFailed("Not logged in")])
    func aTurnThatEndsOnAnEmptyChatEndsQuietly(_ outcome: TurnOutcome) {
        let transcript = HostTranscript()
        transcript.apply(.turnStarted("t1", origin: .user, at: Date()))
        transcript.apply(.turnFinished("t1", outcome, duration: nil))
        #expect(transcript.entries.isEmpty)
        #expect(transcript.log.turns["t1"]?.finished == true)
        #expect(transcript.log.current == nil)
    }
}
