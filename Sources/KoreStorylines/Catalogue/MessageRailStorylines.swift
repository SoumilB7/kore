import Foundation
import KoreCore
import KoreUI

/// The scroller on a long chat's right: a mark for every user message, plain for those built,
/// the rest dim, a click on any brings its message to the top of the view, reading it in first if
/// it has to, and the marks say so after.
final class MessageRailMarks: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let session = "scripted-rail"

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let marks = { (story: StoryContext) in story.app.chat?.storyTranscript.railMarks ?? [] }
        let count = { (kind: String, story: StoryContext) in marks(story).count { $0 == kind } }
        return super.steps() + [
            Do("Open a long chat that was compacted") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
                let world = ScriptedWorld.shared
                let session = "\(Self.session)-\(provider)"
                world.earlier[session] = (0..<3).flatMap { Self.turn($0, session) }
                world.sessions[session] = [.compacted(at: Date()), .compactionSummary("What the chat did so far.")]
                    + (3..<33).flatMap { n -> [ChatEvent] in
                        // Another session's messages between the user's, as a busy chat has: no marks.
                        Self.turn(n, session) + (n % 3 == 0 ? [.peerMessage(from: "scout", text: "Hand-back \(n)", turn: nil, id: "\(session)-peer-\(n)")] : [])
                    }
                workspace.open(SessionSummary(id: session, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Long", updated: .now))
            },
            WaitForElement(.id(StoryID.Transcript.rail)),
            Expect("a mark per message: 3 on disk, the rest held or built", found: { marks($0).description }) { story in
                count("earlier", story) == 3 && marks(story).count == 33 && count("held", story) > 0 && count("built", story) > 0
                    && marks(story).first == "earlier" && marks(story).last == "built"
            },
            Do("The pointer on a dim mark") { $0.app.chat?.storyTranscript.railHover(1) },
            WaitIdle(), Snapshot("rail-hover-earlier"),
            Do("The pointer on a built mark") { $0.app.chat?.storyTranscript.railHover(30) },
            WaitIdle(), Snapshot("rail-hover-built"),
            Do("The pointer leaves") { $0.app.chat?.storyTranscript.railHover(nil) },
            // Built: there, nothing loaded.
            Do("Click a built mark") { $0.app.chat?.storyTranscript.railJump(marks($0).count - 4) },
            Self.inView(29),
            // Held: built, then there.
            Do("Click a held mark") { story in
                guard let held = marks(story).firstIndex(of: "held") else { throw StoryFailure.modelMissing("a held mark") }
                story.app.chat?.storyTranscript.railJump(held + 1)
            },
        ] + Self.atTop(4) + [
            // On disk (unless nearing the top already read it in, as scrolling there does): read
            // in, there, and plain from then on.
            Do("Click the first mark") { $0.app.chat?.storyTranscript.railJump(0) },
            Expect("the page read in", found: { marks($0).description }) { count("earlier", $0) == 0 && marks($0).count == 33 },
        ] + Self.atTop(0) + [
            Snapshot("rail-after-load"),
            Expect("the first mark lit", found: { "\($0.app.chat?.storyTranscript.railCurrent ?? -1)" }) { $0.app.chat?.storyTranscript.railCurrent == 0 },
        ] + [20, 19, 18, 17].flatMap { n -> [any Step] in
            // One up is one up: that message at the top, its mark lit, nothing else moved.
            [Do("Click mark \(n)") { $0.app.chat?.storyTranscript.railJump(n) } as any Step] + Self.atTop(n) + [
                Expect("mark \(n) lit", found: { "\($0.app.chat?.storyTranscript.railCurrent ?? -1)" }) { $0.app.chat?.storyTranscript.railCurrent == n },
            ]
        } + [
            Snapshot("rail-one-up"),
        ]
    }

    /// Message `n`'s row drawn in the window.
    static func inView(_ n: Int) -> Expect {
        Expect("message \(n) drawn in view", timeout: .seconds(8)) { story in
            guard let window = story.window, let chat = story.app.chat,
                let entry = chat.storyTranscript.entries.first(where: { $0.kind == .user && $0.text == text(n) }),
                let frame = StoryElement(StoryID.Transcript.user(entry.id), in: window)?.frame ?? nil
            else { return false }
            return window.contentView.map { $0.bounds.intersects(frame) } ?? false
        }
    }

    /// Message `n`'s row where a jump puts it: in the top part of the window (whose origin is at
    /// its bottom), once the landing's over.
    static func atTop(_ n: Int) -> [any Step] {
        [
            inView(n), Landing(),
            Expect("message \(n) at the top") { story in
                guard let window = story.window, let height = window.contentView?.bounds.height, let chat = story.app.chat,
                    let entry = chat.storyTranscript.entries.first(where: { $0.kind == .user && $0.text == text(n) }),
                    let frame = StoryElement(StoryID.Transcript.user(entry.id), in: window)?.frame ?? nil
                else { return false }
                return frame.midY > height * 0.7
            },
        ]
    }

    /// The landing's second aim and what follows it.
    private struct Landing: Step {
        var label: String { "Let the jump land" }
        var timeout: Duration? { .seconds(5) }
        func run(_ story: StoryContext) async throws { try await Task.sleep(for: .milliseconds(700)) }
    }

    static func text(_ n: Int) -> String { "Message number \(n)" }

    static func turn(_ n: Int, _ session: String, say: String? = nil) -> [ChatEvent] {
        [
            .userMessage(text: text(n), attachments: [], id: "\(session)-message-\(n)"),
            .turnStarted("\(session)-turn-\(n)", origin: .user, at: Date()),
            .text("\(session)-block-\(n)", .answer, say ?? "The answer to number \(n)."),
            .turnFinished("\(session)-turn-\(n)", .completed, duration: nil),
        ]
    }
}

