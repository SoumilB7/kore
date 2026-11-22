import AppKit
import KoreUI
import src

/// Three chats, each with its own rows, draft and place in its transcript, switched between by
/// their tabs: each comes back exactly as it was left, with the composer holding its draft and
/// the caret in it. Typing in one chat leaves nothing to undo in another; a fourth chat lets the
/// longest unseen one's view go, and it comes back where it was too; and a reply that streams
/// in while its chat is hidden is all there when it shows.
final class TabSwitching: Storyline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    /// A long answer: a few screens of paragraphs, so there's a middle to leave the reader in.
    static func answer(_ chat: Int, turn: Int) -> String {
        (1...30).map { "Chat \(chat), answer \(turn), paragraph \($0): the scripted CLI says enough here to fill a line or two of the transcript, and then a little more, so that each paragraph wraps." }
            .joined(separator: "\n\n")
    }

    static func script(_ chat: Int) -> CLIScript {
        CLIScript(turns: (1...3).map { turn in [.startTurn, .stream(.answer, answer(chat, turn: turn), chunk: 400), .finishTurn(.completed)] })
    }

    /// A chat in a new tab: two long turns, a draft typed, and the reader a little way up.
    static func chat(_ n: Int, draft: String) -> [any Step] {
        [
            UseScript(script(n)), StartChat("claude"),
            Send("chat \(n), first"), TurnFinished(1), Send("chat \(n), second"), TurnFinished(2),
            WaitForFocus(.id(StoryID.Composer.field)), TypeText(draft),
            Expect("“\(draft)” in the draft") { try $0.activeChat().draft == draft },
            Scroll(.answer(turn: 2), to: .by(n == 2 ? -900 : -300 - 70 * CGFloat(n))),
        ]
    }

    override func steps() -> [any Step] {
        [OpenFolder()] + Self.chat(1, draft: "draft one") + Self.chat(2, draft: "draft two") + Self.chat(3, draft: "draft three") + [
            SwitchTab(1), SwitchTab(2), SwitchTab(3), SwitchTab(1), SwitchTab(3), SwitchTab(2), SwitchTab(1),

            // Undo stays with the chat it was typed in.
            TypeText(" more"),
            Expect("the typing in chat 1's draft") { try $0.activeChat().draft == "draft one more" },
            SwitchTab(2),
            Expect("nothing of chat 1's typing to undo in chat 2") { story in
                story.window?.firstResponder?.undoManager?.canUndo == false
            },
            SwitchTab(1),

            // A fourth chat: chat 3, the longest unseen, is let go, and comes back as it was.
            StartChat("claude"), WaitForFocus(.id(StoryID.Composer.field)),
            // The composer keeps its focus through the start: typing waits for it to show the new chat.
            Expect("the new chat's empty draft in the composer") { story in SwitchTab.composerText(story) == "" },
            TypeText("draft four"),
            SwitchTab(3), SwitchTab(2), SwitchTab(1), SwitchTab(3), SwitchTab(4), SwitchTab(3),

            // A reply streaming into a hidden chat is all there when it shows.
            SwitchTab(1), Pace(20), Send("chat 1, third"),
            Expect("chat 1's reply streaming") { try $0.activeChat().isRunning },
            Press(.tab(2)),
            Expect("chat 1's reply to finish while hidden") { story in
                story.app.workspace?.tabs.first?.chat.map { !$0.isRunning && $0.rows.last?.text == Self.answer(1, turn: 3) } ?? false
            },
            Press(.tab(1)),
            Expect("its whole reply drawn, at the end") { story in
                guard let chat = story.app.chat, let last = chat.storyTranscript.entries.last, last.kind == .answer,
                    let element = StoryElement(StoryID.Transcript.answer(last.id)), let view = element.registeredView
                else { return false }
                return last.text == Self.answer(1, turn: 3) && !view.visibleRect.isEmpty
            },

            Expect("one CLI per chat, none started again") { _ in ScriptedWorld.shared.backends.count == 4 },
        ]
    }
}

