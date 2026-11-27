import AppKit
import KoreCore
import KoreUI
import QuartzCore
import src

// The UI at scale (scripts/ui-scale.sh): every area of the window worked as a person works it,
// at the run's window size (`--size`: narrow, laptop, very large), with a light load (the area's
// own storyline, its checks as the gate runs them) and a heavy one (30 tabs, a chat of 300
// turns, a folder of 500 files). Each click or key is timed to the frame it settles on, against
// a budget; each area ends with a look at its frames (steady, nothing cut off) as the live
// check takes it. The numbers go to `ui-scale.jsonl` in the run's folder; ui-scale.sh turns
// them into one line per area × load × size.

extension Tag {
    /// The UI-at-scale run (scripts/ui-scale.sh).
    package static let scale: Tag = "scale"
}

// MARK: - The clock and the log

/// The main display's frame clock, ticking in the common modes. A window off every screen (a
/// storyline's) gets no frames of its own: the main display paces it, as DevFramePacer does.
@MainActor final class ScaleClock: NSObject {
    static let shared = ScaleClock()
    private var link: CADisplayLink?
    private(set) var duration: CFTimeInterval = 1.0 / 60
    private(set) var last: CFTimeInterval = 0
    /// The longest gap between two frames since `mark()`: the main thread's longest stall.
    private(set) var longest: CFTimeInterval = 0

    func mark() {
        longest = 0
        last = CACurrentMediaTime()
    }
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var next = 0

    func start() {
        guard link == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if last > 0 { longest = max(longest, now - last) }
        last = now
        if link.duration > 0 { duration = link.duration }
        let ready = waiters
        waiters = [:]
        for (_, waiter) in ready { waiter.resume(returning: true) }
    }

    /// The next frame; false when none comes within `seconds` (no display).
    func frame(within seconds: Double = 0.5) async -> Bool {
        next += 1
        let id = next
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            waiters[id] = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                guard let self, let waiter = waiters.removeValue(forKey: id) else { return }
                waiter.resume(returning: false)
            }
        }
    }

    /// From `since` (the action done): the first frame that two more follow on time, the main
    /// thread free and drawing at the display's pace again, and the longest gap between frames
    /// on the way (the main thread's longest stall). nil settle: still stalling after `limit` s.
    func settle(since: CFTimeInterval, limit: Double = 3) async -> (settled: CFTimeInterval?, worst: CFTimeInterval) {
        start()
        var previous = since
        var candidate: CFTimeInterval?
        var onTime = 0
        var worst: CFTimeInterval = 0
        while CACurrentMediaTime() - since < limit {
            guard await frame() else { return (CACurrentMediaTime(), worst) }
            let now = last
            let gap = now - previous
            worst = max(worst, gap)
            if gap <= duration * 1.5 + 0.002 {
                if candidate == nil { candidate = previous }
                onTime += 1
                if onTime >= 2 { return (candidate, worst) }
            } else {
                onTime = 0
                candidate = nil
            }
            previous = now
        }
        return (nil, worst)
    }
}

/// One line per measure in `<out>/ui-scale.jsonl`.
@MainActor enum ScaleLog {
    static func write(_ story: StoryContext, _ fields: [String: Any]) {
        var row = fields
        row["story"] = story.name
        row["variant"] = story.variant?.name ?? ""
        let size = story.window?.contentView?.bounds.size ?? story.windowSize
        row["size"] = "\(Int(size.width))x\(Int(size.height))"
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        let url = story.outputs.appendingPathComponent("ui-scale.jsonl")
        let line = data + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    static func ms(_ seconds: CFTimeInterval) -> Double { (seconds * 10_000).rounded() / 10 }
}

// MARK: - Steps

/// Where a failure from here on belongs: the area and the load it was worked at.
struct ScaleBegin: Step {
    let element: String
    let load: String
    var label: String { "· \(element), \(load)" }
    func run(_ story: StoryContext) async throws {
        ScaleClock.shared.start()
        ScaleLog.write(story, ["kind": "begin", "element": element, "load": load])
    }
}

/// A click or key, timed: its own work on the main thread (`busy`), and the time until the
/// window draws at the display's pace again (`ms`, against `budget`). Over the budget is logged,
/// not thrown: the area's later steps still run and are timed.
struct Timed: Step {
    let inner: any Step
    let element: String
    let load: String
    var budget = 100.0
    var label: String { inner.label }
    var timeout: Duration? { inner.timeout }

