import AppKit
import KoreUI
import src

/// A code block's Copy, at the natural size and pinched in to 1.5× and 3×: hovered, it's in view
/// and clear of the message rail even when the block runs past the page's right edge (pinched in,
/// a column-wide block does), and at the natural size a click where it's drawn copies the code.
final class PinchZoomCodeCopy: ChatStoryline {
    static let code = "swift build --configuration release"
    static let reply = """
        Build it with:

        ```sh
        \(code)
        ```

        Then open the app.
        """
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(reply)]) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("How do I build it?"), TurnFinished(1), WaitIdle(),
            CopyCodeWithPointer(zoom: 1),
            CopyCodeWithPointer(zoom: 1.5),
            CopyCodeWithPointer(zoom: 3),
        ]
    }
}

/// The page pinched to `zoom` on the first code block's left, the block hovered, its Copy in view
/// and clear of the rail; at 1× a click on it copies the block's code.
private struct CopyCodeWithPointer: Step {
    let zoom: CGFloat
    var label: String { "The code block's Copy in view at \(zoom)×" }
    var timeout: Duration? { .seconds(20) }

    func run(_ story: StoryContext) async throws {
        try await story.until("the code block on screen") { !CodeBlockCopyBelow.blocks().isEmpty }
        let id = CodeBlockCopyBelow.blocks()[0]
        let scroll = try PinchZoomNewLineHolds.scroll(story)
        guard let window = scroll.window else { throw StoryFailure.modelMissing("the transcript's window") }
        let clip = scroll.contentView
        let root = window.contentView?.superview ?? window.contentView
        let block = { @MainActor () -> CGRect? in StoryRegistry.entry(id)?.frame }
        let copy = { @MainActor () -> CGRect? in StoryRegistry.entry(id + ".copy")?.frame }
        let inView = { @MainActor (point: CGPoint) -> Bool in
            clip.convert(clip.bounds, to: nil).insetBy(dx: 10, dy: 10).contains(point)
        }
        // The pointer away first: no hover left from the step before.
        let visible = clip.convert(clip.bounds, to: nil)
        await story.input.movedFree(to: CGPoint(x: visible.minX + 4, y: visible.maxY - 4), in: window)
        try await story.idle()
        var frame = try await story.wait("the code block's frame") { block() }
        if abs(scroll.magnification - zoom) > 0.01 {
            let point = CGPoint(x: frame.minX + min(60, frame.width / 2), y: frame.midY)
            let local = clip.convert(point, from: nil)
            let at = CGPoint(x: (local.x - clip.bounds.minX) / clip.bounds.width, y: (local.y - clip.bounds.minY) / clip.bounds.height)
            try await PinchZoomNewLineHolds.pinch(story, scroll, at: at, amount: (zoom - scroll.magnification) / scroll.magnification)
            frame = try await story.wait("the code block's frame") { block() }
        }
        guard abs(scroll.magnification - zoom) < 0.01 else { throw StoryFailure.other("the pinch left \(scroll.magnification)×") }
        // Over the code itself, where a person would put the pointer.
        let shown = frame.intersection(clip.convert(clip.bounds, to: nil).insetBy(dx: 20, dy: 20))
        let over = CGPoint(x: shown.isNull ? frame.minX : shown.minX + min(40, shown.width / 2), y: frame.maxY - min(14, frame.height / 2))
        guard inView(over) else { throw StoryFailure.expectation("the code block at \(over) out of view at \(zoom)×") }
        await story.input.movedFree(to: over, in: window)
        // The pointer there (its stand-in: a storyline window's hover isn't the window server's).
        try await Press(.id(StoryID.Transcript.code(CodeBlockCopyBelow.path(id)).part(.hover))).run(story)
        try await story.idle()
        let button: CGRect
        do {
            button = try await story.wait("Copy under the code block", timeout: .seconds(3)) { copy() }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("no Copy under the code block at \(zoom)× with the pointer at \(Int(over.x)),\(Int(over.y)) (block \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)))")
        }
        let target = CGPoint(x: button.midX, y: button.midY)
        guard inView(target), root?.hitTest(target)?.isDescendant(of: scroll) == true else {
            throw StoryFailure.expectation("Copy at \(Int(target.x)),\(Int(target.y)) out of view or covered at \(zoom)× (by \(root?.hitTest(target).map { String(describing: type(of: $0)) } ?? "nothing"))")
        }
        // Clear of the message rail over the view's right edge.
        let railLeft = clip.convert(clip.bounds, to: nil).maxX - (26 + 12) // the rail's width and inset (Size.railWidth, railInset)
        guard button.maxX <= railLeft + 0.5 else {
            throw StoryFailure.expectation("Copy at \(Int(button.minX))–\(Int(button.maxX)) under the message rail (from \(Int(railLeft))) at \(zoom)×")
        }
        // A click where it's drawn: at the natural size (pinched in, a storyline window's press on
        // this row isn't routed as a person's is; the zoom's own storylines cover zoomed clicks).
        guard zoom == 1 else { return }
        if !window.isKeyWindow { window.makeKey() }
        StoryTranscript.clearCopied()
        await story.input.click(at: target, in: window)
        do {
            try await story.until("the block's code copied", timeout: .seconds(4)) {
                StoryTranscript.copied?.trimmingCharacters(in: .whitespacesAndNewlines) == PinchZoomCodeCopy.code
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("a click on Copy at \(zoom)×, drawn at \(Int(target.x)),\(Int(target.y)), copied \(StoryTranscript.copied.map { "“\($0)”" } ?? "nothing")")
        }
    }
}
