import AppKit
import KoreUI

/// The sidebar's divider dragged a little at a time, as a hand does, beside a long chat. The chat
/// holds still all through it (its width, its row on screen, across and down) while the sidebar
/// follows the pointer, wraps anew once on release, and the reader's place is where it was. Each
/// drag's numbers go to `sash.notes` in the run's folder.
class SashStoryline: ChatStoryline {
    override class var isFamily: Bool { self == SashStoryline.self }
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { TranscriptHoldsOnResize.script }

    override func steps() -> [any Step] {
        super.steps() + [Command(.toggleExplorer), WaitForElement(.id(StoryID.Explorer.sash))] + TranscriptHoldsOnResize.chat()
    }
}

/// Scrolled up: a row near the top of the view, then deep inside a row taller than the view.
final class SashHoldsChatScrolledUp: SashStoryline {
    override func steps() -> [any Step] {
        let answer = Locator.answer(turn: 2)
        return super.steps() + [
            SashDrag(row: answer, by: 120), SashDrag(row: answer, by: -160), SashDrag(row: answer, at: -1500, by: 100),
        ]
    }
}

/// The scroll view built again with the reader above the end: their place and what's being typed
/// are as they were.
final class SashRebuildKeepsPlace: SashStoryline {
    // Not yet true: a rebuild restores the offset, not the row, so it stays out of the gate.
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        let answer = Locator.answer(turn: 2)
        return super.steps() + [SashDrag(row: answer, by: 120), TypeText(SashHoldsChatAtEnd.draft), SashRebuildKeeps(row: answer)]
    }
}

/// At the end, the view stays there, or is back there drawing its rows within a second of
/// release, with what's being typed as it was.
final class SashHoldsChatAtEnd: SashStoryline {
    static let draft = "half a thought"

    override func steps() -> [any Step] {
        super.steps() + [
            TypeText(Self.draft),
            SashDrag(row: nil, by: 120), SashDrag(row: nil, by: -160),
            Expect("the draft as it was") { try $0.activeChat().draft == Self.draft },
        ]
    }
}

/// The scroll view built again, as the blank check does (`checkBlank`): a reader above the end
/// keeps their place, and what's being typed stays.
private struct SashRebuildKeeps: Step {
    let row: Locator
    var label: String { "Build the scroll view again with \(row) on screen" }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        let element = try await story.element(row)
        guard let was = element.frame, let view = DevNavProbe.transcriptFrame(workspace) else { throw StoryFailure.other("no \(row)") }
        let chat = try story.activeChat()
        chat.storyTranscript.rebuildScrollView()
        try await story.until("\(row) back on screen") { StoryElement(element.id)?.frame?.intersects(view) ?? false }
        try? await Task.sleep(for: .milliseconds(600))
        guard let now = StoryElement(element.id)?.frame, now.intersects(view) else { throw StoryFailure.expectation("\(row) on screen after the scroll view was built again") }
        try sashNote(story, "\(story.name) rebuilt: the reader's row moved \(String(format: "%.1f", now.maxY - was.maxY)) pt")
        guard chat.draft == SashHoldsChatAtEnd.draft else { throw StoryFailure.expectation("the draft kept through a rebuild (“\(chat.draft)”)") }
        guard abs(now.maxY - was.maxY) <= 2 else { throw StoryFailure.expectation("the reader's place kept through a rebuild (moved \(now.maxY - was.maxY) pt)") }
    }
}

/// Reads back how far the sash, the chat's frame and its row are, per step of a held drag.
struct SashSample {
    var chat: CGRect?
    var row: CGRect?
    /// A word of the text nearest the middle of the view, in window coordinates.
    var word: CGPoint?
    var sidebar: CGFloat
    var fromEnd: Double
}

