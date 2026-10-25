import AppKit
import KoreUI

/// A backend holds its acknowledgement, then acknowledges a turn without content. The
/// transcript gives immediate, truthful feedback through both gaps, with one spinner.
final class SendStartupFeedback: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[
            .wait(.release), .startTurn, .wait(.release),
            .stream(.answer, "The startup is complete."), .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Start a reply"),
            Expect("one Sending row before the acknowledgement") { try $0.activeChat().storyTranscript.sendFeedback == ["Sending"] },
            Expect("no backend turn has been invented") { story in
                !story.chatEvents().contains { if case .turnStarted = $0 { true } else { false } }
            },
            PaintedFeedback("Sending"),
            Snapshot("sending-before-acknowledgement"),
            Do("Acknowledge the real turn, leaving it empty") { _ in ScriptedWorld.shared.backends.last?.release() },
            WaitForEvent("the real turn") { if case .turnStarted = $0 { true } else { false } },
            Expect("one working row while the acknowledged turn is empty") { try $0.activeChat().storyTranscript.sendFeedback == ["Working"] },
            PaintedFeedback("Working"),
            Snapshot("working-before-first-content"),
            Do("Let the answer arrive") { _ in ScriptedWorld.shared.backends.last?.release() },
            TurnFinished(1),
            Expect("no feedback row after completion") { try $0.activeChat().storyTranscript.sendFeedback.isEmpty },
            ExpectElement(.id(StoryID.Transcript.spinner), .absent),
        ]
    }
}

/// Wait for the actual label raster after the existing 300 ms fade. Registry presence and
/// a model spinner alone cannot pass: pixels beyond the glyph must differ from the row's
/// own background. This uses the same AppKit rendering path as the saved window snapshots.
private struct PaintedFeedback: Step {
    let phase: String
    var label: String { "See painted \(phase) feedback after its fade" }
    init(_ phase: String) { self.phase = phase }

    @MainActor func run(_ story: StoryContext) async throws {
        try await ExpectElement(.id(StoryID.Transcript.spinner), .visible).run(story)
        let settled = ContinuousClock.now + .milliseconds(350)
        var evidence = "Waiting for fade"
        var png: Data?
        do {
            try await story.until(label) {
                guard ContinuousClock.now >= settled else { return false }
                let rendered = Self.render(story)
                evidence = rendered.evidence
                png = rendered.png
                return png != nil
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("painted \(phase) label: \(evidence)")
        }
        try png?.write(to: story.outputs.appendingPathComponent("\(phase.lowercased())-feedback-row.png"))
    }

    @MainActor private static func render(_ story: StoryContext) -> (png: Data?, evidence: String) {
        guard let element = StoryElement(StoryID.Transcript.spinner), let view = element.registeredView,
            let row = element.frame, row.width > 60, row.height > 8,
            let window = element.window, window === story.window,
            let frameView = window.contentView?.superview, !view.isHiddenOrHasHiddenAncestor
        else { return (nil, "No visible feedback view") }
        let visible = view.convert(view.visibleRect, to: nil).intersection(row)
        guard visible.height >= row.height * 0.9, visible.width >= min(row.width, 300) else {
            return (nil, "Feedback is clipped: \(visible) inside \(row)")
        }
        let crop = frameView.convert(row, from: nil)
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: crop) else {
            return (nil, "Could not render feedback")
        }
        frameView.cacheDisplay(in: crop, to: rep)
        guard rep.pixelsWide > 10, rep.pixelsHigh > 4,
            let background = rep.colorAt(x: rep.pixelsWide - 3, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        else { return (nil, "Feedback raster has no background sample") }
        let scale = CGFloat(rep.pixelsWide) / row.width
        // Skip the animated glyph. Only painted label characters can satisfy this check.
        let first = Int(40 * scale)
        let last = min(rep.pixelsWide - 4, Int(300 * scale))
        guard last > first else { return (nil, "Feedback label has no raster area") }
        var ink = 0
        var columns = 0
        for x in first..<last {
            var hasInk = false
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let contrast = max(abs(color.redComponent - background.redComponent),
                                   max(abs(color.greenComponent - background.greenComponent),
                                       abs(color.blueComponent - background.blueComponent)))
                if contrast > 0.16 { ink += 1; hasInk = true }
            }
            if hasInk { columns += 1 }
            if ink >= 30, columns >= 12 {
                return (rep.representation(using: .png, properties: [:]), "\(ink) label pixels in \(columns) columns")
            }
        }
        return (nil, "Only \(ink) label pixels in \(columns) columns")
    }
}
