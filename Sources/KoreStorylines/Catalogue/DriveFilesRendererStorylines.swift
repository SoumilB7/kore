import AppKit
import Foundation
import KoreUI

// The renderers' controls no other storyline uses as a person does: the CSV grid's clicks, keys,
// header and wheel; the hex view's clicks, keys and wheel; the JSON tree's clicks, keys, menu
// and filter; a PDF's toolbar, thumbnails and find; a renderer state's button, the notice's
// Show Preview, and ⇧⌘V. The grid, hex view and JSON tree draw their own rows, so a click aims
// where the renderer says a row or byte is.

/// A click at a point the renderer gives for what it draws (a cell, a byte, a row).
private struct DriveClickAt: Step {
    let what: String
    var count = 1
    var right = false
    let point: @MainActor @Sendable (StoryContext) -> (NSWindow, CGPoint)?
    var label: String { (right ? "Right-click " : count == 2 ? "Double-click " : "Click ") + what }

    func run(_ story: StoryContext) async throws {
        let (window, p) = try await story.wait(what) { point(story) }
        guard right else { return await story.input.click(at: p, in: window, count: count, modifiers: []) }
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0)
            {
                NSApp.sendEvent(event)
            }
        }
        try await story.idle()
    }
}

/// A wheel turn over a point the renderer gives, to the view under it: `points` positive moves
/// down the content.
private struct DriveWheelAt: Step {
    let what: String
    let points: CGFloat
    let point: @MainActor @Sendable (StoryContext) -> (NSWindow, CGPoint)?
    var label: String { "Turn the wheel over \(what) by \(Int(points)) pt" }

    func run(_ story: StoryContext) async throws {
        let (window, p) = try await story.wait(what) { point(story) }
        guard let view = window.contentView?.hitTest(p),
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-points), wheel2: 0, wheel3: 0),
            let event = NSEvent(cgEvent: wheel)
        else { throw StoryFailure.other("can't turn the wheel over \(what)") }
        view.scrollWheel(with: event)
        try await story.idle()
    }
}

/// The status row's facts while a renderer shows.
@MainActor private func driveFacts(_ story: StoryContext) -> [String] { story.app.workspace?.storyRendererFacts ?? [] }

/// A check on the status row's facts.
@MainActor private func driveFactsShow(_ what: String, _ check: @escaping @MainActor ([String]) -> Bool) -> Expect {
    Expect(what, found: { "\(driveFacts($0))" }) { check(driveFacts($0)) }
}

/// The active file in this renderer.
@MainActor private func driveRenderer(_ id: String) -> Expect {
    // The renderers with window keys (⌘C, ⌘=, ⌘F) take them once their view is in the window.
    let keyed = ["image", "pdf", "web", "html", "mermaid"].contains(id)
    return Expect("the file in the \(id) renderer" + (keyed ? ", taking its keys" : ""), found: { $0.app.workspace?.storyActiveRenderer ?? "no renderer" }) {
        $0.app.workspace?.storyActiveRenderer == id && (!keyed || StoryRendererKeys.taken(in: $0.window))
    }
}

/// The storyline host's own pasteboard emptied, before a copy that should fill it.
@MainActor private func driveClearBoard() -> Do {
    Do("Empty the host's pasteboard") { _ in StoryHost.pasteboard.clearContents() }
}

/// The host's pasteboard holds this text.
@MainActor private func driveBoard(_ what: String, _ text: String) -> Expect {
    Expect(what, found: { _ in StoryHost.pasteboard.string(forType: .string).map { "“\($0)”" } ?? "nothing" }) { _ in
        StoryHost.pasteboard.string(forType: .string) == text
    }
}

/// These URLs are the storyline folder's files at `paths`, symlinks resolved.
@MainActor private func driveSame(_ urls: [URL], _ story: StoryContext, _ paths: [String]) -> Bool {
    urls.map { $0.resolvingSymlinksInPath().path } == paths.map { story.folder.appendingPathComponent($0).resolvingSymlinksInPath().path }
}