    func run(_ story: StoryContext) async throws {
        let clock = ScaleClock.shared
        clock.start()
        clock.mark()
        let began = CACurrentMediaTime()
        try await inner.run(story)
        let done = CACurrentMediaTime()
        let (settled, _) = await clock.settle(since: done)
        let worst = clock.longest
        // A click or key: from the action to the settled frame (its own handling included). A
        // gesture that takes time by design (a drag, typing, a menu walked): its longest frame
        // gap, or the settling after it, whichever is longer.
        let gesture = Self.gestures.contains(String(describing: type(of: inner)))
        let after = settled.map { $0 - done } ?? 3
        let ms = gesture ? ScaleLog.ms(max(worst, after)) : (settled.map { ScaleLog.ms($0 - began) } ?? 3000)
        ScaleLog.write(story, [
            "kind": "step", "element": element, "load": load, "label": inner.label, "ms": ms,
            "busy": ScaleLog.ms(done - began), "worst": ScaleLog.ms(worst), "budget": budget, "settled": settled != nil,
            "measure": gesture ? "gesture" : "action",
        ])
    }

    /// Steps that take time by design: judged by their frames, not their length.
    static let gestures: Set<String> = ["DragSelect", "Drag", "TypeText", "TreeMenuItem", "Scroll", "Wheel", "PasteText", "Send"]

    /// The steps a person does: these are timed, the waits and checks between them aren't.
    static let kinds: Set<String> = [
        "Press", "Click", "RightClick", "Key", "KeyIn", "TypeText", "Scroll", "Wheel", "PasteText", "Drag", "DoubleClick",
        "Send", "DragSelect", "PressChip", "HoverCode", "TreeMenuItem", "Command", "ScalePressCopy", "ScaleHoverCode",
    ]

    static func wrap(_ steps: [any Step], _ element: String, _ load: String) -> [any Step] {
        steps.map { step in
            let kind = String(describing: type(of: step))
            let acts = kinds.contains(kind)
                || (kind == "Do" && ["Click", "Press", "⌘", "Open", "Type"].contains { step.label.hasPrefix($0) })
            return acts ? Timed(inner: step, element: element, load: load) : step
        }
    }
}

/// A popup whole inside the window, at its anchor (touching it above or below, overlapping it
/// across), while it's open.
struct AnchoredInside: Step {
    let what: String
    let popup: StoryID
    let anchor: StoryID
    var label: String { "\(what): whole in the window, at its anchor" }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window, let bounds = window.contentView?.bounds else { throw StoryFailure.modelMissing("the window") }
        let popupFrame = try await story.wait("\(what)'s frame") { StoryRegistry.entry(popup.raw, in: window)?.frame }
        guard let anchorFrame = StoryRegistry.entry(anchor.raw, in: window)?.frame else { throw StoryFailure.elementNotFound(anchor.raw, nearby: []) }
        let file = { LiveEyes.frame(window).map { LiveEyes.save($0, "\(story.name)-\(what)", story) } ?? "" }
        if !bounds.insetBy(dx: -0.5, dy: -0.5).contains(popupFrame) {
            throw StoryFailure.other("\(what) cut off: \(Self.text(popupFrame)) in \(Self.text(bounds)) (\(file()))")
        }
        let across = popupFrame.maxX >= anchorFrame.minX - 40 && popupFrame.minX <= anchorFrame.maxX + 40
        // Composer popups rise over the whole composer, not just their chip: up to the composer's
        // height (about 80 pt with its padding) above the anchor still reads as its popup.
        let above = popupFrame.minY >= anchorFrame.maxY - 6 && popupFrame.minY - anchorFrame.maxY <= 90
        let below = anchorFrame.minY >= popupFrame.maxY - 6 && anchorFrame.minY - popupFrame.maxY <= 30
        if !across || !(above || below) {
            throw StoryFailure.other("\(what) away from its anchor: \(Self.text(popupFrame)) for \(Self.text(anchorFrame)) (\(file()))")
        }
        ScaleLog.write(story, ["kind": "layout", "label": "\(what) at its anchor", "ok": true])
    }

    static func text(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))" }
}

