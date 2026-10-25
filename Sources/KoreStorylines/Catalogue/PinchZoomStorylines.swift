import AppKit
import Darwin
import KoreUI

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

/// Starts at the followed end, then keeps adding lines while fingers hold a pinch. Nothing
/// reveals or scrolls a row before beginning: the test retains the normal follow state.
final class PinchZoomWhileStreaming: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let answer = (1...150).map { "Paragraph \($0). More text arrives while the viewport stays still under the pinch. Following resumes after the gesture, without discarding any streamed words." }.joined(separator: "\n\n")
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .stream(.answer, answer, chunk: 8), .finishTurn(.completed)]])
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
            guard chat.isRunning,
                  let answer = chat.storyTranscript.entries.last(where: { $0.kind == .answer }), answer.text.count > 1500,
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
            try await Task.sleep(for: .milliseconds(8))
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
        try await ClickText(.answer(1, [3], at: PinchZoomGesture.paragraph(4), "optical"), count: 2).run(story)
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