@MainActor
func sashSample(_ story: StoryContext, _ workspace: Workspace, row: StoryID?, word: SashWord?) -> SashSample {
    let place = DevNavProbe.scrollPlace(workspace)
    return SashSample(
        chat: DevNavProbe.transcriptFrame(workspace),
        row: row.flatMap { StoryElement($0)?.frame },
        word: word.flatMap { word in (try? story.activeChat().storyTranscript)?.textPoint(word.entry, word.path, offset: word.offset) },
        sidebar: workspace.storyExplorerWidth,
        fromEnd: place.map { $0.height - $0.offset - $0.visible } ?? 0)
}

func sashNote(_ story: StoryContext, _ line: String) throws {
    let url = story.outputs.appendingPathComponent("sash.notes")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    } else {
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

@MainActor
final class SashTrace {
    var commits: [(offset: Double, row: CGFloat?, word: CGFloat?)] = []
    /// After release: when, and whether the last row was on screen and anything drew.
    var released: ContinuousClock.Instant?
    var after: [(at: Duration, shown: Bool)] = []
}

/// The word followed: the text on screen nearest the middle of the view, some way into it.
struct SashWord {
    let entry: UUID
    let path: [Int]
    let offset: Int

    @MainActor static func nearMiddle(_ story: StoryContext, of view: CGRect) throws -> SashWord? {
        let t = try story.activeChat().storyTranscript
        var best: (SashWord, CGFloat)?
        for entry in t.entries where t.isBuilt(entry.id) {
            for path in t.selectableTexts(entry.id) {
                let word = SashWord(entry: entry.id, path: path, offset: 40)
                guard let p = t.textPoint(entry.id, path, offset: word.offset), view.contains(p) else { continue }
                let off = abs(p.y - view.midY)
                if off < (best?.1 ?? .infinity) { best = (word, off) }
            }
        }
        return best?.0
    }
}

/// Places the reader (`row` `at` below the top of the view, or at the end), then presses the sash
/// and moves it `by` in `steps`, `pause` apart, sampling after each and for a while after release.
struct SashDrag: Step {
    let row: Locator?
    var at: CGFloat = 80
    let by: CGFloat
    var steps = 30
    var pause: Duration = .milliseconds(11)
    var label: String { "Drag the sash \(Int(by)) pt with " + (row.map { "\($0) \(Int(at)) pt below the top of the view" } ?? "the view at the end") }
    var timeout: Duration? { .seconds(40) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        var id: StoryID?
        var top: CGFloat = 0
        if let row {
            // Up the chat until the row is built: narrowed by the sidebar, it's further from the end.
            var element = try await story.element(row)
            for _ in 0..<40 where (try? await story.input.scroll(element, to: .by(0))) == nil {
                _ = await DevNavProbe.scrollUp(workspace, by: 500)
                element = try await story.element(row)
            }
            guard let scroll = try story.activeChat().storyTranscript.scrollView, let frame = element.frame else {
                throw StoryFailure.other("\(row) has no frame in a scroll view")
            }
            top = scroll.convert(scroll.bounds, to: nil).maxY - scroll.contentInsets.top
            var off = top - at - frame.maxY
            for _ in 0..<10 where abs(off) > 2 {
                try await story.input.scroll(element, to: .by(off))
                try? await Task.sleep(for: .milliseconds(500))
                off = element.frame.map { top - at - $0.maxY } ?? off
            }
            guard abs(off) <= 2 else { throw StoryFailure.other("\(row) didn't stay \(Int(at)) pt below the top of the view (\(Int(off)) pt off)") }
            id = element.id
        } else {
            // To the end as a reader scrolls, a little at a time, the rows measuring on the way: a
            // scripted turn's glide can stop short, and one jump lands past the rows, on an
            // estimated height.
            let last = try await story.element(.answer(turn: 4))
            id = last.id
            for _ in 0..<80 where !(DevNavProbe.scrollPlace(workspace).map { $0.offset + $0.visible >= $0.height - 2 } ?? false) {
                try await story.input.scroll(last, to: .by(300))
                try? await Task.sleep(for: .milliseconds(50))
            }
            try await story.until("the view at the end, its last row built") {
                StoryElement(last.id)?.frame != nil && (DevNavProbe.scrollPlace(workspace).map { $0.offset + $0.visible >= $0.height - 2 } ?? false)
            }
        }

        let sash = try await story.element(.id(StoryID.Explorer.sash))
        guard let chat = DevNavProbe.transcriptFrame(workspace) else { throw StoryFailure.other("no transcript") }
        // Its rows have reported their texts once it's come to rest.
        let word = try? await story.wait("a word on screen", timeout: .seconds(1)) { try SashWord.nearMiddle(story, of: chat) }
        let sample = { sashSample(story, workspace, row: id, word: word) }
        let before = sample()
        var during: [SashSample] = []
        var after: [SashSample] = []
        // Every pass of the run loop, just after what it drew is committed: a place put right a
        // pass later is on screen for a frame, and shows here.
        let trace = SashTrace()
        let tracer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                let s = sample()
                trace.commits.append((DevNavProbe.scrollPlace(workspace)?.offset ?? 0, s.row?.maxY, s.word?.y))
                if let released = trace.released {
                    let view = s.chat ?? chat
                    let shown = (s.row?.intersects(view) ?? false) && (DevNavProbe.transcriptDrawn(workspace) ?? 0) > 0
                    trace.after.append((ContinuousClock.now - released, shown))
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), tracer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), tracer, .commonModes) }
        let frames = try await DevNavProbe.recording(workspace) {
            let (window, start) = try await story.input.press(sash)
            for i in 1...steps {
                await story.input.moved(to: CGPoint(x: start.x + by * CGFloat(i) / CGFloat(steps), y: start.y), in: window)
                try? await Task.sleep(for: pause)
                during.append(sample())
            }
            trace.released = ContinuousClock.now
            await story.input.release(at: CGPoint(x: start.x + by, y: start.y), in: window)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(10))
                after.append(sample())
            }
        }
        // On past the second a blank may last, outside the frame times.
        if row == nil {
            try? await Task.sleep(for: .milliseconds(1000))
            after.append(sample())
        }

        let widths = during.map { ($0.chat?.width ?? 0) }
        let rowStep = zip([before] + during, during).compactMap { a, b -> Double? in
            guard let x = a.row, let y = b.row else { return nil }
            return abs(Double(y.maxY - x.maxY))
        }
        let rowAcross = during.compactMap { $0.row.map { abs($0.minX - (before.row?.minX ?? $0.minX)) } }.max() ?? 0
        let rowDown = during.compactMap { $0.row.map { abs($0.maxY - (before.row?.maxY ?? $0.maxY)) } }.max() ?? 0
        let endStep = during.map { abs($0.fromEnd) }
        let wordStep = zip([before] + during, during).compactMap { a, b -> Double? in
            guard let x = a.word, let y = b.word else { return nil }
            return Double(hypot(y.x - x.x, y.y - x.y))
        }
        let wordDown = during.compactMap { s in s.word.flatMap { w in before.word.map { Double(abs(w.y - $0.y)) } } }.max() ?? 0
        let wordAcross = during.compactMap { s in s.word.flatMap { w in before.word.map { Double(abs(w.x - $0.x)) } } }.max() ?? 0
        let wraps = Set(([before] + during + after).compactMap { $0.chat.map { Int($0.width.rounded()) } }).count - 1
        // Where the reader's place went, as `ResizeHolds`: the top of the row, or as far into it
        // as the top of the view was.
        let share = (before.row?.height ?? 0) > 0 ? max(0, ((before.row?.maxY ?? 0) - top) / (before.row?.height ?? 1)) : 0
        func spot(_ r: CGRect) -> CGFloat { r.maxY - share * r.height }
        let settled = after.last
        let drift = settled?.row.flatMap { r in before.row.map { spot(r) - spot($0) } }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        try sashNote(story, """
            \(story.name) \(row.map { "\($0) at \(Int(at))" } ?? "end") by \(Int(by)): chat \(Int(chat.width)) pt, \(Set(widths.map { Int($0.rounded()) }).count) widths during the drag; \
            row per step mean \(f(rowStep.isEmpty ? 0 : rowStep.reduce(0, +) / Double(rowStep.count))) max \(f(rowStep.max() ?? 0)) pt, moved at most \(f(Double(rowDown))) down, \(f(Double(rowAcross))) across; \
            word \(word == nil ? "none" : "per step median \(f(wordStep.sorted().dropFirst(wordStep.count / 2).first ?? 0)) mean \(f(wordStep.isEmpty ? 0 : wordStep.reduce(0, +) / Double(wordStep.count))) max \(f(wordStep.max() ?? 0)) pt, moved at most \(f(wordDown)) down, \(f(wordAcross)) across"); \
            from end at most \(f(endStep.max() ?? 0)); wraps \(wraps); settled drift \(drift.map { f(Double($0)) } ?? "-"), from end \(f(settled?.fromEnd ?? 0)); \
            frames \(frames.frames), over 33 ms \(frames.over33), p95 \(f(frames.p95)) ms, worst \(f(frames.worst)) ms
            """)

        CFRunLoopRemoveObserver(CFRunLoopGetMain(), tracer, .commonModes)
        func jumps(_ v: [CGFloat?]) -> String {
            let d = zip(v, v.dropFirst()).compactMap { a, b -> CGFloat? in a.flatMap { x in b.map { abs($0 - x) } } }.filter { $0 > 0.5 }.sorted()
            return "\(d.count) moves, median \(f(Double(d.dropFirst(d.count / 2).first ?? 0))), max \(f(Double(d.last ?? 0)))"
        }
        try sashNote(story, "  every commit (\(trace.commits.count)): offset \(jumps(trace.commits.map { CGFloat($0.offset) })); row \(jumps(trace.commits.map(\.row))); word \(jumps(trace.commits.map(\.word)))")
        // The sidebar follows the pointer at every step.
        let sidebarOff = during.enumerated().map { i, s in abs(s.sidebar - (before.sidebar + by * CGFloat(i + 1) / CGFloat(steps))) }.max() ?? 0
        guard sidebarOff <= 2 else { throw StoryFailure.expectation("the sidebar following the pointer (up to \(f(Double(sidebarOff))) pt off)") }
        // The chat holds still through the drag.
        guard Set(widths.map { Int($0.rounded()) }) == [Int(chat.width.rounded())] else {
            throw StoryFailure.expectation("the chat at \(Int(chat.width)) pt all through the drag (it went through \(Set(widths.map { Int($0.rounded()) }).count) widths, \(Int(widths.first ?? 0)) to \(Int(widths.last ?? 0)))")
        }
        guard wordDown <= 0.5, wordAcross <= 0.5 else {
            throw StoryFailure.expectation("the text on screen still through the drag (a word moved up to \(f(wordDown)) pt down, \(f(wordAcross)) across)")
        }
        guard during.allSatisfy({ $0.row != nil }), rowDown <= 0.5, rowAcross <= 0.5 else {
            throw StoryFailure.expectation("the reader's row still through the drag (it moved up to \(f(Double(rowDown))) pt down, \(f(Double(rowAcross))) across)")
        }
        // Wrapped once, to the room left.
        guard wraps == 1 else { throw StoryFailure.expectation("one new width on release (\(wraps))") }
        // How the release went: passes with the last row off screen or nothing drawn, and how long
        // after release the last of them was.
        let moves = zip(trace.commits, trace.commits.dropFirst()).filter { abs($0.0.offset - $0.1.offset) > 0.5 }.count
        let gaps = trace.after.filter { !$0.shown }
        let gap = gaps.last?.at ?? .zero
        try sashNote(story, "  release: \(gaps.count) of \(trace.after.count) passes blank, the last \(gap) after release; \(moves) moves of the view")
        let want = chat.width - by
        guard let last = settled?.chat, abs(last.width - want) <= 1 else {
            throw StoryFailure.expectation("the chat \(Int(want)) pt wide after release (\(Int(settled?.chat?.width ?? 0)))")
        }
        // The reader's place kept.
        if row != nil {
            guard let drift, abs(drift) <= 2 else { throw StoryFailure.expectation("the reader's place kept on release (moved \(drift.map { f(Double($0)) } ?? "off the built rows"))") }
        } else {
            guard (settled?.fromEnd ?? .infinity) <= 2 else {
                throw StoryFailure.expectation("the view at the end after release (above it by \(Int(settled?.fromEnd ?? -1)))")
            }
            // Blank for a moment can happen; never past a second.
            guard gap <= .seconds(1), trace.after.last?.shown == true else {
                throw StoryFailure.expectation("the last row on screen and drawn within a second of release (blank \(gap) after it, and \(trace.after.last?.shown == true ? "drawn" : "still blank") at the end)")
            }
        }
    }
}

