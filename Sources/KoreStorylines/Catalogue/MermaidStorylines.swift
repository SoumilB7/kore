import AppKit
import KoreUI

/// Mermaid files open drawn: a flowchart as a diagram in the page, a broken one as mermaid's
/// reason in one line with its source under it, drawn once it's fixed on disk; and a ```mermaid
/// block in a Markdown file as a diagram in the column.
final class MermaidPreview: ChatStoryline {
    override class var tags: Set<Tag> { [.files] }

    static let flow = "docs/flow.mmd"
    static let broken = "docs/broken.mmd"
    static let notes = "docs/notes.md"
    static let flowText = """
        flowchart LR
            open[Open a file] --> pick{Which renderer?}
            pick -->|Mermaid| draw[Draw the diagram]
            pick -->|Markdown| read[Read the column]
            pick -->|Other| source[Show the source]
            draw --> done((Done))
            read --> done
        """
    static let brokenText = "flowchart TD\n    start[Start] --> middle[Middle]\n    middle --> --> finish[Finish]\n"
    static let notesText = """
        # Notes

        The flow, as a diagram:

        ```mermaid
        sequenceDiagram
            Kore->>CLI: send
            CLI-->>Kore: reply
        ```

        And the text after it.
        """

    static let svgs = "document.querySelectorAll('#diagram svg').length"
    static let nodes = "document.querySelectorAll('#diagram svg .node').length"
    static let reason = "document.documentElement.classList.contains('failed') ? document.querySelector('#error .reason').textContent : ''"
    static let badLine = "document.querySelector('#source .bad .n')?.textContent ?? ''"

    override func steps() -> [any Step] {
        [WriteFiles([(Self.flow, Self.flowText), (Self.broken, Self.brokenText), (Self.notes, Self.notesText)])] + super.steps()
            + FileTabState.open(Self.flow) + [
                Expect("the flowchart in the Mermaid renderer", found: { $0.app.workspace?.storyActiveRenderer ?? "no renderer" }) {
                    $0.app.workspace?.storyActiveRenderer == "mermaid"
                },
                DiagramAnswer("the flowchart drawn, its six nodes in it", Self.nodes) { ($0 as? Int) == 6 },
                DiagramSnapshot("mermaid-flow"),
            ]
            + FileTabState.open(Self.broken) + [
                Expect("the broken file in the Mermaid renderer") { $0.app.workspace?.storyActiveRenderer == "mermaid" },
                DiagramAnswer("mermaid's reason, naming line 3", Self.reason) { ($0 as? String)?.contains("line 3") == true },
                DiagramAnswer("line 3 of the source marked", Self.badLine) { ($0 as? String) == "3" },
                DiagramAnswer("no diagram drawn", Self.svgs) { ($0 as? Int) == 0 },
                DiagramSnapshot("mermaid-broken"),
                // Fixed on disk: drawn in place.
                WriteFiles([(Self.broken, Self.brokenText.replacingOccurrences(of: "--> -->", with: "-->"))]),
                DiagramAnswer("the fixed file drawn", Self.svgs) { ($0 as? Int) == 1 },
                DiagramAnswer("its reason gone", Self.reason) { ($0 as? String) == "" },
            ]
            + FileTabState.open(Self.notes) + [
                Expect("the notes in the Markdown renderer") { $0.app.workspace?.storyActiveRenderer == "markdown" },
                DiagramAnswer("the notes' block drawn", Self.svgs) { ($0 as? Int) == 1 },
                DiagramSnapshot("mermaid-notes"),
            ]
    }
}

/// Waits for the active diagram's answer to a script to pass `check`.
private struct DiagramAnswer: Step {
    let what: String
    let script: String
    let check: @MainActor (Any?) -> Bool
    var label: String { "Find \(what)" }

    init(_ what: String, _ script: String, _ check: @escaping @MainActor (Any?) -> Bool) {
        self.what = what
        self.script = script
        self.check = check
    }

    @MainActor final class Box {
        var value: Any?
        var asking = false
        var answered = false
    }

    func run(_ story: StoryContext) async throws {
        let box = Box()
        let (script, check) = (script, check)
        do {
            _ = try await story.wait(what) { () -> Bool? in
                if box.answered, check(box.value) { return true }
                if !box.asking, let workspace = story.app.workspace {
                    box.asking = true
                    Task { @MainActor in
                        box.value = await workspace.storyDiagram(script)
                        box.answered = true
                        box.asking = false
                    }
                }
                return nil
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("\(what) (found \(box.value.map { "\($0)" } ?? "no diagram"))")
        }
    }
}

/// Saves the window as `<name>.png`, with the diagrams' web views as WebKit drew them (the
/// window's own snapshot may show them a frame behind, or not yet).
private struct DiagramSnapshot: Step {
    let name: String
    var label: String { "Snapshot “\(name)” with its diagrams" }
    init(_ name: String) { self.name = name }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window, let workspace = story.app.workspace else { throw StoryFailure.other("no window to snapshot") }
        try await story.idle()
        let shots = await workspace.storyDiagramSnapshots()
        guard !shots.isEmpty else { throw StoryFailure.other("no diagram on screen") }
        guard let png = snapshot(window), let base = NSBitmapImageRep(data: png),
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw StoryFailure.other("the window couldn't be drawn") }
        let size = window.frame.size
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw StoryFailure.other("the window couldn't be drawn") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        base.draw(in: CGRect(origin: .zero, size: size))
        // Opaque: they cover whatever frame of them the window's own picture holds.
        for shot in shots { shot.image.draw(in: shot.frame) }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: story.outputs.appendingPathComponent("\(name).png"))
    }
}
