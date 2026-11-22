import AppKit
import Foundation
import KoreUI

// Zooming keeps the reader's place (owner, 0.3.10: a pinch jumped the view several messages up):
// the text under a pinch stays under it within a few points while the fingers move, when they
// let go, pinching back out, and ⌘+ / ⌘- keep the message under the view's middle there. In a
// long chat whose rows are built as they come, mid-chat and near its end.

final class ZoomKeepsPlace: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let turns = 10
    /// Answers of different heights and kinds, so rows not yet built aren't the height guessed.
    static func answer(_ turn: Int) -> String {
        let words = String(repeating: "and on ", count: (turn % 4) * 12)
        let paragraphs = (1...(10 + (turn * 7) % 30)).map { "Paragraph \($0) of answer \(turn), long enough to wrap \(words)at a narrow width." }
        let code = "```swift\n" + (1...(turn % 3 * 8 + 2)).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n```"
        let list = (1...(turn % 5 + 2)).map { "- point \($0) of answer \(turn)" }.joined(separator: "\n")
        return ([paragraphs[0], code, list] + paragraphs.dropFirst()).joined(separator: "\n\n")
    }
    override class var script: CLIScript { CLIScript(turns: (1...turns).map { CLIScript.reply(answer($0)) }) }

    override func steps() -> [any Step] {
        super.steps() + (1...Self.turns).flatMap { n -> [any Step] in [Send("Part \(n)"), TurnFinished(n)] } + [
            WaitIdle(),
            BoxStep("Mid-chat") { story in
                let transcript = try story.activeChat().storyTranscript
                for _ in 0..<10 {
                    transcript.scrollContent(by: -400)
                    try await Task.sleep(for: .milliseconds(60))
                }
            },
            WaitIdle(), Snapshot("mid-chat"),
            KeepsPlace(where: "mid-chat", at: 0.5),
            KeepsPlace(where: "mid-chat", at: 0.5, trackpad: true),
            KeepsPlace(where: "mid-chat, scrolled far while magnified", at: 0.5, scrolledMagnified: -3000),
            // Near the end, not at it: at the end ⌘+ keeps the end in view, and what's under a
            // point above it changes with the text's size, as it should.
            UnloadStoryline.ToEnd(), WaitIdle(),
            Do("A little above the end") { story in try story.activeChat().storyTranscript.scrollContent(by: -300) },
            WaitIdle(),
            KeepsPlace(where: "near the end", at: 0.7),
            KeepsPlace(where: "near the end", at: 0.7, trackpad: true),
            UnloadStoryline.ToEnd(), WaitIdle(),
            Key(KeyChord(.character("="), .command)), WaitIdle(),
            Self.endKept,
            Key(KeyChord(.character("0"), .command)), WaitIdle(),
            // At the end by a move that took nothing up, as a zoom out can leave it (the text
            // shrinks under a reader above the end): ⌘+ keeps the end in view there too.
            BoxStep("Up from the end, then onto it by a move that isn't the reader's") { story in
                let transcript = try story.activeChat().storyTranscript
                for _ in 0..<5 {
                    transcript.readerScrolled()
                    transcript.scrollContent(by: -400)
                    try await Task.sleep(for: .milliseconds(60))
                }
                try await story.idle()
                try await Task.sleep(for: .milliseconds(200))
                // The rows built on the way down make the content taller: again till it's the end.
                for _ in 0..<5 where !transcript.readerAtEnd {
                    transcript.scrollContent(by: 5000)
                    try await story.idle()
                    try await Task.sleep(for: .milliseconds(150))
                }
            },
            WaitIdle(),
            Expect("there, at the end, not followed", found: { try? $0.activeChat().storyTranscript.endWhy }) { story in
                let transcript = try story.activeChat().storyTranscript
                return transcript.readerAtEnd && transcript.endWhy.hasPrefix("following false")
            },
            Key(KeyChord(.character("="), .command)), WaitIdle(),
            Self.endKept,
            Key(KeyChord(.character("0"), .command)), WaitIdle(),
        ]
    }
}

extension ZoomKeepsPlace {
    static var endKept: Expect {
        Expect("at the end, ⌘+ keeps the end in view", found: { story in
            guard let view = story.app.chat?.storyTranscript.scrollView, let document = view.documentView else { return "no scroll view" }
            return "bottom \(view.contentView.bounds.maxY) of \(document.frame.height); \(story.app.chat?.storyTranscript.endWhy ?? "-")"
        }) { story in try story.activeChat().storyTranscript.readerAtEnd }
    }
}

/// Pinches in and out at a point `at` of the way down the view, then ⌘+ and ⌘-, measuring.
struct KeepsPlace: Step {
    let `where`: String
    let at: CGFloat
    /// Scrolled this far (points, up when negative) while magnified, before pinching back out:
    /// rows the stack hadn't built come in as the page shrinks.
    var scrolledMagnified: CGFloat = 0
    /// As a trackpad sends it: magnify events with two-finger scroll events among them (the
    /// fingers never move exactly together: small, back and forth), and momentum after.
    var trackpad = false
    /// How far the text under a pinch may move (points), as rounding and a pass's lag allow.
    static let slack: CGFloat = 6
    var label: String { "Zoom keeps the place \(`where`)" + (trackpad ? ", by trackpad" : "") }
    var timeout: Duration? { .seconds(60) }

    /// The text at `p`, else the nearest line up or down within 120 pt (it can fall between blocks).
    @MainActor static func near(_ p: CGPoint, _ transcript: StoryTranscript) -> (entry: UUID, path: [Int], offset: Int)? {
        for dy in stride(from: CGFloat(0), through: 120, by: 4) {
            for y in [p.y - dy, p.y + dy] {
                if let hit = transcript.textAt(CGPoint(x: p.x, y: y)) { return hit }
            }
        }
        return nil
    }

    func run(_ story: StoryContext) async throws {
        try await UnloadStoryline.GlideEnds().run(story)
        guard let window = story.window else { throw StoryFailure.modelMissing("the window") }
        let transcript = try story.activeChat().storyTranscript
        guard let scroll = transcript.scrollView else { throw StoryFailure.modelMissing("the scroll view") }
        let view = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        // Window points are y up: `at` of the way down, a third of the way across (on the text).
        let aim = CGPoint(x: view.minX + view.width / 3, y: view.maxY - view.height * at)
        try await Spot.holdStill(story)
        // The nearest line of text to the aim, up or down (it can fall between blocks).
        let found: (entry: UUID, path: [Int], offset: Int)?
        do { found = try await story.wait("text near the view's \(Int(at * 100))% point") { Self.near(aim, transcript) } } catch { found = nil }
        guard let hit = found else { throw StoryFailure.other("no text near \(aim): " + transcript.slotsDescription(near: aim)) }
        // A glyph inside the text: its end has no point of its own.
        var text = (entry: hit.entry, path: hit.path, offset: max(0, hit.offset - 1))
        guard var point = transcript.textPoint(text.entry, text.path, offset: text.offset) else {
            throw StoryFailure.other("no point for \(text) near the view's \(Int(at * 100))% point \(aim)")
        }
        // The measure isn't blind: the text moves as far as the view scrolls (up: the end can't go further).
        let clipBefore = scroll.contentView.bounds.origin.y
        transcript.scrollContent(by: -30)
        try await story.idle()
        let scrolled = abs(scroll.contentView.bounds.origin.y - clipBefore)
        if let moved = transcript.textPoint(text.entry, text.path, offset: text.offset), abs(hypot(moved.x - point.x, moved.y - point.y) - scrolled) > 2 {
            throw StoryFailure.other("the measure read \(scrolled) pt of scroll as \(hypot(moved.x - point.x, moved.y - point.y))")
        }
        guard scrolled > 20 else { throw StoryFailure.other("the view didn't scroll for the measure's check (\(scrolled) pt)") }
        transcript.scrollContent(by: 30)
        try await story.idle()
        try await Task.sleep(for: .milliseconds(200))
        guard let back = transcript.textPoint(text.entry, text.path, offset: text.offset), hypot(back.x - point.x, back.y - point.y) < 1 else {
            throw StoryFailure.other("the view didn't come back for the measure's check")
        }
        var worst: (CGFloat, String) = (0, "")
        var notes: [String] = []
        func drift(_ when: String) -> CGFloat {
            guard let now = transcript.textPoint(text.entry, text.path, offset: text.offset) else {
                worst = (.infinity, when)
                return .infinity
            }
            let d = hypot(now.x - point.x, now.y - point.y)
            if d > worst.0 { worst = (d, when) }
            return d
        }
        func pinch(_ amount: CGFloat, _ name: String) async throws {
            var most: CGFloat = 0
            var mostScale: CGFloat = scroll.magnification
            if trackpad {
                try story.input.trackpad(magnify: 0, phase: 1, at: point, in: window)
                for i in 0..<30 {
                    try story.input.trackpad(magnify: amount, phase: 2, at: point, in: window)
                    if i % 3 == 1 { try story.input.trackpad(scrollDY: i % 6 == 1 ? 1 : -1, phase: i == 1 ? 1 : 2, at: point, in: window) }
                    try await Task.sleep(for: .milliseconds(8))
                    most = max(most, drift("\(name), live"))
                    mostScale = max(mostScale, scroll.magnification)
                }
                try story.input.trackpad(magnify: 0, phase: 4, at: point, in: window)
                try story.input.trackpad(scrollDY: 0, phase: 4, at: point, in: window)
                // The fingers lift: momentum, small and back and forth, dying away.
                for (i, dy) in [1, -1, 1, -1, 1, 0].enumerated() {
                    try story.input.trackpad(scrollDY: CGFloat(dy), momentum: i == 0 ? 1 : i == 5 ? 3 : 2, at: point, in: window)
                    try await Task.sleep(for: .milliseconds(16))
                    most = max(most, drift("\(name), momentum"))
                }
            } else {
                guard PinchZoom.storySample(in: window, amount: 0, phase: .began, at: point) else { throw StoryFailure.other("\(name): no pinch began") }
                for _ in 0..<30 {
                    _ = PinchZoom.storySample(in: window, amount: amount, phase: .changed, at: point)
                    try await Task.sleep(for: .milliseconds(8))
                    most = max(most, drift("\(name), live"))
                }
                _ = PinchZoom.storySample(in: window, amount: 0, phase: .ended, at: point)
                try await story.until("\(name) to finish") { PinchZoom.storyPlacement(in: window) != nil }
            }
            try await story.idle()
            let end = drift("\(name), let go")
            try await Task.sleep(for: .milliseconds(400))
            let later = drift("\(name), 0.4 s on")
            notes.append(String(format: "%@: live ≤ %.1f, let go %.1f, 0.4 s on %.1f pt (page %.2f, view %.2f, most %.2f, cancelled %d)", name, most, end, later,
                PinchZoom.storyPageScale(in: window) ?? 1, scroll.magnification, mostScale, PinchZoom.storyCounts(in: window)?.cancellations ?? -1))
        }
        try await pinch(0.02, "pinch in")
        // The fingers' small scrolls among the samples are the pinch's: it zooms all the way.
        if trackpad, (PinchZoom.storyPageScale(in: window) ?? 1) < 1.5 {
            throw StoryFailure.expectation("a trackpad pinch, its fingers' scrolls among it, zoomed only to \(PinchZoom.storyPageScale(in: window) ?? 1). " + notes.joined(separator: "; "))
        }
        if scrolledMagnified != 0 {
            for _ in 0..<10 {
                transcript.scrollContent(by: scrolledMagnified / 10)
                try await Task.sleep(for: .milliseconds(60))
            }
            try await story.idle()
            try await Task.sleep(for: .milliseconds(300))
            // A new place to keep: what's under the point now.
            guard let now = Self.near(point, transcript), let at = transcript.textPoint(now.entry, now.path, offset: max(0, now.offset - 1)) else {
                throw StoryFailure.other("no text under the pinch point after scrolling magnified")
            }
            text = (now.entry, now.path, max(0, now.offset - 1))
            point = at
        }
        try await pinch(-0.02, "pinch out")
        // ⌘+ and ⌘-: the text reflows, so the message under the view's middle, not the glyph.
        for (key, name) in [("=", "⌘+"), ("-", "⌘-")] {
            let middle = CGPoint(x: point.x, y: point.y)
            guard let before = Self.near(middle, transcript) else { throw StoryFailure.other("no text at the place before \(name)") }
            try await story.input.key(KeyChord(.character(Character(key)), .command))
            try await story.idle()
            try await Task.sleep(for: .milliseconds(400))
            let after = Self.near(middle, transcript)
            let same = before.entry == after?.entry ? (before.path == after?.path ? "the same message and block" : "the same message, block \(before.path) → \(after?.path ?? [])") : "ANOTHER message"
            notes.append("\(name): under the place \(same) (scale \(PinchZoom.storyScale()))")
            if before.entry != after?.entry { worst = (.infinity, "\(name): the message under the middle changed") }
        }
        try await story.input.key(KeyChord(.character("0"), .command))
        try await story.idle()
        let line = "\(story.name) \(`where`): " + notes.joined(separator: "; ") + "\n"
        let url = story.outputs.appendingPathComponent("zoom-place.notes")
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try line.write(to: url, atomically: true, encoding: .utf8) }
        guard worst.0 <= Self.slack else {
            throw StoryFailure.expectation("\(`where`): the place moved \(worst.0 == .infinity ? "away" : String(format: "%.1f pt", worst.0)) at \(worst.1). " + notes.joined(separator: "; "))
        }
    }
}
