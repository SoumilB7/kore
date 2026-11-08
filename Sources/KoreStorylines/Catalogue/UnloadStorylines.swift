import AppKit
import Foundation
import KoreCore
import KoreUI
import src

/// A chat keeps its newest 15 turns in memory, and what's older can always be read back: these
/// tell where that happens and where it must not.
class UnloadStoryline: ChatStoryline {
    override class var isFamily: Bool { self == UnloadStoryline.self }
    override class var script: CLIScript { CLIScript(turns: (1...40).map(turn)) }

    override func steps() -> [any Step] { [NoNap.step] + super.steps() }

    static func text(_ n: Int) -> String { MessageRailMarks.text(n) }
    /// A turn played live says this: a long answer arriving under its send's glide can leave the
    /// view short of the end, not following. Those read from history are long, for rows the lazy
    /// stack only estimates.
    static func short(_ n: Int) -> String { "The answer to part \(n)." }

    /// A message, a command and a long answer; some with an edit, one with an agent.
    static func turn(_ n: Int) -> [Beat] {
        var beats: [Beat] = [.startTurn]
        if n == 3 { beats.append(.agent(id: "helper", name: "Helper", says: "I looked into part 3.")) }
        beats.append(.tool(name: "Bash", detail: "ls part-\(n)", output: "part \(n) listed"))
        if n % 5 == 2 { beats.append(.fileEdit(path: "notes-\(n).txt", content: "notes of part \(n)\n")) }
        beats += [.stream(.answer, short(n), chunk: 4000), .finishTurn(.completed)]
        return beats
    }

    /// Turns one after another; quicker than a send's glide, so the view may not be at its end
    /// after them. The last goes when the others' glides are over, which brings it there.
    static func sends(_ range: ClosedRange<Int>) -> [any Step] {
        range.flatMap { n -> [any Step] in
            (n == range.upperBound ? [GlideEnds()] : []) + [Send(text(n)), TurnFinished(n)]
        } + [GlideEnds()]
    }

