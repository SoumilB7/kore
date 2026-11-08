import AppKit
import Darwin
import KoreUI
import src

/// Native trackpad samples magnify only the active page, without changing its text layout.
/// Keep geometry, selection and tab-isolation evidence beside the timing measurements.
final class PinchZoomGesture: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static func paragraph(_ n: Int) -> String { "Paragraph \(n). An optical pinch keeps these words under the cursor while the existing page grows smoothly. Wrapping and font preferences stay unchanged, and selection still follows the visible text." }
    static let answer = (1...12).map { paragraph($0) }.joined(separator: "\n\n")
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(answer)]) }
    override func steps() -> [any Step] {
        super.steps() + [Send("Show some text"), TurnFinished(1), ExercisePinch(), Snapshot("pinch-finished")]
    }
}

/// Magnified at the chat's end by a pinch right of centre (the page moved to its right side),
/// the view stays put through the composer growing (three ⇧↩), its side and top as they were.
/// A send takes it to the end and the reply streams in: the end is pinned up and down only, the
/// page at its side and scale, and at the end.
final class PinchZoomKeepsSide: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let rest = (13...80).map { PinchZoomWhileStreaming.paragraph($0) }.joined(separator: "\n\n")
    override class var script: CLIScript {
        // Taller than the view unzoomed: a shorter one SwiftUI keeps at its top whatever the zoom.
        CLIScript(turns: [CLIScript.reply(PinchZoomNewLineHolds.answer), [.startTurn, .stream(.answer, rest, chunk: 8), .finishTurn(.completed)]])
    }
    override func steps() -> [any Step] {
        let newline = Key(KeyChord(.returnKey, .shift))
        return super.steps() + [
            Send("Show some text"), TurnFinished(1), WaitIdle(), WaitForFocus(.id(StoryID.Composer.field)),
            ZoomRightAtEnd(),
            newline, newline, newline,
            ExpectSideKept(streaming: false),
            Pace(240), Send("Keep writing"),
            ExpectSideKept(streaming: true),
        ]
    }

    /// The page's side, top, scale and visible height as the pinch left them.
    final class Noted { var side: CGFloat = 0, top: CGFloat = 0, scale: CGFloat = 1, height: CGFloat = 0 }

    /// The view's bottom within this of the content's end: at the end, as following counts it.
    static let atEnd: CGFloat = 50

    @MainActor static func distanceToEnd(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .infinity }
        return document.frame.height - scroll.contentView.bounds.maxY
    }
}

/// A pinch at the bottom right of the view, at the chat's end: magnified 1.5×, the page moved to
/// its right side, the bottom still at the end.
private struct ZoomRightAtEnd: Step {
    var label: String { "Pinch to 1.5× right of centre at the chat's end" }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        let scroll = try await story.wait("the transcript's scroll view") { chat.storyTranscript.scrollView }
        let clip = scroll.contentView
        // Past the send's glide (two seconds), and the new view's settling with it: either moves
        // the view by SwiftUI's own scroll, which a pinch this instant (a real one holds the page
        // through it) would have land on the magnified page.
        if let sent = chat.storyTranscript.sentAt {
            try await story.until("the send's glide over", timeout: .seconds(3)) { Date() >= sent + 2.05 }
        }
        // A reader's scroll to the end first: a scripted turn's glide can stop short of it.
        try await Scroll(.answer(turn: 1), to: .bottom).run(story)
        try await story.until("the transcript at its end") { PinchZoomKeepsSide.distanceToEnd(scroll) < 2 }
        try await PinchZoomNewLineHolds.pinch(story, scroll, at: CGPoint(x: 0.8, y: 0.99), amount: 0.5)
        let noted = story.stash(PinchZoomKeepsSide.Noted.self) { .init() }
        noted.side = clip.bounds.minX
        noted.top = clip.bounds.minY
        noted.scale = scroll.magnification
        noted.height = clip.frame.height
        guard abs(noted.scale - 1.5) < 0.01, noted.side > 1, PinchZoomKeepsSide.distanceToEnd(scroll) < PinchZoomKeepsSide.atEnd else {
            throw StoryFailure.other("the pinch left scale \(noted.scale), side \(noted.side), \(PinchZoomKeepsSide.distanceToEnd(scroll)) pt from the end")
        }
    }
}