/// Picks the open option popup's item titled `title`.
private struct DrivePickItem: Step {
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

private let driveCSV = "name,score\nzed,3\namy,1\nbob,2\ncat,4\n"

/// A click on a grid cell selects it; the arrows move the selection, ⌘C copies the cell, and Esc
/// clears it.
final class DriveFilesGridClickKeys: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("people.csv", driveCSV)] }

    override func steps() -> [any Step] {
        super.steps() + FileTabState.open("people.csv") + [
            driveRenderer("delimited"),
            DriveClickAt(what: "the grid's second row") { $0.app.workspace?.storyGridPoint(row: 1) },
            driveFactsShow("row 2, column 1 selected") { $0.first == "Row 2, Col 1" },
            Key(.down),
            driveFactsShow("↓: row 3") { $0.first == "Row 3, Col 1" },
            Key(.right),
            driveFactsShow("→: column 2") { $0.first == "Row 3, Col 2" },
            Key(.up),
            driveFactsShow("↑: row 2") { $0.first == "Row 2, Col 2" },
            driveClearBoard(),
            Key(.cmd("c")),
            driveBoard("⌘C copied the cell: amy's score", "1"),
            Key(.escape),
            driveFactsShow("Esc: nothing selected") { !$0.isEmpty && !$0.contains { $0.hasPrefix("Row ") } },
        ]
    }
}

/// A click on a column's header sorts by it: up, down, then the file's order.
final class DriveFilesGridHeaderSort: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("people.csv", driveCSV)] }

    override func steps() -> [any Step] {
        let header = DriveClickAt(what: "the name column's header") { $0.app.workspace?.storyGridPoint(row: nil) }
        // The second row shown is file row 2 (amy); sorted up it's bob (3), down it's cat (4).
        return super.steps() + FileTabState.open("people.csv") + [
            driveRenderer("delimited"),
            DriveClickAt(what: "the grid's second row") { $0.app.workspace?.storyGridPoint(row: 1) },
            driveFactsShow("the second row is file row 2") { $0.first == "Row 2, Col 1" },
            header,
            driveFactsShow("sorted up: the second row is bob, file row 3") { $0.first == "Row 3, Col 1" },
            header,
            driveFactsShow("sorted down: the second row is cat, file row 4") { $0.first == "Row 4, Col 1" },
            header,
            // Back in the file's order the fourth row is cat (4); sorted down it would be amy (2).
            Key(.down),
            Key(.down),
            driveFactsShow("the file's order again: the fourth row is file row 4") { $0.first == "Row 4, Col 1" },
        ]
    }
}

/// The wheel over the grid's row numbers scrolls the grid.
final class DriveFilesGridWheel: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] {
        [("long.csv", "n\n" + (1...300).map(String.init).joined(separator: "\n") + "\n")]
    }

    override func steps() -> [any Step] {
        super.steps() + FileTabState.open("long.csv") + [
            driveRenderer("delimited"),
            Expect("the grid at its top", found: { "\($0.app.workspace?.storyGridTop ?? -1)" }) { $0.app.workspace?.storyGridTop == 0 },
            DriveWheelAt(what: "the grid's row numbers", points: 300) { $0.app.workspace?.storyGridGutterPoint },
            Expect("the grid scrolled down", found: { "\($0.app.workspace?.storyGridTop ?? -1)" }) { ($0.app.workspace?.storyGridTop ?? 0) > 0 },
        ]
    }
}

/// 64 KB that isn't text: NUL then fifteen letters, over and over.
private let driveBlob = String(repeating: "\u{0}ABCDEFGHIJKLMNO", count: 4096)

/// A click on a byte puts the hex view's caret there; the arrows move it.
final class DriveFilesHexClickKeys: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("blob.bin", driveBlob)] }

    override func steps() -> [any Step] {
        super.steps() + FileTabState.open("blob.bin") + [
            driveRenderer("hex"),
            DriveClickAt(what: "byte 0x23") { $0.app.workspace?.storyHexPoint(offset: 0x23) },
            driveFactsShow("the caret on 0x23") { $0.first == "Offset 0x00000023" },
            Key(.right),
            driveFactsShow("→: 0x24") { $0.first == "Offset 0x00000024" },
            Key(.down),
            driveFactsShow("↓: a row on, 0x34") { $0.first == "Offset 0x00000034" },
            Key(.left),
            driveFactsShow("←: 0x33") { $0.first == "Offset 0x00000033" },
            driveClearBoard(),
            Key(.cmd("c")),
            driveBoard("⌘C copied the byte's hex: C is 43", "43"),
        ]
    }
}