    /// A chat of these turns, all built, read from its history: nothing's been sent in it, so
    /// the reader's at its end.
    static func opened(_ turns: ClosedRange<Int>, _ story: Storyline) -> [any Step] {
        let provider = story.variant.provider ?? "claude"
        let name = "\(Swift.type(of: story).storyName)-\(provider)"
        return [
            Do("Open a chat of \(turns.count) turns") { context in
                guard let workspace = context.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
                ScriptedWorld.shared.sessions[name] = turns.flatMap { history($0, name) }
                workspace.open(SessionSummary(id: name, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Long", updated: .now))
            },
            holds(max(turns.lowerBound, turns.upperBound - 14)...turns.upperBound),
            WaitIdle(),
            Do("Build every turn it holds") { try $0.activeChat().storyTranscript.showAll() },
            WaitIdle(), Settle(),
            drawn(answer: turns.upperBound),
        ]
    }

    static func history(_ n: Int, _ session: String) -> [ChatEvent] {
        let turn = "\(session)-turn-\(n)"
        return [
            .userMessage(text: text(n), attachments: [], id: "\(session)-message-\(n)"),
            .turnStarted(turn, origin: .user, at: Date()),
            .toolStarted(ToolCall(id: "\(turn)-call", name: "Bash", detail: "ls part-\(n)")),
            .toolFinished(id: "\(turn)-call", output: "part \(n) listed", isError: false),
            .text("\(turn)-answer", .answer, NavCost.answer(1, turn: n)),
            .turnFinished(turn, .completed, duration: nil),
        ]
    }

    /// A turn held on a command until the test lets it go.
    static func heldTurn(_ n: Int) -> [Beat] {
        [
            .startTurn, .tool(name: "Bash", detail: "sleep", output: "woke", wait: .release),
            .stream(.answer, short(n), chunk: 4000), .finishTurn(.completed),
        ]
    }

    static func users(_ story: StoryContext) throws -> [String] {
        try story.activeChat().rows.filter { $0.kind == "user" }.map(\.text)
    }

    static func holds(_ range: ClosedRange<Int>) -> Expect {
        Expect("messages \(range) in memory", found: { (try? users($0))?.description }) { story in
            try users(story) == range.map(text)
        }
    }

    /// Dim marks: the messages read as not loaded, every message marked.
    static func marks(earlier: Int, of all: Int) -> Expect {
        Expect("\(earlier) of \(all) marks dim", found: { $0.app.chat?.storyTranscript.railMarks.description }) { story in
            let marks = try story.activeChat().storyTranscript.railMarks
            return marks.count == all && marks.count { $0 == "earlier" } == earlier
        }
    }

    /// A send's glide is over (`TranscriptTimeline.glide`).
    struct GlideEnds: Step {
        var label: String { "Let the send's glide end" }
        func run(_ story: StoryContext) async throws { try await Task.sleep(for: .milliseconds(2300)) }
    }

    /// The end of the transcript, as the scroll bar takes it there.
    struct ToEnd: Step {
        /// The chat, when it isn't the active one (a board's tile).
        var chat: (@MainActor (StoryContext) -> Chat?)?
        var label: String { "Back to the end" }
        func run(_ story: StoryContext) async throws {
            let chat = try self.chat?(story) ?? story.activeChat()
            for _ in 0..<6 {
                guard let view = chat.storyTranscript.scrollView, let document = view.documentView else { throw StoryFailure.modelMissing("the scroll view") }
                let y = document.bounds.height - view.contentView.bounds.height + view.contentInsets.bottom
                view.contentView.scroll(to: NSPoint(x: 0, y: y))
                view.reflectScrolledClipView(view.contentView)
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// A chat left behind another tab, to read it from there.
    @MainActor final class Left {
        var chat: Chat?
        var backend: ScriptedBackend?
        func users() -> [String] { chat?.rows.filter { $0.kind == "user" }.map(\.text) ?? [] }
    }

    /// Notes the chat, then leaves it for a new chat's tab; `atEnd`, from its end, which a send's
    /// glide may have left it short of (the rows behind that are another matter).
    static func leave(_ left: Left, atEnd: Bool = true) -> [any Step] {
        (atEnd ? [ToEnd(), readerAtEnd] : []) + [
            Do("Note the chat") { story in
                left.chat = try story.activeChat()
                left.backend = ScriptedWorld.shared.backend(session: left.chat?.sessionId)
            },
            StartChat(),
        ]
    }

    static func held(_ range: ClosedRange<Int>, _ left: Left) -> Expect {
        Expect("messages \(range) in memory, behind the tab", found: { _ in left.users().description }) { _ in left.users() == range.map(text) }
    }

    /// To a tab, and how it draws: every few milliseconds for a second from the press, the
    /// transcript's never blank, and its last answer's where it stays.
    struct BackDrawn: Step {
        let tab: Int
        /// The answer it's on, when the story knows it.
        var answer: Int?
        var label: String { "Back to tab \(tab), drawn at once" }
        var timeout: Duration? { .seconds(8) }

        /// A band across the transcript is one colour.
        @MainActor static func blank(_ story: StoryContext) -> Bool {
            guard let frame = story.window?.contentView?.superview else { return true }
            let band = CGRect(x: 0, y: frame.bounds.height * 0.4, width: frame.bounds.width - 100, height: frame.bounds.height * 0.3)
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: band) else { return true }
            frame.cacheDisplay(in: band, to: rep)
            guard let data = rep.bitmapData else { return true }
            let (row, width) = (rep.bytesPerRow, rep.pixelsWide * rep.bitsPerPixel / 8)
            let first = Data(bytes: data, count: width)
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) where Data(bytes: data + y * row, count: width) != first { return false }
            return true
        }

        /// Some row of the chat lies in the band, on the window's scale.
        @MainActor static func rowInBand(_ story: StoryContext) -> Bool {
            guard let window = story.window, let frame = window.contentView?.superview?.bounds, let chat = story.app.chat else { return false }
            let band = CGRect(x: 0, y: frame.height * 0.4, width: frame.width, height: frame.height * 0.3)
            return chat.storyTranscript.entries.suffix(12).contains { entry in
                let id = entry.kind == .answer ? StoryID.Transcript.answer(entry.id) : StoryID.Transcript.user(entry.id)
                return StoryElement(id, in: window)?.frame?.intersects(band) == true
            }
        }

        func run(_ story: StoryContext) async throws {
            let pressed = Date()
            try await Press(.tab(tab)).run(story)
            var (looks, away, undrawn, pictures, blanks) = (0, 0, 0, 0, 0)
            var (drawnAfter, slowest): (TimeInterval?, TimeInterval) = (nil, 0)
            var nextPicture = Date()
            let end = Date().addingTimeInterval(1)
            while Date() < end {
                let transcript = story.app.chat?.storyTranscript
                // Up to the moment the tab's shown, nothing of it is on the screen to be blank.
                if transcript?.showing == true {
                    looks += 1
                    if !Self.rowInBand(story) { away += 1 }
                    let layers = transcript?.drawnLayers ?? 0
                    if layers == 0 { undrawn += 1 } else if drawnAfter == nil { drawnAfter = Date().timeIntervalSince(pressed) }
                    if Date() >= nextPicture {
                        pictures += 1
                        if Self.blank(story) { blanks += 1 }
                        nextPicture = Date().addingTimeInterval(0.3)
                    }
                }
                let beforeSleep = Date()
                try await Task.sleep(for: .milliseconds(4))
                // How long the main thread was taken from this loop, other than by its own look.
                slowest = max(slowest, Date().timeIntervalSince(beforeSleep))
            }
            let ms = { (t: TimeInterval) in Int(t * 1000) }
            let (clip, document) = (story.app.chat?.storyTranscript.scrollView?.contentView.bounds.maxY ?? -1, story.app.chat?.storyTranscript.scrollView?.documentView?.frame.height ?? -1)
            let found = "tab \(tab): \(looks) looks, \(away) with no row in view, \(undrawn) drawing nothing; \(pictures) pictures, \(blanks) blank; drawn after \(drawnAfter.map { "\(ms($0)) ms" } ?? "never"), longest wait \(ms(slowest)) ms; bottom \(Int(clip)) of \(Int(document))"
            try await story.outputs.appendingPathComponent("back-drawn.notes").appendLine(found)
            guard away == 0, undrawn == 0, blanks == 0, pictures >= 3, looks >= 20 else { throw StoryFailure.expectation(found) }
            if let answer { try await UnloadStoryline.drawn(answer: answer).run(story) }
        }
    }

    static func answerRow(_ story: StoryContext, turn n: Int) throws -> StoryID {
        let wanted = [NavCost.answer(1, turn: n), short(n)]
        guard let entry = try story.activeChat().storyTranscript.entries.first(where: { $0.kind == .answer && wanted.contains($0.text) }) else {
            throw StoryFailure.modelMissing("answer \(n)")
        }
        return StoryID.Transcript.answer(entry.id)
    }

    static func drawn(answer n: Int) -> Expect {
        Expect("answer \(n) drawn in view", timeout: .seconds(8)) { story in
            guard let window = story.window, let frame = StoryElement(try answerRow(story, turn: n), in: window)?.frame else { return false }
            return window.contentView.map { $0.bounds.intersects(frame) } ?? false
        }
    }

    static var readerAtEnd: Expect {
        Expect("the reader at the end", found: { story in
            guard let view = story.app.chat?.storyTranscript.scrollView, let document = view.documentView else { return "no scroll view" }
            return "\(story.app.chat?.storyTranscript.readerAtEnd ?? false), bottom \(view.contentView.bounds.maxY) of \(document.frame.height)"
        }) { try $0.activeChat().storyTranscript.readerAtEnd }
    }

    /// The scroll view is at its end.
    static let atEnd = Expect("the view at the end", found: { story in
        guard let view = story.app.chat?.storyTranscript.scrollView, let document = view.documentView else { return "no scroll view" }
        return "bottom \(view.contentView.bounds.maxY) of \(document.frame.height)"
    }) { story in
        guard let view = try story.activeChat().storyTranscript.scrollView, let document = view.documentView else { return false }
        return view.contentView.bounds.maxY >= document.frame.height - 60
    }

    /// Writes the rows, for a before and after to look at.
    static func dump(_ name: String) -> Do {
        Do("Dump the rows as \(name)") { story in
            let lines = try story.activeChat().dumpLines().map { String($0.prefix(120)) }
            try lines.joined(separator: "\n").write(to: story.outputs.appendingPathComponent("\(name).rows"), atomically: true, encoding: .utf8)
        }
    }

    /// What was just read in stays for a moment (`TranscriptStore.staysUntil`).
    struct StaysOver: Step {
        var label: String { "Let what was read in be" }
        func run(_ story: StoryContext) async throws { try await Task.sleep(for: .milliseconds(2200)) }
    }

    /// A pause long enough for anything that was going to happen.
    struct Settle: Step {
        var label: String { "Give it a moment" }
        func run(_ story: StoryContext) async throws { try await Task.sleep(for: .milliseconds(800)) }
    }
}

extension URL {
    func appendLine(_ line: String) async throws {
        let old = (try? String(contentsOf: self, encoding: .utf8)) ?? ""
        try (old + line + "\n").write(to: self, atomically: true, encoding: .utf8)
    }
}

/// A chat on screen keeps every turn, however long: at the end of a turn, and when asked. Left at
/// its end, its oldest go, its marks go dim, the rest are as they were; coming back it's at its end,
/// drawn at once, and stays so across switches, past the tabs kept built (`KeptChats.limit`).
final class UnloadLeavingTab: UnloadStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [turn(16)]) }