/// The page at the side and scale the pinch left: after the composer grew (the view got shorter)
/// at its top too, or through each delta of a reply streaming in at the end.
private struct ExpectSideKept: Step {
    let streaming: Bool
    var label: String { "Expect the magnified page's side kept, \(streaming ? "at the end through a streamed reply" : "and its top, with the composer grown")" }
    // Up to the streamed reply's whole length, at its pace.
    var timeout: Duration? { .seconds(streaming ? 75 : 15) }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        guard let scroll = chat.storyTranscript.scrollView else { throw StoryFailure.modelMissing("the transcript's scroll view") }
        let noted = story.stash(PinchZoomKeepsSide.Noted.self) { .init() }
        let clip = scroll.contentView
        func check(_ when: String) throws {
            let side = clip.bounds.minX, scale = scroll.magnification
            guard abs(side - noted.side) <= 0.5, abs(scale - noted.scale) < 0.001 else {
                throw StoryFailure.expectation("\(when): the page at side \(noted.side), \(noted.scale)× (found side \(side), \(scale)×)")
            }
        }
        if streaming {
            defer { chat.storyStop() }
            let start = scroll.documentView?.frame.height ?? 0
            // Each delta that lands is looked at: the end pinned for it must not move the side.
            for n in 0..<60 {
                let seen = count(chat)
                try await story.until("more of the reply") { count(chat) > seen }
                try check("after delta \(n)")
            }
            // The reply streams at its pace (the clock's, which a busy Mac stretches): on until it's
            // past a screen, or over; past a screen and followed it must be, either way.
            let followed = {
                (scroll.documentView?.frame.height ?? 0) > start + clip.bounds.height
                    && PinchZoomKeepsSide.distanceToEnd(scroll) < PinchZoomKeepsSide.atEnd
            }
            try? await story.until("the reply past a screen, or over", timeout: .seconds(60)) { followed() || !chat.isRunning }
            guard followed() else {
                throw StoryFailure.expectation(
                    "the reply past a screen, still followed (the page \(Int(scroll.documentView?.frame.height ?? 0)) tall from \(Int(start)), a screen \(Int(clip.bounds.height)), \(Int(PinchZoomKeepsSide.distanceToEnd(scroll))) pt from the end, the reply \(count(chat)) characters, running \(chat.isRunning))")
            }
            try check("at the end")
        } else {
            try await story.until("the composer grown, the transcript shorter") { clip.frame.height < noted.height - 20 }
            try await story.idle()
            try check("with the composer grown")
            guard abs(clip.bounds.minY - noted.top) <= 1 else {
                throw StoryFailure.expectation("the page's top at \(noted.top) with the composer grown (found \(clip.bounds.minY))")
            }
        }
    }

    @MainActor private func count(_ chat: Chat) -> Int {
        chat.storyTranscript.entries.filter { $0.kind == .answer }.reduce(0) { $0 + $1.text.count }
    }
}

/// Starts at the followed end, then keeps adding lines while fingers hold a pinch. Nothing
/// reveals or scrolls a row before beginning: the test retains the normal follow state.
/// The first page lands in one delta, so a scrollable answer never waits on the paced rate.
final class PinchZoomWhileStreaming: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static func paragraph(_ n: Int) -> String { "Paragraph \(n). More text arrives while the viewport stays still under the pinch. Following resumes after the gesture, without discarding any streamed words." }
    static let page = (1...12).map { paragraph($0) + "\n\n" }.joined()
    static let rest = (13...150).map { paragraph($0) }.joined(separator: "\n\n")
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .stream(.answer, page, chunk: page.count), .stream(.answer, rest, chunk: 8), .finishTurn(.completed)]])
    }
    override func steps() -> [any Step] {
        super.steps() + [Pace(240), Send("Keep writing"), ExerciseStreamingPinch(), Snapshot("pinch-streaming-stopped")]
    }
}

private struct ExerciseStreamingPinch: Step {
    var label: String { "Hold the followed viewport during streaming, then resume following" }
    var timeout: Duration? { .seconds(20) }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        defer { chat.storyStop() }
        let (window, scroll) = try await story.wait("a scrollable answer still arriving") { () -> (NSWindow, NSScrollView)? in
            guard chat.isRunning, count(chat) > 1500,
                  let answer = chat.storyTranscript.entries.last(where: { $0.kind == .answer }),
                  let row = StoryElement(StoryID.Transcript.answer(answer.id)),
                  let scroll = row.registeredView?.enclosingScrollView, let document = scroll.documentView,
                  let window = scroll.window, document.bounds.height > scroll.contentView.bounds.height + 100
            else { return nil }
            let visible = scroll.documentVisibleRect
            let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            guard distance < 70 else { return nil }
            return (window, scroll)
        }
        let clip = scroll.contentView, document = scroll.documentView!
        let visible = scroll.documentVisibleRect
        let distanceToEnd = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
        guard distanceToEnd < 70 else { throw StoryFailure.other("the streaming chat was not following its end") }
        let point = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
        defer { _ = PinchZoom.storySample(in: window, amount: 0, phase: .cancelled, at: point) }
        let textBefore = count(chat)
        let globalScale = PinchZoom.storyScale()
        let pageScale = PinchZoom.storyPageScale(in: window)
        guard let before = PinchZoom.storyCounts(in: window),
              PinchZoom.storySample(in: window, amount: 0, phase: .began, at: point),
              PinchZoom.storySample(in: window, amount: 0.04, phase: .changed, at: point),
              let held = PinchZoom.storyOffset(in: window),
              let magnified = PinchZoom.storyPageScale(in: window), magnified > (pageScale ?? 1)
        else { throw StoryFailure.other("the streaming transcript did not take the pinch") }
        guard PinchZoom.storyCounts(in: window)?.freezes == before.freezes + 1 else {
            throw StoryFailure.other("the live transcript did not freeze its retained scroll target")
        }
        var largestDrift: CGFloat = 0
        for _ in 0..<120 {
            guard PinchZoom.storySample(in: window, amount: 0, phase: .changed, at: point) else {
                throw StoryFailure.other("streaming interrupted the pinch")
            }
            // Each held sample sees one more delta land, however fast the stream runs.
            let seen = count(chat)
            try await story.until("more text to stream in under the pinch") { count(chat) > seen }
            guard let offset = PinchZoom.storyOffset(in: window),
                  PinchZoom.storyScale() == globalScale,
                  PinchZoom.storyPageScale(in: window) == magnified
            else { throw StoryFailure.other("streaming changed the held page scale or global font size") }
            largestDrift = max(largestDrift, abs(offset.y - held.y))
            guard largestDrift < 1 else { throw StoryFailure.other("following moved the pinched viewport by \(largestDrift) points") }
        }
        let added = count(chat) - textBefore
        guard chat.isRunning, added > 8, PinchZoom.storyCounts(in: window)?.commits == before.commits,
              PinchZoom.storyCounts(in: window)?.previews == before.previews + 1 else {
            throw StoryFailure.other("text stopped arriving or a held pinch committed zoom")
        }
        guard PinchZoom.storySample(in: window, amount: 0, phase: .cancelled, at: point) else {
            throw StoryFailure.other("the streaming pinch did not cancel")
        }
        let released = clip.bounds.minY
        try await story.until("following resumes after releasing the pinch") { abs(clip.bounds.minY - released) > 1 }
        guard PinchZoom.storyCounts(in: window)?.commits == before.commits,
              PinchZoom.storyPageScale(in: window) == pageScale, PinchZoom.storyScale() == globalScale else {
            throw StoryFailure.other("cancelling a streaming pinch failed to restore its page or changed global font size")
        }
        chat.storyStop()
        try await story.until("the scripted stream stops") { !chat.isRunning }
        let corrections = (PinchZoom.storyCounts(in: window)?.corrections ?? before.corrections) - before.corrections
        let note = "\(story.name): samples=121 globalFontChanges=0 pageCommits=0 freezes=1 nativeCorrections=\(corrections) streamedChars=\(added) maxViewportDrift=\(String(format: "%.2f", largestDrift)) followingResumed=true\n"
        try note.write(to: story.outputs.appendingPathComponent(story.name + ".pinch-streaming.notes"), atomically: true, encoding: .utf8)
    }

    @MainActor private func count(_ chat: Chat) -> Int {
        chat.storyTranscript.entries.filter { $0.kind == .answer }.reduce(0) { $0 + $1.text.count }
    }
}

