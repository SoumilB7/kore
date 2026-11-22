import AppKit
import CoreGraphics
import Foundation
import KoreCore
import KoreUI
import src

// Shared pieces no other storyline uses as a person does: the dimmed page around Kore's
// question and its "Apply to all" tick, a submenu's Back in an option popup, VoiceOver's Copy
// on a code block and a table and its Open on a link, the picture viewer's Actual size, pen
// colours, canvas (draw, pan, double click) and Done, an SVG's double click, and a large diff's
// Open in editor.

// MARK: - Kore's question

/// The tab's Rename…: a click on the dimmed page beside the card cancels, the name kept.
final class DriveWindowAskScrim: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    private final class Name { var value: String? }

    override func steps() -> [any Step] {
        let name = Name()
        return super.steps() + [
            Do("Note the tab's name") { story in name.value = story.app.workspace?.tabs.first?.title },
            RightClick(.tab(1)), DriveWindowOption("Rename…"),
            WaitForElement(.id(StoryID.Ask.card)),
            Expect("the rename question up") { _ in KoreAsk.storyOpen == "rename-chat" },
            Press(.id(StoryID.Ask.scrim)),
            ExpectElement(.id(StoryID.Ask.card), .absent),
            Expect("cancelled, the name kept") { story in KoreAsk.storyOpen == nil && story.app.workspace?.tabs.first?.title == name.value },
        ]
    }
}

/// Two files dropped where both names are taken: the first collision's "Apply to all" ticked,
/// its Keep Both answers the second too, asked once.
final class DriveWindowAskTick: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] {
        [("a.txt", "a\n"), ("b.txt", "b\n"), ("dest/a.txt", "old a\n"), ("dest/b.txt", "old b\n")]
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Command(.toggleExplorer),
            Do("Drop a.txt and b.txt on dest") { story in story.app.workspace?.storyDrop(["a.txt", "b.txt"], into: "dest", copy: false) },
            WaitForElement(.id(StoryID.Ask.card)),
            Expect("asked to move") { _ in KoreAsk.storyOpen == "move" },
            Key(.returnKey),
            Expect("a name taken: asked about it") { _ in KoreAsk.storyOpen == "collision" },
            ExpectElement(.id(StoryID.Ask.tick), .visible),
            Expect("Apply to all not ticked") { _ in !KoreAsk.shared.ticked },
            Press(.id(StoryID.Ask.tick)),
            Expect("Apply to all ticked") { _ in KoreAsk.shared.ticked },
            Press(.id(StoryID.Ask.choice("Keep Both"))),
            Expect("both moved, each beside the one there, asked once", found: { story in
                let dest = story.folder.appendingPathComponent("dest").path
                return "\((try? FileManager.default.contentsOfDirectory(atPath: dest)) ?? []), asking \(KoreAsk.storyOpen ?? "nothing")"
            }) { story in
                guard let workspace = story.app.workspace, KoreAsk.storyOpen == nil else { return false }
                let dest = story.folder.appendingPathComponent("dest").path
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dest)) ?? []
                return names.filter { !$0.hasPrefix(".") }.count == 4 && !workspace.storyHasFile("a.txt") && !workspace.storyHasFile("b.txt")
            },
        ]
    }
}

// MARK: - Option popups

/// The editor's right-click: a row with a submenu shows its items with Back on top; Back puts
/// the first list back.
final class DriveWindowOptionsBack: EditorStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("menu.txt", "hello from the editor\n")] }

    private final class Rows { var first: [String] = [] }

    override func steps() -> [any Step] {
        let rows = Rows()
        return super.steps() + [
            RightClick(.editor),
            WaitForElement(.id(StoryID.Options.panel)),
            ExpectElement(.id(StoryID.Options.back), .absent),
            DriveWindowOpenBranch(rows: { rows.first = $0 }),
            WaitForElement(.id(StoryID.Options.back)),
            Expect("the submenu's own items", found: { _ in "\(StoryMenus.open)" }) { _ in StoryMenus.open != rows.first },
            Press(.id(StoryID.Options.back)),
            Expect("Back: the first list again", found: { _ in "\(StoryMenus.open)" }) { _ in StoryMenus.open == rows.first },
            ExpectElement(.id(StoryID.Options.back), .absent),
            Key(.escape),
            ExpectElement(.id(StoryID.Options.panel), .absent),
        ]
    }
}