/// Scrolls the active transcript `px` up at a person's speed and back, frames timed: the
/// 95th percentile against `budget` (16 ms).
struct ScaleScroll: Step {
    let element: String
    let load: String
    var px: Double = 12_000
    var budget = 16.0
    var label: String { "Scroll \(Int(px)) pt up and down, frames timed" }
    var timeout: Duration? { .seconds(40) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        let frames = await DevNavProbe.recording(workspace) {
            _ = await DevNavProbe.scrollUp(workspace, by: px, speed: 3000)
            _ = await DevNavProbe.scrollUp(workspace, by: -px, speed: 3000)
        }
        ScaleLog.write(story, [
            "kind": "frames", "element": element, "load": load, "label": label, "ms": (frames.p95 * 10).rounded() / 10,
            "worst": (frames.worst * 10).rounded() / 10, "frames": frames.frames, "over33": frames.over33, "budget": budget,
        ])
    }
}

/// The area's frames once it settles (steady, no work word left over, nothing clipped: the
/// live check's Look) and the window's edge controls whole.
@MainActor func scaleLook(_ element: String, _ load: String, edges: [StoryID] = LiveZoom.edges) -> [any Step] {
    [
        ScaleBegin(element: element + " layout", load: load),
        Look(name: "\(element)-\(load.replacingOccurrences(of: " ", with: "-"))", frames: 2),
        InsideWindow(ids: edges),
    ]
}

// MARK: - Light: each area's own storyline, at the run's size

/// An area: the storyline it walks, every click and key timed, then a look at it.
class ScaleArea: Storyline {
    override class var isFamily: Bool { self == ScaleArea.self }
    override class var tags: Set<Tag> { [.scale] }
    class var wraps: Storyline.Type? { nil }
    /// A storyline found by name as the run starts: one a build may not have yet (a feature not on
    /// its base). Without it the area is pending, not failed (`ScalePending`).
    class var wrapsName: String? { nil }
    class var element: String { "" }
    /// "light", or "30 tabs": the walk with 29 more chat tabs opened before its own chat.
    class var load: String { "light" }
    /// The storyline walked: `wraps`, or the one named `wrapsName` in this build.
    class var walks: Storyline.Type? { wraps ?? wrapsName.flatMap(ScaleNamed.type) }
    override class var variants: [Variant] { walks?.variants ?? [.only] }
    override class var needs: Needs { walks?.needs ?? Needs() }

    func walked() -> [any Step] {
        guard let type = Self.walks else { return [] }
        let story = type.init()
        story.variant = variant
        let steps = story.steps()
        guard Self.load == ScaleLoad.tabs30 else { return steps }
        // The 29 tabs open once the folder's window is up, before the area's own chat: it is the
        // 30th, in front, as the walk expects.
        guard let at = steps.firstIndex(where: { $0 is OpenFolder }) else { return steps }
        return Array(steps[...at]) + [OpenTabs(29)] + Array(steps[(at + 1)...])
    }

    /// Checks after the walk, timed the same way.
    func extra() -> [any Step] { [] }
    /// The window's edge controls this area keeps on screen.
    var edges: [StoryID] { LiveZoom.edges }

    override func steps() -> [any Step] {
        let begin = ScaleBegin(element: Self.element, load: Self.load)
        if Self.walks == nil, let name = Self.wrapsName {
            return [begin, ScalePending(element: Self.element, load: Self.load, what: "\(name) (not in this build)")]
        }
        return [begin] + Timed.wrap(walked() + extra(), Self.element, Self.load)
            + scaleLook(Self.element, Self.load, edges: edges)
    }
}

/// The loads' names, as the report groups them.
enum ScaleLoad {
    static let light = "light"
    static let tabs30 = "30 tabs"
    static let hugeChat = "huge chat"
    static let files500 = "500 files"
}

/// Select, ⇧-select, ⌘W and ⇧⌘T, the drafts back where they were.
final class ScaleTabs: ScaleArea {
    override class var wraps: Storyline.Type? { TabSelectCloseReopen.self }
    override class var element: String { "tabs" }
    override class var variants: [Variant] { [.claude] }
}

/// A held tab groups; the name popup names it.
final class ScaleGroups: ScaleArea {
    override class var wraps: Storyline.Type? { TabGroupMake.self }
    override class var element: String { "groups" }
    override class var variants: [Variant] { [.codex] }
}

final class ScaleModel: ScaleArea {
    override class var wraps: Storyline.Type? { ModelPicker.self }
    override class var element: String { "model picker" }
}

final class ScaleMode: ScaleArea {
    override class var wraps: Storyline.Type? { ModePicker.self }
    override class var element: String { "mode picker" }
}

