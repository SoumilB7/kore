import Foundation
import KoreUI

/// The update cue on the new-tab picker: nothing while Kore is the latest; a newer release shows
/// its version, a click builds it, and a build that stops short says so and can go again.
final class UpdateCueOnNewTab: Storyline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override func steps() -> [any Step] {
        let cue = StoryID.NewTab.update
        return [
            UseScript(CLIScript()),
            Do("Kore is the latest") { _ in Updater.shared.storySet(.current) },
            OpenFolder(),
            WaitForElement(.id(StoryID.NewTab.provider("claude"))),
            ExpectElement(.id(cue), .absent),
            Do("A newer release is out, its build held") { _ in
                Updater.shared.storyInstaller = {
                    try? await Task.sleep(for: .seconds(1))
                    return "Not enough disk space"
                }
                Updater.shared.storySet(.available("99.0.0"))
            },
            WaitForElement(.id(cue)),
            Snapshot("update-available"),
            Press(.id(cue)),
            WaitForElement(.id(cue.part(.working))),
            Snapshot("update-building"),
            WaitForElement(.id(cue.part(.retry)), timeout: .seconds(5)),
            Expect("the build's reason is kept") { _ in
                Updater.shared.state == .failed("99.0.0", "Not enough disk space")
            },
            Snapshot("update-failed"),
            Press(.id(cue.part(.retry))),
            WaitForElement(.id(cue.part(.working))),
            Do("Back to the latest") { _ in
                Updater.shared.storyInstaller = nil
                Updater.shared.storySet(.current)
            },
            ExpectElement(.id(cue.part(.working)), .absent, timeout: .seconds(3)),
        ]
    }
}