/// A chat left mid-way up its transcript, then let go as three other chats show (only the last
/// three shown keep their views), comes back after a while with its rows drawn where the reader
/// was: never parked past the real rows on a height that only estimates them.
final class TabComesBackDrawn: Storyline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var variants: [Variant] { [.claude, .codex] }

    static let turns = 8

    /// Answers of very different heights (a line, then screens of paragraphs, lists and code), so
    /// the lazy stack's estimates for rows it hasn't built are well off.
    static func answer(_ chat: Int, turn: Int) -> String {
        guard turn % 2 == 0 else { return "Chat \(chat), answer \(turn): short." }
        let paragraphs = (1...(10 * turn)).map { i in
            i % 7 == 0
                ? "```swift\nlet chat = \(chat), turn = \(turn), line = \(i)\nprint(chat + turn + line)\n```"
                : i % 5 == 0 ? "- one point\n- another point, \(i)\n- a last one" : String(repeating: "Chat \(chat), turn \(turn), paragraph \(i), wrapping. ", count: 1 + i % 4)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    static func chat(_ n: Int) -> [any Step] {
        let script = CLIScript(turns: (1...turns).map { turn in [.startTurn, .stream(.answer, answer(n, turn: turn), chunk: 2000), .finishTurn(.completed)] })
        return [UseScript(script), StartChat()] + (1...turns).flatMap { turn -> [any Step] in [Send("chat \(n), turn \(turn)"), TurnFinished(turn)] }
    }

    override func steps() -> [any Step] {
        [OpenFolder()] + Self.chat(1) + [
            // Mid-way up: well away from both ends.
            Scroll(.answer(turn: Self.turns), to: .by(-6000)), WaitIdle(),
        ] + Self.chat(2) + Self.chat(3) + Self.chat(4) + [
            Press(.tab(2)), WaitIdle(), Press(.tab(3)), WaitIdle(), Press(.tab(4)), WaitIdle(),
            Linger(seconds: 3),
            Press(.tab(1)), WaitIdle(),
            ExpectRowsDrawn(),
            // And once the blank check has looked (two seconds after the last move).
            Linger(seconds: 3),
            ExpectRowsDrawn(),
        ]
    }
}

/// Nothing for a while.
private struct Linger: Step {
    let seconds: Double
    var label: String { "Wait \(Int(seconds)) s" }
    func run(_ story: StoryContext) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// The active transcript shows rows: one of its messages or answers in view, inside AppKit's
/// content.
private struct ExpectRowsDrawn: Step {
    var label: String { "Expect the transcript's rows drawn" }

    func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        var seen = "no scroll view"
        do {
            try await story.until("rows drawn", timeout: .seconds(4)) {
                guard let scroll = chat.storyTranscript.scrollView, scroll.window != nil, let document = scroll.documentView else { return false }
                let visible = document.convert(scroll.contentView.bounds, from: scroll.contentView)
                let shown = SwitchTab.rowIDs(chat).filter { SwitchTab.top(of: $0) != nil }.count
                let faded = scroll.isHiddenOrHasHiddenAncestor
                    || sequence(first: scroll.layer, next: { $0?.superlayer }).contains { $0.map { $0.isHidden || $0.opacity < 0.01 } ?? false }
                seen = "document \(Int(document.frame.height)), visible \(Int(visible.minY))–\(Int(visible.maxY)), \(shown) rows in view\(faded ? ", faded" : "")"
                return document.bounds.intersects(visible) && shown > 0 && !faded
            }
        } catch StoryFailure.timedOut {
            throw StoryFailure.expectation("rows drawn (found \(seen))")
        }
    }
}

/// Text deltas a second for the scripted CLI's replies from here on, in every chat.
struct Pace: Step {
    let rate: Double
    var label: String { "Stream at \(Int(rate)) deltas a second" }
    init(_ rate: Double) { self.rate = rate }
    func run(_ story: StoryContext) async throws {
        ScriptedWorld.shared.rate = rate
        for backend in ScriptedWorld.shared.backends { backend.rate = rate }
    }
}

/// Clicks the nth tab, then finds its chat as it was last left: the same rows, its draft in the
/// composer with the caret there, and the same row at the same place in the transcript.
struct SwitchTab: Step {
    let n: Int
    var label: String { "Switch to tab \(n), and find it as it was" }
    init(_ n: Int) { self.n = n }

    func run(_ story: StoryContext) async throws {
        let memory = story.stash(TabMemory.self) { TabMemory() }
        if let chat = story.app.chat { memory.left[chat.id] = TabMemory.Left(chat) }
        try await Press(.tab(n)).run(story)
        let chat = try await story.wait("tab \(n) to be the active one") {
            story.app.workspace.flatMap { $0.tabs.indices.contains(n - 1) && $0.activeTab === $0.tabs[n - 1] ? $0.activeTab.chat : nil }
        }
        try await WaitForFocus(.id(StoryID.Composer.field)).run(story)
        guard let left = memory.left[chat.id] else { return }
        do {
            try await story.until("tab \(n) as it was left") {
                chat.rows == left.rows && chat.draft == left.draft && Self.composerText(story) == left.draft
                    && left.place.map { place in Self.top(of: place.id).map { abs($0 - place.top) < 0.5 } ?? false } ?? true
            }
        } catch StoryFailure.timedOut {
            let top = left.place.flatMap { Self.top(of: $0.id) }
            throw StoryFailure.expectation(
                "tab \(n) as it was left: \(chat.rows.count) rows (was \(left.rows.count)), draft “\(chat.draft)” (was “\(left.draft)”), "
                    + "composer “\(Self.composerText(story) ?? "?")”, row top \(top.map { "\($0)" } ?? "gone") (was \(left.place.map { "\($0.top)" } ?? "none"))")
        }
    }

    /// What the composer's field shows.
    @MainActor static func composerText(_ story: StoryContext) -> String? {
        var view = StoryElement(StoryID.Composer.field)?.view
        while let current = view {
            if let text = current as? NSTextView { return text.string }
            if let field = current as? NSTextField { return field.stringValue }
            view = current.superview
        }
        return nil
    }

    /// Where a transcript row's top is in its window, while it's built and in view.
    @MainActor static func top(of id: StoryID) -> CGFloat? {
        guard let element = StoryElement(id), let frame = element.frame, let view = element.registeredView,
            !view.visibleRect.isEmpty
        else { return nil }
        return frame.maxY
    }

    /// The chat's message and answer rows, oldest first: the ones that can mark a place.
    @MainActor static func rowIDs(_ chat: Chat) -> [StoryID] {
        chat.storyTranscript.entries.compactMap { entry in
            switch entry.kind {
            case .user: StoryID.Transcript.user(entry.id)
            case .answer: StoryID.Transcript.answer(entry.id)
            default: nil
            }
        }
    }
}

/// What each chat looked like when its tab was left.
@MainActor
final class TabMemory {
    struct Left {
        let rows: [StoryRow]
        let draft: String
        /// A row in view and its top in the window.
        let place: (id: StoryID, top: CGFloat)?

        @MainActor init(_ chat: Chat) {
            rows = chat.rows
            draft = chat.draft
            place = SwitchTab.rowIDs(chat).lazy.compactMap { id in SwitchTab.top(of: id).map { (id, $0) } }.first
        }
    }

    var left: [UUID: Left] = [:]
}



/// Thirty tabs in a window a thousand points wide: they shrink to their first letters, the
/// active tab's name shows before them, and `»N` counts the tabs out of view. Its list holds
/// them, a running chat with its spinner and a file among them; picking one shows it and brings
/// it into view, as ⌘9 and a new tab do. Closed back down to four, the strip is as it was.
final class TabOverflow: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript { CLIScript(turns: [[.startTurn, .wait(.interrupt), .finishTurn(.interrupted)]]) }
    static let notes = "notes.md"

    override func steps() -> [any Step] {
        super.steps() + [
            Send("keep going"),
            Expect("the first chat's turn running") { try $0.activeChat().isRunning },
            WriteFiles([(Self.notes, "# Notes\n")]),
        ]
            + FileTabState.open(Self.notes) + [
                OpenTabs(28),
                Expect("thirty tabs") { $0.app.workspace?.tabs.count == 30 },
                StripCheck.shown("the new tab", at: 30),
                ExpectElement(.id(StoryID.Titlebar.tabName)),
                StripCheck.counted,

                // The list: the tabs out of view, the running chat's spinner in its row.
                Press(.id(StoryID.Titlebar.overflow)),
                ExpectElement(.id(StoryID.Titlebar.hiddenTabs), .visible),
                ExpectElement(.hiddenTab(1).action(.working)),
                Snapshot("hidden-tabs"),
                Do("Resize with the hidden-tab list open") { story in
                    story.window?.setContentSize(CGSize(width: 760, height: 600))
                },
                ExpectElement(.id(StoryID.Titlebar.hiddenTabs), .absent),
                Do("Restore the window size") { story in
                    story.window?.setContentSize(story.windowSize)
                },
                Press(.id(StoryID.Titlebar.overflow)),
                Press(.hiddenTab(1)),
                Expect("the first tab active") { $0.app.workspace.map { $0.activeTab === $0.tabs[0] } ?? false },
                ExpectElement(.id(StoryID.Titlebar.hiddenTabs), .absent),
                StripCheck.shown("the first tab", at: 1),
                StripCheck.counted,

                // ⌘9: the last, brought into view.
                Key(.cmd("9")),
                StripCheck.shown("the last tab", at: 30),

                // The file, from the list.
                Press(.id(StoryID.Titlebar.overflow)),
                Press(.hiddenTab(2)),
                Expect("the file's tab active") { $0.app.workspace?.storyActiveFile == Self.notes },
                StripCheck.shown("the file's tab", at: 2),

                // Esc closes the list. (Back on a chat: a storyline's window, never key, takes no
                // click in the title row while a file shows.)
                Key(.cmd("1")),
                Press(.id(StoryID.Titlebar.overflow)),
                ExpectElement(.id(StoryID.Titlebar.hiddenTabs), .visible),
                Key(.escape),
                ExpectElement(.id(StoryID.Titlebar.hiddenTabs), .absent),

                // A new tab, at the end, in view.
                Press(.id(StoryID.Titlebar.newtab)),
                StripCheck.shown("the new tab", at: 31),
            ]
            + Array(repeating: CloseLast() as any Step, count: 27) + [
                Expect("four tabs") { $0.app.workspace?.tabs.count == 4 },
                ExpectElement(.id(StoryID.Titlebar.overflow), .absent),
                ExpectElement(.id(StoryID.Titlebar.tabName), .absent),
                StripCheck.shown("the first tab", at: 1),
                StripCheck.shown("the last tab", at: 4),
            ]
    }
}