/// The history's search reads what chats say: a chat named nothing like the query is listed with
/// the words around it; another that doesn't hold it isn't. Picked, it opens at that message.
final class HistorySearchesWords: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        let (found, other) = ("searched-\(provider)", "unrelated-\(provider)")
        // Before the folder opens: a list read as it opens would be the one the panel gets.
        let seed: [any Step] = [
            Do("Two chats in the folder's history") { story in
                let world = ScriptedWorld.shared
                world.sessions[found] = (0..<30).flatMap { MessageRailMarks.turn($0, found, say: $0 == 4 ? "It was the zebra crossing." : nil) }
                for (id, title, zebra) in [(found, "Road work", true), (other, "Paint job", false)] {
                    let file = provider == "claude" ? ClaudeHistory.transcript(sessionId: id, in: story.folder) : story.outputs.appendingPathComponent("\(id).jsonl")
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.history(provider, session: id, folder: story.folder, zebra: zebra).write(to: file, atomically: true, encoding: .utf8)
                    if provider != "claude" { world.list(id, provider: provider, folder: story.folder, title: title, file: file) }
                }
            },
        ]
        return seed + super.steps() + [
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(.id(StoryID.History.row(found))),
            Click(.id(StoryID.History.search)),
            WaitForFocus(.id(StoryID.History.search)),
            TypeText("Zebra"),
            ExpectElement(.id(StoryID.History.row(other)), .absent),
            ExpectElement(.id(StoryID.History.row(found))),
            WaitIdle(), Snapshot("history-search"),
            Press(.id(StoryID.History.row(found))),
        ] + MessageRailMarks.atTop(4) + [
            Snapshot("history-search-opened"),
        ]
    }

    /// The chat's file, as each CLI writes it.
    private static func history(_ provider: String, session: String, folder: URL, zebra: Bool) -> String {
        (0..<30).flatMap { n -> [String] in
            let (ask, answer) = (MessageRailMarks.text(n), zebra && n == 4 ? "It was the zebra crossing." : "The answer to number \(n).")
            if provider == "claude" {
                return [
                    #"{"parentUuid":\#(n == 0 ? "null" : "\"a\(n - 1)\""),"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(ask)"},"uuid":"u\#(n)","timestamp":"2026-10-20T09:00:00.000Z","cwd":"\#(folder.path)","sessionId":"\#(session)"}"#,
                    #"{"parentUuid":"u\#(n)","isSidechain":false,"message":{"id":"m\#(n)","type":"message","role":"assistant","content":[{"type":"text","text":"\#(answer)"}]},"type":"assistant","uuid":"a\#(n)","timestamp":"2026-10-20T09:00:01.000Z","sessionId":"\#(session)"}"#,
                ]
            }
            return [
                #"{"timestamp":"2026-10-20T09:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(ask)"}]}}"#,
                #"{"timestamp":"2026-10-20T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(answer)"}]}}"#,
            ]
        }.joined(separator: "\n") + "\n"
    }
}