/// The KoreNet switch on and off, a phone allowed and denied, the add window's ×.
final class ScaleDevices: ScaleArea {
    override class var wraps: Storyline.Type? { DevicesAddPhone.self }
    override class var element: String { "devices" }
    override class var variants: [Variant] { [.claude] }
}

/// The agent map opens with every agent, and closing it gives the chat back as it was.
final class ScaleAgents: ScaleArea {
    override class var wraps: Storyline.Type? { AgentMapOpen.self }
    override class var element: String { "agents" }
    override class var variants: [Variant] { [.claude] }
}

/// A search finds a message; picked, the chat opens at it.
final class ScaleHistory: ScaleArea {
    override class var wraps: Storyline.Type? { HistorySearchesWords.self }
    override class var element: String { "history" }
    override class var variants: [Variant] { [.codex] }
}

/// Copy, paste, duplicate, rename (undone, redone), Open in Terminal, Find in Folder, a drop.
final class ScaleExplorer: ScaleArea {
    override class var wraps: Storyline.Type? { ExplorerFileOps.self }
    override class var element: String { "explorer" }
    override class var variants: [Variant] { [.claude] }
    override var edges: [StoryID] { [StoryID.Titlebar.newtab, StoryID.Titlebar.history] }
}

final class ScaleCopyTable: ScaleArea {
    override class var wraps: Storyline.Type? { TableCopy.self }
    override class var element: String { "copy table" }
}

/// The code block's Copy shows under it, and puts its code on the pasteboard, exactly.
final class ScaleCopyCode: ScaleArea {
    override class var wraps: Storyline.Type? { CodeBlockCopyBelow.self }
    override class var element: String { "copy code" }
    override func extra() -> [any Step] { ScaleCopy.code("swift build", block: 0) }
}

/// A mark's click brings its message to the top, reading it in when it has to.
final class ScaleRail: ScaleArea {
    override class var wraps: Storyline.Type? { MessageRailMarks.self }
    override class var element: String { "rail" }
}

/// The composer sends; the answer streams in; the turn ends.
final class ScaleComposer: ScaleArea {
    override class var wraps: Storyline.Type? { SendAndStream.self }
    override class var element: String { "composer" }
}

/// The terminal: a shell in the folder echoes, survives tab changes and hiding.
final class ScaleTerminal: ScaleArea {
    override class var wraps: Storyline.Type? { WindowTerminal.self }
    override class var element: String { "terminal" }
    override class var variants: [Variant] { [.codex] }
}

/// Arsenal on: the chat's logo, spinner and `>_` in Arsenal blue and no tab corners; off: their
/// own colours (read off the window's pixels).
final class ScaleArsenal: ScaleArea {
    override class var wraps: Storyline.Type? { ArsenalLogoTint.self }
    override class var element: String { "arsenal" }
    override class var variants: [Variant] { [.codex] }
}

/// Copy's checks: the block's Copy pressed puts exactly its code on the pasteboard.
@MainActor enum ScaleCopy {
    static func code(_ text: String, block: Int, last: Bool = false) -> [any Step] {
        [
            Do("clear the pasteboard") { _ in StoryTranscript.clearCopied() },
            ScaleHoverCode(block: block, last: last),
            ScalePressCopy(block: block, last: last),
            Expect("the pasteboard holds exactly the code", found: { _ in StoryTranscript.copied.map { "\"\($0)\"" } ?? "nothing" }) { _ in
                StoryTranscript.copied == text
            },
        ]
    }
}

/// Hovers a code block (by place, or the last on screen) so its Copy shows.
struct ScaleHoverCode: Step {
    let block: Int
    var last = false
    var label: String { last ? "Hover the last code block" : "Hover code block \(block + 1)" }
    func run(_ story: StoryContext) async throws {
        try await story.until("a code block on screen") { CodeBlockCopyBelow.blocks().count > (last ? 0 : block) }
        let ids = CodeBlockCopyBelow.blocks()
        guard let id = last ? ids.last : ids[block] as String? else { throw StoryFailure.modelMissing("a code block") }
        try await Press(.id(StoryID.Transcript.code(CodeBlockCopyBelow.path(id)).part(.hover))).run(story)
    }
}