    override func steps() -> [any Step] {
        let left = Left()
        var steps = super.steps() + Self.opened(1...15, self)
        steps += [
            Expect("nothing earlier yet") { try !$0.activeChat().storyTranscript.earlierAvailable },
            Send(Self.text(16)), TurnFinished(1), WaitIdle(), GlideEnds(),
            // At its end, with nothing under way: only being on screen keeps its turns.
            ToEnd(), Self.readerAtEnd,
            Do("Ask for an unload") { try $0.activeChat().storyUnload() },
            Settle(),
            Self.holds(1...16),
            Self.marks(earlier: 0, of: 16),
            Self.dump("before"),
        ]
        steps += Self.leave(left)
        steps += [
            Self.held(2...16, left),
            BackDrawn(tab: 2, answer: 16),
            WaitIdle(), Settle(),
            Self.atEnd,
            Self.holds(2...16),
            Self.marks(earlier: 1, of: 16),
            Self.dump("after"),
            Expect("the rows after it are the same", found: { _ in nil }) { story in
                let (before, after) = (
                    try String(contentsOf: story.outputs.appendingPathComponent("before.rows"), encoding: .utf8).components(separatedBy: "\n"),
                    try String(contentsOf: story.outputs.appendingPathComponent("after.rows"), encoding: .utf8).components(separatedBy: "\n"))
                return after.count < before.count && Array(before.suffix(after.count)) == after
            },
            Snapshot("unload-back"),
            // Again, then past the chats kept built (tabs 1 to 6: at most 3 of them).
            StartChat(), StartChat(), StartChat(),
        ]
        for other in [3, 4, 5, 6, 1, 3] {
            steps += [Press(.tab(other)), WaitIdle(), BackDrawn(tab: 2, answer: 16), WaitIdle(), Self.atEnd]
        }
        return steps + [Self.holds(2...16)]
    }
}