// MARK: - The sash itself

/// The sash's reach and limits: a press up to 5 pt either side of the line is its, one 8 pt off
/// isn't; it stops at the sidebar's least and most with the chat still; a double-click gives the
/// sidebar back its own width, the chat wrapping once.
final class SashReachAndLimits: SashStoryline {
    static let files = (1...80).map { (path: "file\($0).txt", text: "x\n") }

    override func steps() -> [any Step] {
        [WriteFiles(Self.files)] + super.steps() + [
            WaitForElement(.treeRow("file1.txt")),
            SashPress(off: 5, moves: true), SashPress(off: -5, moves: true), SashPress(off: 8, moves: false), SashPress(off: -8, moves: false),
            SashClamps(by: -1000), SashClamps(by: 1000),
            SashDouble(),
        ]
    }
}

/// A press `off` the line in the window (no element under it to check first), dragged 20 pt.
private struct SashPress: Step {
    let off: CGFloat
    let moves: Bool
    var label: String { "A press \(Int(off)) pt off the line \(moves ? "drags" : "doesn't drag") the sash" }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace, let window = story.window else { throw StoryFailure.modelMissing("the workspace") }
        let sash = try await story.element(.id(StoryID.Explorer.sash))
        guard let frame = sash.frame else { throw StoryFailure.other("no sash") }
        let was = workspace.storyExplorerWidth
        // Off the line to the left, by the sidebar's header: a press on a tree row starts its own
        // drag of the file, which needs the window server.
        let start = CGPoint(x: frame.midX + off, y: moves ? frame.midY : frame.maxY - 8)
        await story.input.drag(from: start, to: CGPoint(x: start.x + 20, y: start.y), in: window, steps: 8)
        let moved = workspace.storyExplorerWidth - was
        guard abs(moved - (moves ? 20 : 0)) <= 1 else { throw StoryFailure.expectation("the sidebar \(moves ? "20 pt" : "no") wider (\(moved))") }
        try await story.idle()
    }
}