/// Presses a code block's Copy once it shows (a frame after the hover).
struct ScalePressCopy: Step {
    let block: Int
    var last = false
    var label: String { "Press the code block's Copy" }
    func run(_ story: StoryContext) async throws {
        let id = try await story.wait("the code block's Copy") { () -> String? in
            let ids = CodeBlockCopyBelow.blocks()
            guard let id = last ? ids.last : (ids.indices.contains(block) ? ids[block] : nil) else { return nil }
            return StoryRegistry.entry(id + ".copy")?.frame == nil ? nil : id
        }
        try await Click(.id(StoryID.Transcript.code(CodeBlockCopyBelow.path(id)).part(.copy))).run(story)
    }
}

// MARK: - Heavy: the same work at a heavy load

/// 30 tabs: select one past the middle, ⇧-select four, ⌘W, ⇧⌘T, the last tab.
final class ScaleTabs30: Storyline {
    override class var tags: Set<Tag> { [.scale] }
    override class var variants: [Variant] { [.claude] }
    static let element = "tabs"
    static let load = "30 tabs"

    override func steps() -> [any Step] {
        let active = { (n: Int) in
            Expect("tab \(n) shown", found: { story in
                guard let w = story.app.workspace else { return nil }
                return "\((w.tabs.firstIndex { $0 === w.activeTab } ?? -1) + 1)"
            }) { story in
                let w = try TabGroupProbe.workspace(story)
                return w.tabs.indices.contains(n - 1) && w.activeTab === w.tabs[n - 1]
            }
        }
        let setup: [any Step] = [
            ScaleBegin(element: Self.element, load: Self.load),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])), OpenFolder(), StartChat(), OpenTabs(29),
            Do("A draft in each tab: tab 1 … tab 30") { story in
                for (n, tab) in try TabGroupProbe.workspace(story).tabs.enumerated() { tab.chat?.draft = "tab \(n + 1)" }
            },
        ]
        let work: [any Step] = [
            Click(.tab(1)), active(1),
            Click(.tab(17)), active(17),
            Click(.tab(20), modifiers: .shift),
            Expect("tabs 17–20 picked", found: { (try? TabSelectProbe.picked($0))?.map { $0 + 1 }.description }) { try TabSelectProbe.picked($0) == [16, 17, 18, 19] },
            Key(KeyChord(.character("w"), .command)),
            Expect("four closed, 26 left", found: { "\($0.app.workspace?.tabs.count ?? -1)" }) { try TabGroupProbe.workspace($0).tabs.count == 26 },
            Key(KeyChord(.character("t"), [.command, .shift])),
            Expect("all four back where they were", found: { story in story.app.workspace?.tabs.map { $0.chat?.draft ?? "-" }.joined(separator: ",") }) { story in
                try TabGroupProbe.workspace(story).tabs.map { $0.chat?.draft } == (1...30).map { "tab \($0)" }
            },
            Click(.tab(30)), active(30),
            Click(.tab(1)), active(1),
        ]
        return setup + Timed.wrap(work, Self.element, Self.load) + scaleLook(Self.element, Self.load)
    }
}

/// A chat of 300 turns: opened, scrolled, its rail clicked to the first message and back,
/// the code block and the table at its end copied exactly, both pickers at their anchors, a
/// message sent.
final class ScaleHugeChat: Storyline {
    override class var tags: Set<Tag> { [.scale] }
    override class var variants: [Variant] { [.claude, .codex] }
    static let load = "huge chat"
    static let turns = 300
    static let session = "scripted-scale"
    static let table = StoryID.Transcript.table([1])
    static let lastAnswer = """
        Totals so far:

        | Name | Qty |
        |---|--:|
        | alpha | 3 |
        | beta | 12 |

        ```sh
        echo scale
        ```

        Done.
        """

