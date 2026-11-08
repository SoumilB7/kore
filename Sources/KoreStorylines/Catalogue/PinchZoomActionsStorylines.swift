import AppKit
import KoreUI
import src

/// Pinched in, every action under a message and an answer takes a click where it's drawn: Copy,
/// Fork and Roll back (its icon, then the "Roll back, files stay" it shows, or the icon again).
/// Copy under the newest answer at the natural size, then at 1.5× and 3×; at 1.5× the Copy under
/// the messages and the earlier answers (shown on hover); forking from the second message, rolling
/// back from the third message and then the first answer, and forking from the first answer.
final class PinchZoomAnswerActions: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    // The first answer is taller than the view: a shorter page SwiftUI keeps at its top whatever
    // the zoom. The rest sit together at its end, all in view at 1.5×.
    override class var script: CLIScript {
        CLIScript(turns: [CLIScript.reply(PinchZoomGesture.answer), CLIScript.reply("The second answer."), CLIScript.reply("The third answer.")])
    }
    override func steps() -> [any Step] {
        let users = { @MainActor (story: StoryContext) throws -> [String] in try story.activeChat().storyTranscript.entries.filter { $0.kind == .user }.map(\.text) }
        return super.steps() + [
            Send("First"), TurnFinished(1), Send("Second"), TurnFinished(2), Send("Third"), TurnFinished(3), WaitIdle(),
            AtTheEnd(),
            Expect("no pointer events re-aimed at the natural size") { story in
                story.window.map { !PinchZoom.storyAiming(in: $0) } ?? false
            },
            ClickRowAction(.answer(3), .copy, zoom: 1),
            ClickRowAction(.answer(3), .copy, zoom: 1.5),
            ClickRowAction(.user(3), .copy, zoom: 1.5),
            ClickRowAction(.answer(2), .copy, zoom: 1.5),
            ClickRowAction(.user(2), .copy, zoom: 1.5),
            ClickRowAction(.answer(3), .copy, zoom: 3),
            Snapshot("pinch-actions-3x"),
            MeasureAim(),
            ClickRowAction(.user(2), .fork, zoom: 1.5),
            Do("Back to the zoomed chat") { story in _ = story.app.workspace?.storySelect(tabAt: 0) },
            Expect("the zoomed chat's tab active") { story in story.app.workspace.map { $0.activeTab.id == $0.tabs[0].id } ?? false },
            WaitIdle(), AtTheEnd(),
            ClickRowAction(.user(3), .rollback, zoom: 1.5),
            ClickRowAction(.user(3), .confirm, zoom: 1.5, "message 3 and its answer gone, its text in the composer") { story in
                try users(story) == ["First", "Second"] && story.activeChat().draft == "Third"
            },
            ClickRowAction(.answer(1), .rollback, zoom: 1.5),
            ClickRowAction(.answer(1), .rollback, zoom: 1.5, "the chat through answer 1") { story in try users(story) == ["First"] },
            ClickRowAction(.answer(1), .fork, zoom: 1.5),
        ]
    }
}

/// Past the last send's glide (two seconds), a reader's scroll to the chat's end: the rows the
/// clicks go to are there.
private struct AtTheEnd: Step {
    var label: String { "Scroll to the chat's end" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        let scroll = try await story.wait("the transcript's scroll view") { chat.storyTranscript.scrollView }
        if let sent = chat.storyTranscript.sentAt {
            try await story.until("the send's glide over", timeout: .seconds(3)) { Date() >= sent + 2.05 }
        }
        try await Scroll(.answer(turn: 3), to: .bottom).run(story)
        try await story.until("the transcript at its end") { PinchZoomNewLineHolds.distanceToEnd(scroll) < 2 }
        try await story.idle()
    }
}