/// The open popup's first row with a submenu (the text menu's Substitutions and the like),
/// pressed; the rows before it noted.
private struct DriveWindowOpenBranch: Step {
    let rows: @MainActor ([String]) -> Void
    var label: String { "Press a row with a submenu" }
    static let branches = ["Spelling and Grammar", "Substitutions", "Transformations", "Speech", "Font", "Layout Orientation", "Share"]

    func run(_ story: StoryContext) async throws {
        let open = StoryMenus.open
        guard let index = open.firstIndex(where: { Self.branches.contains($0) }) else {
            throw StoryFailure.expectation("a row with a submenu (the popup has \(open.filter { !$0.isEmpty }))")
        }
        rows(open)
        try await Press(.id(StoryID.Options.item(index))).run(story)
    }
}

// MARK: - VoiceOver's actions

/// A code block's Copy, as VoiceOver offers it (the button itself shows only on hover).
final class DriveWindowCodeCopyVoiceOver: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Here it is:\n\n```\nlet total = 42\n```\n")]) }

    override func steps() -> [any Step] {
        let block = driveWindowNamed("the code block", "transcript.code") { key in
            StoryID.Transcript.code(key.split(separator: ".").compactMap { Int($0) })
        }
        return super.steps() + [
            Send("Show the code"), TurnFinished(1),
            WaitForElement(block),
            Do("An empty clipboard") { _ in TranscriptSelection.pasteboard.clearContents() },
            DriveWindowVoiceOver(block, "Copy"),
            Expect("the code copied", found: { _ in TranscriptSelection.pasteboard.string(forType: .string) }) { _ in
                TranscriptSelection.pasteboard.string(forType: .string)?.contains("let total = 42") == true
            },
        ]
    }
}

/// A table's Copy, as VoiceOver offers it.
final class DriveWindowTableCopyVoiceOver: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var script: CLIScript {
        CLIScript(turns: [CLIScript.reply("Totals:\n\n| Name | Qty |\n|---|--:|\n| alpha | 3 |\n| beta | 12 |\n")])
    }

    override func steps() -> [any Step] {
        let table = driveWindowNamed("the table", "transcript.table") { key in
            StoryID.Transcript.table(key.split(separator: ".").compactMap { Int($0) })
        }
        return super.steps() + [
            Send("Show the totals"), TurnFinished(1),
            WaitForElement(table),
            Do("An empty clipboard") { _ in TranscriptSelection.pasteboard.clearContents() },
            DriveWindowVoiceOver(table, "Copy"),
            Expect("the table copied", found: { _ in TranscriptSelection.pasteboard.string(forType: .string) }) { _ in
                guard let text = TranscriptSelection.pasteboard.string(forType: .string) else { return false }
                return text.contains("alpha") && text.contains("beta") && text.contains("12")
            },
        ]
    }
}

/// A link in an answer, opened by VoiceOver's "Open …" (under storylines it's noted, not opened).
final class DriveWindowLinkOpenVoiceOver: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let link = URL(string: "https://example.com/guide")!
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("See [the guide](https://example.com/guide) for more.")]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Where is it"), TurnFinished(1),
            WaitForElement(.answer(turn: 1)),
            Do("Nothing opened yet") { _ in TranscriptSelection.opened = [] },
            DriveWindowVoiceOver(.answer(turn: 1), "Open the guide"),
            Expect("the link opened", found: { _ in "\(TranscriptSelection.opened)" }) { _ in TranscriptSelection.opened == [Self.link] },
        ]
    }
}

