import AppKit
import KoreUI

// Kore's own questions and tips where macOS's alerts and tooltips were (`KoreAsk`, `KoreTip`):
// each opens in the window, Esc and Return answer it, and the answer does what it says.

@MainActor private var card: Locator { .id(StoryID.Ask.card) }

/// The question up now is `key`, its answers these words.
@MainActor private func asking(_ key: String, _ choices: [String]? = nil) -> [any Step] {
    [
        WaitForElement(card),
        Expect("the question is “\(key)”") { _ in KoreAsk.storyOpen == key },
    ] + (choices.map { words in [Expect("its answers are \(words.joined(separator: " · "))") { _ in KoreAsk.storyChoices == words }] } ?? [])
}

@MainActor private var answered: [any Step] { [ExpectElement(card, .absent), Expect("no question up") { _ in KoreAsk.storyOpen == nil }] }

/// Lets time pass (a tip's rest), with nothing to wait for.
private struct Rest: Step {
    let milliseconds: Int
    var label: String { "Wait \(milliseconds) ms" }
    func run(_ story: StoryContext) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}

/// Picks the open option popup's item titled `title`.
private struct PickOption: Step {
    let title: String
    var label: String { "Pick “\(title)”" }
    init(_ title: String) { self.title = title }

    func run(_ story: StoryContext) async throws {
        try await WaitForElement(.id(StoryID.Options.panel)).run(story)
        guard let index = StoryMenus.open.firstIndex(of: title) else {
            throw StoryFailure.expectation("“\(title)” in the menu (it has \(StoryMenus.open.filter { !$0.isEmpty }))")
        }
        try await Press(.id(StoryID.Options.item(index))).run(story)
    }
}

/// The chat tab's Rename…: Kore's question with the name in its field. Return renames, Esc and
/// Cancel leave the name.
final class AskRenameChat: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    private static func title(_ story: StoryContext) -> String? { story.app.workspace?.tabs.first?.title }

    override func steps() -> [any Step] {
        super.steps() + [
            RightClick(.tab(1)), PickOption("Rename…"),
        ] + asking("rename-chat", ["Cancel", "Rename"]) + [
            Expect("the field holds the tab's name") { story in KoreAsk.shared.text == Self.title(story) },
            Rest(milliseconds: 400), Snapshot("ask-rename"),
            Key(.cmd("a")), TypeText("Renamed chat"), Key(.returnKey),
        ] + answered + [
            Expect("Return renamed the chat") { story in Self.title(story) == "Renamed chat" },
            RightClick(.tab(1)), PickOption("Rename…"),
        ] + asking("rename-chat") + [
            TypeText(" not this"), Key(.escape),
        ] + answered + [
            Expect("Esc kept the name") { story in Self.title(story) == "Renamed chat" },
            RightClick(.tab(1)), PickOption("Rename…"),
        ] + asking("rename-chat") + [
            Press(.id(StoryID.Ask.choice("Cancel"))),
        ] + answered + [
            Expect("Cancel kept the name") { story in Self.title(story) == "Renamed chat" },
        ]
    }
}

