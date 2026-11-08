import AppKit
import KoreCore
import KoreUI
import src

/// An old, long chat brought over from another CLI, opened from History: rows many screens tall
/// with long unbroken lines (tool calls and their output pasted in as text, a task notification's
/// XML, a 5 000-character token). It opens at its last message, and the transcript never runs
/// wider than its column: nothing scrolls sideways, every row inside it.
class OpenEndStoryline: ChatStoryline {
    override class var isFamily: Bool { self == OpenEndStoryline.self }
    static let turns = 24

    /// The chat's session, by CLI.
    var session: String { "opened-end-\(variant.provider ?? "claude")" }

    /// The chat in the folder's history, the folder opened, History pressed and the chat picked.
    func opened(during: [any Step] = []) -> [any Step] {
        let provider = variant.provider ?? "claude"
        let id = session
        return [
            UseScript(Self.script),
            Do("A long imported chat in the folder's history") { story in
                let world = ScriptedWorld.shared
                world.sessions[id] = (1...Self.turns).flatMap { Self.turn($0, id) }
                let file = provider == "claude" ? ClaudeHistory.transcript(sessionId: id, in: story.folder) : story.outputs.appendingPathComponent("\(id).jsonl")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.listing(provider, session: id, folder: story.folder).write(to: file, atomically: true, encoding: .utf8)
                if provider != "claude" { world.list(id, provider: provider, folder: story.folder, title: "Imported work", file: file) }
            },
            OpenFolder(), StartChat(),
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(.id(StoryID.History.row(id))),
            Press(.id(StoryID.History.row(id))),
        ] + during + [
            WaitForElement(.id(StoryID.Transcript.rail)),
            WaitIdle(),
            AtEnd(when: "opened from History"),
        ]
    }
}

/// Left for another tab and back, it's at its end again; scrolled up first, it comes back where
/// the reader left it.
final class OpenedChatLandsAtEnd: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let tab = Self.tab(of: session)
        return opened() + [
            Snapshot("opened-end"),
            StartChat(), WaitIdle(),
            Press(tab), WaitIdle(),
            AtEnd(when: "switched back to"),
            // Up through the last turn's rows, a screen at a time: each in its column.
            Sweep(), UnloadStoryline.ToEnd(), WaitIdle(),
            // A place above the end is kept through a switch.
            Scroll(Self.lastAnswer, to: .by(-2500)), WaitIdle(),
            NotePlace(),
            Press(.tab(1)), WaitIdle(),
            Press(tab), WaitIdle(),
            KeptPlace(),
            Clean(when: "back where it was left"),
        ]
    }
}

/// The window's width changes a few times in the first second, as the chat opens (a scroller
/// showing, the window resized): it still lands at the end.
final class OpenedChatLandsAtEndResized: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] { opened(during: [ResizedOpening()]) }

    struct ResizedOpening: Step {
        var label: String { "Change the window's width as the chat opens" }
        func run(_ story: StoryContext) async throws {
            guard let window = story.window else { throw StoryFailure.modelMissing("the window") }
            let size = window.contentRect(forFrameRect: window.frame).size
            for (wait, by) in [(60, -120), (150, -40), (200, -160), (250, 0)] as [(Int, CGFloat)] {
                try await Task.sleep(for: .milliseconds(wait))
                window.setContentSize(NSSize(width: size.width + by, height: size.height))
            }
        }
    }
}

