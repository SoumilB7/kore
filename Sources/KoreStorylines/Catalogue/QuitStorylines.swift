import AppKit
import KoreUI

/// ⌘Q takes two: the first press only says so, and the word goes away by itself; a second soon
/// after, a key's repeat as much as a press, quits. Quit from the menu with the pointer is meant.
final class QuitTakesTwo: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.only] }

    private final class Quits {
        var count = 0
    }

    override func steps() -> [any Step] {
        let quits = Quits()
        let notice = Locator.id(StoryID.Titlebar.quitNotice)
        return super.steps() + [
            Do("Quitting only counted") { _ in QuitGuard.shared.terminate = { quits.count += 1 } },
            Do("⌘Q") { _ in QuitGuard.shared.press(byKey: true, hasWindow: true) },
            WaitForElement(notice),
            Expect("not quit") { _ in quits.count == 0 },
            Snapshot("quit-notice"),
            ExpectElement(notice, .absent, timeout: .seconds(4)),
            Do("⌘Q, long after") { _ in QuitGuard.shared.press(byKey: true, hasWindow: true) },
            Expect("still not quit") { _ in quits.count == 0 },
            Do("⌘Q again") { _ in QuitGuard.shared.press(byKey: true, hasWindow: true) },
            Expect("quit") { _ in quits.count == 1 },
            ExpectElement(notice, .absent),
            Do("Quit picked with the pointer") { _ in QuitGuard.shared.press(byKey: false, hasWindow: true) },
            Expect("quit at once") { _ in quits.count == 2 },
            Do("Back as it was") { _ in QuitGuard.shared.terminate = { NSApp.terminate(nil) } },
        ]
    }
}