/// A file tab with unsaved edits closing: Save, Don't Save or Cancel, in Kore's card. Esc keeps
/// the tab and its edits; Don't Save closes it and leaves the disk; Return saves and closes.
final class AskUnsavedTab: FilesStoryline {
    override class var tags: Set<Tag> { [.editor, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }
    static let path = "notes.txt"
    override class var files: [(path: String, text: String)] { [(path, "one\n")] }

    private final class Saved { var autoSave = false }

    private static func fileOpen(_ story: StoryContext) -> Bool { story.app.workspace?.storyFilePaths.contains { $0.hasSuffix("/" + path) } == true }

    override func steps() -> [any Step] {
        [Do("Auto Save off, as a person may have it") { story in
            story.stash(Saved.self) { Saved() }.autoSave = FileAutoSave.shared.isEnabled
            FileAutoSave.shared.isEnabled = false
        }] + super.steps() + [
            // A chat tab beside it: closing the file's tab isn't closing the window.
            Command(.newTab), Command(.toggleExplorer),
            Press(.treeRow(Self.path)), Click(.editor), WaitForFocus(.editor), Key(KeyChord(.up, .command)),
            TypeText("edit "),
            Expect("the file has unsaved edits") { $0.app.workspace?.storyActiveFileDirty == true },
            Command(.closeTab),
        ] + asking("save-tab", ["Don't Save", "Cancel", "Save"]) + [
            Rest(milliseconds: 400), Snapshot("ask-save-tab"),
            Key(.escape),
        ] + answered + [
            Expect("Esc kept the tab and its edits") { story in Self.fileOpen(story) && story.app.workspace?.storyActiveFileDirty == true },
            Command(.closeTab),
        ] + asking("save-tab") + [
            Press(.id(StoryID.Ask.choice("Don't Save"))),
        ] + answered + [
            Expect("Don't Save closed the tab") { story in !Self.fileOpen(story) },
            Expect.disk(Self.path, "one\n"),
            Press(.treeRow(Self.path)), Click(.editor), WaitForFocus(.editor), Key(KeyChord(.up, .command)),
            TypeText("kept "),
            Command(.closeTab),
        ] + asking("save-tab") + [
            Key(.returnKey),
        ] + answered + [
            Expect("Save wrote the edit to disk") { story in
                let text = story.app.workspace.flatMap { try? String(contentsOf: $0.folder.appendingPathComponent(Self.path), encoding: .utf8) }
                return text?.contains("kept ") == true && text?.contains("one") == true
            },
            Expect("Save closed the tab") { story in !Self.fileOpen(story) },
            Do("Auto Save as it was") { story in FileAutoSave.shared.isEnabled = story.stash(Saved.self) { Saved() }.autoSave },
        ]
    }
}

/// A window with unsaved edits closing asks first, in its own card; Esc keeps the window.
final class AskUnsavedWindow: EditorStoryline {
    override class var tags: Set<Tag> { [.editor, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }
    override class var files: [(path: String, text: String)] { [("draft.txt", "first\n")] }

    private final class Saved { var autoSave = false }

    override func steps() -> [any Step] {
        [Do("Auto Save off") { story in
            story.stash(Saved.self) { Saved() }.autoSave = FileAutoSave.shared.isEnabled
            FileAutoSave.shared.isEnabled = false
        }] + super.steps() + [
            TypeText("more "),
            Do("Press the window's close button") { story in story.app.workspace?.storyPressClose() },
        ] + asking("save-files", ["Don't Save", "Cancel", "Save"]) + [
            Rest(milliseconds: 400), Snapshot("ask-save-window"),
            Key(.escape),
        ] + answered + [
            Expect("the window stays, its edits kept") { story in
                story.window?.isVisible == true && story.app.workspace?.storyActiveFileDirty == true
            },
            Expect.disk("draft.txt", "first\n"),
            Do("Auto Save as it was") { story in FileAutoSave.shared.isEnabled = story.stash(Saved.self) { Saved() }.autoSave },
        ]
    }
}

/// Move to Trash asks once, in Kore's card: Esc leaves the file, Return trashes it.
final class AskTrashFile: FilesStoryline {
    override class var tags: Set<Tag> { [.editor, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }
    override class var files: [(path: String, text: String)] { [("gone.txt", "x\n"), ("stay.txt", "y\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.toggleExplorer),
            TreeMenuItem("stay.txt", "Move to Trash"),
        ] + asking("trash", ["Move to Trash", "Cancel"]) + [
            Rest(milliseconds: 400), Snapshot("ask-trash"),
            Key(.escape),
        ] + answered + [
            Expect("Esc left stay.txt") { $0.app.workspace?.storyHasFile("stay.txt") == true },
            TreeMenuItem("gone.txt", "Move to Trash"),
        ] + asking("trash") + [
            Key(.returnKey),
        ] + answered + [
            Expect("Return trashed gone.txt, stay.txt left") { story in
                story.app.workspace.map { !$0.storyHasFile("gone.txt") && $0.storyHasFile("stay.txt") } ?? false
            },
        ]
    }
}

/// A drop of several asks first; a name already there asks Replace, Keep Both or Cancel with
/// "Apply to all". Esc moves nothing; Return moves; Keep Both keeps both.
final class AskMoveAndCollision: FilesStoryline {
    override class var tags: Set<Tag> { [.editor, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }
    override class var files: [(path: String, text: String)] { [("a.txt", "a\n"), ("b.txt", "b\n"), ("dest/a.txt", "old\n")] }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.toggleExplorer),
            Do("Drop a.txt and b.txt on dest") { story in story.app.workspace?.storyDrop(["a.txt", "b.txt"], into: "dest", copy: false) },
        ] + asking("move", ["Move", "Cancel"]) + [
            Key(.escape),
        ] + answered + [
            Expect("Esc moved nothing") { story in
                story.app.workspace.map { $0.storyHasFile("a.txt") && $0.storyHasFile("b.txt") && !$0.storyHasFile("dest/b.txt") } ?? false
            },
            Do("Drop them again") { story in story.app.workspace?.storyDrop(["a.txt", "b.txt"], into: "dest", copy: false) },
        ] + asking("move") + [
            Key(.returnKey),
        ] + asking("collision", ["Cancel", "Keep Both", "Replace"]) + [
            ExpectElement(.id(StoryID.Ask.tick), .visible),
            Rest(milliseconds: 400), Snapshot("ask-collision"),
            Press(.id(StoryID.Ask.choice("Keep Both"))),
        ] + answered + [
            Expect("both moved, the one there kept beside the new one") { story in
                guard let workspace = story.app.workspace, workspace.storyHasFile("dest/b.txt") else { return false }
                let dest = workspace.folder.appendingPathComponent("dest").path
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dest)) ?? []
                return !workspace.storyHasFile("a.txt") && !workspace.storyHasFile("b.txt") && names.count == 3
                    && (try? String(contentsOfFile: dest + "/a.txt", encoding: .utf8)) == "old\n"
            },
        ]
    }
}