private struct ExercisePinch: Step {
    var label: String { "Magnify a page without reflow, scroll and copy, then check tab isolation" }
    var timeout: Duration? { .seconds(30) }

    func run(_ story: StoryContext) async throws {
        let spot = Spot(row: .answer(1), path: [3], offset: 40)
        let (window, point) = try await spot.point(story)
        defer { _ = PinchZoom.storySample(in: window, amount: 0, phase: .cancelled, at: point) }
        let entry = try spot.entry(story)
        let chat = try story.activeChat()
        let start = PinchZoom.storyScale()
        guard let row = StoryElement(StoryID.Transcript.answer(entry)),
              let scroll = row.registeredView?.enclosingScrollView, let document = scroll.documentView,
              let pageStart = PinchZoom.storyPageScale(in: window)
        else { throw StoryFailure.other("the transcript has no native page surface") }
        let layoutSize = document.bounds.size
        let offsets = [20, 80, 140]
        let geometry = try offsets.map { offset -> CGPoint in
            guard let point = chat.storyTranscript.textPoint(entry, [3], offset: offset) else {
                throw StoryFailure.other("the paragraph geometry is missing before magnification")
            }
            return point
        }
        // Identical pacing gives the process's idle cost beside the preview measurement.
        // These timers belong only to the benchmark; the app schedules no preview frames.
        let clock = ContinuousClock(), idleBegan = clock.now, idleCPU = cpuTime()
        for _ in 0..<120 { try await Task.sleep(for: .milliseconds(8)) }
        let idleCPUMs = (cpuTime() - idleCPU) * 1000
        let idleWallMs = milliseconds(idleBegan.duration(to: clock.now))
        guard let before = PinchZoom.storyCounts(in: window),
              PinchZoom.storySample(in: window, amount: 0, phase: .began, at: point)
        else { throw StoryFailure.other("the window did not route a pinch to its transcript") }
        let began = clock.now, cpu = cpuTime()
        for _ in 0..<120 {
            guard PinchZoom.storySample(in: window, amount: 0.002, phase: .changed, at: point),
                  PinchZoom.storyScale() == start else {
                throw StoryFailure.other("a page preview changed global font size or lost its target")
            }
            // Test pacing only: production has no frame timer or scheduled preview work.
            try await Task.sleep(for: .milliseconds(8))
        }
        let cpuMs = (cpuTime() - cpu) * 1000
        let wallMs = milliseconds(began.duration(to: clock.now))
        guard let preview = PinchZoom.storyCounts(in: window), preview.commits == before.commits,
              preview.previews - before.previews == 120 else { throw StoryFailure.other("page previews finished early or skipped native magnification") }
        // Where the last sample left the view: releasing the fingers must not move it.
        let lastSample = scroll.contentView.bounds.origin
        guard PinchZoom.storySample(in: window, amount: 0, phase: .ended, at: point) else {
            throw StoryFailure.other("the pinch did not finish")
        }
        try await story.until("the native page magnification to finish") { PinchZoom.storyPlacement(in: window) != nil }
        try await story.idle()
        guard let after = PinchZoom.storyCounts(in: window), after.commits == before.commits + 1,
              let placement = PinchZoom.storyPlacement(in: window),
              let kept = chat.storyTranscript.textPoint(entry, [3], offset: 40),
              let committed = PinchZoom.storyPageScale(in: window), committed > pageStart + 0.1,
              PinchZoom.storyScale() == start
        else { throw StoryFailure.other("native magnification was lost or changed the global font size") }
        // A few more passes: a target held from the pinch's start would land by then.
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        let released = scroll.contentView.bounds.origin
        guard abs(released.y - lastSample.y) < 1, abs(released.x - lastSample.x) < 1 else {
            throw StoryFailure.other("releasing the pinch moved the view: \(lastSample) → \(released)")
        }
        guard abs(document.bounds.width - layoutSize.width) < 1, abs(document.bounds.height - layoutSize.height) < 1 else {
            throw StoryFailure.other("optical magnification reflowed the document: \(layoutSize) → \(document.bounds.size)")
        }
        let ratio = committed / pageStart
        let enlarged = try offsets.map { offset -> CGPoint in
            guard let point = chat.storyTranscript.textPoint(entry, [3], offset: offset) else {
                throw StoryFailure.other("the magnified paragraph geometry is missing")
            }
            return point
        }
        for n in 1..<geometry.count {
            let before = CGPoint(x: geometry[n].x - geometry[0].x, y: geometry[n].y - geometry[0].y)
            let after = CGPoint(x: enlarged[n].x - enlarged[0].x, y: enlarged[n].y - enlarged[0].y)
            guard hypot(after.x - before.x * ratio, after.y - before.y * ratio) < 3 else {
                throw StoryFailure.other("magnification changed line wrapping instead of scaling the existing glyph positions")
            }
        }
        let dx = kept.x - point.x, dy = kept.y - point.y
        let residual = hypot(dx - placement.unavoidableDrift.dx, dy - placement.unavoidableDrift.dy)
        // Independently constrain the ideal cursor-preserving origin. At document edges,
        // compare with the nearest legal viewport rather than requiring impossible scroll.
        let ideal = CGRect(origin: placement.desiredOrigin, size: scroll.contentView.bounds.size)
        let feasible = scroll.contentView.constrainBoundsRect(ideal).origin
        let nativeResidual = hypot(placement.actualOrigin.x - feasible.x, placement.actualOrigin.y - feasible.y)
        guard residual < 4, nativeResidual < 1 else {
            throw StoryFailure.other("the pinch missed its nearest feasible anchor: dx=\(dx),dy=\(dy), expected=\(placement.unavoidableDrift), residual=\(residual), nativeResidual=\(nativeResidual)")
        }
        guard PinchZoom.storySample(in: window, amount: 0.03, phase: .began, at: kept),
              PinchZoom.storySample(in: window, amount: 0, phase: .cancelled, at: kept),
              PinchZoom.storyPageScale(in: window) == committed, PinchZoom.storyScale() == start,
              PinchZoom.storyCounts(in: window)?.commits == after.commits
        else { throw StoryFailure.other("cancelling a pinch failed to restore its page scale") }
        // Native scrolling and pointer selection must use the magnified coordinates.
        let scrollBefore = scroll.contentView.bounds.origin
        try await Scroll(.answer(turn: 1), to: .by(80)).run(story)
        guard abs(scroll.contentView.bounds.minY - scrollBefore.y) > 1,
              PinchZoom.storyPageScale(in: window) == committed else {
            throw StoryFailure.other("the magnified page did not scroll independently of its scale")
        }
        // Well below the top: scrolled, the message's pinned copy covers the first paragraphs.
        try await ClickText(.answer(1, [7], at: PinchZoomGesture.paragraph(8), "optical"), count: 2).run(story)
        try await CopySelection("optical").run(story)
        guard let workspace = story.app.workspace,
              let originalIndex = workspace.tabs.firstIndex(where: { $0.id == workspace.activeTab.id }) else {
            throw StoryFailure.other("the magnified tab is missing")
        }
        try await StartChat().run(story)
        try await Send("An independent page").run(story)
        try await TurnFinished(1).run(story)
        try await story.idle()
        guard let otherIndex = workspace.tabs.firstIndex(where: { $0.id == workspace.activeTab.id }),
              otherIndex != originalIndex, PinchZoom.storyPageScale(in: window) == 1,
              PinchZoom.storyScale() == start else {
            throw StoryFailure.other("page magnification leaked into another tab or global font preferences")
        }
        workspace.storySelect(tabAt: originalIndex)
        try await story.until("the original tab restores its own magnification") {
            PinchZoom.storyPageScale(in: window) == committed && story.app.chat === chat
        }
        try await story.idle()
        try await story.until("the restored transcript actually paints at its committed native magnification") {
            guard let activeRow = StoryElement(StoryID.Transcript.answer(entry)),
                  let activeScroll = activeRow.registeredView?.enclosingScrollView,
                  activeScroll.window === window, let activeDocument = activeScroll.documentView else { return false }
            return abs(activeScroll.magnification - committed) < 0.001 &&
                abs(activeDocument.bounds.width - layoutSize.width) < 1 &&
                abs(activeDocument.bounds.height - layoutSize.height) < 1
        }
        let (restoredWindow, restoredPoint) = try await spot.point(story)
        let otherChat = workspace.tabs[otherIndex].chat
        guard PinchZoom.storySample(in: restoredWindow, amount: 0.08, phase: .began, at: restoredPoint) else {
            throw StoryFailure.other("the restored page did not start another pinch")
        }
        let cancelledBeforeSwitch = PinchZoom.storyCounts(in: restoredWindow)?.cancellations ?? 0
        workspace.storySelect(tabAt: otherIndex)
        var switchState = ""
        do {
        try await story.until("switching tabs cancels the unfinished pinch") {
            // Rows can be unregistered while a retained tab hides. Inspect the native
            // surfaces themselves: leaving this page must reset every mounted scroll view.
            let scales = nativeScales(window.contentView)
            switchState = "native=\(scales), page=\(String(describing: PinchZoom.storyPageScale(in: window))), cancellations=\(PinchZoom.storyCounts(in: window)?.cancellations ?? -1), expected=\(cancelledBeforeSwitch + 1), activeChatMatches=\(story.app.chat === otherChat)"
            return story.app.chat === otherChat && !scales.isEmpty && scales.allSatisfy({ abs($0 - 1) < 0.001 }) &&
                PinchZoom.storyPageScale(in: window) == 1 &&
                (PinchZoom.storyCounts(in: window)?.cancellations ?? 0) == cancelledBeforeSwitch + 1
        }
        } catch {
            throw StoryFailure.other("tab switch did not finish cancelling the pinch: " + switchState)
        }
        guard PinchZoom.storyCounts(in: window)?.commits == after.commits, PinchZoom.storyScale() == start else {
            throw StoryFailure.other("switching away from a pinch committed it or changed global font preferences")
        }
        workspace.storySelect(tabAt: originalIndex)
        try await story.until("switch cancellation preserves the original committed page factor") {
            PinchZoom.storyPageScale(in: window) == committed && story.app.chat === chat
        }
        let note = "\(story.name): samples=120 previews=120 pageCommits=1 globalFontChanges=0 reflow=false zoomedCopy=true tabIsolation=true switchCancelled=true idleCpuMs=\(String(format: "%.2f", idleCPUMs)) idleWallMs=\(String(format: "%.2f", idleWallMs)) cpuMs=\(String(format: "%.2f", cpuMs)) wallMs=\(String(format: "%.2f", wallMs)) anchorDx=\(String(format: "%.2f", dx)) anchorDy=\(String(format: "%.2f", dy)) horizontalClamped=\(placement.horizontalClamped) anchorResidual=\(String(format: "%.2f", residual))\n"
        try note.write(to: story.outputs.appendingPathComponent(story.name + ".pinch.notes"), atomically: true, encoding: .utf8)
    }