    /// A screen or two of Markdown: a heading, paragraphs, a list. No code or tables, so the
    /// last answer's are the only ones on screen.
    static func answer(_ n: Int) -> String {
        let words = "The change keeps each row's height once measured, so scrolling back up reuses it rather than laying the row out again; "
        return "### Part \(n)\n\n" + (1...3).map { "Paragraph \($0) of answer \(n). " + String(repeating: words, count: 3) }.joined(separator: "\n\n")
            + "\n\n" + (1...5).map { "- point \($0) of answer \(n), with a few words after it" }.joined(separator: "\n")
    }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let session = "\(Self.session)-\(provider)"
        let marks = { (story: StoryContext) in story.app.chat?.storyTranscript.railMarks ?? [] }
        let codex = variant == .codex
        let (first, second) = codex ? ("askForApproval", "approveForMe") : ("default", "acceptEdits")
        let entries = { (story: StoryContext) in story.app.chat?.storyTranscript.entries ?? [] }
        var steps: [any Step] = [
            ScaleBegin(element: "open", load: Self.load),
            UseScript(CLIScript(turns: [CLIScript.reply("Sent at scale.")])), OpenFolder(), StartChat(),
        ]
        steps += Timed.wrap([
            Do("Open a chat of \(Self.turns) turns") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
                ScriptedWorld.shared.sessions[session] = (0..<Self.turns).flatMap { n in
                    MessageRailMarks.turn(n, session, say: n == Self.turns - 1 ? Self.lastAnswer : Self.answer(n))
                }
                workspace.open(SessionSummary(id: session, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Huge", updated: .now))
            },
        ], "open", Self.load)
        steps += [
            WaitForElement(.id(StoryID.Transcript.rail)),
            Expect("a mark per message", timeout: .seconds(20), found: { "\(marks($0).count)" }) { marks($0).count == Self.turns },
            WaitForElement(.id(ScaleHugeChat.table)),
            ScaleBegin(element: "copy code", load: Self.load),
        ]
        steps += Timed.wrap(ScaleCopy.code("echo scale", block: 0, last: true), "copy code", Self.load)
        steps += [ScaleBegin(element: "copy table", load: Self.load)]
        steps += Timed.wrap([
            Do("clear the pasteboard") { _ in StoryTranscript.clearCopied() },
            Press(.id(ScaleHugeChat.table.part(.hover))),
            Click(.id(ScaleHugeChat.table.part(.copy))),
            Expect("the pasteboard holds exactly the table, tabbed", found: { _ in StoryTranscript.copied ?? "nothing" }) { _ in
                StoryTranscript.copied == "Name\tQty\nalpha\t3\nbeta\t12"
            },
        ], "copy table", Self.load)
        steps += [ScaleBegin(element: "scroll", load: Self.load), ScaleScroll(element: "scroll", load: Self.load)]
        steps += [ScaleBegin(element: "rail", load: Self.load)]
        steps += Timed.wrap([Do("Click the first mark") { $0.app.chat?.storyTranscript.railJump(0) }], "rail", Self.load)
        steps += MessageRailMarks.atTop(0)
        steps += Timed.wrap([Do("Click mark 150") { $0.app.chat?.storyTranscript.railJump(150) }], "rail", Self.load)
        steps += MessageRailMarks.atTop(150)
        steps += Timed.wrap([Do("Click the last mark") { story in story.app.chat?.storyTranscript.railJump(marks(story).count - 1) }], "rail", Self.load)
        steps += [MessageRailMarks.inView(Self.turns - 1)]
        steps += [ScaleBegin(element: "model picker", load: Self.load)]
        steps += Timed.wrap([Press(.id(StoryID.Composer.model))], "model picker", Self.load)
        steps += [
            AnchoredInside(what: "the model picker", popup: StoryID.Composer.models, anchor: StoryID.Composer.model),
        ]
        steps += Timed.wrap([Key(.escape)], "model picker", Self.load)
        steps += [ExpectElement(.id(StoryID.Composer.models), .absent), ScaleBegin(element: "mode picker", load: Self.load)]
        steps += Timed.wrap([Press(.id(StoryID.Composer.mode))], "mode picker", Self.load)
        steps += [AnchoredInside(what: "the mode picker", popup: StoryID.Composer.modes, anchor: StoryID.Composer.mode)]
        steps += Timed.wrap([Press(.id(StoryID.Composer.modeRow(second)))], "mode picker", Self.load)
        steps += [
            ExpectElement(.id(StoryID.Composer.modes), .absent),
            Expect("the click picked \(second)", found: { $0.app.chat?.mode }) { $0.app.chat?.mode == second },
        ]
        steps += Timed.wrap([Press(.id(StoryID.Composer.mode))], "mode picker", Self.load)
        steps += Timed.wrap([Press(.id(StoryID.Composer.modeRow(first)))], "mode picker", Self.load)
        steps += [
            Expect("and back to \(first)", found: { $0.app.chat?.mode }) { $0.app.chat?.mode == first },
            ScaleBegin(element: "composer", load: Self.load),
        ]
        steps += Timed.wrap([Send("One more, at scale")], "composer", Self.load)
        steps += [
            Expect("the message sent and answered", timeout: .seconds(20), found: { story in entries(story).suffix(2).map { "\($0.kind): \($0.text.prefix(30))" }.joined(separator: " / ") }) { story in
                let list = entries(story)
                return list.contains { $0.kind == .user && $0.text == "One more, at scale" } && list.last?.text.contains("Sent at scale.") == true
            },
        ]
        return steps + scaleLook("chat", Self.load)
    }
}

