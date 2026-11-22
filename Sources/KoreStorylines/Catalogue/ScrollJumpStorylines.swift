import AppKit
import KoreCore
import KoreUI
import src

/// A long chat's place moves only by the reader's own scrolling (the owner's 0.3.9 bug: scrolling
/// a long chat jumped to the middle or the top by itself). The chat is a real transcript
/// (`KORE_SCROLL_CHAT`, a Claude jsonl, put in the run's store as a link; else `LongChatOpen`'s
/// synthetic one), opened through the real backend with a CLI that never starts. Then it's
/// scrolled every way a reader does, in-process: a line at a time, flung, a page at a time, by the
/// scroll bar, by the message rail, up to the top (earlier turns and conversation paging in above)
/// and down again. After each move and through a still spell after it (the 2 s checks run then),
/// the row in the middle of the view is followed in the window: it must move by exactly what was
/// scrolled, and not at all while nobody scrolls. Every move goes to `scroll.notes`; with
/// `KORE_SCROLL_LOG` set the transcript's own log names the code behind any jump.
final class ScrollJumpClaude: Storyline {
    override class var tags: Set<Tag> { [.resume, .claude] }

    override func steps() -> [any Step] { [OpenFolder(), OpenLongChat(), ScrollJumpProbe()] }
}

/// The long chat opened and settled at its end.
struct OpenLongChat: Step {
    var label: String { "Open a long Claude chat" }
    var timeout: Duration? { .seconds(240) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        guard let store = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] else { throw StoryFailure.other("no Claude store") }
        let project = URL(fileURLWithPath: store).appendingPathComponent("projects")
            .appendingPathComponent(CassettePaths.encoded(ClaudeTraces.realPath(story.folder.path)))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("\(LongChatOpen.session).jsonl")
        try? FileManager.default.removeItem(at: file)
        if let path = ProcessInfo.processInfo.environment["KORE_SCROLL_CHAT"] {
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: path))
        } else {
            try LongChatOpen.synthetic(turns: 400, tail: 30).write(to: file)
        }
        let seams = StorylineSeams.backend
        let standIns = CLIExecutable.standIns.value
        StorylineSeams.backend = nil
        CLIExecutable.standIns.value = ["claude": .init(executable: URL(fileURLWithPath: "/usr/bin/false"))]
        defer {
            StorylineSeams.backend = seams
            CLIExecutable.standIns.value = standIns
        }
        try await story.until("the folder's chats listed") { DevNavProbe.chatsListed(workspace) }
        _ = await DevNavProbe.open(workspace, ready: { StoryRegistry.ids.contains { $0.hasPrefix("transcript.") } }) {
            workspace.open(SessionSummary(id: LongChatOpen.session, agent: .claude, title: "Long", updated: .now))
        }
        try await story.idle()
    }
}

/// The moves, and what the row followed did through each.
struct ScrollJumpProbe: Step {
    var label: String { "Scroll a long chat every way: nothing moves but the reader" }
    var timeout: Duration? { .seconds(600) }
    /// With nobody scrolling, a row may move this far (a frame's rounding).
    static let slack: CGFloat = 4
    /// While the reader scrolls, a row may land this far off what was scrolled in one frame: rows
    /// coming into view above are measured as they come (a line's height at most).
    static let movingSlack: CGFloat = 40