    @MainActor private func nativeScales(_ root: NSView?) -> [CGFloat] {
        guard let root else { return [] }
        let own = (root as? NSScrollView).map { [$0.magnification] } ?? []
        return own + root.subviews.flatMap { nativeScales($0) }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func cpuTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }
}

/// A code file and a Markdown file, each in its tab and scrolled down, pinched as the transcript
/// is: out first (no smaller than ⌘+ / ⌘− set), then in, and let go where the last sample left
/// the view. The page scrolls on after, at its new size.
final class FilePreviewPinch: ChatStoryline {
    override class var tags: Set<Tag> { [.files] }

    override func steps() -> [any Step] {
        [WriteFiles([FileTabState.files[1], FileTabState.files[2]])] + super.steps()
            + FileTabState.open(FileTabState.code) + [
                Expect.editor("the code in the editor") { $0.path == FileTabState.code },
                Scroll(.editor, to: .by(2000)),
                PinchFile(target: .editor, name: "the editor"),
            ]
            + FileTabState.open(FileTabState.notes) + [
                Expect("the notes in the Markdown renderer") { $0.app.workspace?.storyActiveRenderer == "markdown" },
                Scroll(.id(StoryID.Editor.rows), to: .by(2400)),
                PinchFile(target: .id(StoryID.Editor.rows), name: "the Markdown"),
            ]
    }
}