/// A tab pinched and back at its natural size: left and back, it's at its end. Pinched again
/// and moved, then left, it's drawn from its left edge meanwhile and comes back magnified as it
/// was; back at its natural size, nothing scrolls sideways.
final class PinchedTabKeepsItsPlace: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let tab = Self.tab(of: session)
        return opened() + [
            Pinch(at: CGPoint(x: 0.75, y: 0.5), amount: 0.5, to: 1.5),
            Pinch(at: CGPoint(x: 0.5, y: 0.98), amount: -1, to: 1),
            UnloadStoryline.ToEnd(), WaitIdle(),
            StartChat(), WaitIdle(),
            Press(tab), WaitIdle(),
            AtEnd(when: "back after a pinch"),
            // Magnified and moved: kept through a switch.
            Scroll(Self.lastAnswer, to: .by(-900)), WaitIdle(),
            Pinch(at: CGPoint(x: 0.75, y: 0.35), amount: 0.5, to: 1.5),
            NoteZoom(),
            Press(.tab(1)), WaitIdle(),
            // Left behind at its natural size, it's drawn from its left edge.
            Expect("the tab left behind at 1×, from its left edge", found: { story in Self.left(story) }) { story in
                guard let scroll = story.stash(Zoomed.self, make: { Zoomed() }).scroll else { return false }
                return scroll.magnification < 1.001 && abs(scroll.contentView.bounds.minX) < 0.5
            },
            Press(tab), WaitIdle(),
            KeptZoom(),
            // Back to 1×: nothing sideways, and no sideways scrolling.
            Pinch(at: CGPoint(x: 0.5, y: 0.5), amount: -1, to: 1),
            Expect("at 1×, from the left edge, not scrolling sideways", found: { story in Self.left(story) }) { story in
                let scroll = try PinchZoomNewLineHolds.scroll(story)
                return abs(scroll.contentView.bounds.minX) < 0.5 && scroll.horizontalScrollElasticity != .allowed && Look(story).clean
            },
        ]
    }

    struct Pinch: Step {
        let at: CGPoint
        let amount: CGFloat
        let to: CGFloat
        var label: String { "Pinch the transcript to \(to)×" }
        func run(_ story: StoryContext) async throws {
            let scroll = try PinchZoomNewLineHolds.scroll(story)
            try await PinchZoomNewLineHolds.pinch(story, scroll, at: at, amount: amount)
            guard abs(scroll.magnification - to) < 0.01 else { throw StoryFailure.other("the pinch left \(scroll.magnification)×") }
        }
    }

    final class Zoomed {
        var scale: CGFloat = 1, origin = CGPoint.zero
        var row: (id: String, y: CGFloat)?
        weak var scroll: NSScrollView?
    }

    @MainActor static func left(_ story: StoryContext) -> String {
        guard let scroll = story.stash(Zoomed.self, make: { Zoomed() }).scroll ?? (try? PinchZoomNewLineHolds.scroll(story)) else { return "no scroll view" }
        return "\(scroll.magnification)× at \(scroll.contentView.bounds.origin), sideways \(scroll.horizontalScrollElasticity.rawValue); \(Look(story).described)"
    }

    struct NoteZoom: Step {
        var label: String { "Note the magnified view" }
        func run(_ story: StoryContext) async throws {
            let scroll = try PinchZoomNewLineHolds.scroll(story)
            let noted = story.stash(Zoomed.self) { Zoomed() }
            try await story.idle()
            (noted.scale, noted.origin, noted.scroll) = (scroll.magnification, scroll.contentView.bounds.origin, scroll)
            noted.row = OpenEndStoryline.rowAcross(story)
            guard noted.origin.x > 1 else { throw StoryFailure.other("the pinch left the view at its left side (\(noted.origin))") }
        }
    }

    /// Its scale and side as left, and the row the reader was at still on screen. (Its exact place
    /// is the native origin the pinch kept, which content changing above it can shift.)
    struct KeptZoom: Step {
        var label: String { "Expect the magnified view as it was left" }
        func run(_ story: StoryContext) async throws {
            let noted = story.stash(Zoomed.self) { Zoomed() }
            guard let row = noted.row else { throw StoryFailure.other("no row noted") }
            var seen = "-"
            do {
                try await story.until("the view magnified as left", timeout: .seconds(4)) {
                    let scroll = try PinchZoomNewLineHolds.scroll(story)
                    let x = scroll.contentView.bounds.minX, y = DevNavProbe.rowY(row.id)
                    seen = "\(scroll.magnification)× at side \(x), \(row.id.prefix(24)) at \(y.map { "\(Int($0))" } ?? "not built")"
                    let shown = scroll.convert(scroll.bounds, to: nil)
                    let onScreen = StoryRegistry.entry(row.id).flatMap(\.frame).map { $0.intersects(shown) } ?? false
                    return abs(scroll.magnification - noted.scale) < 0.001 && abs(x - noted.origin.x) <= 1 && onScreen
                }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation("\(noted.scale)× at side \(noted.origin.x), the row noted at \(Int(row.y)) on screen (found \(seen))")
            }
        }
    }
}