/// Eleven chat tabs with long names, the window narrowed from wide to small 20 points at a time:
/// every tab wholly in view shows at least the first few characters of its name, its title
/// taking the tab's room to its end (an inactive tab keeps nothing back for its hidden ×); the
/// active one's name shows before the strip once the tabs show first letters; and once even
/// those won't fit, the strip scrolls, `»N` counting the rest. Never a letter or two beside
/// empty room. Each width's numbers go to `tab-fit.txt`, three widths' windows to snapshots.
final class TabFit: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    /// The owner's tabs the day the strip cut them to two letters.
    static let titles = [
        "CM-main-review", "CM-MP sync", "CM-data checks", "Ncdex sync", "Evidence portal", "Orders plan",
        "MP_ACCESS fix", "Bugs-list", "Helm chart", "Asana import", "Bugs triage",
    ]
    /// The fewest characters of its name a tab in view shows: its mark and four.
    static let least = 4
    static let widths: [CGFloat] = Array(stride(from: 1800, through: 640, by: -20))
    static let shots: Set<CGFloat> = [1340, 1440, 1560]

    override func steps() -> [any Step] {
        super.steps() + [
            OpenTabs(Self.titles.count - 1),
            Do("Name the tabs") { story in
                guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
                for (tab, title) in zip(workspace.tabs, Self.titles) { tab.chat?.adoptName(title) }
            },
            Expect("eleven named tabs") { story in story.app.workspace?.tabs.map(\.title) == Self.titles },
            FitAcross(widths: Self.widths, least: Self.least, shots: Self.shots),
            Do("Restore the window size") { story in story.window?.setContentSize(story.windowSize) },
        ]
    }
}