private struct PinchFile: Step {
    let target: Locator
    let name: String
    var label: String { "Pinch \(name) out and in, let go, and scroll on" }
    var timeout: Duration? { .seconds(20) }

    func run(_ story: StoryContext) async throws {
        let element = try await story.element(target)
        guard let view = element.registeredView, let scroll = view.enclosingScrollView,
              let window = scroll.window, let document = scroll.documentView
        else { throw StoryFailure.other("\(name) has no native scroll view") }
        // A file just opened takes the keys a frame after it shows (the Markdown preview's
        // responder once it's attached), and a pinch lets go when the keys move. Wait for them.
        try await story.until("\(name) to have the keys") {
            (window.firstResponder as? NSView)?.enclosingScrollView === scroll
        }
        let clip = scroll.contentView
        let point = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
        defer { _ = PinchZoom.storySample(in: window, amount: 0, phase: .cancelled, at: point) }
        let start = PinchZoom.storyScale()
        let pageStart = PinchZoom.storyPageScale(in: window) ?? 1
        // The width text lays out in: an unwrapped editor's view widens to the magnified clip,
        // its container stays as it was.
        let layoutWidth = { (document as? NSTextView)?.textContainer?.size.width ?? document.bounds.width }
        let width = layoutWidth()
        guard PinchZoom.storySample(in: window, amount: 0, phase: .began, at: point) else {
            throw StoryFailure.other("\(name) did not take the pinch")
        }
        // Paced as a trackpad's samples, with SwiftUI's updates landing in between.
        for _ in 0..<10 {
            _ = PinchZoom.storySample(in: window, amount: -0.05, phase: .changed, at: point)
            try await Task.sleep(for: .milliseconds(8))
        }
        guard let out = PinchZoom.storyPageScale(in: window), out >= pageStart - 0.001, PinchZoom.storyScale() == start else {
            throw StoryFailure.other("pinching \(name) out went below the ⌘ scale")
        }
        for _ in 0..<20 {
            _ = PinchZoom.storySample(in: window, amount: 0.02, phase: .changed, at: point)
            try await Task.sleep(for: .milliseconds(8))
        }
        guard let magnified = PinchZoom.storyPageScale(in: window), magnified > pageStart + 0.1 else {
            throw StoryFailure.other("pinching \(name) in did not magnify it")
        }
        let lastSample = clip.bounds.origin
        guard PinchZoom.storySample(in: window, amount: 0, phase: .ended, at: point) else {
            throw StoryFailure.other("the pinch on \(name) did not finish")
        }
        try await story.until("the pinch on \(name) to finish") { PinchZoom.storyPlacement(in: window) != nil }
        try await story.idle()
        // A few more passes: a target held from the pinch's start would land by then.
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        let released = clip.bounds.origin
        guard abs(released.y - lastSample.y) < 1, abs(released.x - lastSample.x) < 1 else {
            throw StoryFailure.other("releasing the pinch moved \(name): \(lastSample) → \(released)")
        }
        guard let committed = PinchZoom.storyPageScale(in: window), abs(committed - magnified) < 0.001,
              PinchZoom.storyScale() == start, abs(layoutWidth() - width) < 1
        else {
            throw StoryFailure.other("\(name) lost its magnification (\(magnified) → \(String(describing: PinchZoom.storyPageScale(in: window)))), reflowed (\(width) → \(layoutWidth())) or changed the ⌘ scale")
        }
        let before = clip.bounds.minY
        try await Wheel(target, by: 200).run(story)
        try await story.until("\(name) to scroll at its new size") { abs(clip.bounds.minY - before) > 1 }
        guard PinchZoom.storyPageScale(in: window) == committed else {
            throw StoryFailure.other("scrolling \(name) changed its magnification")
        }
    }
}

