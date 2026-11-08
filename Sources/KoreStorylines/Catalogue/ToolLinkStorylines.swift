import AppKit
import Foundation
import KoreUI
import src

/// A tool header's file name opens the file on a click, and only the name does: it's drawn as
/// text, not as a SwiftUI link (a link is a text responder of its own, and one changing under
/// the transparent titlebar can send AppKit round its window-regions pass until it throws), and
/// where the name is comes from the text's own layout.
final class ToolFileNameOpens: ChatStoryline {
    static let file = "notes.md"
    override class var tags: Set<Tag> { [.chat, .files, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            // No answer after it: the turn's work isn't folded under one, so the edit's row shows.
            .startTurn, .fileEdit(path: file, content: "# Notes\n\nWritten by the script.\n"), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        let name = Locator.id(StoryID.Transcript.fileName(Self.file))
        return super.steps() + [
            Send("Write the notes"), TurnFinished(1), WaitIdle(),
            Expect.fileTabs("no file tab yet") { $0.isEmpty },
            WaitForElement(name),
            NameOnly(name: name),
            // Its action, as a click on the name runs it (a storyline window isn't key, and SwiftUI
            // takes no first click there; the area above is what a pointer reaches).
            Press(name),
            Expect.fileTabs("the file in a preview tab") { $0.contains { $0.path == Self.file && $0.active } },
        ]
    }

    /// The click area is the name's: after the header's verb, and a fraction of the row's width.
    struct NameOnly: Step {
        let name: Locator
        var label: String { "The file name's click area covers the name only" }
        func run(_ story: StoryContext) async throws {
            let area = try await story.element(name)
            let row = try await story.element(.tool("Edit"))
            guard let a = area.frame, let r = row.frame else { throw StoryFailure.modelMissing("the frames") }
            guard a.minX > r.minX + 20, a.width < r.width / 2 else {
                throw StoryFailure.modelMissing("a name-sized click area (area \(a), row \(r))")
            }
        }
    }
}
