import AppKit
import Foundation
import KoreCore
import KoreUI
import src

/// The rail on a long chat whose first messages are on disk (before a compaction): the chat's
/// first and last message and a run of eighteen around the one being read, 8 pt apart, the run
/// one message a tick. A click on a tick brings its message up, one on disk read in first. Read
/// mid-chat, scrolled or with an answer streaming in, the lit tick is the message read, never the
/// last one.
final class MessageRailMaps: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        let long = (1...8).map { NavCost.answer($0 % 5, turn: $0 % 4 + 1) }.joined(separator: "\n\n")
        return CLIScript(turns: [[.startTurn, .stream(.answer, long, chunk: 40), .finishTurn(.completed)]])
    }
    /// On disk, then in the CLI's history.
    static let (earlier, turns) = (10, 46)

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let session = "scripted-rail-map-\(provider)"
        return super.steps() + [
            Do("Open a long chat that was compacted") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
                let world = ScriptedWorld.shared
                world.earlier[session] = (0..<Self.earlier).flatMap { Self.turn($0, session) }
                world.sessions[session] = [.compacted(at: Date()), .compactionSummary("What the chat did so far.")]
                    + (Self.earlier..<Self.turns).flatMap { Self.turn($0, session) }
                workspace.open(SessionSummary(id: session, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Map", updated: .now))
            },
            WaitForElement(.id(StoryID.Transcript.rail)),
            Expect("a mark per message, the first ones on disk", found: Self.describe) { story in
                let marks = story.app.chat?.storyTranscript.railMarks ?? []
                return marks.count == Self.turns && marks.first == "earlier"
            },
            WaitIdle(), Self.run("opened"), Self.reads("at the end", end: true),
            Do("Scroll up a screen and a half") { $0.app.chat?.storyTranscript.scrollContent(by: -1200) },
            WaitIdle(), Self.run("a screen and a half up"), Self.reads("a screen and a half up"),
            NeverLast(label: "Scrolling on up mid-chat", streaming: false),
            Self.clickBuilt(),
            Self.run("after a click"),
            Do("The pointer on the run's first tick") { story in
                guard let transcript = story.app.chat?.storyTranscript, transcript.railTicks.count > 1 else { return }
                transcript.railHover(transcript.railTicks[1].index)
            },
            WaitIdle(), Snapshot("rail-run-hover"),
            Do("The pointer leaves") { $0.app.chat?.storyTranscript.railHover(nil) },
            ClickOnDisk(),
            Do("Click the first tick") { story in
                guard let transcript = story.app.chat?.storyTranscript, let first = transcript.railTicks.first else { throw StoryFailure.modelMissing("the rail") }
                transcript.railClick(atY: first.y)
            },
        ] + MessageRailMarks.atTop(0) + [
            Expect("the first page read in", found: Self.describe) { !($0.app.chat?.storyTranscript.railMarks.contains("earlier") ?? true) },
            Self.reads("at the top"), Self.run("at the top"),
            UnloadStoryline.ToEnd(), WaitIdle(), Self.reads("back at the end", end: true),
            NeverLast(label: "An answer streams in, read mid-chat", streaming: true),
            Snapshot("rail-map"),
        ]
    }

    static func turn(_ n: Int, _ session: String) -> [ChatEvent] { MessageRailFixedSize.turn(n, session) }

    /// A click on a drawn tick of a message in memory, in the run, the one read and the ends
    /// aside, brings its message to the top.
    static func clickBuilt() -> any Step { ClickTick() }

    private struct ClickTick: Step {
        var label: String { "Click a built message's tick in the run: its message at the top" }
        var timeout: Duration? { .seconds(10) }

        func run(_ story: StoryContext) async throws {
            guard let transcript = story.app.chat?.storyTranscript,
                let tick = transcript.railTicks.dropFirst().dropLast().last(where: { $0.index != transcript.railCurrent && transcript.railMarks[$0.index] == "built" })
            else { throw StoryFailure.modelMissing("a built message's tick: \(MessageRailMaps.describe(story))") }
            let kind = transcript.railMarks[tick.index]
            transcript.railClick(atY: tick.y)
            try await MessageRailMaps.lands(story, tick.index, kind)
        }
    }

    /// Message `index` (the nth mark: every user message here is one) brought to the top.
    @MainActor static func lands(_ story: StoryContext, _ index: Int, _ kind: String) async throws {
        guard let transcript = story.app.chat?.storyTranscript else { throw StoryFailure.modelMissing("the chat") }
        let row = { @MainActor () -> CGRect? in
            guard let window = story.window,
                let entry = transcript.entries.first(where: { $0.kind == .user && $0.text == MessageRailMarks.text(index) })
            else { return nil }
            return StoryElement(StoryID.Transcript.user(entry.id), in: window)?.frame ?? nil
        }
        do {
            try await story.until("message \(index) at the top", timeout: .seconds(8)) {
                guard let frame = row(), let height = story.window?.contentView?.bounds.height else { return false }
                return frame.midY > height * 0.7 && frame.maxY <= height
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("message \(index) (\(kind) when clicked) not at the top: its row \(row().map { "\($0)" } ?? "not drawn") in \(story.window?.contentView?.bounds ?? .zero); \(MessageRailMaps.describe(story))")
        }
    }

    /// A click on a tick in the middle of what's on disk lands on that message, not the first of
    /// what its page reads in. The run's first tick is clicked until the run reaches the disk's.
    private struct ClickOnDisk: Step {
        var label: String { "Click a tick on disk, past the first: its message at the top" }
        var timeout: Duration? { .seconds(40) }

        func run(_ story: StoryContext) async throws {
            guard let transcript = story.app.chat?.storyTranscript else { throw StoryFailure.modelMissing("the chat") }
            func onDisk() -> (index: Int, y: CGFloat)? {
                transcript.railTicks.dropFirst().filter { transcript.railMarks[$0.index] == "earlier" }.max { $0.index < $1.index }
            }
            for _ in 0..<8 where onDisk() == nil {
                guard transcript.railTicks.count > 1 else { break }
                let up = transcript.railTicks[1]
                transcript.railClick(atY: up.y)
                try await MessageRailMaps.lands(story, up.index, transcript.railMarks[up.index])
                try await Task.sleep(for: .milliseconds(700))
            }
            guard let tick = onDisk() else { throw StoryFailure.modelMissing("a tick on disk past the first: \(MessageRailMaps.describe(story))") }
            let first = transcript.railMarks.firstIndex(of: "earlier") ?? 0
            guard tick.index > first else { throw StoryFailure.other("the disk's first tick only: \(MessageRailMaps.describe(story))") }
            transcript.railClick(atY: tick.y)
            try await MessageRailMaps.lands(story, tick.index, "earlier")
        }
    }

    /// 0.3.6's rail: twenty ticks 8 pt apart, the first and last message at the ends and the rest
    /// a run, one message a tick, with the lit one in it.
    static func run(_ label: String) -> Expect {
        Expect("the rail's run (\(label))", found: describe) { story in
            guard let transcript = story.app.chat?.storyTranscript, let window = story.window,
                let rail = StoryElement(StoryID.Transcript.rail, in: window)?.frame ?? nil, let current = transcript.railCurrent
            else { return false }
            let (ticks, count) = (transcript.railTicks, transcript.railMarks.count)
            let indices = ticks.map(\.index)
            guard indices.count == 20, indices.first == 0, indices.last == count - 1 else { return false }
            let run = Array(indices[1...18])
            let contiguous = zip(run, run.dropFirst()).allSatisfy { $1 == $0 + 1 }
            let apart = zip(ticks, ticks.dropFirst()).allSatisfy { abs($1.y - $0.y - 8) < 0.5 }
            return contiguous && apart && indices.contains(current) && abs(rail.height - (19 * 8 + 2 + 16)) < 0.5
        }
    }

    /// The lit tick is the message being read, from where the rows are: the last whose top has
    /// reached the read line (40 pt down), or the one before the first below it; at the end, the
    /// last. A row within a few points of the line may count either way.
    static func reads(_ label: String, end: Bool = false) -> Expect {
        Expect("the lit tick is the message read (\(label))", timeout: .seconds(4), found: describe) { story in
            guard let transcript = story.app.chat?.storyTranscript, let current = transcript.railCurrent,
                transcript.railTicks.contains(where: { $0.index == current })
            else { return false }
            if end { return current == transcript.railMarks.count - 1 }
            let rows = rowTops(story)
            guard !rows.isEmpty else { return true }
            func reading(_ line: CGFloat) -> Int {
                rows.filter { $0.top <= line }.map(\.index).max() ?? max((rows.map(\.index).min() ?? 0) - 1, 0)
            }
            return [reading(40 - 8), reading(40 + 8)].contains(current)
        }
    }

    /// Each user message row drawn: its mark, and its top from the transcript's top (the rail is
    /// centred in the transcript, its room 16 pt short of each end).
    @MainActor static func rowTops(_ story: StoryContext) -> [(index: Int, top: CGFloat)] {
        guard let window = story.window, let transcript = story.app.chat?.storyTranscript,
            let rail = StoryElement(StoryID.Transcript.rail, in: window)?.frame ?? nil
        else { return [] }
        let top = rail.midY + (transcript.railRoom + 32) / 2
        return transcript.entries.compactMap { entry in
            guard entry.kind == .user, let index = transcript.railIndex(of: entry.id),
                let frame = StoryElement(StoryID.Transcript.user(entry.id), in: window)?.frame ?? nil
            else { return nil }
            return (index, top - frame.maxY)
        }
    }

    /// The last message's row on screen.
    @MainActor static func lastOnScreen(_ story: StoryContext) -> Bool {
        guard let transcript = story.app.chat?.storyTranscript, let scroll = transcript.scrollView else { return true }
        let count = transcript.railMarks.count
        let shown = scroll.convert(scroll.bounds, to: nil)
        return transcript.entries.contains { entry in
            guard entry.kind == .user, transcript.railIndex(of: entry.id) == count - 1,
                let frame = StoryElement(StoryID.Transcript.user(entry.id), in: story.window!)?.frame ?? nil
            else { return false }
            return frame.intersects(shown)
        }
    }

    @MainActor static func describe(_ story: StoryContext) -> String {
        guard let transcript = story.app.chat?.storyTranscript else { return "no chat" }
        let ticks = transcript.railTicks.map { "\($0.index)@\(Int($0.y))" }.joined(separator: " ")
        let rows = rowTops(story).map { "\($0.index):\(Int($0.top))" }.joined(separator: " ")
        let rail = story.window.flatMap { StoryElement(StoryID.Transcript.rail, in: $0)?.frame ?? nil }
        return "rail \(rail.map { "\($0)" } ?? "none"), marks \(transcript.railMarks.count) \(transcript.railMarks.prefix(3)), lit \(transcript.railCurrent ?? -1), ticks [\(ticks)], rows [\(rows)]"
    }

    /// Mid-chat, the lit tick never the last message while the last message's row is off screen:
    /// sampled every frame while the reader scrolls up a screen at a time, or (`streaming`) while
    /// a message sent from the end is answered with the reader scrolled away from it.
    private struct NeverLast: Step {
        let label: String
        let streaming: Bool
        var timeout: Duration? { .seconds(90) }

        func run(_ story: StoryContext) async throws {
            let chat = try story.activeChat()
            let transcript = { chat.storyTranscript }
            var samples = 0
            // To the middle message: from there on up the reader is above the last message,
            // whatever the view's following flag says.
            func midChat() async throws {
                let count = transcript().railMarks.count
                transcript().railJump(count / 2)
                do {
                    try await story.until("the middle message read", timeout: .seconds(8)) { (transcript().railCurrent ?? .max) <= count - 3 }
                } catch StoryFailure.timedOut {
                    let scroll = transcript().scrollView.map { s in "\(Int(s.contentView.bounds.minY)) of \(Int(s.documentView?.bounds.height ?? 0))" } ?? "none"
                    throw StoryFailure.expectation("the jump to \(count / 2) not read: at \(scroll); \(transcript().endWhy); \(MessageRailMaps.describe(story))")
                }
            }
            func look(_ doing: String) throws {
                guard let current = transcript().railCurrent, !MessageRailMaps.lastOnScreen(story) else { return }
                samples += 1
                if current == transcript().railMarks.count - 1 {
                    throw StoryFailure.expectation("the last message lit mid-chat \(doing): \(MessageRailMaps.describe(story))")
                }
            }
            if streaming {
                let finished = { story.chatEvents(chat).count { if case .turnFinished = $0 { true } else { false } } }
                let before = finished()
                // Paced, so it's still streaming once the send's glide (two seconds) is over.
                ScriptedWorld.shared.rate = 60
                for backend in ScriptedWorld.shared.backends { backend.rate = 60 }
                defer {
                    ScriptedWorld.shared.rate = nil
                    for backend in ScriptedWorld.shared.backends { backend.rate = nil }
                }
                chat.storySend(MessageRailMarks.text(MessageRailMaps.turns))
                try await story.until("its mark in") { transcript().railMarks.count == MessageRailMaps.turns + 1 }
                if let sent = transcript().sentAt {
                    try await story.until("the send's glide over", timeout: .seconds(3)) { Date() >= sent + 2.05 }
                }
                guard finished() == before else { throw StoryFailure.other("the answer finished before the glide did") }
                try await midChat()
                while finished() == before {
                    try await Task.sleep(for: .milliseconds(16))
                    try look("while the answer streams")
                }
                guard samples >= 5 else { throw StoryFailure.other("the answer finished before the rail was looked at (\(samples) looks)") }
            } else {
                try await midChat()
                for _ in 0..<8 {
                    transcript().scrollContent(by: -150)
                    for _ in 0..<8 {
                        try await Task.sleep(for: .milliseconds(16))
                        try look("while scrolling")
                    }
                }
                guard samples >= 20 else { throw StoryFailure.other("the rail was looked at only \(samples) times mid-chat") }
            }
        }
    }
}