/// Performs one of VoiceOver's actions on an element by its name, as VoiceOver's actions menu
/// does: the element's accessibility node over the element's frame that offers it.
private struct DriveWindowVoiceOver: Step {
    let target: Locator
    let action: String
    var label: String { "VoiceOver's “\(action)” on \(target)" }
    init(_ target: Locator, _ action: String) {
        self.target = target
        self.action = action
    }

    func run(_ story: StoryContext) async throws {
        let element = try await story.element(target)
        guard let window = element.window, let frame = element.frame, let root = window.contentView else {
            throw StoryFailure.modelMissing("\(target)'s frame")
        }
        let spot = window.convertToScreen(frame)
        let action = self.action
        DriveAccessibility.on()
        defer { DriveAccessibility.off() }
        let found = try await story.wait("“\(action)” among VoiceOver's actions there") { Self.find(action, from: root, near: spot) }
        if let handler = found.handler {
            _ = handler()
        } else if let target = found.target as? NSObject, let selector = found.selector {
            _ = target.perform(selector, with: found)
        } else {
            throw StoryFailure.other("“\(action)” has nothing to run")
        }
        try await story.idle()
    }

    /// The action named `name` whose node covers most of `spot` (screen coordinates).
    @MainActor static func find(_ name: String, from root: NSView, near spot: CGRect) -> NSAccessibilityCustomAction? {
        var queue: [Any] = [root]
        var next = 0
        var best: (action: NSAccessibilityCustomAction, area: CGFloat)?
        var any: NSAccessibilityCustomAction?
        while next < queue.count, next < 40_000 {
            let node = queue[next]
            next += 1
            guard let object = node as? NSObject else { continue }
            if let match = actions(of: object).first(where: { $0.name == name }) {
                if any == nil { any = match }
                let frame = (object as? NSAccessibilityElementProtocol)?.accessibilityFrame() ?? .zero
                let overlap = frame.intersection(spot)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > (best?.area ?? 0) { best = (match, area) }
            }
            queue.append(contentsOf: children(of: object))
            if let view = object as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return best?.action ?? any
    }

    @MainActor private static func actions(of object: NSObject) -> [NSAccessibilityCustomAction] {
        if let view = object as? NSView { return view.accessibilityCustomActions() ?? [] }
        let selector = NSSelectorFromString("accessibilityCustomActions")
        guard object.responds(to: selector) else { return [] }
        return object.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction] ?? []
    }

    @MainActor private static func children(of object: NSObject) -> [Any] {
        if let view = object as? NSView { return view.accessibilityChildren() ?? [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector) else { return [] }
        return object.perform(selector)?.takeUnretainedValue() as? [Any] ?? []
    }
}

// MARK: - The picture viewer

/// A big picture attached and opened from its chip: the percentage sets it to actual size; a
/// drag pans it, drawing nothing; a double click fits it again; the pen's blue swatch picks blue
/// and a drag draws a stroke; Done puts the marked-up picture in the chip's place.
final class DriveWindowViewerImage: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let name = "big.png"

    @MainActor static var zoom: Int? { driveWindowKey("viewer.zoom").flatMap { Int($0) } }

    /// Where the viewer's scroll view has the picture.
    @MainActor static func place(_ story: StoryContext) -> CGPoint {
        var views = story.window?.contentView.map { [$0] } ?? []
        while let view = views.popLast() {
            if String(describing: type(of: view)) == "ImageCanvasView" { return view.enclosingScrollView?.contentView.bounds.origin ?? .zero }
            views += view.subviews
        }
        return .zero
    }

