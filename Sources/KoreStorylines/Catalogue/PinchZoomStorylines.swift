import AppKit
import Darwin
import KoreUI

/// Phased trackpad samples travel through the real window target/preview/commit path. The
/// run writes measured CPU/wall times and semantic-update counts beside its snapshots.
final class PinchZoomGesture: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let answer = (1...12).map { "Paragraph \($0). A pinch keeps these words under the cursor while the rendered surface scales smoothly. A finished gesture lays out this text once at the chosen size." }.joined(separator: "\n\n")
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
        guard let before = PinchZoom.storyCounts(in: window),
              PinchZoom.storySample(in: window, amount: 0, phase: .began, at: point),
              let held = PinchZoom.storyOffset(in: window)
        else { throw StoryFailure.other("the streaming transcript did not take the pinch") }
        var largestDrift: CGFloat = 0
        for _ in 0..<120 {
            guard PinchZoom.storySample(in: window, amount: 0.0002, phase: .changed, at: point) else {
                throw StoryFailure.other("streaming interrupted the pinch")
            }
            try await Task.sleep(for: .milliseconds(8))
            guard let offset = PinchZoom.storyOffset(in: window) else { throw StoryFailure.other("the pinch lost its viewport") }
            largestDrift = max(largestDrift, abs(offset.y - held.y))
            guard largestDrift < 1 else { throw StoryFailure.other("following moved the pinched viewport by \(largestDrift) points") }
        }
        let added = count(chat) - textBefore
        guard chat.isRunning, added > 8, PinchZoom.storyCounts(in: window)?.commits == before.commits else {
            throw StoryFailure.other("text stopped arriving or a preview committed semantic zoom")
        }
        guard PinchZoom.storySample(in: window, amount: 0, phase: .cancelled, at: point) else {
            throw StoryFailure.other("the streaming pinch did not cancel")
        }
        let released = clip.bounds.minY
        try await story.until("following resumes after releasing the pinch") { abs(clip.bounds.minY - released) > 1 }
        guard PinchZoom.storyCounts(in: window)?.commits == before.commits else {
            throw StoryFailure.other("cancelling a streaming pinch committed zoom")
        }
        chat.storyStop()
        try await story.until("the scripted stream stops") { !chat.isRunning }
        let note = "\(story.name): samples=120 semantic=0 streamedChars=\(added) maxViewportDrift=\(String(format: "%.2f", largestDrift)) followingResumed=true\n"
        try note.write(to: story.outputs.appendingPathComponent(story.name + ".pinch-streaming.notes"), atomically: true, encoding: .utf8)
    }

    @MainActor private func count(_ chat: Chat) -> Int {
        chat.storyTranscript.entries.filter { $0.kind == .answer }.reduce(0) { $0 + $1.text.count }
    }
}

@MainActor private final class RestorePinchScale: StoryFinishing {
    let original = PinchZoom.storyScale()
    func finish() { PinchZoom.storyRestoreScale(original) }
}

private struct ExercisePinch: Step {
    var label: String { "Pinch 120 frames, commit once, preserve text, then cancel" }
    var timeout: Duration? { .seconds(20) }

    func run(_ story: StoryContext) async throws {
        _ = story.stash(RestorePinchScale.self) { RestorePinchScale() }
        let spot = Spot(row: .answer(1), path: [3], offset: 40)
        let (window, point) = try await spot.point(story)
        let entry = try spot.entry(story)
        let start = PinchZoom.storyScale()
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
            guard PinchZoom.storySample(in: window, amount: 0.0005, phase: .changed, at: point),
                  PinchZoom.storyScale() == start else {
                throw StoryFailure.other("a preview changed semantic zoom or lost its target")
            }
            // Test pacing only: production has no frame timer or scheduled preview work.
            try await Task.sleep(for: .milliseconds(8))
        }
        let cpuMs = (cpuTime() - cpu) * 1000
        let wallMs = milliseconds(began.duration(to: clock.now))
        guard let preview = PinchZoom.storyCounts(in: window), preview.commits == before.commits,
              preview.previews - before.previews == 120 else { throw StoryFailure.other("pinch previews caused semantic updates") }
        guard PinchZoom.storySample(in: window, amount: 0, phase: .ended, at: point) else {
            throw StoryFailure.other("the pinch did not finish")
        }
        try await story.until("pinch anchor layout to finish") { PinchZoom.storyPlacement(in: window) != nil }
        try await story.idle()
        guard let after = PinchZoom.storyCounts(in: window), after.commits == before.commits + 1,
              let placement = PinchZoom.storyPlacement(in: window),
              let kept = story.app.chat?.storyTranscript.textPoint(entry, [3], offset: 40)
        else { throw StoryFailure.other("the final font commit or its text anchor was lost") }
        let dx = kept.x - point.x, dy = kept.y - point.y
        let residual = hypot(dx - placement.unavoidableDrift.dx, dy - placement.unavoidableDrift.dy)
        guard residual < 4, abs(dy) < 4 else {
            throw StoryFailure.other("the pinch missed its nearest feasible anchor: dx=\(dx),dy=\(dy), expected=\(placement.unavoidableDrift), residual=\(residual)")
        }
        let committed = PinchZoom.storyScale()
        guard PinchZoom.storySample(in: window, amount: 0.03, phase: .began, at: kept),
              PinchZoom.storySample(in: window, amount: 0, phase: .cancelled, at: kept),
              PinchZoom.storyScale() == committed,
              PinchZoom.storyCounts(in: window)?.commits == after.commits
        else { throw StoryFailure.other("cancelling a pinch committed a font change") }
        let note = "\(story.name): samples=120 previews=120 semantic=1 cancelledSemantic=0 idleCpuMs=\(String(format: "%.2f", idleCPUMs)) idleWallMs=\(String(format: "%.2f", idleWallMs)) cpuMs=\(String(format: "%.2f", cpuMs)) wallMs=\(String(format: "%.2f", wallMs)) anchorDx=\(String(format: "%.2f", dx)) anchorDy=\(String(format: "%.2f", dy)) horizontalClamped=\(placement.horizontalClamped) anchorResidual=\(String(format: "%.2f", residual))\n"
        try note.write(to: story.outputs.appendingPathComponent(story.name + ".pinch.notes"), atomically: true, encoding: .utf8)
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
