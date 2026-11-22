import AppKit
import KoreUI

/// An answer whose second section numbers on from its first ("**B. The rule checker**" then
/// "5.", "6."): both sections draw as numbered lists, the second from 5 (the owner's case,
/// chat 90abea89).
final class ListNumberedOn: ChatStoryline {
    static let reply = """
        Two parts to it.

        **A. The tools**
        1. **A gate.** One check before a version lands.
        2. **A map.** One picture of what reads what.
        3. **A ledger.** What landed, and when.
        4. **A bench.** Navigation numbers against main.

        **B. The rule checker**
        5. **A 1-second rule checker.** Reads the rules and says which one a change breaks.
        6. **Rules as tools.** Each written rule becomes a check that runs.

        We shipped the first version in
        2026. That line stays a sentence.
        """
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Plan the factory"),
            TurnFinished(1),
            ExpectElement(.answer(turn: 1)),
            WaitIdle(),
            Snapshot("list-numbered-on"),
        ]
    }
}