/// Far past its limit: the sidebar stops there and the chat stays as it was until release.
private struct SashClamps: Step {
    let by: CGFloat
    var label: String { "Drag the sash \(Int(by)) pt, past its limit" }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        let sash = try await story.element(.id(StoryID.Explorer.sash))
        guard let chat = DevNavProbe.transcriptFrame(workspace) else { throw StoryFailure.other("no transcript") }
        let was = workspace.storyExplorerWidth
        let (window, start) = try await story.input.press(sash)
        for i in 1...10 {
            await story.input.moved(to: CGPoint(x: start.x + by * CGFloat(i) / 10, y: start.y), in: window)
            guard DevNavProbe.transcriptFrame(workspace)?.width == chat.width else { throw StoryFailure.expectation("the chat held at step \(i)") }
        }
        let limit = by < 0 ? Workspace.storyExplorerRange.lowerBound : Workspace.storyExplorerRange.upperBound
        guard workspace.storyExplorerWidth == limit else { throw StoryFailure.expectation("the sidebar at \(limit) (\(workspace.storyExplorerWidth))") }
        await story.input.release(at: CGPoint(x: start.x + by, y: start.y), in: window)
        let want = chat.width - (limit - was)
        try await story.until("the chat \(Int(want)) pt wide") { abs((DevNavProbe.transcriptFrame(workspace)?.width ?? 0) - want) <= 1 }
        try await story.idle()
    }
}

