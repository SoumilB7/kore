import AppKit
import KoreUI

/// ⌘A in the composer takes the whole draft, the chips with the text; ⌘C copies all of it,
/// Backspace clears all of it (⌘Z brings it back), and ⌘V in a new chat's composer puts it
/// back as it was: the text, then the image and the file in their order. The files come in
/// as a Finder copy does (⌘V with their URLs). Keys go in-process, on the storylines' board.
final class ComposerCopyWholeDraft: ChatStoryline {
    static let text = "what changed here"
    static let names = ["shot.png", "notes.md"]
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Copy an image and a file, as Finder does") { story in
                let image = story.folder.appendingPathComponent(Self.names[0])
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                try rep?.representation(using: .png, properties: [:])?.write(to: image)
                let file = story.folder.appendingPathComponent(Self.names[1])
                try Data("# notes\n".utf8).write(to: file)
                let board = Self.board
                board.clearContents()
                board.writeObjects([image as NSURL, file as NSURL])
            },
            WaitForFocus(.id(StoryID.Composer.field)),
            Key(.cmd("v")),
            Expect("both attached, in their order") { story in try Self.names(story) == Self.names },
            TypeText(Self.text),
            Key(.cmd("a")),
            Expect("⌘A takes the whole draft, the chips with the text") { _ in
                guard let view = Self.focusedView() else { return false }
                return view.wholeDraft && view.selectedRange() == NSRange(location: 0, length: (view.string as NSString).length)
            },
            Snapshot("composer-whole-draft"),
            Key(.cmd("c")),
            Expect("the whole draft on the clipboard, with the text and the files for other apps") { _ in
                let board = Self.board
                let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                return board.types?.contains(.init("dev.kore.composer-draft")) == true
                    && board.string(forType: .string) == Self.text && urls?.map(\.lastPathComponent) == Self.names
            },
            Key(KeyChord(.backspace)),
            Expect("Backspace clears the text and the chips") { story in
                let chat = try story.activeChat()
                return chat.draft.isEmpty && chat.attachments.isEmpty
            },
            Key(.cmd("z")),
            Expect("⌘Z brings all of it back") { story in
                try story.activeChat().draft == Self.text && Self.names(story) == Self.names
            },
            Key(.cmd("a")), Key(KeyChord(.backspace)),
            Expect("cleared again") { story in try story.activeChat().attachments.isEmpty },
            Command(.newTab), StartChat(),
            Click(.id(StoryID.Composer.field)),
            Expect("the new chat's composer has the keys") { story in
                try story.activeChat().draft.isEmpty && Self.focusedView() != nil
            },
            Key(.cmd("v")),
            Expect("⌘V in the new chat puts back the text and both files, in their order") { story in
                try story.activeChat().draft == Self.text && Self.names(story) == Self.names
            },
            Snapshot("composer-pasted-draft"),
            Key(.cmd("z")),
            Expect("⌘Z takes the paste out again") { story in
                let chat = try story.activeChat()
                return chat.draft.isEmpty && chat.attachments.isEmpty
            },
        ]
    }

    static var board: NSPasteboard { NSPasteboard(name: .init("kore-storylines")) }

    @MainActor static func names(_ story: StoryContext) throws -> [String] {
        try story.activeChat().attachments.map(\.name)
    }

    /// The composer text view with the keys (a hidden tab keeps its own).
    @MainActor static func focusedView() -> ComposerTextView? {
        NSApp.windows.lazy.compactMap { $0.firstResponder as? ComposerTextView }.first
    }

}