/// Sets each window width in turn, waits for the title row to settle, and checks the tabs in view.
private struct FitAcross: Step {
    let widths: [CGFloat]
    let least: Int
    let shots: Set<CGFloat>
    var label: String { "Narrow the window from \(Int(widths.first ?? 0)) to \(Int(widths.last ?? 0)), reading every tab's title" }
    var timeout: Duration? { .seconds(120) }

    func run(_ story: StoryContext) async throws {
        guard let window = story.window else { throw StoryFailure.modelMissing("the window") }
        var lines: [String] = []
        var problems: [String] = []
        for width in widths {
            window.setContentSize(CGSize(width: width, height: story.windowSize.height))
            let fit = try await TabFitReading.settled(story, width: width)
            lines.append("\(Int(width)): " + fit.line)
            problems += fit.problems(least).map { "\(Int(width)): \($0)" }
            if shots.contains(width) { try await Snapshot("width-\(Int(width))").run(story) }
        }
        try lines.joined(separator: "\n").write(to: story.outputs.appendingPathComponent("tab-fit.txt"), atomically: true, encoding: .utf8)
        guard problems.isEmpty else {
            throw StoryFailure.expectation(
                "every tab in view showing \(least)+ characters of its name, nothing kept back (\(problems.count) problems): "
                    + problems.prefix(6).joined(separator: "; "))
        }
    }
}