private struct SashDouble: Step {
    var label: String { "Double-click the sash" }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        let sash = try await story.element(.id(StoryID.Explorer.sash))
        guard let chat = DevNavProbe.transcriptFrame(workspace) else { throw StoryFailure.other("no transcript") }
        let was = workspace.storyExplorerWidth, own = Workspace.storyExplorerOwnWidth
        guard abs(was - own) > 10 else { throw StoryFailure.other("the sidebar at its own width already") }
        try await story.input.pointerClick(sash, count: 2)
        try await story.until("the sidebar at its own width") { workspace.storyExplorerWidth == own }
        let want = chat.width - (own - was)
        try await story.until("the chat \(Int(want)) pt wide") { abs((DevNavProbe.transcriptFrame(workspace)?.width ?? 0) - want) <= 1 }
        try await story.idle()
    }
}

// MARK: - A drag cut off

/// A drag whose end never comes: the chat is held no longer, whichever way it went, the sash and
/// everything around it take the pointer as before, and a next drag goes as any.
final class SashDragCutOff: SashStoryline {
    override func steps() -> [any Step] {
        super.steps() + [
            SashCut(how: .sidebarHidden), SashCut(how: .pointerFree), SashCut(how: .focusLost), SashCut(how: .tabSwitched),
            SashDrag(row: nil, by: 60),
        ]
    }
}

