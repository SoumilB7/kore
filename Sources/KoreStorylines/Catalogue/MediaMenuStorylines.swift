import AppKit
import KoreUI

/// Right-click a sent image's chip: Kore's own popup (not a native menu) offers Copy Image, and
/// that puts the picture on the storylines' pasteboard, never the owner's clipboard.
final class ImageChipMenu: ChatStoryline {
    static let name = "chip-shot.png"
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            Do("Attach a picture") { story in
                let image = story.folder.appendingPathComponent(Self.name)
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                try rep?.representation(using: .png, properties: [:])?.write(to: image)
                try story.activeChat().storyAttach([image])
                Self.board.clearContents()
            },
            Send("What is in this picture"), TurnFinished(1),
            RightClick(.id(StoryID.Transcript.attachment(Self.name))),
            WaitForElement(.id(StoryID.Options.panel)),
            Snapshot("image-chip-menu"),
            Press(.id(StoryID.Options.item(0))),
            Expect("Copy Image put the picture on the pasteboard") { _ in
                let board = Self.board
                return board.data(forType: .png) != nil && board.data(forType: .tiff) != nil
            },
            ExpectElement(.id(StoryID.Options.panel), .absent),
        ]
    }

    static var board: NSPasteboard { NSPasteboard(name: .init("kore-storylines")) }
}