/// The title row as drawn: the tabs wholly in the strip, the room each one's title got, the
/// active name before the strip, and `»N`.
@MainActor
struct TabFitReading: Equatable {
    struct Tab: Equatable {
        let title: String
        let active: Bool
        /// The tab with its ×, and its title's room.
        let frame: CGRect
        let room: CGRect?
    }

    var count = 0
    var strip = CGRect.zero
    var tabs: [Tab] = []
    var name: CGRect?
    var counted: Int?
    var controls = ""

    static func read(_ story: StoryContext) -> TabFitReading {
        var reading = TabFitReading()
        guard let workspace = story.app.workspace, let strip = StoryElement(StoryID.Tabs.strip)?.frame else { return reading }
        reading.count = workspace.tabs.count
        reading.strip = strip
        for (i, tab) in workspace.tabs.enumerated() {
            guard let id = workspace.storyTabID(at: i), let frames = StripCheck.frames(story, i + 1), StripCheck.inside(frames.tab, frames.strip)
            else { continue }
            reading.tabs.append(Tab(title: tab.title, active: tab === workspace.activeTab, frame: frames.tab, room: StoryElement(id.part(.title))?.frame))
        }
        reading.name = StoryElement(StoryID.Titlebar.tabName)?.frame
        reading.counted = StoryElement(StoryID.Titlebar.overflow) == nil ? nil : StripCheck.shownCount()
        let named: [(String, StoryID)] = [("+", StoryID.Titlebar.newtab), ("agents", StoryID.Titlebar.agents), ("history", StoryID.Titlebar.history)]
        reading.controls = named.compactMap { label, id in StoryElement(id)?.frame.map { "\(label) \(Int($0.minX))+\(Int($0.width))" } }.joined(separator: ", ")
        return reading
    }