private struct SashCut: Step {
    enum How { case sidebarHidden, pointerFree, focusLost, tabSwitched }
    let how: How
    var label: String { "A sash drag ended by \(how)" }
    var timeout: Duration? { .seconds(20) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        let sash = try await story.element(.id(StoryID.Explorer.sash))
        guard let chat = DevNavProbe.transcriptFrame(workspace) else { throw StoryFailure.other("no transcript") }
        let was = workspace.storyExplorerWidth
        let (window, start) = try await story.input.press(sash)
        func to(_ x: CGFloat) async { await story.input.moved(to: CGPoint(x: start.x + x, y: start.y), in: window) }
        for i in 1...12 { await to(CGFloat(i) * 5) }
        guard DevNavProbe.transcriptFrame(workspace)?.width == chat.width else { throw StoryFailure.expectation("the chat held before the cut") }
        func chatWide(_ want: CGFloat) async throws {
            try await story.until("the chat \(Int(want)) pt wide (\(Int(DevNavProbe.transcriptFrame(workspace)?.width ?? 0)))") {
                abs((DevNavProbe.transcriptFrame(workspace)?.width ?? 0) - want) <= 1
            }
        }
        switch how {
        case .sidebarHidden:
            workspace.explorerOpen = false
            try await chatWide(window.contentView?.bounds.width ?? 0)
            await story.input.release(at: CGPoint(x: start.x + 60, y: start.y), in: window)
            workspace.explorerOpen = true
            _ = try await story.element(.id(StoryID.Explorer.sash))
            try await chatWide(chat.width - 60)
        case .pointerFree:
            await story.input.movedFree(to: CGPoint(x: start.x + 60, y: start.y), in: window)
            try await chatWide(chat.width - 60)
            await story.input.release(at: CGPoint(x: start.x + 60, y: start.y), in: window)
        case .focusLost:
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            try await chatWide(chat.width - 60)
            // The button still down, it carries on from the pointer with no jump, and ends.
            for i in 13...16 { await to(CGFloat(i) * 5) }
            let moved = workspace.storyExplorerWidth - was
            guard abs(moved - 75) <= 5.5 else { throw StoryFailure.expectation("the sidebar carrying on from the pointer (\(moved) pt)") }
            let carried = workspace.storyExplorerWidth - was
            await story.input.release(at: CGPoint(x: start.x + 80, y: start.y), in: window)
            try await chatWide(chat.width - carried)
        case .tabSwitched:
            try await Command(.newTab).run(story)
            await to(65)
            await story.input.release(at: CGPoint(x: start.x + 65, y: start.y), in: window)
            try await Press(.tab(1)).run(story)
            try await chatWide(chat.width - 65)
        }
        // The sash is itself again: a click beside it lands.
        try await story.idle()
        let field = try await story.element(.id(StoryID.Composer.field))
        guard let spot = field.frame else { throw StoryFailure.other("no composer") }
        await story.input.click(at: CGPoint(x: spot.midX, y: spot.midY), in: window)
        try await WaitForFocus(.id(StoryID.Composer.field)).run(story)
        // Back where it started, for the next.
        let (w, p) = try await story.input.press(try await story.element(.id(StoryID.Explorer.sash)))
        let back = was - workspace.storyExplorerWidth
        await story.input.moved(to: CGPoint(x: p.x + back, y: p.y), in: w)
        await story.input.release(at: CGPoint(x: p.x + back, y: p.y), in: w)
        try await chatWide(chat.width)
        try await story.idle()
    }
}