    override func steps() -> [any Step] {
        let canvas = Locator.id(StoryID.Viewer.canvas)
        let was = DriveChatNote(CGPoint.zero)
        return super.steps() + [
            Do("A picture bigger than the window, attached") { story in
                let file = story.folder.appendingPathComponent(Self.name)
                try Self.picture(width: 1600, height: 1200).write(to: file)
                try story.activeChat().storyAttach([file])
            },
            Expect("its chip shows it") { try $0.activeChat().storyChipShowsPicture(Self.name) },
            Press(.id(StoryID.Composer.attachment(Self.name))),
            WaitForElement(canvas),
            Expect("fitted, under 100%", found: { _ in Self.zoom.map { "\($0)%" } }) { _ in (Self.zoom ?? 100) < 100 },
            Press(.id(StoryID.Viewer.actualSize)),
            ExpectElement(.id(StoryID.Viewer.zoom(100))),
            Do("note where the picture is") { was.value = Self.place($0) },
            DriveWindowDragOn(canvas, by: CGVector(dx: -120, dy: 80)),
            Expect("panned: the picture moved, still 100%, nothing drawn", found: { "\(Self.place($0)), was \(was.value)" }) { story in
                Self.place(story) != was.value && Self.zoom == 100 && StoryElement(StoryID.Viewer.strokes(0)) != nil
            },
            Click(canvas, count: 2),
            Expect("the double click fits it again", found: { _ in Self.zoom.map { "\($0)%" } }) { _ in (Self.zoom ?? 100) < 100 },
            Press(.id(StoryID.Viewer.pen)),
            WaitForElement(.id(StoryID.Viewer.swatch("blue"))),
            ExpectElement(.id(StoryID.Viewer.swatch("red").part(.selected))),
            Press(.id(StoryID.Viewer.swatch("blue"))),
            ExpectElement(.id(StoryID.Viewer.swatch("blue").part(.selected))),
            ExpectElement(.id(StoryID.Viewer.swatch("red").part(.selected)), .absent),
            DriveWindowDragOn(canvas, by: CGVector(dx: 60, dy: -40)),
            ExpectElement(.id(StoryID.Viewer.strokes(1))),
            Press(.id(StoryID.Viewer.add)),
            ExpectElement(canvas, .absent),
            Expect("the chip now the marked-up picture", found: { "\($0.app.chat?.storyAttachmentNames ?? [])" }) { story in
                let names = try story.activeChat().storyAttachmentNames
                return names.count == 1 && names.first != Self.name
            },
        ]
    }

    /// A PNG of one colour.
    static func picture(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw StoryFailure.other("no context to draw the picture in") }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw StoryFailure.other("the picture didn't encode")
        }
        return png
    }
}