extension OpenEndStoryline {
    /// The chat's last answer: on screen at the end, so the scroll view it's in is the
    /// transcript's wherever the view is.
    static var lastAnswer: Locator {
        Locator("the last answer") { app in
            guard let last = app.chat?.storyTranscript.entries.last(where: { $0.kind == .answer }) else { return .failure(LocatorMiss("no answer yet", pending: true)) }
            return .success(StoryID.Transcript.answer(last.id))
        }
    }

    /// The tab showing the chat of session `id`.
    static func tab(of id: String) -> Locator {
        Locator("the chat \(id)'s tab") { app in
            guard let tabs = app.workspace?.tabs else { return .failure(LocatorMiss("no workspace")) }
            guard let tab = tabs.first(where: { $0.chat?.sessionId == id }) else { return .failure(LocatorMiss("no tab of \(id) yet", pending: true)) }
            return .success(StoryID.Tabs.tab(tab.id))
        }
    }

    /// A word of `count` characters with nothing to break at.
    static func token(_ count: Int, _ seed: Int) -> String {
        String(String(repeating: "q\(seed)xyzw0123456789", count: count / 10 + 1).prefix(count))
    }

    /// A task's notification as the CLI words it, its output file's path long and unbroken.
    static func notification(_ n: Int) -> String {
        "<task-notification>\n<task-id>b\(n)task</task-id>\n<tool-use-id>call-\(n)</tool-use-id>\n"
            + "<output-file>/private/tmp/work-\(n)/" + token(900, n) + ".output</output-file>\n"
            + "<status>completed</status>\n<summary>Background command \"Check part \(n)\" completed (exit code 0)</summary>\n</task-notification>"
    }

    /// A tool call pasted in as text, as an import across CLIs carries it.
    static func call(_ n: Int, _ k: Int) -> String {
        "[external_agent_tool_call: Bash]\ndescription: Look at part \(n).\(k)\ncommand: "
            + (0..<160).map { "--option-\($0)=value-\(n)-\(k)" }.joined(separator: " ")
            + "\n[/external_agent_tool_call]"
    }

    /// Its result: colour codes, a progress line of carriage returns, a dict printed on one line,
    /// and many lines more.
    static func result(_ n: Int, _ k: Int) -> String {
        let esc = "\u{1B}"
        let progress = (1...120).map { "Updating files: \($0)% (\($0 * 10)/1200)" }.joined(separator: "\r")
        let dict = "{" + (0..<90).map { "'key\($0)':'value-\(n)-\(k)-\($0)'" }.joined(separator: ",") + "}"
        let lines = (0..<180).map { "\(esc)[0;36m\($0) |\(esc)[0;0m line \($0) of what part \(n).\(k) printed" }.joined(separator: "\n")
        return "[external_agent_tool_result]\n\(progress)\n\(dict)\n\(lines)\n[/external_agent_tool_result]"
    }