// MARK: - Whatever sits beside it

/// What's in the content column holds still too: a file in its tab.
final class SashHoldsFileTab: Storyline {
    override class var tags: Set<Tag> { [.files, .gate] }

    override func steps() -> [any Step] {
        [WriteFiles([(FileTabState.notes, (1...200).map { "Paragraph \($0): a few words that wrap at a narrower width, and then some more to be sure of it." }.joined(separator: "\n\n"))]),
            OpenFolder(), StartChat("claude"), Command(.toggleExplorer), WaitForElement(.id(StoryID.Explorer.sash))]
            + FileTabState.open(FileTabState.notes)
            + [WaitForElement(.id(StoryID.Editor.rows)), SashHolds(.id(StoryID.Explorer.sash), held: { _ in StoryID.Editor.rows }, by: 100)]
    }
}

/// And a board's tiles.
final class SashHoldsBoard: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            MakeBoard(name: "Backend", take: 2),
            Command(.toggleExplorer), WaitForElement(.id(StoryID.Explorer.sash)),
            SashHolds(.id(StoryID.Explorer.sash), held: { story in
                guard let tile = try BoardProbe.model(story).board.tiles.first?.id else { throw StoryFailure.modelMissing("a tile") }
                return StoryID.Board.tile(tile)
            }, by: 100),
        ]
    }
}

/// `held`'s frame is the same at every step of a sash's drag `by`, and narrower after release.
struct SashHolds: Step {
    let sash: Locator
    let held: @MainActor (StoryContext) throws -> StoryID
    let by: CGFloat
    init(_ sash: Locator, held: @escaping @MainActor (StoryContext) throws -> StoryID, by: CGFloat) {
        self.sash = sash
        self.held = held
        self.by = by
    }
    var label: String { "Drag \(sash) \(Int(by)) pt with what's beside it held" }

    func run(_ story: StoryContext) async throws {
        let id = try held(story)
        guard let before = try await story.element(.id(id)).frame else { throw StoryFailure.other("\(id) has no frame") }
        let (window, start) = try await story.input.press(try await story.element(sash))
        for i in 1...20 {
            await story.input.moved(to: CGPoint(x: start.x + by * CGFloat(i) / 20, y: start.y), in: window)
            try? await Task.sleep(for: .milliseconds(8))
            guard let now = StoryElement(id)?.frame, abs(now.width - before.width) <= 0.5, abs(now.maxX - before.maxX) <= 0.5, abs(now.maxY - before.maxY) <= 0.5 else {
                throw StoryFailure.expectation("\(id) as it was at step \(i): \(before), now \(String(describing: StoryElement(id)?.frame))")
            }
        }
        await story.input.release(at: CGPoint(x: start.x + by, y: start.y), in: window)
        try await story.until("\(id) narrower after release") { (StoryElement(id)?.frame?.width ?? before.width) < before.width - 20 }
        try await story.idle()
    }
}