/// Left scrolled up in its turns, a chat keeps them, and the reader's place; back at its end and
/// left again, its oldest go.
final class UnloadSparesReader: UnloadStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [turn(16)]) }

    final class Place { var top: CGFloat? }

    /// Up to an answer, as many goes as it takes: one aims at what the rows between are estimated
    /// at, and can land well short of a row that far off.
    struct ScrollUp: Step {
        let answer: Int
        var label: String { "Scroll up to answer \(answer)" }
        var timeout: Duration? { .seconds(8) }
        func run(_ story: StoryContext) async throws {
            let transcript = try story.activeChat().storyTranscript
            guard let entry = transcript.entries.first(where: { $0.kind == .answer && $0.text == NavCost.answer(1, turn: answer) }) else {
                throw StoryFailure.modelMissing("answer \(answer)")
            }
            for _ in 0..<20 {
                transcript.show(entry.id)
                try await Task.sleep(for: .milliseconds(300))
                if let window = story.window, let frame = StoryElement(StoryID.Transcript.answer(entry.id), in: window)?.frame, window.contentView?.bounds.intersects(frame) == true { return }
            }
        }
    }

    static func top(_ story: StoryContext) -> CGFloat? {
        guard let window = story.window, let id = try? answerRow(story, turn: 10) else { return nil }
        return StoryElement(id, in: window)?.frame?.maxY
    }

    override func steps() -> [any Step] {
        let (left, place) = (Left(), Place())
        return super.steps() + Self.opened(1...15, self) + [
            Send(Self.text(16)), TurnFinished(1), WaitIdle(), GlideEnds(),
            ScrollUp(answer: 10),
            Self.drawn(answer: 10), Settle(), Settle(),
            Do("Note where it is") { place.top = Self.top($0) },
        ] + Self.leave(left, atEnd: false) + [
            WaitIdle(), Settle(),
            Self.held(1...16, left),
            Press(.tab(2)), WaitIdle(),
            Self.holds(1...16),
            Self.drawn(answer: 10),
            Expect("the answer where it was", found: { "\(Self.top($0) ?? -1), was \(place.top ?? -1)" }) { story in
                guard let top = Self.top(story), let was = place.top else { return false }
                return abs(top - was) < 0.5
            },
            Snapshot("unload-reader-above"),
            ToEnd(),
            Self.readerAtEnd,
            Press(.tab(3)),
            Self.held(2...16, left),
            BackDrawn(tab: 2, answer: 16),
            Self.holds(2...16),
            Snapshot("unload-reader-back"),
        ]
    }
}

/// What left memory comes back as it was, twice over: the rows the store holds, and the rows
/// built from them, the mode of the folds and the agents' cards included. A rollback and a fork
/// work on a turn read back.
final class UnloadLoadsBack: UnloadStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    /// The rows and lines of the turns of the first 15 that leave, as they were.
    final class Was {
        var dump: [String] = []
        var lines: [String] = []
    }

    static func first(_ turns: Int, of lines: [String], starting: String) -> [String] {
        var seen = 0
        return Array(lines.prefix { line in
            if line.hasPrefix(starting) { seen += 1 }
            return seen <= turns
        })
    }

    override func steps() -> [any Step] {
        let was = Was()
        let left = Left()
        let compare = { (when: String) -> [any Step] in
            [
                Expect("the store's rows as they were \(when)", found: { story in
                    let now = (try? story.activeChat().dumpLines()) ?? []
                    return (zip(was.dump, now).first { $0 != $1 }).map { "\($0)  ≠  \($1)" } ?? "\(was.dump.count) rows, now \(now.count)"
                }) { try $0.activeChat().dumpLines() == was.dump },
                Expect("the built rows as they were \(when)", found: { story in
                    let now = (try? story.activeChat().storyTranscript.rowLines) ?? []
                    return (zip(was.lines, now).first { $0 != $1 }).map { "\($0)  ≠  \($1)" } ?? "\(was.lines.count) rows, now \(now.count)"
                }) { try $0.activeChat().storyTranscript.rowLines == was.lines },
            ]
        }
        return super.steps() + Self.sends(1...15) + [
            WaitIdle(),
            // Opened by hand, the second turn's fold is as it was left when it's back.
            Do("Open turn 2's fold") { try $0.activeChat().storyTranscript.toggleTurn(of: Self.text(2)) },
            Do("Keep the first turns' rows") { story in
                let transcript = try story.activeChat()
                was.dump = Self.first(5, of: transcript.dumpLines(), starting: "user | ")
                was.lines = Self.first(5, of: transcript.storyTranscript.rowLines, starting: "message|")
            },
            Expect("the helper on the map") { try $0.activeChat().storyTranscript.mapAgents == ["helper"] },
        ] + Self.sends(16...20) + Self.leave(left) + [
            Self.held(6...20, left),
            Press(.tab(1)), WaitIdle(),
            Self.marks(earlier: 5, of: 20),
            // On the map, and its own work read back, with its turn out of memory.
            Expect("the helper still on the map") { try $0.activeChat().storyTranscript.mapAgents == ["helper"] },
            Expect("its work not in memory") { try $0.activeChat().storyTranscript.agentRows("helper") == 0 },
            Do("Open it") { try $0.activeChat().storyOpenAgent("helper") },
            Expect("its work read back") { try $0.activeChat().storyTranscript.agentRows("helper") > 0 },
            Expect("the oldest held message can roll back") { try $0.activeChat().storyTranscript.offersRollBack(Self.text(6)) },
            Do("Keep the whole chat's rows") { story in
                let chat = try story.activeChat()
                was.dump += chat.dumpLines()
                was.lines += chat.storyTranscript.rowLines
            },
            Do("Click the first mark") { $0.app.chat?.storyTranscript.railJump(0) },
            Self.holds(1...20),
        ] + MessageRailMarks.atTop(1) + [
            Self.marks(earlier: 0, of: 20),
            Snapshot("unload-loaded-back"),
        ] + compare("the first time") + [
            Expect("the helper on the map once") { try $0.activeChat().storyTranscript.mapAgents == ["helper"] },
            Expect("every changes row opens its files") { story in
                let shown = try story.activeChat().storyTranscript.changesShown
                return shown.count == 4 && shown.allSatisfy { $0 == 1 }
            },
            StaysOver(),
            ToEnd(),
            Self.readerAtEnd,
            Press(.tab(2)),
            Self.held(6...20, left),
            BackDrawn(tab: 1, answer: 20),
            Do("Click the first mark again") { $0.app.chat?.storyTranscript.railJump(0) },
            Self.holds(1...20),
        ] + MessageRailMarks.atTop(1) + compare("the second time") + [
            Fork.fromMessage(3),
            Expect("the fork holds what came before its message") { story in try Self.users(story) == [Self.text(1), Self.text(2)] },
            Press(.tab(1)), WaitIdle(),
            Do("Roll back to message 3") { story in
                let chat = try story.activeChat()
                guard let entry = chat.transcript.entries.first(where: { $0.kind == .user && $0.text == Self.text(3) }) else {
                    throw StoryFailure.modelMissing("message 3")
                }
                chat.rollBack(entry)
            },
            Expect.rows("the rollback's rows") { rows in
                rows.filter { $0.kind == "user" }.map(\.text) == [Self.text(1), Self.text(2)] && rows.last?.text == "Rolled back. Files not changed."
            },
            Expect("the message back in the composer") { try $0.activeChat().draft == Self.text(3) },
        ]
    }
}