/// 500 files: the explorer opens, a folder expands, a file is renamed and another trashed.
final class ScaleFiles500: FilesStoryline {
    override class var tags: Set<Tag> { [.scale] }
    override class var variants: [Variant] { [.codex] }
    static let element = "explorer"
    static let load = "500 files"
    override class var files: [(path: String, text: String)] {
        (0..<500).map { (String(format: "f%03d.txt", $0), "file \($0)\n") } + [("docs/a.txt", "a\n")]
    }
    private let confirms = Confirms()

    override func steps() -> [any Step] {
        let has = { (path: String) in { (story: StoryContext) in story.app.workspace?.storyHasFile(path) == true } }
        let rows = { (story: StoryContext) in story.app.workspace?.storyTreeRows ?? [] }
        let work: [any Step] = [
            Command(.toggleExplorer),
            WaitForElement(.treeRow("docs")),
            Click(.treeRow("docs")),
            Expect("docs open", found: { rows($0).prefix(4).joined(separator: ", ") }) { rows($0).contains("docs/a.txt") },
            TreeMenuItem("f001.txt", "Rename…"),
            WaitForFocus(.id(StoryID.Explorer.namefield)),
            Key(.cmd("a")),
            TypeText("renamed.txt"),
            Key(.returnKey),
            Expect("renamed") { has("renamed.txt")($0) && !has("f001.txt")($0) },
            Do("answer confirmations") { [confirms] story in confirms.install(story) },
            // Chosen, not opened: a file's click opens it, and opening one closes the explorer
            // floating over a narrow window (FolderWindow's tab change), so ⌘⌫ would go to the file.
            // A folder's click keeps the keys in the tree; type to find chooses the row.
            Click(.treeRow("docs")),
            TypeText("f002"),
            Expect("f002.txt chosen", found: { $0.app.workspace?.storyTreeSelection ?? "none" }) {
                $0.app.workspace?.storyTreeSelection == "f002.txt"
            },
            Key(KeyChord(.backspace, .command)),
            Expect("trashed, one question", found: { [confirms] _ in confirms.asked.joined(separator: ", ") }) { [confirms] story in
                confirms.asked == ["trash"] && !has("f002.txt")(story)
            },
            Do("stop answering") { [confirms] _ in confirms.remove() },
        ]
        return [ScaleBegin(element: Self.element, load: Self.load)] + super.steps() + Timed.wrap(work, Self.element, Self.load)
            + scaleLook(Self.element, Self.load, edges: [StoryID.Titlebar.newtab, StoryID.Titlebar.history])
    }
}

/// 30 tabs and Devices: the popup whole at its icon, KoreNet switched on and off again.
final class ScaleDevices30: Storyline {
    override class var tags: Set<Tag> { [.scale] }
    override class var variants: [Variant] { [.codex] }
    static let element = "devices"
    static let load = "30 tabs"

    override func steps() -> [any Step] {
        let icon = Locator.id(StoryID.Net.icon)
        let work: [any Step] = [
            Press(icon),
            WaitForElement(.id(StoryID.Net.panel)),
            AnchoredInside(what: "the Devices popup", popup: StoryID.Net.panel, anchor: StoryID.Net.icon),
            Expect("KoreNet off") { _ in Devices.shared.picture().net == .off },
            Press(.id(StoryID.Net.toggle)),
            Expect("KoreNet on, on a tailnet") { _ in Devices.shared.picture().net == .running },
            Press(.id(StoryID.Net.toggle)),
            Expect("KoreNet off again") { _ in Devices.shared.picture().net == .off },
            Press(icon),
            ExpectElement(.id(StoryID.Net.panel), .absent),
        ]
        return [
            ScaleBegin(element: Self.element, load: Self.load),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])), OpenFolder(), StartChat(), OpenTabs(29),
            DevicesSetUp(),
        ] + Timed.wrap(work, Self.element, Self.load) + scaleLook(Self.element, Self.load)
    }
}
