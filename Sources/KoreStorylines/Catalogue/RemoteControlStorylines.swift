import Foundation
import KoreCore
import KoreUI

/// The CLIs' own remote control (phase 13, part A): "/" → Remote control turns it on for the
/// chat, and the bar's mark says so, its line naming the CLI and where the chat is picked up. A
/// message typed on the remote side opens a turn that shows it as its prompt, the answer under
/// it, as any turn shows. A click on the mark turns it off, and the entry offers it again.
final class RemoteControlOnOff: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    static let typed = "Add the same check to the iOS client"
    static let answer = "Done: the app now reads X-Min-Version."

    override class var script: CLIScript {
        var script = CLIScript()
        script.remote = [.remotePrompt(typed)] + Beat.answer(answer) + [.finishTurn(.completed)]
        return script
    }

    override func steps() -> [any Step] {
        let claude = variant == .claude
        let entry = Locator.id(StoryID.Composer.command("remote-control"))
        let mark = Locator.id(StoryID.Composer.remote)
        let line = claude ? "Remote control · claude CLI · claude.ai/code" : "Remote control · codex CLI · acme-mac"
        return super.steps() + [
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)),
            WaitForElement(entry),
            Expect("no mark while it's off") { try $0.activeChat().storyRemote == nil },
            Press(entry),
            WaitForElement(mark),
            Expect("the mark's line “\(line)”", found: { $0.app.chat?.storyRemote }) { try $0.activeChat().storyRemote == line },
            Expect("the CLI asked to turn it on") { try $0.scriptedBackend().log.contains(.setRemoteControl(true)) },
            TurnFinished(1),
            Expect.rows("the remote message as the turn's prompt, the answer under it") { rows in
                guard let prompt = rows.firstIndex(where: { $0.kind == "user" && $0.text == Self.typed }) else { return false }
                return rows[(prompt + 1)...].contains { $0.kind == "assistant" && $0.text == Self.answer }
            },
            // Only looks, as a person would: no scroll, no unfold.
            Expect("the answer drawn in the window", timeout: .seconds(10)) { story in
                guard let window = story.window, let transcript = story.app.chat?.storyTranscript,
                    let answer = transcript.entries.last(where: { $0.kind == .answer }),
                    let frame = StoryElement(StoryID.Transcript.answer(answer.id), in: window)?.frame
                else { return false }
                return window.contentView.map { $0.bounds.contains(frame) } ?? false
            },
            Snapshot("remote-on"),
            Press(mark),
            ExpectElement(mark, .absent),
            Expect("the CLI asked to turn it off") { try $0.scriptedBackend().log.contains(.setRemoteControl(false)) },
        ]
    }
}