    static func answer(_ n: Int) -> String {
        let fence = String(repeating: "`", count: 3)
        return "Part \(n) is done.\n\n" + token(5000, n) + "\n\n"
            + "\(fence)\n" + token(1200, n) + "\n\(fence)\n\n"
            // The rest of what markdown can hold a long word in.
            + "# " + token(600, n) + "\n\n"
            + "- " + token(3000, n) + "\n- a list holding code:\n\n  \(fence)\n  " + token(1500, n) + "\n  \(fence)\n\n"
            + "> " + token(2000, n) + "\n\n"
            + "Inline `" + token(900, n) + "` code.\n\n"
            + "| " + (0..<24).map { "col \($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 24) + "\n| "
            + (0..<24).map { _ in token(40, n) }.joined(separator: " | ") + " |\n\n"
            + "    // MARK: indented " + token(700, n) + "\n\n"
            + (1...60).map { "Paragraph \($0) of answer \(n), long enough to wrap a little at a narrow width." }.joined(separator: "\n\n")
    }

    static func turn(_ n: Int, _ session: String) -> [ChatEvent] {
        let id = "\(session)-turn-\(n)"
        let ask = n % 2 == 0 ? notification(n) : "Message \(n): look at part \(n) " + token(2000, n)
        var events: [ChatEvent] = [
            .userMessage(text: ask, attachments: [], id: "\(session)-message-\(n)"),
            .turnStarted(id, origin: .user, at: Date()),
        ]
        for k in 0..<2 {
            events.append(.text("\(id)-call-\(k)", .answer, call(n, k)))
            events.append(.text("\(id)-result-\(k)", .answer, result(n, k)))
        }
        events += [.text("\(id)-answer", .answer, answer(n)), .turnFinished(id, .completed, duration: nil)]
        return events
    }

    /// The chat's file, for History to list it; what it holds comes from the scripted CLI.
    private static func listing(_ provider: String, session: String, folder: URL) -> String {
        if provider == "claude" {
            return [
                #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Imported work"},"uuid":"u0","timestamp":"2026-10-20T09:00:00.000Z","cwd":"\#(folder.path)","sessionId":"\#(session)"}"#,
                #"{"parentUuid":"u0","isSidechain":false,"message":{"id":"m0","type":"message","role":"assistant","content":[{"type":"text","text":"Done."}]},"type":"assistant","uuid":"a0","timestamp":"2026-10-20T09:00:01.000Z","sessionId":"\#(session)"}"#,
            ].joined(separator: "\n") + "\n"
        }
        return [
            #"{"timestamp":"2026-10-20T09:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Imported work"}]}}"#,
            #"{"timestamp":"2026-10-20T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#,
        ].joined(separator: "\n") + "\n"
    }

    /// The transcript's geometry, as the checks read it.
    @MainActor struct Look {
        var fromEnd: CGFloat = .infinity
        var side: CGFloat = 0
        var documentWidth: CGFloat = 0
        var clipWidth: CGFloat = 0
        var lastShown = false
        var wide: [String] = []
        var end = "-"

        init(_ story: StoryContext) {
            guard let window = story.window, let transcript = story.app.chat?.storyTranscript, let scroll = transcript.scrollView,
                let document = scroll.documentView
            else { return }
            let clip = scroll.contentView
            fromEnd = document.frame.height - clip.bounds.maxY
            side = clip.bounds.minX
            documentWidth = document.frame.width
            clipWidth = clip.bounds.width
            end = transcript.endWhy
            let shown = scroll.convert(scroll.bounds, to: nil)
            if let last = transcript.entries.last(where: { $0.kind == .answer }), let frame = StoryElement(StoryID.Transcript.answer(last.id), in: window)?.frame {
                lastShown = frame.intersects(shown) && frame.maxY >= shown.minY
            }
            // Every row built on screen, inside the column.
            for id in StoryRegistry.ids where id.hasPrefix("transcript.answer[") || id.hasPrefix("transcript.user[") {
                guard let entry = StoryRegistry.entry(id, in: window), let frame = entry.frame, frame.intersects(shown) else { continue }
                if frame.minX < shown.minX - 0.5 || frame.maxX > shown.maxX + 0.5 { wide.append("\(id.prefix(24)) \(Int(frame.minX))–\(Int(frame.maxX))") }
            }
            wide = Array(wide.prefix(3)) + (wide.count > 3 ? ["…\(wide.count) in all"] : [])
            wide = wide.isEmpty ? [] : wide + ["column \(Int(shown.minX))–\(Int(shown.maxX))"]
        }

        var clean: Bool { abs(side) < 0.5 && documentWidth <= clipWidth + 0.5 && wide.isEmpty }
        var described: String {
            "\(Int(fromEnd)) pt above the end, last answer \(lastShown ? "shown" : "not shown"); side \(side), document \(Int(documentWidth)) in \(Int(clipWidth)); "
                + "too wide: \(wide.isEmpty ? "none" : wide.joined(separator: ", ")); \(end)"
        }
    }

    /// At its end, its last answer on screen, nothing sideways, and so still a moment later (the
    /// tall rows have laid out by then).
    struct AtEnd: Step {
        let when: String
        var label: String { "Expect the chat at its end and in its column, \(when)" }
        var timeout: Duration? { .seconds(10) }

        /// In view within a second of the chat showing (blank or mid-way meanwhile is what the
        /// reader sees), then so at every look for over a second more.
        func run(_ story: StoryContext) async throws {
            var seen = "nothing read"
            func ok() -> Bool {
                let look = Look(story)
                seen = look.described
                return look.fromEnd <= 2 && look.lastShown && look.clean
            }
            do {
                try await story.until("at the end", timeout: .seconds(1)) { ok() }
                for _ in 0..<12 {
                    try await Task.sleep(for: .milliseconds(100))
                    guard ok() else { throw StoryFailure.timedOut("") }
                }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation("\(when): the end in view, in the column (found \(seen))")
            }
        }
    }

    /// Up a screen at a time through the last turn, every row in the column at each.
    struct Sweep: Step {
        var label: String { "Expect every row in the column, a screen at a time up the last turn" }
        var timeout: Duration? { .seconds(30) }
        func run(_ story: StoryContext) async throws {
            for screen in 1...8 {
                try await Scroll(OpenEndStoryline.lastAnswer, to: .by(-500)).run(story)
                try await story.idle()
                let look = Look(story)
                guard look.clean else { throw StoryFailure.expectation("screen \(screen) up: every row in the column (found \(look.described))") }
            }
        }
    }

    struct Clean: Step {
        let when: String
        var label: String { "Expect every row in the column, \(when)" }
        func run(_ story: StoryContext) async throws {
            let look = Look(story)
            guard look.clean else { throw StoryFailure.expectation("\(when): every row in the column (found \(look.described))") }
        }
    }

    final class Place { var row: (id: String, y: CGFloat)? }

    /// Notes the row across the top quarter of the view, and where its top is.
    struct NotePlace: Step {
        var label: String { "Note where the reader is" }
        func run(_ story: StoryContext) async throws {
            try await story.idle()
            guard let row = OpenedChatLandsAtEnd.rowAcross(story) else { throw StoryFailure.other("no row on screen") }
            guard (try? story.activeChat().storyTranscript.readerAtEnd) != true else { throw StoryFailure.expectation("the reader above the end") }
            story.stash(Place.self) { Place() }.row = row
        }
    }

    /// The message or answer row across the line a quarter down the transcript, and its top.
    @MainActor static func rowAcross(_ story: StoryContext) -> (id: String, y: CGFloat)? {
        guard let window = story.window, let scroll = story.app.chat?.storyTranscript.scrollView else { return nil }
        let shown = scroll.convert(scroll.bounds, to: nil)
        let mark = shown.maxY - shown.height / 4
        for id in StoryRegistry.ids where id.hasPrefix("transcript.answer[") || id.hasPrefix("transcript.user[") {
            if let frame = StoryRegistry.entry(id, in: window)?.frame, frame.minY <= mark, frame.maxY >= mark { return (id, frame.maxY) }
        }
        return nil
    }

    /// That answer where it was (±2 pt), not the end.
    struct KeptPlace: Step {
        var label: String { "Expect the reader's place kept" }
        func run(_ story: StoryContext) async throws {
            guard let noted = story.stash(Place.self, make: { Place() }).row else { throw StoryFailure.other("no place noted") }
            var found: Double?
            do {
                try await story.until("the place kept", timeout: .seconds(4)) {
                    found = DevNavProbe.rowY(noted.id)
                    return found.map { abs($0 - noted.y) <= 2 } ?? false
                }
                try await Task.sleep(for: .milliseconds(800))
                found = DevNavProbe.rowY(noted.id)
                guard found.map({ abs($0 - noted.y) <= 2 }) ?? false else { throw StoryFailure.timedOut("") }
            } catch StoryFailure.timedOut {
                throw StoryFailure.expectation("\(noted.id) at \(Int(noted.y)) (found \(found.map { "\(Int($0))" } ?? "not built"); \(Look(story).described))")
            }
        }
    }
}