    func run(_ story: StoryContext) async throws {
        guard let window = story.window, let chat = story.app.chat else { throw StoryFailure.modelMissing("the chat") }
        let probe = JumpWatch(window: window)
        guard probe.scroll != nil else { throw StoryFailure.other("no transcript scroll view") }
        let transcript = chat.transcript

        await probe.settle(label: "opened", until: 3)
        await probe.stillAtEnd("opened at the end")
        // A swipe up from the end, then down: the end's pin mustn't pull it back.
        await probe.wheel(by: -300, label: "swipe up from the end")
        await probe.still("after a swipe up from the end")
        // Off the end (within 50 pt of it the end is still followed, by design), then a line at a
        // time (a wheel's notches), up and back down.
        // Not asserted: right at the followed end, SwiftUI can aim at the end once more in the
        // pass the clip moves (0.3.9 too); a real trackpad's gesture isn't reproducible in-process.
        await probe.live(by: -200, label: "off the end", asserted: false)
        await probe.still("off the end")
        for _ in 0..<30 { await probe.live(by: -40, label: "line up") }
        await probe.still("after lines up")
        for _ in 0..<15 { await probe.live(by: 40, label: "line down") }
        await probe.still("after lines down")
        // Flung up and down, a trackpad's momentum.
        await probe.fling(distance: 2500, up: true, label: "fling up")
        await probe.still("after a fling up")
        await probe.fling(distance: 1500, up: false, label: "fling down")
        await probe.still("after a fling down")
        // A page at a time.
        for _ in 0..<6 { await probe.page(up: true) }
        await probe.still("after pages up")
        // The scroll bar dragged to the middle, then near the top.
        await probe.bar(to: 0.5)
        await probe.still("after the bar to the middle")
        // The scroll view built again (what a blank check does): the reader's row stays.
        let kept = probe.pickRow()
        chat.storyTranscript.rebuildScrollView()
        await probe.settle(label: "rebuilt", until: 2)
        probe.expectBack(kept, label: "rebuilt in the middle")
        await probe.still("after the rebuild")
        await probe.bar(to: 0.1)
        await probe.still("after the bar near the top")
        // Up to the top, flung: what's above pages in on the way (earlier turns, then the
        // conversation before a compaction), and the reader goes on up through it.
        var still = 0
        for round in 1...40 where still < 3 {
            let before = probe.offset ?? 0
            await probe.fling(distance: 4000, up: true, label: "fling to the top")
            await probe.still("flung up \(round)", seconds: 1.2)
            still = abs((probe.offset ?? 0) - before) < 1 ? still + 1 : 0
        }
        // At the top, the row there pressed for more, as a reader does.
        for press in 1...3 {
            guard let row = StoryRegistry.entry(StoryID.Transcript.earlier.raw), let action = row.press else { break }
            action()
            await probe.settle(label: "load earlier \(press)", until: 3)
            await probe.still("after load earlier \(press)")
        }
        // The rail, to messages here and there.
        let marks = transcript.messageCount
        for index in [marks / 2, marks / 4, marks * 3 / 4, marks - 2].filter({ $0 >= 0 && $0 < marks }) {
            transcript.storyRail?.jump(index)
            // A far message can be read from disk first: settled once it's still for a second.
            await probe.settle(label: "rail \(index) of \(marks)", until: 10, steadyPasses: 120)
            await probe.still("after the rail to \(index)")
            // The reader's swipe after a jump stays theirs: the jump's row doesn't pull it back.
            await probe.wheel(by: 270, label: "swipe after the rail")
            await probe.still("after a swipe after the rail to \(index)")
        }
        // Back down to the end, flung.
        for _ in 0..<80 {
            guard let place = DevNavProbe.scrollPlace(story.app.workspace!), place.offset + place.visible < place.height - 2 else { break }
            await probe.fling(distance: 6000, up: false, label: "fling to the end")
        }
        await probe.still("back at the end")

        let text = probe.lines.map { "\(story.name) \($0)" }.joined(separator: "\n") + "\n"
        try text.write(to: story.outputs.appendingPathComponent("scroll-\(story.name).notes"), atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["KORE_SCROLL_PROBE_ONLY"] == nil, !probe.jumps.isEmpty {
            throw StoryFailure.expectation("no jump without the reader, found \(probe.jumps.count): " + probe.jumps.prefix(6).joined(separator: "; "))
        }
    }
}

/// Follows a built transcript row in the window through moves of the scroll view.
@MainActor
final class JumpWatch {
    let window: NSWindow
    private(set) var lines: [String] = []
    private(set) var jumps: [String] = []
    private var lost = 0

    init(window: NSWindow) { self.window = window }

    var scroll: NSScrollView? { DevScroller.transcript(in: window) }
    var offset: CGFloat? { scroll.map { $0.contentView.bounds.minY } }