/// An SVG attached and opened from its chip: a double click shows it at its own size, another
/// fits it again.
final class DriveWindowViewerSVG: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let name = "art.svg"
    static let text = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">
          <rect x="10" y="10" width="100" height="60" fill="#3a8fb7"/>
        </svg>
        """

    private final class Fit {
        var zoom: Int?
        var spot = CGPoint.zero
        var frames: [String] = []
    }

    override func steps() -> [any Step] {
        let fit = Fit()
        return super.steps() + [
            WriteFiles([(Self.name, Self.text)]),
            Do("Attach the SVG") { story in try story.activeChat().storyAttach([story.folder.appendingPathComponent(Self.name)]) },
            Expect("its chip shows it") { try $0.activeChat().storyChipShowsPicture(Self.name) },
            Press(.id(StoryID.Composer.attachment(Self.name))),
            WaitForElement(.id(StoryID.Viewer.svg)),
            Expect("fitted: drawn larger than its own size", found: { _ in DriveWindowViewerImage.zoom.map { "\($0)%" } }) { _ in
                fit.zoom = DriveWindowViewerImage.zoom
                return (fit.zoom ?? 0) > 100
            },
            BoxStep("Double-click the SVG") { story in
                let element = try await story.element(.id(StoryID.Viewer.svg))
                guard let window = element.window, let frame = element.frame else { throw StoryFailure.modelMissing("the SVG's frame") }
                fit.spot = CGPoint(x: frame.midX, y: frame.midY)
                fit.frames.append("fitted \(frame)")
                await story.input.click(at: fit.spot, in: window, count: 2)
            },
            ExpectElement(.id(StoryID.Viewer.zoom(100))),
            // Magnified below 1×, a web view's own frame no longer says where it shows: the
            // second double-click goes where the first did (the view fills the viewer).
            BoxStep("Double-click the SVG again, there") { story in
                let element = try await story.element(.id(StoryID.Viewer.svg))
                guard let window = element.window else { throw StoryFailure.modelMissing("the SVG's window") }
                fit.frames.append("at 100% \(String(describing: element.frame))")
                await story.input.click(at: fit.spot, in: window, count: 2)
            },
            Expect("fitted again", found: { _ in "\(DriveWindowViewerImage.zoom.map { "\($0)%" } ?? "-"); frames \(fit.frames); last click \(InputDriver.lastRoute)" }) { _ in
                DriveWindowViewerImage.zoom == fit.zoom
            },
            Key(.escape),
            ExpectElement(.id(StoryID.Viewer.svg), .absent),
        ]
    }
}

/// A press on an element's middle, moved by `by` (window space, y up) and let go, through the
/// app as a mouse's events come: an AppKit view's own drag (the viewer's canvas).
private struct DriveWindowDragOn: Step {
    let target: Locator
    let by: CGVector
    var label: String { "Drag on \(target) by \(Int(by.dx)), \(Int(by.dy))" }
    init(_ target: Locator, by: CGVector) {
        self.target = target
        self.by = by
    }

    func run(_ story: StoryContext) async throws {
        let element = try await story.element(target)
        guard let window = element.window, let frame = element.frame else { throw StoryFailure.modelMissing("\(target)'s frame") }
        let start = CGPoint(x: frame.midX, y: frame.midY)
        await story.input.drag(from: start, to: CGPoint(x: start.x + by.dx, y: start.y + by.dy), in: window, steps: 10)
        try await story.idle()
    }
}

// MARK: - A large diff

/// A file too large to show as a diff, in View changes: its "Open in editor" opens it in a tab.
final class DriveWindowOpenInEditor: ChatStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let big = (1...2100).map { "line \($0)" }.joined(separator: "\n") + "\n"
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .fileEdit(path: "big.txt", content: big), .stream(.answer, "Wrote it."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let viewChanges = driveWindowNamed("the turn's View changes", "transcript.changes", suffix: ".open") { turn in
            StoryID.Transcript.changes(turn).part(.open)
        }
        return super.steps() + [
            Send("Write the big file"), TurnFinished(1),
            Press(viewChanges),
            WaitForElement(.id(StoryID.Changes.done)),
            DriveChatSettle(),
            DriveNetBoardPointer("Click Open in editor", count: 1) { _ in StoryID.Changes.openInEditor("big.txt") },
            Expect("big.txt open in a tab", found: { $0.app.workspace?.storyActiveFile }) { $0.app.workspace?.storyActiveFile == "big.txt" },
        ]
    }
}

// MARK: - The image tab

/// A picture opened in its own tab: its Copy puts the picture on the clipboard.
final class DriveWindowImageTabCopy: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let name = "pic.png"

    override func steps() -> [any Step] {
        [
            Do("A picture in the folder") { story in
                try FileManager.default.createDirectory(at: story.folder, withIntermediateDirectories: true)
                try DriveWindowViewerImage.picture(width: 320, height: 200).write(to: story.folder.appendingPathComponent(Self.name))
            },
        ] + super.steps() + FileTabState.open(Self.name) + [
            WaitForElement(.id(StoryID.Viewer.secondary)),
            Do("An empty clipboard") { _ in StoryHost.pasteboard.clearContents() },
            Press(.id(StoryID.Viewer.secondary)),
            Expect("the picture on the clipboard") { _ in
                (StoryHost.pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.isEmpty == false)
            },
        ]
    }
}
