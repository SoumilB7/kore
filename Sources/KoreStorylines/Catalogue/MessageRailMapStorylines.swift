import AppKit
import Foundation
import KoreCore
import KoreUI
import src

/// The rail maps the chat: each message's tick at its place in order down a rail that grows with
/// the chat to fill its room, the lit tick the message being read wherever the reader is (the
/// end, the middle, the top, after a resize, a zoom and another tab), a click at a message's place
/// brings that message up, and an answer streaming in moves nothing.
final class MessageRailMaps: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .stream(.answer, NavCost.answer(1, turn: 1) + "\n\n" + NavCost.answer(2, turn: 2), chunk: 4), .finishTurn(.completed)]])
    }
    static let turns = 36

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let session = "scripted-rail-map-\(provider)"
        let long = { (story: StoryContext) in story.stash(LongChat.self) { LongChat() } }
        return super.steps() + [
            Do("Open a long chat: long answers, work folded away") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
                ScriptedWorld.shared.sessions[session] = (0..<Self.turns).flatMap { Self.turn($0, session) }
                workspace.open(SessionSummary(id: session, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Map", updated: .now))
            },
            WaitForElement(.id(StoryID.Transcript.rail)),
            Expect("a mark per message", found: Self.describe) { ($0.app.chat?.storyTranscript.railMarks.count ?? 0) == Self.turns },
            Do("Keep the chat") { long($0).chat = $0.app.chat },
            Self.mapped("opened"),
            Self.reads("at the end", end: true),
            Do("Scroll up a screen and a half") { $0.app.chat?.storyTranscript.scrollContent(by: -1200) },
            WaitIdle(), Self.reads("a screen and a half up"),
            Self.click(17),
        ] + MessageRailMarks.atTop(17) + [
            Self.reads("17 at the top"),
            Do("On into its answer") { $0.app.chat?.storyTranscript.scrollContent(by: 400) },
            WaitIdle(), Self.reads("in 17's answer"),
            Do("Back up past it") { $0.app.chat?.storyTranscript.scrollContent(by: -600) },
            WaitIdle(), Self.reads("17 below the top"),
            Self.click(0),
        ] + MessageRailMarks.atTop(0) + [
            Self.reads("at the top"), Self.mapped("at the top"),
            Self.click(30),
        ] + MessageRailMarks.atTop(30) + [
            Self.reads("30 at the top"),
            SizeWindow(width: 760), WaitIdle(), Self.mapped("narrow"), Self.reads("narrow"),
            Do("A shorter window") { story in
                guard let window = story.window, let content = window.contentView else { throw StoryFailure.other("no window") }
                window.setContentSize(CGSize(width: content.bounds.width, height: content.bounds.height - 200))
            },
            WaitIdle(), Self.mapped("short"), Self.reads("short"),
            Key(KeyChord(.character("="), .command)), Key(KeyChord(.character("="), .command)),
            WaitIdle(), Self.mapped("zoomed"), Self.reads("zoomed"),
            Key(KeyChord(.character("0"), .command)), WaitIdle(),
            StartChat(provider),
            WaitIdle(),
            Do("Back to the long chat") { story in
                guard let workspace = story.app.workspace, let chat = long(story).chat,
                    let index = workspace.tabs.firstIndex(where: { $0.chat === chat })
                else { throw StoryFailure.modelMissing("the long chat's tab") }
                workspace.storySelect(tabAt: index)
            },
            WaitForElement(.id(StoryID.Transcript.rail)), WaitIdle(),
            Self.mapped("back from another tab"), Self.reads("back from another tab"),
            Self.click(12),
        ] + MessageRailMarks.atTop(12) + [
            StreamsStill(),
            Self.mapped("after the answer"), Self.reads("after the answer"),
            Snapshot("rail-map"),
        ]
    }

    private final class LongChat { var chat: Chat? }

    /// A turn with a long answer (a heading, paragraphs, a list, code, a table), and every other
    /// one with work folded above it.
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

    /// A click on the rail at message `n`'s place: the ticks' step from the first to the last.
    static func click(_ n: Int) -> Do {
        Do("Click the rail at message \(n)'s place") { story in
            guard let transcript = story.app.chat?.storyTranscript, let first = transcript.railTicks.first, let last = transcript.railTicks.last,
                last.index > first.index
            else { throw StoryFailure.modelMissing("the rail's ticks") }
            let step = (last.y - first.y) / CGFloat(last.index - first.index)
            transcript.railClick(atY: first.y + CGFloat(n - first.index) * step)
        }
    }

    /// Each drawn tick at its message's place, one step a message from the first at the top to
    /// the last, in order, no more than twenty, and the rail as long as the chat at 24 pt a step
    /// up to its room (the transcript's height less a 16 pt margin each end).
    static func mapped(_ label: String) -> Expect {
        Expect("the ticks map the chat (\(label))", found: describe) { story in
            guard let transcript = story.app.chat?.storyTranscript, let window = story.window, let scroll = transcript.scrollView,
                let rail = StoryElement(StoryID.Transcript.rail, in: window)?.frame ?? nil
            else { return false }
            let (ticks, count, room) = (transcript.railTicks, transcript.railMarks.count, transcript.railRoom)
            guard count > 1, let first = ticks.first, let last = ticks.last, first.index == 0, last.index == count - 1 else { return false }
            let step = (last.y - first.y) / CGFloat(count - 1)
            let inOrder = zip(ticks, ticks.dropFirst()).allSatisfy { $0.index < $1.index }
            let placed = ticks.allSatisfy { abs($0.y - (first.y + CGFloat($0.index) * step)) < 0.5 }
            let long = abs((last.y - first.y) - min(room, CGFloat(count - 1) * 24)) < 1
            // On screen, nearly as tall as the transcript (less its margins and the inset under the title bar) when the chat fills it.
            let shown = scroll.convert(scroll.bounds, to: nil)
            let onScreen = shown.insetBy(dx: -1, dy: -1).contains(rail) && (CGFloat(count - 1) * 24 < room || rail.height > shown.height * 0.85)
            return inOrder && placed && long && onScreen && ticks.count <= 20
        }
    }

    /// The lit tick is drawn, and it's the message being read, from where the rows are: the last
    /// whose top has reached the read line (40 pt down), or the one before the first below it;
    /// at the end, the last. A row within a few points of the line may count either way.
    static func reads(_ label: String, end: Bool = false) -> Expect {
        Expect("the lit tick is the message read (\(label))", timeout: .seconds(4), found: describe) { story in
            guard let transcript = story.app.chat?.storyTranscript, let current = transcript.railCurrent,
                transcript.railTicks.contains(where: { $0.index == current })
            else { return false }
            if end { return current == transcript.railMarks.count - 1 }
            let rows = rowTops(story)
            // An answer fills the view: no row says, the place the reader left it is all there is.
            guard !rows.isEmpty else { return true }
            func reading(_ line: CGFloat) -> Int {
                rows.filter { $0.top <= line }.map(\.index).max() ?? max((rows.map(\.index).min() ?? 0) - 1, 0)
            }
            return [reading(40 - 8), reading(40 + 8)].contains(current)
        }
    }

    /// Each user message row drawn: its mark, and its top from the transcript's top. That top is
    /// below the title bar, which the scroll view reaches under: the rail is centred between it
    /// and the bottom, its room 16 pt short of each.
    static func rowTops(_ story: StoryContext) -> [(index: Int, top: CGFloat)] {
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

    static func describe(_ story: StoryContext) -> String {
        guard let transcript = story.app.chat?.storyTranscript else { return "no chat" }
        let ticks = transcript.railTicks.map { "\($0.index)@\(Int($0.y))" }.joined(separator: " ")
        let rows = rowTops(story).map { "\($0.index):\(Int($0.top))" }.joined(separator: " ")
        let rail = story.window.flatMap { StoryElement(StoryID.Transcript.rail, in: $0)?.frame ?? nil }
        let shown = transcript.scrollView.map { $0.convert($0.bounds, to: nil) }
        return "rail \(rail.map { "\($0)" } ?? "none") in \(shown.map { "\($0)" } ?? "none"), marks \(transcript.railMarks.count), room \(Int(transcript.railRoom)), lit \(transcript.railCurrent ?? -1), ticks [\(ticks)], rows [\(rows)]"
    }

    /// A message sent and its answer streaming in: once its mark is in, no tick moves and the lit
    /// one stays, sampled until the turn ends.
    private struct StreamsStill: Step {
        var label: String { "Send, and the rail holds still while the answer streams" }
        var timeout: Duration? { .seconds(90) }

        func run(_ story: StoryContext) async throws {
            let chat = try story.activeChat()
            let finished = { story.chatEvents(chat).count { if case .turnFinished = $0 { true } else { false } } }
            let before = finished()
            let sent = MessageRailMarks.text(MessageRailMaps.turns)
            chat.storySend(sent)
            try await story.until("its mark in") { chat.storyTranscript.railMarks.count == MessageRailMaps.turns + 1 }
            try await Task.sleep(for: .milliseconds(150))
            func now() -> String {
                "\(chat.storyTranscript.railCurrent ?? -1) " + chat.storyTranscript.railTicks.map { "\($0.index)@\($0.y)" }.joined(separator: " ")
            }
            let first = now()
            var samples = 0
            while finished() == before {
                guard now() == first else { throw StoryFailure.other("the rail moved while the answer streamed: \(first) → \(now())") }
                samples += 1
                try await Task.sleep(for: .milliseconds(40))
            }
            guard samples >= 3 else { throw StoryFailure.other("the answer finished before the rail was looked at (\(samples) looks)") }
        }
    }
}
