import AppKit
import KoreUI

/// The window narrowed and widened again a step at a time, as a drag of its edge or the explorer's
/// sash goes, while the transcript's rows wrap anew: a reader scrolled up keeps the row at the top
/// of the view where it was on screen at every step. The drift at each step goes to
/// `resize.notes` in the run's folder.
final class TranscriptHoldsOnResize: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: (1...4).map { turn in [.startTurn, .stream(.answer, NavCost.answer(1, turn: turn), chunk: 4000), .finishTurn(.completed)] })
    }

    static let widths: [CGFloat] = [900, 800, 700, 640, 580, 520, 580, 700, 820, 1000]

    static func chat() -> [any Step] {
        (1...4).flatMap { turn -> [any Step] in [Send("turn \(turn)"), TurnFinished(turn)] } + [WaitIdle()]
    }

    override func steps() -> [any Step] {
        // Deep in answer 2 (its top 1500 pt above the view), then its top a little below the top
        // of the view, its message's tail above it; then the steps run together into one layout,
        // and spread out past the hold, as a slow Mac lays them out.
        let answer = Locator.answer(turn: 2)
        return super.steps() + Self.chat() + [
            ResizeHolds(row: answer, at: -1500), ResizeHolds(row: answer),
            ResizeHolds(row: answer, at: -1500, pause: .zero), ResizeHolds(row: answer, at: -1500, pause: .milliseconds(1300)),
        ]
    }
}

/// The same at the end: the view stays at the end at every step.
final class TranscriptEndHoldsOnResize: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { TranscriptHoldsOnResize.script }

    override func steps() -> [any Step] {
        super.steps() + TranscriptHoldsOnResize.chat() + [ResizeHolds(row: nil), ResizeHolds(row: nil, pause: .zero)]
    }
}

/// Resizes through `TranscriptHoldsOnResize.widths`: with a row, scrolled so its top sits `at`
/// below the top of the view, it stays within 2 pt of there at every step (above the view, the
/// point as far into it as the top of the view was); without one, the view stays at the end.
private struct ResizeHolds: Step {
    let row: Locator?
    var at: CGFloat = 80
    /// Between steps (`DevNavProbe.resize`).
    var pause: Duration = .milliseconds(33)
    var label: String {
        (row.map { "Resize with \($0) \(Int(at)) pt below the top of the view" } ?? "Resize at the end") + (pause == .milliseconds(33) ? "" : ", \(pause) apart")
    }
    var timeout: Duration? { .seconds(40) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        var id: String?
        // The view's top in window space (y up), under the title bar's inset.
        var top: CGFloat = 0
        if let row {
            let element = try await story.element(row)
            guard let scroll = try story.activeChat().storyTranscript.scrollView, let frame = element.frame else {
                throw StoryFailure.other("\(row) has no frame in a scroll view")
            }
            top = scroll.convert(scroll.bounds, to: nil).maxY - scroll.contentInsets.top
            // The scroll made again until it stays: a chat that just finished can still be
            // pinning its end as its rows measure.
            var off = top - at - frame.maxY
            for _ in 0..<10 where abs(off) > 2 {
                try await story.input.scroll(element, to: .by(off))
                try? await Task.sleep(for: .milliseconds(500))
                off = element.frame.map { top - at - $0.maxY } ?? off
            }
            guard abs(off) <= 2 else { throw StoryFailure.other("\(row) didn't stay \(Int(at)) pt below the top of the view (\(Int(off)) pt off)") }
            id = element.id.raw
        } else {
            // A reader's scroll to the end first: a scripted turn's glide can stop short of it.
            try await story.input.scroll(try await story.element(.answer(turn: 4)), to: .bottom)
            try await story.until("the view at the end") {
                DevNavProbe.scrollPlace(workspace).map { $0.offset + $0.visible >= $0.height - 2 } ?? false
            }
        }
        let (steps, frames) = await DevNavProbe.resize(workspace, widths: TranscriptHoldsOnResize.widths, row: id, pause: pause)
        // How far the reader's place moved: the row's top, or the point as far into a row that
        // starts above the view as the top of the view was.
        let first = steps.first?.row ?? .zero
        let share = first.height > 0 ? max(0, (first.maxY - top) / first.height) : 0
        let drift = steps.map { step in step.row.map { ($0.maxY - share * $0.height) - (first.maxY - share * first.height) } }
        let drifts = drift.map { $0.map { String(format: "%.1f", $0) } ?? "-" }.joined(separator: " ")
        let ends = steps.map { String(format: "%.0f", $0.fromEnd) }.joined(separator: " ")
        let line = "\(story.name) \(row.map { "\($0) at \(Int(at))" } ?? "end") \(pause): drift \(drifts); from end \(ends); frames \(frames.frames), over 33 ms \(frames.over33), p95 \(String(format: "%.1f", frames.p95)) ms, worst \(String(format: "%.1f", frames.worst)) ms\n"
        let url = story.outputs.appendingPathComponent("resize.notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
        if row != nil {
            guard drift.allSatisfy({ $0.map { abs($0) <= 2 } ?? false }) else {
                throw StoryFailure.expectation("the reader's place within 2 pt of where it was at every width (moved \(drifts))")
            }
        } else {
            guard steps.allSatisfy({ $0.fromEnd <= 2 }) else {
                throw StoryFailure.expectation("the view at the end at every width (above it by \(ends))")
            }
        }
    }
}