/// The message pinned at the top keeps its size through a pinch, the page under it growing; let
/// back down, it's the page's own again.
final class PinchLeavesStickyMessage: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(PinchZoomGesture.answer + "\n\n" + PinchZoomGesture.answer)]) }
    override func steps() -> [any Step] {
        super.steps() + [Send("Show some text"), TurnFinished(1), Exercise(), Snapshot("pinch-sticky")]
    }

    private struct Exercise: Step {
        var label: String { "Pinch with a message pinned at the top" }
        var timeout: Duration? { .seconds(15) }

        func run(_ story: StoryContext) async throws {
            let chat = try story.activeChat()
            guard let message = chat.storyTranscript.entries.first(where: { $0.kind == .user }) else { throw StoryFailure.modelMissing("the message") }
            let id = StoryID.Transcript.pinned(message.id)
            let before = try await story.wait("the message pinned") { story.window.flatMap { StoryElement(id, in: $0)?.frame } }
            guard let window = story.window, let scroll = chat.storyTranscript.scrollView else { throw StoryFailure.modelMissing("the transcript") }
            // A copy where it was, its size: the one in the page, hidden, goes by the same name.
            func held() -> Bool {
                return StoryRegistry.entries(id.raw, in: window).contains { entry in
                    entry.frame.map { abs($0.height - before.height) < 1 && abs($0.maxY - before.maxY) < 2 && abs($0.minX - before.minX) < 2 } ?? false
                }
            }
            let clip = scroll.contentView
            let point = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
            defer { _ = PinchZoom.storySample(in: window, amount: 0, phase: .cancelled, at: point) }
            guard PinchZoom.storySample(in: window, amount: 0, phase: .began, at: point),
                PinchZoom.storySample(in: window, amount: 0.5, phase: .changed, at: point),
                let scale = PinchZoom.storyPageScale(in: window), scale > 1.2
            else { throw StoryFailure.other("the transcript did not take the pinch") }
            try await story.until("the pinned message its own size, at the top, on a page \(scale)×", timeout: .seconds(3)) { held() }
            // It stays through a pinch that goes on: there every time it's looked at.
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(25))
                guard held() else { throw StoryFailure.other("the pinned message left or grew") }
            }
            try await Snapshot("pinch-sticky-held").run(story)
            _ = PinchZoom.storySample(in: window, amount: 0, phase: .ended, at: point)
            try await story.until("still its size with the fingers up", timeout: .seconds(2)) { held() }
        }
    }
}

