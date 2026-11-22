import AppKit
import KoreCore
import KoreUI
import src

/// The rail's lit tick is the message in view, as 0.3.6's was: the last at the end, and kept lit
/// there while an answer streams in, whether the view follows the end or the reader sits a little
/// above it; the middle message after a jump there; the first at the top, reached by scrolling;
/// and the last again once scrolled back down. Never a tick mid-run near the bottom.
final class MessageRailTracksReader: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { MessageRailMaps.script }
    static let turns = 46

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let session = "scripted-rail-tracks-\(provider)"
        return super.steps() + [
            Do("Open a long chat") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
                ScriptedWorld.shared.sessions[session] = (0..<Self.turns).flatMap { MessageRailMaps.turn($0, session) }
                workspace.open(SessionSummary(id: session, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Tracks", updated: .now))
            },
            WaitForElement(.id(StoryID.Transcript.rail)),
            WaitIdle(), MessageRailMaps.reads("opened at the end", end: true),
            Streams(away: 0),
            Do("Jump to the middle message") { story in
                guard let transcript = story.app.chat?.storyTranscript else { throw StoryFailure.modelMissing("the chat") }
                transcript.railJump(transcript.railMarks.count / 2)
            },
            WaitIdle(), MessageRailMaps.reads("the middle"),
            Expect("the middle message lit", found: MessageRailMaps.describe) { story in
                guard let transcript = story.app.chat?.storyTranscript, let current = transcript.railCurrent else { return false }
                return abs(current - transcript.railMarks.count / 2) <= 1
            },
            Scrolls(up: true), MessageRailMaps.reads("scrolled to the top"),
            Scrolls(up: false), MessageRailMaps.reads("scrolled back to the end", end: true),
            Streams(away: 120),
        ]
    }

    /// The reader's own scroll a page at a time, to the top (the first message lit) or to the end.
    private struct Scrolls: Step {
        let up: Bool
        var label: String { up ? "Scroll up to the top" : "Scroll down to the end" }
        var timeout: Duration? { .seconds(60) }

        func run(_ story: StoryContext) async throws {
            let transcript = try story.activeChat().storyTranscript
            func done() -> Bool {
                guard let scroll = transcript.scrollView, let document = scroll.documentView else { return false }
                let y = scroll.contentView.bounds.minY + scroll.contentInsets.top
                return up ? y <= 1 && transcript.railCurrent == 0 : scroll.contentView.bounds.maxY >= document.bounds.height - 2
            }
            var still = 0
            var stuck = 0
            for _ in 0..<300 where still < 3 {
                let was = transcript.scrollView?.contentView.bounds.minY
                // As a reader's scroll goes: up past the content's top into its inset (under the
                // toolbar), where the row loading more sits.
                transcript.readerScrolled()
                if let scroll = transcript.scrollView, let document = scroll.documentView {
                    let clip = scroll.contentView
                    let lowest = -scroll.contentInsets.top
                    let highest = max(lowest, document.bounds.height - clip.bounds.height + scroll.contentInsets.bottom)
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(clip.bounds.minY + (up ? -900 : 900), lowest), highest)))
                    scroll.reflectScrolledClipView(clip)
                }
                try await Task.sleep(for: .milliseconds(60))
                still = done() ? still + 1 : 0
                // At the top of what's read in, nothing more to scroll (here a scroll can't go
                // past the top, as a trackpad's does): the row there pressed, as a reader does.
                stuck = up && transcript.scrollView?.contentView.bounds.minY == was ? stuck + 1 : 0
                if stuck >= 3 {
                    guard StoryElement(StoryID.Transcript.earlier) != nil else {
                        throw StoryFailure.expectation("no way further up from the top of what's read in (no load row): \(MessageRailMaps.describe(story))")
                    }
                    try await Press(.id(StoryID.Transcript.earlier)).run(story)
                    stuck = 0
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            try await story.idle()
            guard done() else { throw StoryFailure.expectation("\(up ? "the top" : "the end") reached by scrolling: \(MessageRailMaps.describe(story))") }
        }
    }

    /// A message sent from the end, its answer streamed slowly, the reader at the end (`away` 0)
    /// or that far above it once the answer is under way: every frame till it's done, the lit
    /// tick is the message read, which is the last one (its row's top has gone past the read line).
    private struct Streams: Step {
        let away: CGFloat
        var label: String { away == 0 ? "An answer streams in at the end: the last lit all through" : "An answer streams in \(Int(away)) pt above the end: the last lit all through" }
        var timeout: Duration? { .seconds(90) }

        func run(_ story: StoryContext) async throws {
            let chat = try story.activeChat()
            let transcript = { chat.storyTranscript }
            let finished = { story.chatEvents(chat).count { if case .turnFinished = $0 { true } else { false } } }
            let before = finished()
            let count = transcript().railMarks.count
            ScriptedWorld.shared.rate = 60
            for backend in ScriptedWorld.shared.backends { backend.rate = 60 }
            defer {
                ScriptedWorld.shared.rate = nil
                for backend in ScriptedWorld.shared.backends { backend.rate = nil }
            }
            chat.storySend(MessageRailMarks.text(count))
            try await story.until("its mark in") { transcript().railMarks.count == count + 1 }
            if let sent = transcript().sentAt {
                try await story.until("the send's glide over", timeout: .seconds(3)) { Date() >= sent + 2.05 }
            }
            guard finished() == before else { throw StoryFailure.other("the answer finished before the glide did") }
            if away > 0 {
                transcript().readerScrolled()
                transcript().scrollContent(by: -away)
            }
            var looks = 0
            while finished() == before {
                try await Task.sleep(for: .milliseconds(16))
                // Once the last message's row has gone past the read line (it starts at the top
                // after the send, or under it), nothing but the last may be lit.
                let rows = MessageRailMaps.rowTops(story)
                let last = count
                if let row = rows.first(where: { $0.index == last }), row.top > 40 + 8 { continue }
                looks += 1
                guard transcript().railCurrent == last else {
                    throw StoryFailure.expectation("the last message lit while its answer streams \(away == 0 ? "at the end" : "\(Int(away)) pt above it"): \(MessageRailMaps.describe(story))")
                }
            }
            guard looks >= 5 else { throw StoryFailure.other("the answer finished before the rail was looked at (\(looks) looks)") }
            try await story.idle()
            guard transcript().railCurrent == count else { throw StoryFailure.expectation("the last message lit once the answer is in: \(MessageRailMaps.describe(story))") }
        }
    }
}