/// A rail click on a turn that left memory, read back from a history that gave its turns no
/// duration: the turn takes up what it was, which was none (this crashed: the store was read
/// while it was being written).
final class UnloadJumpNoDuration: UnloadStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        return super.steps() + [
            Do("Open a chat of 20 turns with no durations") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
                let session = "scripted-no-duration-\(provider)"
                ScriptedWorld.shared.sessions[session] = (0..<20).flatMap { MessageRailMarks.turn($0, session) }
                workspace.open(SessionSummary(id: session, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Long", updated: .now))
            },
            WaitForElement(.id(StoryID.Transcript.rail)),
            Self.marks(earlier: 5, of: 20),
            Do("Click a dim mark") { $0.app.chat?.storyTranscript.railJump(1) },
            Expect("the turns read back", found: { (try? Self.users($0))?.description }) { story in
                try Self.users(story) == (1..<20).map(Self.text)
            },
        ] + MessageRailMarks.atTop(1)
    }
}

/// A running turn and a message waiting behind it, left behind another tab: nothing goes
/// meanwhile, what waits is delivered, and then the turns go.
final class UnloadSparesRunning: UnloadStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [heldTurn(18), CLIScript.reply("The waiting one's answer.")]) }

    override func steps() -> [any Step] {
        let left = Left()
        return super.steps() + Self.opened(1...17, self) + [
            Send(Self.text(18)),
            WaitForEvent("the command running") { if case .toolStarted(let call, _) = $0 { call.detail == "sleep" } else { false } },
            Queue("Waiting behind it"),
            GlideEnds(),
        ] + Self.leave(left) + [
            Settle(),
            Self.held(3...18, left),
            Expect("the waiting message's row") { _ in left.chat?.storyTranscript.rowLines.contains("queued|Waiting behind it") == true },
            Expect("the command still running") { _ in left.chat?.rows.contains { $0.text == "sleep" && !$0.done } == true },
            Do("The command ends") { _ in left.backend?.release() },
            Expect("the waiting message delivered, the turns after it kept", found: { _ in left.users().description }) { _ in
                left.users() == (5...18).map(Self.text) + ["Waiting behind it"]
                    && left.chat?.rows.last?.text == "The waiting one's answer."
            },
            Expect("nothing waits") { _ in left.chat?.queuedCount == 0 },
            BackDrawnPlain(tab: 2),
            Self.marks(earlier: 4, of: 19),
        ]
    }

    struct BackDrawnPlain: Step {
        let tab: Int
        var label: String { "Back to tab \(tab)" }
        func run(_ story: StoryContext) async throws { try await Press(.tab(tab)).run(story) }
    }
}

/// A history that can't give turns back: the chat keeps them all, out of sight too.
final class UnloadKeepsUnreadable: UnloadStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        var script = super.script
        script.unreadable = true
        return script
    }

    override func steps() -> [any Step] {
        let left = Left()
        return super.steps() + Self.sends(1...18) + Self.leave(left) + [
            Settle(),
            Self.held(1...18, left),
            Press(.tab(1)),
            Self.marks(earlier: 0, of: 18),
            Expect("nothing to load") { try !$0.activeChat().storyTranscript.earlierAvailable },
        ]
    }
}

/// Rows only this run has (a notice, a turn's failure) keep their turn and all after it.
final class UnloadKeepsLocalRows: UnloadStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        var turns = (1...20).map(turn)
        turns[3] = [.startTurn, .event(.notice("Only Kore saw this")), .stream(.answer, short(4), chunk: 4000), .finishTurn(.completed)]
        turns[6] = [.startTurn, .stream(.answer, short(7), chunk: 4000), .finishTurn(.failed("It broke"))]
        return CLIScript(turns: turns)
    }

    override func steps() -> [any Step] {
        let left = Left()
        return super.steps() + Self.sends(1...20) + Self.leave(left) + [
            Self.held(4...20, left),
            Press(.tab(1)),
            Self.marks(earlier: 3, of: 20),
            Expect.rows("the notice kept") { $0.contains { $0.text == "Only Kore saw this" } },
            Expect("the failure kept") { try $0.activeChat().storyTranscript.rowLines.contains("outcome|It broke") },
        ]
    }
}