/// The rail looks the same whatever the window's size: a long chat's rail is as tall, its ticks as
/// far apart, in a window 250 pt shorter. It never draws over what the transcript shows: at the
/// natural size no code block, table or tool box reaches under it, and with the page pinched in
/// to 2× (a column-wide block running past the right edge) its column between the ticks is plain.
final class MessageRailFixedSize: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let session = "scripted-rail-fixed-\(provider)"
        let noted = { (story: StoryContext) in story.stash(Noted.self) { Noted() } }
        return super.steps() + [
            Do("Open a long chat") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
                ScriptedWorld.shared.sessions[session] = (0..<36).flatMap { Self.turn($0, session) }
                workspace.open(SessionSummary(id: session, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Fixed", updated: .now))
            },
            WaitForElement(.id(StoryID.Transcript.rail)), WaitIdle(),
            Expect("the rail drawn", found: MessageRailMaps.describe) { ($0.app.chat?.storyTranscript.railTicks.count ?? 0) == 20 },
            Do("Note the rail") { story in
                let (height, ticks) = try Self.rail(story)
                (noted(story).height, noted(story).ticks) = (height, ticks)
            },
            Self.clear("at the natural size"),
            Do("A window 250 pt shorter") { story in
                guard let window = story.window, let content = window.contentView else { throw StoryFailure.other("no window") }
                window.setContentSize(CGSize(width: content.bounds.width, height: content.bounds.height - 250))
            },
            WaitIdle(),
            Expect("the same rail in the shorter window", found: { story in
                let now = try? Self.rail(story)
                return "before \(noted(story).height) \(noted(story).ticks), now \(now.map { "\($0.height) \($0.ticks)" } ?? "none")"
            }) { story in
                guard let now = try? Self.rail(story) else { return false }
                return abs(now.height - noted(story).height) < 0.5 && now.ticks == noted(story).ticks
            },
            Self.clear("shorter"),
            PinchOverBlock(),
            Snapshot("rail-fixed-pinched"),
        ]
    }

    /// A turn with a long answer (a heading, paragraphs, a list, code, a table), and every other
    /// one with work above it.
    static func turn(_ n: Int, _ session: String) -> [ChatEvent] {
        let id = "\(session)-turn-\(n)"
        var events: [ChatEvent] = [
            .userMessage(text: MessageRailMarks.text(n), attachments: [], id: "\(session)-message-\(n)"),
            .turnStarted(id, origin: .user, at: Date()),
        ]
        if n % 2 == 0 {
            events += [
                .text("\(id)-thinking", .thinking, "Looking at part \(n)."),
                .toolStarted(ToolCall(id: "\(id)-tool", name: "Bash", detail: "ls part-\(n)", input: "ls part-\(n)")),
                .toolFinished(id: "\(id)-tool", output: "part-\(n).txt", isError: false),
            ]
        }
        return events + [.text("\(id)-answer", .answer, NavCost.answer(n % 5, turn: n % 4 + 1)), .turnFinished(id, .completed, duration: nil)]
    }

    private final class Noted {
        var height: CGFloat = 0
        var ticks: [CGFloat] = []
    }

    /// The rail's height and its ticks' places down it.
    @MainActor static func rail(_ story: StoryContext) throws -> (height: CGFloat, ticks: [CGFloat]) {
        guard let window = story.window, let transcript = story.app.chat?.storyTranscript,
            let frame = StoryElement(StoryID.Transcript.rail, in: window)?.frame ?? nil
        else { throw StoryFailure.modelMissing("the rail") }
        return (frame.height, transcript.railTicks.map(\.y))
    }

    /// Where the ticks reach: in from the rail's inset from the scroll bar (`Size.railInset`) by
    /// the longest, under the pointer (`railTickHover` and half a stroke).
    @MainActor static func column(_ story: StoryContext) -> CGRect? {
        guard let window = story.window, let rail = StoryElement(StoryID.Transcript.rail, in: window)?.frame ?? nil else { return nil }
        return CGRect(x: rail.maxX - 12 - 23, y: rail.minY, width: 23, height: rail.height)
    }

    /// The code blocks, tables and tool boxes drawn in the window.
    @MainActor static func boxes(_ story: StoryContext) -> [CGRect] {
        guard let window = story.window else { return [] }
        let kinds = ["transcript.code[", "transcript.table[", "transcript.tool["]
        return StoryRegistry.ids.filter { id in kinds.contains { id.hasPrefix($0) } && id.hasSuffix("]") }
            .compactMap { StoryRegistry.entry($0, in: window)?.frame }
    }

    /// No box reaches under the rail's column.
    static func clear(_ label: String) -> Expect {
        Expect("no box under the rail (\(label))", found: { story in
            "column \(column(story).map { "\($0)" } ?? "none"), boxes \(boxes(story).map { "\(Int($0.minX))…\(Int($0.maxX))" })"
        }) { story in
            guard let column = column(story) else { return false }
            return !boxes(story).isEmpty && boxes(story).allSatisfy { !$0.intersects(column) }
        }
    }

    /// Pinched in to 2× on a code block's left, and scrolled until a box runs under the rail: the
    /// rail's column halfway between its ticks, past its inner edge's fade, is one colour.
    private struct PinchOverBlock: Step {
        var label: String { "Pinched in to 2×, the rail clear over a box running under it" }
        var timeout: Duration? { .seconds(30) }

        func run(_ story: StoryContext) async throws {
            let scroll = try PinchZoomNewLineHolds.scroll(story)
            let clip = scroll.contentView
            let visible = clip.convert(clip.bounds, to: nil)
            let block = try await story.wait("a code block on screen") {
                CodeBlockCopyBelow.blocks().compactMap { StoryRegistry.entry($0)?.frame }.first { visible.insetBy(dx: 0, dy: 40).contains(CGPoint(x: $0.minX + 20, y: $0.midY)) }
            }
            let local = clip.convert(CGPoint(x: block.minX + 20, y: block.midY), from: nil)
            let at = CGPoint(x: (local.x - clip.bounds.minX) / clip.bounds.width, y: (local.y - clip.bounds.minY) / clip.bounds.height)
            try await PinchZoomNewLineHolds.pinch(story, scroll, at: at, amount: (2 - scroll.magnification) / scroll.magnification)
            guard abs(scroll.magnification - 2) < 0.05 else { throw StoryFailure.other("the pinch left \(scroll.magnification)×") }
            // Down the chat until a box runs under the rail's column.
            var under = false
            for _ in 0..<40 {
                try await story.idle()
                if let column = MessageRailFixedSize.column(story), MessageRailFixedSize.boxes(story).contains(where: { $0.intersects(column) }) {
                    under = true
                    break
                }
                story.app.chat?.storyTranscript.scrollContent(by: -120)
            }
            guard under, let window = story.window, let column = MessageRailFixedSize.column(story), let frame = window.contentView?.superview,
                let ticks = story.app.chat?.storyTranscript.railTicks, ticks.count > 1,
                let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
            else { throw StoryFailure.expectation("no box ran under the rail at 2×") }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
            // Past the backing's fade (the inner 30 % of the rail's 26 pt) to the ticks' edge;
            // halfway between ticks.
            let xs = stride(from: column.maxX - 26 * 0.65, through: column.maxX - 1, by: 2)
            var seen: [String: Int] = [:]
            for (a, b) in zip(ticks, ticks.dropFirst()) {
                let y = column.maxY - (a.y + b.y) / 2
                for x in xs {
                    guard let color = rep.colorAt(x: Int(x * scale), y: Int((frame.bounds.height - y) * scale))?.usingColorSpace(.deviceRGB) else { continue }
                    let key = [color.redComponent, color.greenComponent, color.blueComponent].map { String(Int(($0 * 255 / 4).rounded())) }.joined(separator: ",")
                    seen[key, default: 0] += 1
                }
            }
            guard seen.count == 1 else {
                throw StoryFailure.expectation("the rail's column shows what's under it at 2×: colours \(seen.sorted { $0.value > $1.value }.prefix(6))")
            }
        }
    }
}