/// The wheel over the hex view scrolls it.
final class DriveFilesHexWheel: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("blob.bin", driveBlob)] }

    override func steps() -> [any Step] {
        super.steps() + FileTabState.open("blob.bin") + [
            driveRenderer("hex"),
            Expect("the hex view at its top", found: { "\($0.app.workspace?.storyHexTop ?? -1)" }) { $0.app.workspace?.storyHexTop == 0 },
            DriveWheelAt(what: "the hex view", points: 600) { $0.app.workspace?.storyHexMiddle },
            Expect("the hex view scrolled down", found: { "\($0.app.workspace?.storyHexTop ?? -1)" }) { ($0.app.workspace?.storyHexTop ?? 0) > 0 },
        ]
    }
}

/// Rows: 0 the root, 1 users, 2 and 3 its two (closed), 4 count.
private let driveJSON = "{\"users\": [{\"name\": \"Ada\", \"age\": 36}, {\"name\": \"Lin\", \"age\": 41}], \"count\": 2}\n"

@MainActor private func driveJSONRows(_ story: StoryContext) -> Int? { story.app.workspace?.storyJSONRowCount }

/// A click on a JSON row selects it; on its chevron, or a double click, it opens or closes.
final class DriveFilesJSONClicks: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("data.json", driveJSON)] }

    override func steps() -> [any Step] {
        let rows = { (n: Int) in Expect("\(n) rows", found: { "\(driveJSONRows($0) ?? -1)" }) { driveJSONRows($0) == n } }
        return super.steps() + FileTabState.open("data.json") + [
            driveRenderer("json"),
            rows(5),
            DriveClickAt(what: "users") { $0.app.workspace?.storyJSONPoint(row: 1) },
            driveFactsShow("users selected") { $0.contains("$.users") },
            DriveClickAt(what: "users' chevron") { $0.app.workspace?.storyJSONPoint(row: 1, chevron: true) },
            rows(3),
            DriveClickAt(what: "the root", count: 2) { $0.app.workspace?.storyJSONPoint(row: 0) },
            rows(1),
        ]
    }
}

/// The JSON tree's keys: ↓ selects, → opens and steps in, ← steps out; ⌘F opens its filter,
/// which narrows the tree to what matches.
final class DriveFilesJSONKeys: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("data.json", driveJSON)] }

    override func steps() -> [any Step] {
        super.steps() + FileTabState.open("data.json") + [
            driveRenderer("json"),
            DriveClickAt(what: "the root") { $0.app.workspace?.storyJSONPoint(row: 0) },
            driveFactsShow("the root selected") { $0.contains("$") },
            Key(.down),
            driveFactsShow("↓: users") { $0.contains("$.users") },
            Key(.down),
            driveFactsShow("↓: its first") { $0.contains("$.users[0]") },
            Key(.right),
            Expect("→ opened it", found: { "\(driveJSONRows($0) ?? -1)" }) { driveJSONRows($0) == 7 },
            Key(.right),
            driveFactsShow("→ again: into its name") { $0.contains("$.users[0].name") },
            Key(.left),
            driveFactsShow("←: back out") { $0.contains("$.users[0]") },
            Key(.cmd("f")),
            WaitForFocus(.id(StoryID.Editor.jsonFilter)),
            TypeText("Lin"),
            driveFactsShow("the filter: one match") { $0.contains("1 match") },
        ]
    }
}