/// An action under a message or an answer clicked at its drawn centre as a pointer would,
/// through AppKit's dispatch. The page is pinched to `zoom` anchored on the row first (back to
/// its natural size on the way when the row is out of view), so it's in view with no scroll,
/// and the row hovered (its storyline stand-in), as a person's pointer there would.
private struct ClickRowAction: Step {
    enum Row: CustomStringConvertible {
        case user(Int), answer(Int)
        var description: String { switch self { case .user(let n): "message \(n)"; case .answer(let n): "answer \(n)" } }
    }
    enum Action: String {
        case copy, fork, rollback
        /// "Roll back, files stay", shown after a first press of Roll back.
        case confirm = "roll back, files stay"
    }
    let row: Row
    let action: Action
    let zoom: CGFloat
    /// What the click did; nil: the action's own (copied, forked, armed).
    let expected: (what: String, check: @MainActor (StoryContext) throws -> Bool)?
    init(_ row: Row, _ action: Action, zoom: CGFloat, _ what: String? = nil, _ check: (@MainActor (StoryContext) throws -> Bool)? = nil) {
        (self.row, self.action, self.zoom) = (row, action, zoom)
        expected = check.map { (what ?? "", $0) }
    }
    var label: String { "Click \(row)'s \(action.rawValue) at \(zoom)×" }
    var timeout: Duration? { .seconds(20) }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        let transcript = chat.storyTranscript
        let entry: StoryTranscript.Entry
        switch row {
        case .user(let n):
            let users = transcript.entries.filter { $0.kind == .user }
            guard users.indices.contains(n - 1) else { throw StoryFailure.modelMissing("\(row)") }
            entry = users[n - 1]
        case .answer(let n):
            guard transcript.turns.indices.contains(n - 1),
                  let answer = transcript.entries.last(where: { $0.turn == transcript.turns[n - 1] && $0.kind == .answer })
            else { throw StoryFailure.modelMissing("\(row)") }
            entry = answer
        }
        let base = if case .user = row { StoryID.Transcript.user(entry.id) } else { StoryID.Transcript.answer(entry.id) }
        let id = action == .confirm ? base.part(.rollback).part(.done) : base.part(Self.part(action))
        // The row's own scroll view (after a rollback the transcript's handle can lag behind).
        let scroll = try await story.wait("\(row)'s scroll view") {
            story.window.flatMap { StoryRegistry.entries(base.part(.copy).raw, in: $0).first?.registeredView?.enclosingScrollView } ?? transcript.scrollView
        }
        guard let window = scroll.window else { throw StoryFailure.modelMissing("the transcript's window") }
        let clip = scroll.contentView
        let root = window.contentView?.superview ?? window.contentView
        let frames = { @MainActor (id: StoryID) -> [CGRect] in StoryRegistry.entries(id.raw, in: window).compactMap(\.frame) }
        // The actions' row (registered whole for its presses, hidden or not), and where to pinch.
        let anchor = { @MainActor () -> CGPoint? in
            frames(base.part(.copy)).max { $0.width < $1.width }.map { CGPoint(x: $0.minX + 40, y: $0.midY) }
        }
        let inView = { @MainActor (point: CGPoint) -> Bool in
            clip.convert(clip.bounds, to: nil).insetBy(dx: 20, dy: 20).contains(point)
                && root?.hitTest(point)?.isDescendant(of: scroll) == true
        }
        func pinch(to scale: CGFloat, at point: CGPoint) async throws {
            let local = clip.convert(point, from: nil)
            let at = CGPoint(x: (local.x - clip.bounds.minX) / clip.bounds.width, y: (local.y - clip.bounds.minY) / clip.bounds.height)
            try await PinchZoomNewLineHolds.pinch(story, scroll, at: at, amount: (scale - scroll.magnification) / scroll.magnification)
        }
        var point = try await story.wait("\(row)'s actions") { anchor() }
        if !inView(point), scroll.magnification > 1.001 {
            try await pinch(to: 1, at: clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil))
            point = try await story.wait("\(row)'s actions") { anchor() }
        }
        guard inView(point) else { throw StoryFailure.expectation("\(row)'s actions out of view at \(scroll.magnification)×") }
        if abs(scroll.magnification - zoom) > 0.01 { try await pinch(to: zoom, at: point) }
        guard abs(scroll.magnification - zoom) < 0.01 else { throw StoryFailure.other("the pinch left \(scroll.magnification)×") }
        // Under the pointer: a pinch moves the page under one that isn't there (a storyline's).
        for hover in StoryRegistry.entries(base.part(.hover).raw, in: window) { hover.press?() }
        try await story.idle()
        // The button's own registration: the row registers its name too, for its presses.
        let button = try await story.wait(id.raw) { () -> CGRect? in
            let all = frames(id)
            return action == .confirm || all.count > 1 ? all.min { $0.width < $1.width } : nil
        }
        let target = CGPoint(x: button.midX, y: button.midY)
        guard inView(target) else {
            throw StoryFailure.expectation("\(id.raw) at \(target) out of view or covered (by \(root?.hitTest(target).map { String(describing: type(of: $0)) } ?? "nothing"))")
        }
        if !window.isKeyWindow { window.makeKey() }
        if !window.isMainWindow { window.makeMain() }
        let scale = scroll.magnification
        let tabs = story.app.workspace?.tabs.count ?? 0
        StoryTranscript.clearCopied()
        await story.input.click(at: target, in: window)
        let (what, check): (String, @MainActor () throws -> Bool) = switch (expected, action) {
        case (let expected?, _): (expected.what, { try expected.check(story) })
        case (nil, .copy): ("its text copied", { StoryTranscript.copied == entry.text })
        case (nil, .fork): ("a fork tab", {
            (story.app.workspace?.tabs.count ?? 0) > tabs && ((try? story.activeChat().storyTitle.hasSuffix("(fork)")) ?? false)
        })
        case (nil, .rollback): ("“Roll back, files stay” shown", { !frames(base.part(.rollback).part(.done)).isEmpty })
        case (nil, .confirm): ("a rollback", { false })
        }
        do {
            try await story.until(what, timeout: .seconds(4)) { try check() }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("a click on \(row)'s \(action.rawValue) at \(String(format: "%.2f", scale))×, drawn at \(Int(target.x)),\(Int(target.y)): \(what) never came")
        }
    }

    private static func part(_ action: Action) -> StoryID.Part {
        switch action {
        case .copy: .copy
        case .fork: .fork
        case .rollback, .confirm: .rollback
        }
    }
}