    /// The reading once the same one has held for 100 ms (a resize lays out over a few passes).
    static func settled(_ story: StoryContext, width: CGFloat) async throws -> TabFitReading {
        final class Last {
            var reading: TabFitReading?
            var since = ContinuousClock.now
        }
        let last = Last()
        return try await story.wait("the title row to settle at \(Int(width))") {
            let now = read(story)
            if now != last.reading {
                last.reading = now
                last.since = .now
                return nil
            }
            return ContinuousClock.now - last.since >= .milliseconds(100) && !now.tabs.isEmpty ? now : nil
        }
    }

    /// While the tabs show their names, a cut name ends in an ellipsis; first letters are clipped.
    var named: Bool { name == nil }

    /// What's wrong: a tab showing fewer than `least` characters of its name (the active one's
    /// name before the strip, when there), an inactive tab's cut name stopping short of its end,
    /// or tabs out of view with no `»N` counting them.
    func problems(_ least: Int) -> [String] {
        var problems: [String] = []
        for tab in tabs {
            if tab.active, let name {
                let shown = Self.visible(tab.title, in: name.width - 6, ellipsis: true)
                if shown < min(least, tab.title.count) { problems.append("the active name before the strip shows \(shown) characters in \(Int(name.width))") }
                continue
            }
            guard let room = tab.room else {
                problems.append("“\(tab.title)” shows no name (tab \(Int(tab.frame.width)))")
                continue
            }
            let shown = Self.visible(tab.title, in: room.width, ellipsis: named)
            if shown < min(least, tab.title.count) {
                problems.append("“\(tab.title)” shows \(shown) characters in \(fmt(room.width)) of a \(fmt(tab.frame.width)) tab")
            }
            let kept = tab.frame.maxX - room.maxX
            if !tab.active, shown < tab.title.count, kept > 8.5 {
                problems.append("“\(tab.title)” keeps \(fmt(kept)) back after its cut name")
            }
        }
        let out = count - tabs.count
        if out > 0, counted != out { problems.append("\(out) tabs out of view, »\(counted.map(String.init) ?? "none")") }
        return problems
    }

    /// One width's numbers: the strip, the tabs' width and the title room an inactive one got,
    /// how many show, the fewest characters any shows, and the controls after the strip.
    var line: String {
        let inactive = tabs.first { !$0.active }
        let fewest = tabs.filter { !$0.active }.compactMap { tab in tab.room.map { (Self.visible(tab.title, in: $0.width, ellipsis: named), tab.title) } }.min { $0.0 < $1.0 }
        return "strip \(fmt(strip.width)), \(named ? "names" : "letters, name \(fmt(name?.width ?? 0))"), tab \(fmt(inactive?.frame.width ?? 0)), "
            + "room \(fmt(inactive?.room?.width ?? 0)), \(tabs.count)/\(count) in view\(counted.map { ", »\($0)" } ?? ""), "
            + "fewest \(fewest.map { "\($0.0) (\($0.1))" } ?? "-"); \(controls)"
    }

    private func fmt(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    /// How many whole characters of `title` show in `width` at the tabs' 13 pt: cut with an
    /// ellipsis after them, or clipped.
    static func visible(_ title: String, in width: CGFloat, ellipsis: Bool) -> Int {
        let font = NSFont.systemFont(ofSize: 13)
        func measure(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        if measure(title) <= width + 0.5 { return title.count }
        let dots = ellipsis ? measure("…") : 0
        var shown = 0
        for k in 1..<max(title.count, 1) where measure(String(title.prefix(k))) + dots <= width + 0.5 { shown = k }
        return shown
    }
}

/// ⌘W on the last tab, made the active one: it closes.
private struct CloseLast: Step {
    var label: String { "Close the last tab" }

    func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        let count = workspace.tabs.count
        workspace.storySelect(tabAt: count - 1)
        try await Key(.cmd("w")).run(story)
        try await story.until("\(count - 1) tabs") { workspace.tabs.count == count - 1 }
    }
}

/// The strip's tabs as the window draws them.
@MainActor
enum StripCheck {
    /// The tab's whole width inside the strip's.
    static func shown(_ what: String, at n: Int) -> Expect {
        Expect("\(what) wholly in the strip", found: { story in frames(story, n).map { "\($0.tab) in \($0.strip)" } ?? "no frame" }) { story in
            frames(story, n).map { inside($0.tab, $0.strip) } ?? false
        }
    }