    /// The rows on screen, by id, with their tops in window coordinates.
    private func shown() -> [(id: String, top: CGFloat)] {
        guard let scroll else { return [] }
        let visible = scroll.convert(scroll.bounds, to: nil)
        return StoryRegistry.ids.lazy.filter(Self.isRow)
            .compactMap { id in StoryRegistry.entry(id)?.frame.flatMap { $0.intersects(visible) && $0.height < visible.height * 4 ? (id, $0.maxY) : nil } }
    }

    /// A row of the content: not the rail, the top row, a part of a row (its copy button), nor a
    /// message, whose box sticks to the top while its section scrolls by.
    static func isRow(_ id: String) -> Bool {
        guard id.hasSuffix("]"), id.filter({ $0 == "[" }).count == 1 else { return false }
        return ["transcript.answer[", "transcript.tool[", "transcript.fold[", "transcript.thinking[", "transcript.notice[", "transcript.changes["]
            .contains { id.hasPrefix($0) }
    }

    /// The row nearest the view's middle.
    private func pick() -> (id: String, top: CGFloat)? {
        guard let scroll else { return nil }
        let middle = scroll.convert(scroll.bounds, to: nil).midY
        return shown().min { abs($0.top - middle) < abs($1.top - middle) }
    }

    private func top(_ id: String) -> CGFloat? { StoryRegistry.entry(id)?.frame.map(\.maxY) }

    /// The row in the middle now, to look for again after something rebuilds the view.
    func pickRow() -> (id: String, top: CGFloat)? { pick() }

    /// The row is where it was in the window.
    func expectBack(_ row: (id: String, top: CGFloat)?, label: String) {
        guard let row else { return note("\(label): no row to keep") }
        guard let now = top(row.id) else { return jump("\(label): \(row.id) gone from the built rows") }
        if abs(now - row.top) > ScrollJumpProbe.slack { jump("\(label): \(row.id) moved \(Int(now - row.top)) pt") } else { note("\(label): \(row.id) back in place") }
    }

    private func note(_ line: String) {
        lines.append(line)
        ScrollLog.write("probe", line)
    }

    private func jump(_ line: String) {
        jumps.append(line)
        note("JUMP " + line)
    }

    private func pass() async { try? await Task.sleep(for: .milliseconds(16)) }

