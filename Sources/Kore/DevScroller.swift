import AppKit

/// The navigation bench's scrolling (phase 11 research-harness.md §2): finds the transcript's
/// scroll view and moves it at a set speed, a frame at a time, checking it really moved.
/// `clip` moves the clip view; `event` sends pixel scroll-wheel events, with phases and
/// momentum, to the scroll view itself.
@MainActor
enum DevScroller {
    enum Mode: String {
        case clip, event
    }

    struct Result {
        var requestedPX = 0.0
        var movedPX = 0.0
        var valid = false
    }

    /// The scroll view under the middle of the chat area: the transcript, not the explorer or
    /// a code block inside it (a nested scroll view is skipped for its larger ancestor).
    static func transcript(in window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        let middle = NSPoint(x: content.bounds.midX + content.bounds.width * 0.1, y: content.bounds.midY)
        var view = content.hitTest(content.convert(middle, to: content.superview))
        var found: NSScrollView?
        while let current = view {
            if let scroll = current as? NSScrollView, scroll.frame.height > content.bounds.height * 0.4 { found = scroll }
            view = current.superview
        }
        return found ?? largest(in: content)
    }

    private static func largest(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView,
                scroll.frame.width * scroll.frame.height > (best.map { $0.frame.width * $0.frame.height } ?? 0)
            {
                best = scroll
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    /// The offset measured from the top, whichever way the document is flipped.
    static func offset(_ scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView
        guard let document = scroll.documentView else { return 0 }
        return document.isFlipped ? clip.bounds.origin.y : document.frame.height - clip.bounds.maxY
    }

    static func maxOffset(_ scroll: NSScrollView) -> CGFloat {
        max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
    }

    private static func setOffset(_ scroll: NSScrollView, _ value: CGFloat) {
        let clip = scroll.contentView
        guard let document = scroll.documentView else { return }
        let y = document.isFlipped ? value : document.frame.height - clip.bounds.height - value
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// Scrolls to the top (`toTop`) or bottom at `speed` px/s. Lazy content growing as it goes
    /// is followed; it ends at the edge, or after `limit` px.
    static func run(_ scroll: NSScrollView, toTop: Bool, speed: Double, mode: Mode, limit: Double = .infinity) async -> Result {
        var result = Result()
        let start = offset(scroll)
        var last = CACurrentMediaTime()
        var travelled = 0.0
        var stuckFrames = 0
        while travelled < limit {
            try? await Task.sleep(for: .milliseconds(8))
            let now = CACurrentMediaTime()
            let step = min(speed * (now - last), limit - travelled)
            last = now
            let before = offset(scroll)
            let edge = toTop ? 0 : maxOffset(scroll)
            if abs(before - edge) < 0.5 {
                stuckFrames += 1
                // At the edge for a few frames with nothing more loading: done.
                if stuckFrames > 6 { break }
                continue
            }
            stuckFrames = 0
            let delta = toTop ? -step : step
            switch mode {
            case .clip:
                setOffset(scroll, min(max(before + delta, 0), maxOffset(scroll)))
            case .event:
                send(scroll, deltaY: -delta, phase: travelled == 0 ? .began : .changed)
            }
            travelled += abs(offset(scroll) - before)
            result.requestedPX += step
        }
        if mode == .event { send(scroll, deltaY: 0, phase: .ended) }
        result.movedPX = abs(offset(scroll) - start)
        // An unmoved scroll never passes: it must cover what was asked, or reach the edge.
        let edge = toTop ? 0 : maxOffset(scroll)
        result.valid = result.movedPX > 0 && (result.movedPX >= min(limit, result.requestedPX) * 0.99 || abs(offset(scroll) - edge) < 1)
        return result
    }

    /// A fling: a short push, then momentum decaying the way a trackpad's does.
    static func fling(_ scroll: NSScrollView, distance: Double, up: Bool) async -> Result {
        var result = Result()
        let start = offset(scroll)
        var velocity = distance * 2.5  // px/s; decays to ~0 over ~1.2 s, covering about `distance`
        var last = CACurrentMediaTime()
        while velocity > 20 {
            try? await Task.sleep(for: .milliseconds(8))
            let now = CACurrentMediaTime()
            let dt = now - last
            last = now
            let step = velocity * dt
            let before = offset(scroll)
            setOffset(scroll, min(max(before + (up ? -step : step), 0), maxOffset(scroll)))
            result.requestedPX += step
            velocity *= pow(0.12, dt)
        }
        result.movedPX = abs(offset(scroll) - start)
        result.valid = result.movedPX > 0
        return result
    }

    private static func send(_ scroll: NSScrollView, deltaY: Double, phase: NSEvent.Phase) {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(deltaY.rounded()), wheel2: 0, wheel3: 0)
        else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        if let ns = NSEvent(cgEvent: event) { scroll.scrollWheel(with: ns) }
    }
}