/// Quitting with work running asks in Kore's card (asked here without quitting): Esc and
/// Cancel say no, Quit says yes.
final class AskQuitWhileWorking: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.only] }

    private final class Answer { var value: Bool? }

    private func ask(_ story: StoryContext) {
        let answer = story.stash(Answer.self) { Answer() }
        answer.value = nil
        Task { @MainActor in answer.value = await QuitQuestion.ask(working: 2, terminals: 0, transfers: 1) }
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Quit, with 2 chats working and 1 transfer") { story in self.ask(story) },
        ] + asking("quit", ["Cancel", "Quit"]) + [
            Expect("it says what stops") { _ in KoreAsk.storyTitle == "2 chats are working" },
            Rest(milliseconds: 400), Snapshot("ask-quit"),
            Key(.escape),
        ] + answered + [
            Expect("Esc: no quit") { story in story.stash(Answer.self) { Answer() }.value == false },
            Do("Quit again") { story in self.ask(story) },
        ] + asking("quit") + [
            Key(.returnKey),
        ] + answered + [
            Expect("Return is Cancel, the safe answer") { story in story.stash(Answer.self) { Answer() }.value == false },
            Do("Quit a third time") { story in self.ask(story) },
        ] + asking("quit") + [
            Press(.id(StoryID.Ask.choice("Quit"))),
        ] + answered + [
            Expect("Quit: yes") { story in story.stash(Answer.self) { Answer() }.value == true },
        ]
    }
}

/// Closing a terminal running a command asks in Kore's card: Esc keeps it, Stop and Close
/// says yes; Tab moves the ring and Return picks what it's on.
final class AskTerminalClose: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.only] }

    private final class Answer { var value: Bool? }

    private func ask(_ story: StoryContext) {
        let answer = story.stash(Answer.self) { Answer() }
        answer.value = nil
        Task { @MainActor in answer.value = await story.app.workspace?.storyAskTerminalClose(working: 1) }
    }

    private func answer(_ story: StoryContext) -> Bool? { story.stash(Answer.self) { Answer() }.value }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Close a terminal with a command running") { story in self.ask(story) },
        ] + asking("close-terminals", ["Cancel", "Stop and Close"]) + [
            Rest(milliseconds: 400), Snapshot("ask-terminal"),
            Key(.escape),
        ] + answered + [
            Expect("Esc keeps it") { story in self.answer(story) == false },
            Do("Close it again") { story in self.ask(story) },
        ] + asking("close-terminals") + [
            Key(.tab), Key(.returnKey),
        ] + answered + [
            Expect("Tab then Return: Stop and Close") { story in self.answer(story) == true },
        ]
    }
}

/// Kore's hover tip: it shows after the pointer rests, one at a time, and goes at a key or the
/// pointer leaving. Nothing shows while a question is up.
final class KoreTipShows: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.only] }

    private let tip = Locator.id(StoryID.Tip.shown)

    override func steps() -> [any Step] {
        super.steps() + [
            Do("A short rest before tips") { _ in KoreTip.delay = .milliseconds(50) },
            Do("The pointer rests on a view") { _ in KoreTip.shared.enter("Close tab", owner: 9_001) },
            WaitForElement(tip),
            Expect("it says the view's words") { _ in KoreTip.storyShown == "Close tab" },
            Snapshot("kore-tip"),
            Key(.escape),
            ExpectElement(tip, .absent),
            Do("Rests on another, then leaves") { _ in KoreTip.shared.enter("New tab", owner: 9_002) },
            WaitForElement(tip),
            Do("The pointer leaves") { _ in KoreTip.shared.leave(owner: 9_002) },
            ExpectElement(tip, .absent),
            Do("A question goes up") { story in Task { @MainActor in _ = await story.app.workspace?.storyAskTerminalClose(working: 1) } },
            WaitForElement(card),
            Do("The pointer rests on a view under it") { _ in KoreTip.shared.enter("Hidden", owner: 9_003) },
            Rest(milliseconds: 300),
            Expect("no tip over the question") { _ in KoreTip.storyShown == nil },
            Key(.escape),
            ExpectElement(card, .absent),
            Do("Tips as they were") { _ in
                KoreTip.shared.leave(owner: 9_003)
                KoreTip.delay = .milliseconds(700)
            },
        ]
    }
}