/// A right-click on a JSON row selects it and offers Copy Value and Copy Path; each copies
/// (to the storyline host's own pasteboard).
final class DriveFilesJSONMenu: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    override class var files: [(path: String, text: String)] { [("data.json", driveJSON)] }

    override func steps() -> [any Step] {
        let menu = DriveClickAt(what: "users", right: true) { $0.app.workspace?.storyJSONPoint(row: 1) }
        return super.steps() + FileTabState.open("data.json") + [
            driveRenderer("json"),
            menu,
            WaitForElement(.id(StoryID.Options.panel)),
            Expect("its menu: Copy Value, Copy Path", found: { _ in "\(StoryMenus.open)" }) { _ in
                StoryMenus.open.filter { !$0.isEmpty } == ["Copy Value", "Copy Path"]
            },
            driveFactsShow("users selected") { $0.contains("$.users") },
            driveClearBoard(),
            DrivePickItem("Copy Value"),
            driveBoard("Copy Value copied the users array as written", "[{\"name\": \"Ada\", \"age\": 36}, {\"name\": \"Lin\", \"age\": 41}]"),
            menu,
            DrivePickItem("Copy Path"),
            driveBoard("Copy Path copied its path", "$.users"),
        ]
    }
}

/// An image file's ⌘C copies the picture (to the storyline host's own pasteboard).
final class DriveFilesImageCopy: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let path = "dot.png"

    override func steps() -> [any Step] {
        var steps = super.steps()
        steps.insert(Do("Write an 8 × 8 picture") { story in
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let png = rep.representation(using: .png, properties: [:])
            else { throw StoryFailure.other("can't make the picture") }
            try FileManager.default.createDirectory(at: story.folder, withIntermediateDirectories: true)
            try png.write(to: story.folder.appendingPathComponent(Self.path))
        }, at: 1)
        return steps + FileTabState.open(Self.path) + [
            driveRenderer("image"),
            driveFactsShow("its size, 8 × 8") { $0.first == "8 × 8" },
            driveClearBoard(),
            Key(.cmd("c")),
            Expect("⌘C put the picture on the pasteboard", found: { _ in "\(StoryHost.pasteboard.types ?? [])" }) { _ in
                StoryHost.pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
            },
        ]
    }
}

/// A four-page PDF, each page's text "Page n: Hello hello".
@MainActor private func driveWritePDF(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw StoryFailure.other("can't write \(url.lastPathComponent)") }
    for page in 1...4 {
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Page \(page): Hello hello" as NSString).draw(at: NSPoint(x: 16, y: 240), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }
    context.closePDF()
}

/// A PDF storyline's folder: the four-page PDF written before the folder opens.
class DriveFilesPDFStoryline: FilesStoryline {
    override class var isFamily: Bool { self == DriveFilesPDFStoryline.self }
    static let pdf = "guide.pdf"

    override func steps() -> [any Step] {
        var steps = super.steps()
        steps.insert(Do("Write a four-page PDF") { try driveWritePDF($0.folder.appendingPathComponent(Self.pdf)) }, at: 1)
        return steps + FileTabState.open(Self.pdf) + [
            driveRenderer("pdf"),
            Expect("its first page shown") { $0.app.workspace?.storyPDF?.page == 0 },
        ]
    }
}

@MainActor private func drivePDF(_ story: StoryContext) -> String { story.app.workspace?.storyPDF.map { "\($0)" } ?? "no PDF" }

/// The page field goes to a page, a thumbnail goes to its page, and the zoom's percentage puts
/// the PDF at its actual size.
final class DriveFilesPDFToolbar: DriveFilesPDFStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }

    override func steps() -> [any Step] {
        typealias PDF = StoryID.Editor.PDF
        return super.steps() + [
            Click(.id(PDF.page)),
            WaitForFocus(.id(PDF.page)),
            Key(.cmd("a")),
            TypeText("3"),
            Key(.returnKey),
            Expect("page 3", found: { drivePDF($0) }) { $0.app.workspace?.storyPDF?.page == 2 },
            Press(.id(PDF.thumbnails)),
            Press(.id(PDF.thumbnail(1))),
            Expect("the thumbnail went to page 2", found: { drivePDF($0) }) { $0.app.workspace?.storyPDF?.page == 1 },
            Expect("fitted to the width, not at 100%", found: { drivePDF($0) }) { story in
                story.app.workspace?.storyPDF.map { abs($0.scale - 1) > 0.05 } ?? false
            },
            Press(.id(PDF.zoom)),
            Expect("at its actual size", found: { drivePDF($0) }) { story in
                story.app.workspace?.storyPDF.map { abs($0.scale - 1) < 0.01 } ?? false
            },
        ]
    }
}