/// What re-aiming costs, in the real window at 3×: per pointer move and per press and release,
/// the work the monitor does (hit tests and an event). Nothing runs per frame or per scroll.
private struct MeasureAim: Step {
    var label: String { "Measure the re-aiming per pointer event" }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        guard let window = story.window, PinchZoom.storyAiming(in: window),
              let answer = chat.storyTranscript.entries.last(where: { $0.kind == .answer }),
              let copy = StoryRegistry.entries(StoryID.Transcript.answer(answer.id).part(.copy).raw, in: window)
                .compactMap(\.frame).min(by: { $0.width * $0.height < $1.width * $1.height })
        else { throw StoryFailure.other("no magnified page re-aiming its pointer events") }
        // Over the answer's Copy, in view where the pinch left it.
        let point = CGPoint(x: copy.midX, y: copy.midY)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: 1)!
        }
        let moves = 2000, presses = 500
        let move = event(.mouseMoved), down = event(.leftMouseDown), up = event(.leftMouseUp)
        let clock = ContinuousClock()
        var aimed = 0
        let movesTook = clock.measure {
            for _ in 0..<moves where PinchZoom.storyAim(in: window, move).locationInWindow != point { aimed += 1 }
        }
        let pressesTook = clock.measure {
            for _ in 0..<presses {
                _ = PinchZoom.storyAim(in: window, down)
                _ = PinchZoom.storyAim(in: window, up)
            }
        }
        // What the window already does for a pointer event there: one hit test (the transcript's
        // I-beam tracking does one per move too).
        let root = window.contentView?.superview ?? window.contentView
        let hitTook = clock.measure { for _ in 0..<moves { _ = root?.hitTest(point) } }
        guard aimed == moves else { throw StoryFailure.other("only \(aimed) of \(moves) moves over the page re-aimed") }
        func micros(_ d: Duration, _ n: Int) -> String { String(format: "%.1f", (Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12) / Double(n)) }
        let note = "\(story.name): magnification=3 movePerEventUs=\(micros(movesTook, moves)) pressAndReleaseUs=\(micros(pressesTook, presses)) oneWindowHitTestUs=\(micros(hitTook, moves)) perFrame=0 perScroll=0\n"
        try note.write(to: story.outputs.appendingPathComponent(story.name + ".aim.notes"), atomically: true, encoding: .utf8)
    }
}
