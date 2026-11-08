import AppKit
import KoreUI

/// The message rail stays where it is as the composer grows and shrinks: a file attached and
/// taken off, then a draft of many lines and cleared.
final class RailStaysAsComposerGrows: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { CLIScript(turns: (1...4).map { CLIScript.reply("Answer \($0)") }) }

    override func steps() -> [any Step] {
        let rail = { (story: StoryContext) -> CGFloat? in
            _ = story
            return StoryElement(StoryID.Transcript.rail)?.frame?.midY
        }
        let place = Remembered<CGFloat>()
        func grown(_ yes: Bool) -> any Step {
            Expect(yes ? "the composer grown" : "the composer back to its smallest", found: { story in "growth \((try? story.activeChat().storyComposerGrowth) ?? -1)" }) { story in
                let growth = try story.activeChat().storyComposerGrowth
                return yes ? growth > 0 : growth == 0
            }
        }
        func still(_ what: String) -> any Step {
            Expect("the rail where it was, \(what)", found: { story in "\(rail(story).map { "\($0)" } ?? "none") against \(place.value.map { "\($0)" } ?? "none")" }) { story in
                guard let now = rail(story), let was = place.value else { return false }
                return abs(now - was) <= 1
            }
        }
        return super.steps() + (1...4).flatMap { n -> [any Step] in [Send("message \(n)"), TurnFinished(n)] } + [
            WaitIdle(),
            WaitForElement(.id(StoryID.Transcript.rail)),
            Do("note where the rail is") { story in place.value = rail(story) },
            Do("attach a file") { story in
                let file = story.folder.appendingPathComponent("notes.txt")
                try "Notes".write(to: file, atomically: true, encoding: .utf8)
                try story.activeChat().storyAttach([file])
            },
            grown(true), WaitIdle(), still("with a file attached"),
            Do("take the file off") { story in try story.activeChat().storyDetachAll() },
            grown(false), WaitIdle(), still("with it taken off"),
            Do("type a draft of eight lines") { story in try story.activeChat().storyType((1...8).map { "line \($0)" }.joined(separator: "\n")) },
            grown(true), WaitIdle(), still("with the draft's lines"),
            Do("clear the draft") { story in try story.activeChat().storyType("") },
            grown(false), WaitIdle(), still("with the draft cleared"),
        ]
    }
}

/// A value a storyline's steps keep between them.
final class Remembered<Value>: @unchecked Sendable {
    var value: Value?
}