/// A turn ends in a tab behind another, its reader having left it at the end: its oldest goes.
/// Back, it's at its end, drawn at once.
final class UnloadBehindTab: UnloadStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [heldTurn(16)]) }

    override func steps() -> [any Step] {
        let left = Left()
        return super.steps() + Self.opened(1...15, self) + [
            Send(Self.text(16)),
            WaitForEvent("the command running") { if case .toolStarted(let call, _) = $0 { call.detail == "sleep" } else { false } },
            GlideEnds(),
        ] + Self.leave(left) + [
            WaitIdle(),
            Do("The turn ends behind the new tab") { _ in left.backend?.release() },
            Self.held(2...16, left),
            BackDrawn(tab: 2, answer: 16),
            Self.holds(2...16),
            WaitIdle(), Settle(),
            Self.atEnd,
            Snapshot("unload-behind-tab"),
        ]
    }
}

/// A chat in a board's tile on screen keeps its turns; the board left, they go.
final class UnloadBoardTile: BoardStoryline {
    override class var tags: Set<Tag> { ["board", .gate] }
    override class var chats: Int { 1 }
    override class var script: CLIScript { CLIScript(turns: (1...40).map { [.startTurn] + Beat.answer("Answer \($0).") + [.finishTurn(.completed)] }) }

    override func steps() -> [any Step] {
        let left = UnloadStoryline.Left()
        let tile = { (story: StoryContext) -> Chat? in (try? BoardProbe.model(story))?.chats.values.first }
        let users = { (story: StoryContext) -> Int in tile(story)?.rows.count { $0.kind == "user" } ?? 0 }
        var steps = [NoNap.step] + super.steps() + [MakeBoard(name: "Backend", take: 1), WaitIdle()]
        for n in 2...18 {
            if n == 18 { steps.append(UnloadStoryline.GlideEnds()) }
            steps.append(Do("Send \(n) in the tile") { tile($0)?.storySend("Message \(n)") })
            steps.append(Expect("message \(n) answered") { story in tile(story)?.rows.last?.text == "Answer \(n)." && tile(story)?.isRunning == false })
        }
        return steps + [
            UnloadStoryline.GlideEnds(),
            // At its end, with nothing under way: only being on screen keeps its turns.
            UnloadStoryline.ToEnd(chat: { tile($0) }),
            Expect("the tile's reader at the end") { tile($0)?.storyTranscript.readerAtEnd == true },
            Do("Ask for an unload") { tile($0)?.storyUnload() },
            UnloadStoryline.Settle(),
            Expect("all 18 turns held", found: { "\(users($0))" }) { users($0) == 18 },
            Do("Note the tile's chat") { left.chat = tile($0) },
            StartChat(),
            Expect("15 turns held with the board behind the new tab", found: { _ in "\(left.chat?.rows.count { $0.kind == "user" } ?? 0)" }) { _ in
                left.chat?.rows.count { $0.kind == "user" } == 15
            },
        ]
    }
}

/// The real Claude backend over a file of its format, with a CLI that never comes up: all that
/// reading it needs. A long chat with a compaction opens on its newest 15 turns, the rest come
/// back whole, across the compaction, and leave again.
final class UnloadClaudeFile: Storyline {
    override class var tags: Set<Tag> { [.resume, .gate] }
    override class var variants: [Variant] { [.claude] }

    static let session = "6f1c1d1e-0000-4000-8000-00000000f11e"
    static let turns = 40
    /// The compaction: this many turns from the end.
    static let tail = 20