    /// A move made as a gesture or the scroll bar makes it (`InputDriver.liveScroll`), the clip
    /// `by` points down the content (up: negative); the row followed must move by what the clip did.
    func live(by delta: CGFloat, label: String, framed: Bool = true, asserted: Bool = true) async {
        guard let scroll else { return }
        let clip = scroll.contentView
        let row = pick()
        let center = NotificationCenter.default
        if framed { center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll) }
        let from = clip.bounds.minY
        let to = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: clip.bounds.minX, y: from + delta), size: clip.bounds.size)).origin.y
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: to))
        scroll.reflectScrolledClipView(clip)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        if framed { center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll) }
        await pass()
        await pass()
        check(row, moved: to - from, label: label, asserted: asserted)
    }

    /// The row's move against what was scrolled: a window's y grows up, a flipped clip's down.
    private func check(_ row: (id: String, top: CGFloat)?, moved: CGFloat, label: String, asserted: Bool = true) {
        guard let row else { return }
        guard let now = top(row.id) else {
            lost += 1
            return
        }
        let off = (now - row.top) - moved
        if abs(off) > ScrollJumpProbe.movingSlack {
            guard asserted else { return note("not asserted, \(label): \(row.id) moved \(Int(now - row.top)) for a scroll of \(Int(moved))") }
            jump("\(label): \(row.id) moved \(Int(now - row.top)) for a scroll of \(Int(moved)) (off \(Int(off)) pt)")
        }
    }

    /// A trackpad fling: a push, then momentum decaying, a frame at a time, framed as one live scroll.
    func fling(distance: CGFloat, up: Bool, label: String) async {
        guard let scroll else { return }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        var velocity = distance * 2.5
        var last = CACurrentMediaTime()
        while velocity > 40 {
            await pass()
            let now = CACurrentMediaTime()
            let dt = now - last
            last = now
            await live(by: (up ? -1 : 1) * velocity * dt, label: label, framed: false)
            velocity *= pow(0.12, dt)
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await pass()
    }

    /// A trackpad swipe as AppKit gets one: pixel wheel events with their phases, then momentum,
    /// handed to the scroll view itself (in-process; nothing goes through the window server).
    /// `points` positive moves down the content. Whatever moved the view, it must stay where the
    /// swipe left it (`still` after).
    func wheel(by points: CGFloat, label: String) async {
        guard let scroll else { return }
        let from = scroll.contentView.bounds.minY
        func send(_ dy: CGFloat, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-dy.rounded()), wheel2: 0, wheel3: 0) else { return }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            if let ns = NSEvent(cgEvent: event) { scroll.scrollWheel(with: ns) }
        }
        send(0, phase: .mayBegin)
        send(points / 10, phase: .began)
        await pass()
        for _ in 0..<5 {
            send(points / 10, phase: .changed)
            await pass()
        }
        send(0, phase: .ended)
        var left = points * 0.4
        send(left / 4, momentum: .began)
        left -= left / 4
        while abs(left) > 1 {
            await pass()
            let step = left / 4
            send(step, momentum: .changed)
            left -= step
        }
        send(0, momentum: .ended)
        await pass()
        note("\(label): wheel moved the clip \(Int(scroll.contentView.bounds.minY - from)) for \(Int(points))")
    }

    /// Page Up or Down: a screen less a line, at once.
    func page(up: Bool) async {
        guard let scroll else { return }
        let step = scroll.contentView.bounds.height - 40
        await live(by: up ? -step : step, label: up ? "page up" : "page down")
        await settle(label: up ? "page up" : "page down")
    }

    /// The scroll bar dragged to `fraction` of the content, in steps.
    func bar(to fraction: CGFloat) async {
        guard let scroll, let document = scroll.documentView else { return }
        let target = fraction * max(0, document.frame.height - scroll.contentView.bounds.height)
        let from = scroll.contentView.bounds.minY
        for i in 1...12 {
            let y = from + (target - from) * CGFloat(i) / 12
            await live(by: y - scroll.contentView.bounds.minY, label: "bar to \(Int(fraction * 100))%")
        }
        await settle(label: "bar to \(Int(fraction * 100))%")
    }

    /// After a move of Kore's own (a page landing, the rail): a few frames for it to land.
    func settle(label: String, until seconds: Double = 0.35, steadyPasses: Int = 20) async {
        let began = CACurrentMediaTime()
        var last = offset
        var steady = 0
        while CACurrentMediaTime() - began < seconds, steady < steadyPasses {
            await pass()
            steady = offset == last ? steady + 1 : 0
            last = offset
        }
        note("\(label): at \(Int(offset ?? -1)) of \(Int(scroll?.documentView?.frame.height ?? -1))")
    }

    /// Followed: through a still spell the view stays on the end, whatever lands there.
    func stillAtEnd(_ label: String, seconds: Double = 2.8) async {
        let began = CACurrentMediaTime()
        var off: CGFloat = 0
        while CACurrentMediaTime() - began < seconds {
            await pass()
            // Where it rests: a pass can land a frame short while what lands is measured.
            guard let scroll, let document = scroll.documentView else { continue }
            off = document.frame.height - scroll.contentView.bounds.maxY
        }
        if off > 2 { jump("\(label): left the end by \(Int(off)) pt") } else { note("\(label): at the end") }
    }

    /// Nobody scrolls for `seconds`: the row followed stays where it is, to the point.
    func still(_ label: String, seconds: Double = 2.8) async {
        guard let first = pick() else {
            note("\(label): no row on screen")
            return
        }
        let began = CACurrentMediaTime()
        let startOffset = offset ?? 0
        var worst: CGFloat = 0
        var gone = false
        while CACurrentMediaTime() - began < seconds {
            await pass()
            guard let now = top(first.id) else {
                gone = true
                break
            }
            if abs(now - first.top) > abs(worst) { worst = now - first.top }
        }
        let summary = "\(label): \(first.id) held \(gone ? "-- left the built rows" : "\(Int(worst)) pt"), offset \(Int(startOffset)) -> \(Int(offset ?? -1)), lost \(lost)"
        if gone || abs(worst) > ScrollJumpProbe.slack { jump(summary) } else { note(summary) }
        lost = 0
    }
}

