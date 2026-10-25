import AppKit
import KoreUI

/// A typed edit saves after the tab hides; an external edit wins over pending local text,
/// and a permissions failure stays in the file's notice instead of opening a modal alert.
final class AutoSaveEdits: EditorStoryline {
    override class var tags: Set<Tag> { [.editor, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }
    static let path = "autosave.txt"
    override class var files: [(path: String, text: String)] { [(path, "original\n")] }

    override func steps() -> [any Step] {
        [Do("Enable Auto Save for this scenario") { story in
            _ = story.stash(SavedAutoSave.self) { SavedAutoSave() }
            FileAutoSave.shared.isEnabled = true
        }] + super.steps() + [
            TypeText("saved "),
            Expect.editor("the edit is initially dirty") { $0.isDirty && $0.text == "saved original\n" },
            Command(.newTab),
            Expect.disk(Self.path, "saved original\n"),
            Key(.cmd("1")), Click(.editor),
            WaitForFocus(.editor),
            Expect.editor("the hidden file's automatic save cleared its dirty mark") { !$0.isDirty },
            Key(KeyChord(.up, .command)),
            TypeText("mine "),
            WriteFiles([(Self.path, "external\n")]),
            ExpectElement(.id(StoryID.Editor.Notice.reload), .visible),
            Expect.editor("external edits leave local edits dirty") { $0.isDirty && $0.text == "mine saved original\n" },
            Expect.disk(Self.path, "external\n"),
            Press(.id(StoryID.Editor.Notice.reload)),
            Expect.editor("reload takes the disk version") { !$0.isDirty && $0.text == "external\n" },
            Do("Make the file read only") { story in
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: story.folder.appendingPathComponent(Self.path).path)
            },
            Key(KeyChord(.up, .command)),
            TypeText("unsaved "),
            ExpectElement(.id(StoryID.Editor.Notice.retry), .visible),
            Expect("automatic failures open no modal window") { _ in NSApp.modalWindow == nil },
            Expect.disk(Self.path, "external\n"),
            Do("Restore write permission") { story in
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: story.folder.appendingPathComponent(Self.path).path)
            },
            TypeText("again "),
            Expect.disk(Self.path, "unsaved again external\n"),
            Expect.editor("the next edit retries and saves") { !$0.isDirty },
            ExpectElement(.id(StoryID.Editor.Notice.retry), .absent),
        ]
    }
}

@MainActor private final class SavedAutoSave: StoryFinishing {
    private let original = FileAutoSave.shared.isEnabled
    func finish() { FileAutoSave.shared.isEnabled = original }
}