/// ⌘F finds in the PDF as typed; Aa makes it match case.
final class DriveFilesPDFFind: DriveFilesPDFStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }

    override func steps() -> [any Step] {
        typealias PDF = StoryID.Editor.PDF
        return super.steps() + [
            Key(.cmd("f")),
            WaitForFocus(.id(PDF.find)),
            TypeText("hello"),
            Expect("eight matches, two a page", found: { drivePDF($0) }) { $0.app.workspace?.storyPDF?.matches == 8 },
            Press(.id(PDF.matchCase)),
            Expect("Aa: the four lowercase ones", found: { drivePDF($0) }) { $0.app.workspace?.storyPDF?.matches == 4 },
        ]
    }
}

/// A CSV that isn't text: the grid can't show it, and offers Open with Default App and Show
/// Source; its source is binary, and the editor's state offers Reveal in Finder and Open with
/// Default App. Opens and reveals are recorded by the storyline host, never done.
final class DriveFilesRendererState: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    static let path = "bad.csv"
    override class var files: [(path: String, text: String)] { [(path, "a,b\u{0}\n1,2\n")] }

    override func steps() -> [any Step] {
        let source = StoryID.Editor.rendererState("Show Source")
        let opened = { (n: Int) in
            Expect("bad.csv opened in its app \(n == 1 ? "once" : "twice")", found: { _ in "\(StoryHost.opened)" }) { story in
                driveSame(StoryHost.opened, story, Array(repeating: Self.path, count: n))
            }
        }
        return super.steps() + FileTabState.open(Self.path) + [
            ExpectElement(.id(source), .visible),
            Expect("the grid's state, not the source") { $0.app.workspace?.storyActiveFileRaw == false },
            Press(.id(StoryID.Editor.rendererState("Open with Default App"))),
            opened(1),
            Press(.id(source)),
            Expect("the tab shows the source") { $0.app.workspace?.storyActiveFileRaw == true },
            ExpectElement(.id(source), .absent),
            Press(.id(StoryID.Editor.state("Reveal in Finder"))),
            Expect("bad.csv shown in Finder", found: { _ in "\(StoryHost.revealed)" }) { driveSame(StoryHost.revealed, $0, [Self.path]) },
            Press(.id(StoryID.Editor.state("Open with Default App"))),
            opened(2),
        ]
    }
}

/// JSON that doesn't parse opens as source under a notice; fixed on disk, the notice's Show
/// Preview shows the tree.
final class DriveFilesRendererNotice: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.codex] }
    static let path = "broken.json"
    override class var files: [(path: String, text: String)] { [(path, "{\"a\": 1,,}\n")] }

    override func steps() -> [any Step] {
        super.steps() + FileTabState.open(Self.path) + [
            ExpectElement(.id(StoryID.Editor.rendererNotice), .visible),
            Expect("the source shown") { $0.app.workspace?.storyActiveFileRaw == true },
            WriteFiles([(Self.path, "{\"a\": 1}\n")]),
            Expect.editor("the fixed text in the source") { $0.text == "{\"a\": 1}\n" },
            Press(.id(StoryID.Editor.rendererNotice)),
            driveRenderer("json"),
            ExpectElement(.id(StoryID.Editor.rendererNotice), .absent),
        ]
    }
}

/// ⇧⌘V flips a Markdown file from its preview to its source and back.
final class DriveFilesPreviewKey: FilesStoryline {
    override class var tags: Set<Tag> { [.drive] }
    override class var variants: [Variant] { [.claude] }
    override class var files: [(path: String, text: String)] { [("readme.md", "# Title\n\nSome text.\n")] }

    override func steps() -> [any Step] {
        super.steps() + FileTabState.open("readme.md") + [
            driveRenderer("markdown"),
            DriveChatSettle(),
            Key(.cmdShift("v")),
            Expect("⇧⌘V: the source") { $0.app.workspace?.storyActiveFileRaw == true },
            Key(.cmdShift("v")),
            Expect("⇧⌘V again: the preview") { $0.app.workspace?.storyActiveFileRaw == false },
            driveRenderer("markdown"),
        ]
    }
}