/// Zoomed in at a spot above the chat's end, the composer growing a line at a time (three ⇧↩)
/// or shrinking again leaves the zoomed view where it was: its scale, and its top-left corner in
/// the content. The view only gets shorter or taller at the bottom. So too a little above the
/// end, where the end is followed. Return then sends, and the view goes to the end at once,
/// keeping its side. Unzoomed at the end, the composer growing keeps the end in view.
final class PinchZoomNewLineHolds: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let answer = (1...30).map { PinchZoomGesture.paragraph($0) }.joined(separator: "\n\n")
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply(answer), CLIScript.reply(PinchZoomGesture.answer)]) }
    override func steps() -> [any Step] {
        let grow = [Key(KeyChord(.returnKey, .shift)), Key(KeyChord(.returnKey, .shift)), Key(KeyChord(.returnKey, .shift))]
        let shrink = [Key(KeyChord(.backspace)), Key(KeyChord(.backspace)), Key(KeyChord(.backspace))]
        return super.steps() + [Send("Show some text"), TurnFinished(1), WaitIdle(), WaitForFocus(.id(StoryID.Composer.field)), ZoomAboveEnd()]
            + grow + [ExpectZoomedViewKept(grown: true)] + shrink + [ExpectZoomedViewKept(grown: false), NearEnd()]
            + grow + [ExpectZoomedViewKept(grown: true), TypeText("Next"), Key(.returnKey), ExpectSendAtEnd(), TurnFinished(2), WaitIdle(), UnzoomAtEnd()]
            + grow + [ExpectEndHeld()]
    }

    /// The zoomed view as last noted, and how far anything moved it since.
    @MainActor final class Noted: StoryFinishing {
        var origin = CGPoint.zero, scale: CGFloat = 1, height: CGFloat = 0
        var drift: CGFloat = 0
        private var watcher: CFRunLoopObserver?

        /// Where the view is now; from here on, wherever it's drawn counts: it's looked at as
        /// each pass of the run loop ends, after the pass's layout and before its frame shows.
        /// (AppKit can move it and back within one call, as SwiftUI resolves its insets for a
        /// new height: never drawn, so not counted.)
        func note(_ scroll: NSScrollView) {
            let clip = scroll.contentView
            origin = clip.bounds.origin
            scale = scroll.magnification
            height = clip.frame.height
            drift = 0
            finish()
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max - 1) { [weak self, weak clip] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let clip else { return }
                    self.drift = max(self.drift, hypot(clip.bounds.minX - self.origin.x, clip.bounds.minY - self.origin.y))
                }
            }
            watcher = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        func finish() {
            if let watcher { CFRunLoopRemoveObserver(CFRunLoopGetMain(), watcher, .commonModes) }
            watcher = nil
        }
    }

    @MainActor static func distanceToEnd(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .infinity }
        return document.frame.height - scroll.contentView.bounds.maxY
    }

    /// A pinch on the transcript at `at` (a fraction of the view across and down) by `amount`,
    /// over a few frames as fingers go.
    @MainActor static func pinch(_ story: StoryContext, _ scroll: NSScrollView, at: CGPoint, amount: CGFloat) async throws {
        guard let window = scroll.window else { throw StoryFailure.modelMissing("the transcript's window") }
        let clip = scroll.contentView
        let point = clip.convert(CGPoint(x: clip.bounds.minX + clip.bounds.width * at.x, y: clip.bounds.minY + clip.bounds.height * at.y), to: nil)
        let before = PinchZoom.storyCounts(in: window)?.commits ?? 0
        guard PinchZoom.storySample(in: window, amount: 0, phase: .began, at: point) else { throw StoryFailure.other("the transcript did not take the pinch") }
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(16))
            guard PinchZoom.storySample(in: window, amount: amount / 6, phase: .changed, at: point) else { throw StoryFailure.other("the pinch was cut off") }
        }
        try await Task.sleep(for: .milliseconds(16))
        guard PinchZoom.storySample(in: window, amount: 0, phase: .ended, at: point) else { throw StoryFailure.other("the pinch did not end") }
        try await story.until("the pinch to finish") { (PinchZoom.storyCounts(in: window)?.commits ?? 0) > before }
        try await story.idle()
        // A few more passes: whatever the pinch's end sets off lands by then.
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor static func scroll(_ story: StoryContext) throws -> NSScrollView {
        guard let scroll = try story.activeChat().storyTranscript.scrollView else { throw StoryFailure.modelMissing("the transcript's scroll view") }
        return scroll
    }
}

/// At the end, a reader's scroll 900 pt up, then a pinch to 1.5× right of centre and above the
/// middle: the view away from the content's sides and its end, which isn't followed.
private struct ZoomAboveEnd: Step {
    var label: String { "Pinch to 1.5× at a spot well above the chat's end" }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        let scroll = try await story.wait("the transcript's scroll view") { chat.storyTranscript.scrollView }
        // Past the send's glide (two seconds): it moves the view by SwiftUI's own scroll.
        if let sent = chat.storyTranscript.sentAt {
            try await story.until("the send's glide over", timeout: .seconds(3)) { Date() >= sent + 2.05 }
        }
        // A reader's scroll to the end first: a scripted turn's glide can stop short of it.
        try await Scroll(.answer(turn: 1), to: .bottom).run(story)
        try await Scroll(.answer(turn: 1), to: .by(-900)).run(story)
        try await story.idle()
        try await PinchZoomNewLineHolds.pinch(story, scroll, at: CGPoint(x: 0.75, y: 0.35), amount: 0.5)
        let noted = story.stash(PinchZoomNewLineHolds.Noted.self) { .init() }
        noted.note(scroll)
        guard abs(noted.scale - 1.5) < 0.01, noted.origin.x > 1, PinchZoomNewLineHolds.distanceToEnd(scroll) > 400 else {
            throw StoryFailure.other("the pinch left scale \(noted.scale), origin \(noted.origin), \(PinchZoomNewLineHolds.distanceToEnd(scroll)) pt from the end")
        }
    }
}

