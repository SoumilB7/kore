import AppKit
import KoreUI

/// `QuoteAfterScrolling` scrolled as a trackpad does: each step a live scroll AppKit posts
/// (the reader's own move, as the transcript counts one), not the clip moved with nobody scrolling.
final class QuoteAfterWheelScrolling: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }
    override class var script: CLIScript { QuoteAfterScrolling.script }

    struct Swiped: Step {
        let dy: CGFloat
        var label: String { "Swipe \(Int(dy)) pt" }
        func run(_ story: StoryContext) async throws {
            guard let view = try story.activeChat().storyTranscript.scrollView else { throw StoryFailure.modelMissing("the scroll view") }
            let center = NotificationCenter.default
            center.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
            let steps = 12
            for _ in 0..<steps {
                let clip = view.contentView
                let place = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + dy / CGFloat(steps)), size: clip.bounds.size))
                clip.scroll(to: place.origin)
                view.reflectScrolledClipView(clip)
                center.post(name: NSScrollView.didLiveScrollNotification, object: view)
                try await Task.sleep(for: .milliseconds(40))
            }
            center.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
            try await story.idle()
        }
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Go on"), TurnFinished(1), WaitIdle(),
            Send("Is it all done?"), TurnFinished(2), WaitIdle(),
            Swiped(dy: -900), Snapshot("scrolled-up"),
            Swiped(dy: 500), Snapshot("partway-back"),
            ClickText(.answer(2, QuoteInOwnerAnswer.quote, at: QuoteInPointSelects.line, "Docker"), count: 2),
            CopySelection("Docker"),
            UnloadStoryline.ToEnd(),
            ClickText(.answer(2, QuoteInOwnerAnswer.quote, at: QuoteInPointSelects.line, "Resume"), count: 2),
            CopySelection("Resume"),
        ]
    }
}
