import AppKit
import KoreUI

// Steps for files: the folder's fixture, focus, and checks on the editor, the file tabs, Search
// and the disk. Opening, typing and pressing go through the generic input steps (Input/).

/// Writes files into the storyline's scratch folder, before the folder opens: its fixture.
package struct WriteFiles: Step {
    let files: [(path: String, text: String)]
    package var label: String { "Write \(files.map(\.path).joined(separator: ", "))" }
    package init(_ files: [(path: String, text: String)]) { self.files = files }

    package func run(_ story: StoryContext) async throws {
        for file in files {
            let url = story.folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Waits until the element has the window's keyboard focus: the view itself (the editor's
/// text), or a text view over it (a text field's field editor, the composer's own text). Typing goes to the focus,
/// so a storyline waits for it before typing into a field that has just appeared.
package struct WaitForFocus: Step {
    let target: Locator
    package var label: String { "Wait for focus in \(target)" }
    package init(_ target: Locator) { self.target = target }

    package func run(_ story: StoryContext) async throws {
        let element = try await story.element(target)
        do {
            try await story.until("\(target) to have focus") {
                guard let responder = element.window?.firstResponder as? NSView, responder.window != nil, let frame = element.frame
                else { return false }
                if let view = element.registeredView, responder.isDescendant(of: view) { return true }
                // A text field's typing goes to the window's field editor, placed over the field; a
                // SwiftUI element's AppKit text sits beside its registrar, not in it.
                guard responder is NSTextView else { return false }
                let inside = responder.convert(responder.visibleRect, to: nil)
                return frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: inside.midX, y: inside.midY))
            }
        } catch StoryFailure.timedOut {
            let focus = element.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
            throw StoryFailure.expectation("\(target) to have focus (\(focus) has it)")
        }
    }
}

extension Expect {
    /// A check on the active file's editor: its text, folds and find bar.
    package static func editor(_ what: String, _ check: @escaping @MainActor (StoryEditor) -> Bool) -> Expect {
        Expect(what, found: { story in story.app.workspace?.storyEditor.map { "\($0)" } ?? "no text file in the active tab" }) { story in
            story.app.workspace?.storyEditor.map(check) ?? false
        }
    }

    /// A check on the window's file tabs.
    package static func fileTabs(_ what: String, _ check: @escaping @MainActor ([StoryFileTab]) -> Bool) -> Expect {
        Expect(what, found: { story in story.app.workspace.map { "\($0.storyFileTabs)" } }) { story in
            story.app.workspace.map { check($0.storyFileTabs) } ?? false
        }
    }

    /// A check on Search's results, once they're all in.
    package static func search(_ what: String, _ check: @escaping @MainActor (StorySearch) -> Bool) -> Expect {
        Expect(what, found: { story in story.app.workspace?.storySearch.map { "\($0)" } ?? "Search never shown" }) { story in
            guard let search = story.app.workspace?.storySearch, search.finished else { return false }
            return check(search)
        }
    }

    /// A file in the storyline's folder reads `text` on disk.
    package static func disk(_ path: String, _ text: String) -> Expect {
        let read = { @MainActor (story: StoryContext) in
            try? String(contentsOf: story.folder.appendingPathComponent(path), encoding: .utf8)
        }
        return Expect("\(path) on disk to hold the saved text", found: { read($0).map { "“\($0)”" } ?? "no file" }) { read($0) == text }
    }
}