/// Still zoomed: a reader's scroll to the end and 100 pt back up, a spot where the end is
/// followed.
private struct NearEnd: Step {
    var label: String { "Scroll the zoomed view to 100 pt above the end" }

    func run(_ story: StoryContext) async throws {
        let scroll = try PinchZoomNewLineHolds.scroll(story)
        try await Scroll(.answer(turn: 1), to: .bottom).run(story)
        try await Scroll(.answer(turn: 1), to: .by(-100)).run(story)
        try await story.idle()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        let noted = story.stash(PinchZoomNewLineHolds.Noted.self) { .init() }
        noted.note(scroll)
        let distance = PinchZoomNewLineHolds.distanceToEnd(scroll)
        guard abs(noted.scale - 1.5) < 0.01, noted.origin.x > 1, distance > 50, distance < 150 else {
            throw StoryFailure.other("the zoomed view at scale \(noted.scale), origin \(noted.origin), \(distance) pt from the end")
        }
    }
}

/// The composer grown (the view shorter) or shrunk (taller): the zoomed view's scale and
/// top-left corner as noted, and never more than a point from there meanwhile.
private struct ExpectZoomedViewKept: Step {
    let grown: Bool
    var label: String { "Expect the zoomed view's scale and top-left corner kept with the composer \(grown ? "grown" : "shrunk")" }

    func run(_ story: StoryContext) async throws {
        let scroll = try PinchZoomNewLineHolds.scroll(story)
        let noted = story.stash(PinchZoomNewLineHolds.Noted.self) { .init() }
        let clip = scroll.contentView
        try await story.until("the composer \(grown ? "grown, the transcript shorter" : "shrunk, the transcript taller")") {
            grown ? clip.frame.height < noted.height - 20 : clip.frame.height > noted.height + 20
        }
        try await story.idle()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        let origin = clip.bounds.origin, scale = scroll.magnification
        let moved = hypot(origin.x - noted.origin.x, origin.y - noted.origin.y)
        let line = "\(story.name) \(grown ? "grown" : "shrunk"): scale \(noted.scale)→\(scale), origin \(noted.origin)→\(origin), moved \(String(format: "%.2f", moved)), most \(String(format: "%.2f", noted.drift)), view \(noted.height)→\(clip.frame.height)\n"
        let url = story.outputs.appendingPathComponent(story.name + ".zoom-newline.notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
        guard abs(scale - noted.scale) < 0.001, moved <= 1, noted.drift <= 1 else {
            throw StoryFailure.expectation("the zoomed view at \(noted.origin), \(noted.scale)× (found \(origin), \(scale)×; moved up to \(noted.drift) pt)")
        }
        noted.note(scroll)
    }
}

/// Return sent the message: the view goes to the end at once, at the zoomed scale and side.
private struct ExpectSendAtEnd: Step {
    var label: String { "Expect Return to send and take the view to the end" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        let scroll = try PinchZoomNewLineHolds.scroll(story)
        try await story.until("the message sent") { chat.storyTranscript.entries.filter { $0.kind == .user }.count == 2 }
        let noted = story.stash(PinchZoomNewLineHolds.Noted.self) { .init() }
        noted.finish()
        try await story.until("the view at the end", timeout: .seconds(1)) { PinchZoomNewLineHolds.distanceToEnd(scroll) < 2 }
        let clip = scroll.contentView
        guard abs(scroll.magnification - noted.scale) < 0.001, abs(clip.bounds.minX - noted.origin.x) <= 1 else {
            throw StoryFailure.expectation("still \(noted.scale)× at side \(noted.origin.x) after the send (found \(scroll.magnification)× at \(clip.bounds.minX))")
        }
    }
}

/// A pinch back to the natural size at the bottom of the view, then the view at the end.
private struct UnzoomAtEnd: Step {
    var label: String { "Pinch back to the natural size at the end" }

    func run(_ story: StoryContext) async throws {
        let scroll = try PinchZoomNewLineHolds.scroll(story)
        try await PinchZoomNewLineHolds.pinch(story, scroll, at: CGPoint(x: 0.5, y: 0.98), amount: -1)
        guard scroll.magnification < 1.001 else { throw StoryFailure.other("the pinch left \(scroll.magnification)×") }
        try await Scroll(.answer(turn: 2), to: .bottom).run(story)
        try await story.idle()
        try await story.until("the transcript at its end") { PinchZoomNewLineHolds.distanceToEnd(scroll) < 2 }
        story.stash(PinchZoomNewLineHolds.Noted.self) { .init() }.height = scroll.contentView.frame.height
    }
}

/// Unzoomed, the composer grown: the view still at the end.
private struct ExpectEndHeld: Step {
    var label: String { "Expect the end held with the composer grown" }

    func run(_ story: StoryContext) async throws {
        let scroll = try PinchZoomNewLineHolds.scroll(story)
        let noted = story.stash(PinchZoomNewLineHolds.Noted.self) { .init() }
        let clip = scroll.contentView
        try await story.until("the composer grown, the transcript shorter") { clip.frame.height < noted.height - 20 }
        try await story.idle()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        let distance = PinchZoomNewLineHolds.distanceToEnd(scroll)
        guard distance < 2 else { throw StoryFailure.expectation("the view at the end (found \(distance) pt above it)") }
    }
}