    /// `»N` counts the tabs not wholly in the strip.
    static let counted = Expect(
        "»N to count the tabs out of view", found: { story in "»\(shownCount() ?? -1), \(outOfView(story)) out of view" }
    ) { story in shownCount() == outOfView(story) }

    /// The tab's frame (its button and its ×) and the strip's.
    static func frames(_ story: StoryContext, _ n: Int) -> (tab: CGRect, strip: CGRect)? {
        guard let id = story.app.workspace?.storyTabID(at: n - 1), let tab = StoryElement(id)?.frame,
            let strip = StoryElement(StoryID.Tabs.strip)?.frame
        else { return nil }
        return (StoryElement(id.part(.close))?.frame.map(tab.union) ?? tab, strip)
    }

    static func inside(_ tab: CGRect, _ strip: CGRect) -> Bool { strip.insetBy(dx: -0.5, dy: -0.5).contains(tab) }

    /// The number `»N` shows.
    static func shownCount() -> Int? {
        let prefix = "titlebar.overflow.count["
        return StoryRegistry.ids.lazy.compactMap { id in id.hasPrefix(prefix) ? Int(id.dropFirst(prefix.count).dropLast()) : nil }.first
    }

    /// The tabs not wholly in the strip (built ones out of it, and the ones the strip hasn't built).
    static func outOfView(_ story: StoryContext) -> Int {
        guard let count = story.app.workspace?.tabs.count else { return -1 }
        return count - (0..<count).count { frames(story, $0 + 1).map { inside($0.tab, $0.strip) } ?? false }
    }
}

/// A Kore started from a chat's shell (an install an agent ran: its pass in the environment) is
/// still the owner's: a folder window holding one chat, closed and opened again, comes back with
/// that chat, not an empty New tab.
final class WindowReopenOneChat: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    private var session: String?

    override func steps() -> [any Step] {
        [
            Do("Kore started from a chat's shell") { _ in
                Workspace.storyLaunch = ["KORE_AGENT_PASS": "story-pass", "KORE_AGENT_SOCKET": "/tmp/kore-story.sock"]
            }
        ] + super.steps() + [
            Send("Say OK"), TurnFinished(1),
            Do("Note the chat's session") { [self] story in session = try story.activeChat().listedId },
            // Its CLI lists it now, as a real one's store would (the scripted CLIs list only forks):
            // a reopened window keeps a restored chat its CLI lists.
            Do("its CLI lists the chat") { [self] story in
                guard let session else { throw StoryFailure.modelMissing("the chat's session") }
                ScriptedWorld.shared.list(session, provider: story.variant?.provider ?? "claude", folder: story.folder, title: "Say OK")
            },
            Expect("one tab, the chat") { [self] story in story.app.workspace?.tabs.count == 1 && session != nil },
            Do("Close the window") { story in story.window?.close() },
            Expect("the window closed") { story in story.app.workspace?.window?.isVisible != true },
            OpenFolder(),
            Expect("the one tab back with the chat, not a New tab", found: { story in
                story.app.workspace.map { $0.tabs.map(\.title).joined(separator: ", ") }
            }) { [self] story in
                guard let workspace = story.app.workspace, workspace.window?.isVisible == true else { return false }
                let tabs = workspace.tabs
                guard tabs.count == 1, let chat = tabs[0].chat else { return false }
                return chat.listedId == session && chat.providerID == (story.variant?.provider ?? "claude")
            },
        ]
    }
}