    static func file(turns: Int = turns, tail: Int = tail, answer: (Int) -> String = { "Part \($0) is fine." }) -> Data {
        var out = Data()
        var parent: String?
        func entry(_ uuid: String, _ object: [String: Any]) {
            var object = object
            object["uuid"] = uuid
            object["parentUuid"] = parent ?? NSNull()
            object["timestamp"] = "2026-10-20T10:00:00.000Z"
            object["sessionId"] = session
            object["isSidechain"] = false
            out += (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            out.append(0x0A)
            parent = uuid
        }
        for t in 0..<turns {
            if t == turns - tail {
                var boundary: [String: Any] = ["type": "system", "subtype": "compact_boundary", "content": "Conversation compacted"]
                boundary["logicalParentUuid"] = parent
                boundary["compactMetadata"] = ["trigger": "auto", "preTokens": 1000]
                parent = nil
                entry("b-\(t)", boundary)
                entry("s-\(t)", ["type": "user", "isCompactSummary": true, "message": ["role": "user", "content": "Summary of the work so far."]])
            }
            entry("u-\(t)", ["type": "user", "permissionMode": "default", "message": ["role": "user", "content": MessageRailMarks.text(t)]])
            entry("a-\(t)", ["type": "assistant", "message": ["id": "m-\(t)", "role": "assistant", "content": [["type": "tool_use", "id": "t-\(t)", "name": "Bash", "input": ["command": "ls part-\(t)"]]]]])
            entry("r-\(t)", ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t-\(t)", "content": "part \(t) listed"]]]])
            entry("c-\(t)", ["type": "assistant", "message": ["id": "n-\(t)", "role": "assistant", "content": [["type": "text", "text": answer(t)]]]])
        }
        return out
    }

    /// The rows of turns `from...`, and the compaction's where it falls, as a whole read shows them.
    static func expected(from first: Int) -> [String] {
        (first..<turns).flatMap { t -> [String] in
            // A page that starts at the turn after a compaction has it in the page before.
            let lead = t == turns - tail && t > first ? ["divider", "summary Summary of the work so far."] : []
            return lead + ["user \(MessageRailMarks.text(t))", "tool Bash ls part-\(t) part \(t) listed", "assistant Part \(t) is fine."]
        }
    }

    static func rows(_ story: StoryContext) throws -> [String] {
        // A notice says the CLI didn't come up: not the history's.
        try story.activeChat().rows.filter { $0.kind != "notice" }.map { row in
            row.kind == "divider" ? "divider" : [row.kind, row.tool, row.text, row.result].compactMap { $0 }.joined(separator: " ")
        }
    }

    override func steps() -> [any Step] {
        let left = UnloadStoryline.Left()
        let holdsExpected = { (first: Int) in
            Expect("rows from turn \(first) as the file has them", found: { story in
                let now = (try? Self.rows(story)) ?? []
                return (zip(Self.expected(from: first), now).first { $0 != $1 }).map { "\($0)  ≠  \($1)" } ?? "\(now.count) rows"
            }) { try Self.rows($0) == Self.expected(from: first) }
        }
        return [
            OpenFolder(),
            WithClaudeFile(steps: [
                holdsExpected(Self.turns - 15),
                Expect("every message marked, the ones gone dim", found: { $0.app.chat?.storyTranscript.railMarks.description }) { story in
                    let marks = try story.activeChat().storyTranscript.railMarks
                    return marks.count == Self.turns && marks.count { $0 == "earlier" } == Self.turns - 15
                },
                Do("Click the first mark") { $0.app.chat?.storyTranscript.railJump(0) },
                holdsExpected(0),
                Snapshot("unload-claude-back"),
                WaitIdle(),
                UnloadStoryline.StaysOver(),
                UnloadStoryline.ToEnd(),
                Do("Note the chat") { left.chat = try $0.activeChat() },
                StartChat(),
                Expect("the newest 15 turns held, behind the new tab", found: { _ in left.users().first }) { _ in
                    left.users() == (Self.turns - 15..<Self.turns).map(MessageRailMarks.text)
                },
                Press(.tab(1)), WaitIdle(),
                holdsExpected(Self.turns - 15),
                Do("Click a dim mark") { $0.app.chat?.storyTranscript.railJump(Self.turns - 20) },
                holdsExpected(Self.turns - 20),
            ]),
        ]
    }
}

/// The real backend and a CLI that exits at once, for as long as `steps` take: they run here so
/// a failure can't leave the next storyline with them.
struct WithClaudeFile: Step {
    /// The chat's file, when it isn't `UnloadClaudeFile.file()`.
    var file: Data?
    let steps: [any Step]
    var label: String { "Open the long chat with the real backend, and read it" }
    var timeout: Duration? { .seconds(120) }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        guard let store = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] else { throw StoryFailure.other("no Claude store") }
        let project = URL(fileURLWithPath: store).appendingPathComponent("projects")
            .appendingPathComponent(CassettePaths.encoded(ClaudeTraces.realPath(story.folder.path)))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try (file ?? UnloadClaudeFile.file()).write(to: project.appendingPathComponent("\(UnloadClaudeFile.session).jsonl"))
        try await story.until("the folder's chats listed") { DevNavProbe.chatsListed(workspace) }
        let (seams, standIns, retries) = (StorylineSeams.backend, CLIExecutable.standIns.value, Chat.startRetries.value)
        StorylineSeams.backend = nil
        CLIExecutable.standIns.value = ["claude": .init(executable: URL(fileURLWithPath: "/usr/bin/false"))]
        // It's tried once: it mustn't come up as the real one once this is over.
        Chat.startRetries.value = []
        defer {
            StorylineSeams.backend = seams
            CLIExecutable.standIns.value = standIns
            Chat.startRetries.value = retries
        }
        workspace.open(SessionSummary(id: UnloadClaudeFile.session, agent: .claude, title: "Long", updated: .now))
        _ = try await story.wait("the chat") { story.app.chat }
        story.timeout = .seconds(10)
        for step in steps { try await step.run(story) }
    }
}

/// A run nobody's using has its timers coalesced 100 ms apart after half a minute (App Nap), which
/// takes its layout and drawing along. Someone pressing a tab is using the app: these run as that.
@MainActor enum NoNap {
    private static var activity: NSObjectProtocol?

    static var step: Do {
        Do("Keep the app from napping") { _ in
            activity = activity ?? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "A storyline's timings")
        }
    }
}

/// A line in a file of the run's.
struct NoteLine: Step {
    let file: String
    let line: @MainActor (StoryContext) async -> String
    var label: String { "Note a number in \(file)" }
    func run(_ story: StoryContext) async throws {
        try await story.outputs.appendingPathComponent(file).appendLine(await line(story))
    }
}

/// The longest the main thread stayed away from a tick of a few milliseconds, while it's watched.
@MainActor final class MainStalls {
    private var ticker: Task<Void, Never>?
    private(set) var longest: TimeInterval = 0