/// The same long chat while a turn streams, does its work and folds: the reader scrolled up a
/// little, then sent far up by the rail. Nothing they're reading moves through the stream, the
/// work rows and the fold at the end (Kore-main's own case: it's nearly always working). On the
/// scripted CLI, for both CLIs: the history is the real transcript's events (`KORE_SCROLL_CHAT`),
/// or a synthetic long chat.
final class ScrollJumpStream: Storyline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude, .codex] }

    static let session = "scroll-jump-stream"

    /// A turn of work: commands with long outputs, then a long answer streamed, then it folds.
    static var turn: [Beat] {
        [.startTurn]
            + (0..<40).map { i in .tool(name: "Bash", detail: "ls part-\(i)", output: HistoryCost.output(i)) }
            + [.stream(.answer, (0..<8).map { DevNavProbe.sample($0) }.joined(separator: "\n\n"), chunk: 20), .finishTurn(.completed)]
    }

    override func steps() -> [any Step] {
        [OpenFolder(), UseScript(CLIScript(turns: [Self.turn, Self.turn])), OpenScriptedLong(), StreamWhileReading()]
    }
}

/// The long chat resumed on the scripted CLI, at its end.
struct OpenScriptedLong: Step {
    var label: String { "Resume a long chat on the scripted CLI" }
    var timeout: Duration? { .seconds(240) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        // Long, with work in every turn (a real transcript's last stretch is short: it's
        // compacted often).
        ScriptedWorld.shared.sessions[ScrollJumpStream.session] = HistoryCost.history
        // Its turns stream at a reader's pace (the backend takes it as it starts).
        ScriptedWorld.shared.rate = 25
        try await story.until("the folder's chats listed") { DevNavProbe.chatsListed(workspace) }
        let agent: SessionSummary.Agent = story.variant?.provider == "codex" ? .codex : .claude
        _ = await DevNavProbe.open(workspace, ready: { StoryRegistry.ids.contains { $0.hasPrefix("transcript.") } }) {
            workspace.open(SessionSummary(id: ScrollJumpStream.session, agent: agent, title: "Long", updated: .now))
        }
        try await story.idle()
    }
}

/// Two turns: through the first the reader is a few screens up, above the turn (its work folds
/// under them); through the second, far up (the rail). Each time the row they read is followed
/// until the turn has folded and a still spell after it. (A reader inside the work that folds is
/// taken where the fold leaves the content; that's the fold's, and isn't followed here.)
struct StreamWhileReading: Step {
    var label: String { "Read above a streaming turn: nothing moves through the stream and the fold" }
    var timeout: Duration? { .seconds(240) }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window, let chat = story.app.chat else { throw StoryFailure.modelMissing("the chat") }
        let probe = JumpWatch(window: window)
        defer { ScriptedWorld.shared.rate = nil }
        for (n, far) in [(1, false), (2, true)] {
            try await Send("turn \(n)").run(story)
            // The work starts in view, followed; then the reader goes up.
            await probe.settle(label: "turn \(n) started", until: 1)
            if far {
                chat.transcript.storyRail?.jump(max(0, chat.transcript.messageCount / 2))
                await probe.settle(label: "rail to the middle", until: 3)
            } else {
                for _ in 0..<30 { await probe.live(by: -150, label: "up while it streams") }
            }
            // Followed through the rest of the turn, its fold, and after.
            while chat.transcript.storyTurnOpen {
                await probe.still("turn \(n) streaming", seconds: 1)
            }
            await probe.still("turn \(n) folded")
        }
        let text = probe.lines.map { "\(story.name) \($0)" }.joined(separator: "\n") + "\n"
        try text.write(to: story.outputs.appendingPathComponent("scroll-\(story.name).notes"), atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["KORE_SCROLL_PROBE_ONLY"] == nil, !probe.jumps.isEmpty {
            throw StoryFailure.expectation("no jump without the reader, found \(probe.jumps.count): " + probe.jumps.prefix(6).joined(separator: "; "))
        }
    }
}