    func start() {
        longest = 0
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                let now = Date()
                self?.longest = max(self?.longest ?? 0, now.timeIntervalSince(last))
                last = now
            }
        }
    }

    func stop() -> Int {
        ticker?.cancel()
        ticker = nil
        return Int(longest * 1000)
    }
}

/// What a big chat costs, in numbers (`big-chat.notes`), with the real backend reading a file of
/// its format: a page read back, all of it read back, its turns leaving, and the tab's return.
final class UnloadBigClaudeFile: Storyline {
    override class var tags: Set<Tag> { ["bench"] }
    override class var variants: [Variant] { [.claude] }

    static let turns = 300

    /// Reads back as the step says, and notes how long that took and the longest stall in it.
    struct Measured: Step {
        let what: String
        let index: Int
        let holding: Int
        var label: String { "Read back \(what)" }
        var timeout: Duration? { .seconds(60) }

        func run(_ story: StoryContext) async throws {
            let stalls = MainStalls()
            stalls.start()
            let began = Date()
            story.app.chat?.storyTranscript.railJump(index)
            try await story.until("\(holding) turns held", timeout: .seconds(60)) {
                story.app.chat?.rows.count { $0.kind == "user" } == holding
            }
            let took = Int(Date().timeIntervalSince(began) * 1000)
            try await Task.sleep(for: .milliseconds(500))
            let found = "\(what): \(took) ms to \(holding) turns, longest main thread stall \(stalls.stop()) ms"
            try await story.outputs.appendingPathComponent("big-chat.notes").appendLine(found)
        }
    }

    override func steps() -> [any Step] {
        let left = UnloadStoryline.Left()
        let stalls = MainStalls()
        let file = UnloadClaudeFile.file(turns: Self.turns, tail: 100) { NavCost.answer(1, turn: $0) }
        return [
            NoNap.step,
            OpenFolder(),
            WithClaudeFile(file: file, steps: [
                Expect("the newest 15 turns held") { $0.app.chat?.rows.count { $0.kind == "user" } == 15 },
                UnloadStoryline.Settle(),
                NoteLine(file: "big-chat.notes") { _ in "file: \(file.count / 1024) KB, \(Self.turns) turns" },
                Measured(what: "a page of 10 turns", index: Self.turns - 25, holding: 25),
                UnloadStoryline.StaysOver(),
                Measured(what: "all the rest", index: 0, holding: Self.turns),
                UnloadStoryline.StaysOver(),
                UnloadStoryline.ToEnd(),
                UnloadStoryline.readerAtEnd,
                Do("Note the chat") { left.chat = try $0.activeChat(); stalls.start() },
                StartChat(),
                Expect("the newest 15 turns held, behind the new tab", timeout: .seconds(20), found: { _ in "\(left.users().count)" }) { _ in left.users().count == 15 },
                UnloadStoryline.StaysOver(),
                NoteLine(file: "big-chat.notes") { _ in "\(Self.turns - 15) turns leaving: longest main thread stall \(stalls.stop()) ms" },
                UnloadStoryline.BackDrawn(tab: 1, answer: nil),
            ]),
        ]
    }
}

/// The footprint of five long chats read through and left at their ends, behind a new tab
/// (`footprint.notes`).
class UnloadFootprint: UnloadStoryline {
    override class var isFamily: Bool { false }
    override class var tags: Set<Tag> { ["bench"] }
    /// Each chat's old turns read back first, rather than only opened.
    class var readThrough: Bool { true }
    static let turns = 120

    static func footprint() async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "footprint didn't run" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            return lines.first { $0.contains("phys_footprint:") } ?? lines.first { $0.contains("Footprint") } ?? "no footprint in \(lines.count) lines"
        }.value
    }

    override func steps() -> [any Step] {
        let provider = variant.provider ?? "claude"
        var steps = super.steps()
        steps.append(NoteLine(file: "footprint.notes") { _ in "no long chat yet: \(await Self.footprint())" })
        for chat in 1...5 {
            let name = "footprint-\(provider)-\(chat)"
            steps += [
                Do("Open long chat \(chat)") { story in
                    guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
                    ScriptedWorld.shared.sessions[name] = (1...Self.turns).flatMap { Self.history($0, name) }
                    workspace.open(SessionSummary(id: name, agent: SessionSummary.Agent(rawValue: provider) ?? .claude, title: "Long \(chat)", updated: .now))
                },
                WaitForElement(.id(StoryID.Transcript.rail)),
                WaitIdle(),
            ]
            if Self.readThrough {
                steps += [
                    Do("Read to its first message") { $0.app.chat?.storyTranscript.railJump(0) },
                    Expect("all \(Self.turns) held", timeout: .seconds(20)) { try Self.users($0).count == Self.turns },
                    WaitIdle(),
                    Do("Build every turn it holds") { try $0.activeChat().storyTranscript.showAll() },
                    WaitIdle(), Settle(), StaysOver(),
                ]
            }
            steps += [Settle(), ToEnd(), Self.readerAtEnd]
        }
        steps += [
            NoteLine(file: "footprint.notes") { _ in "all read, one showing: \(await Self.footprint())" },
            StartChat(),
            StaysOver(), StaysOver(),
            NoteLine(file: "footprint.notes") { _ in "all out of sight: \(await Self.footprint())" },
        ]
        return steps
    }
}

/// The same, each only opened.
final class UnloadFootprintOpened: UnloadFootprint {
    override class var readThrough: Bool { false }
}
