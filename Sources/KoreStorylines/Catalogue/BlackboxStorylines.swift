import AppKit
import KoreCore
import KoreUI
import src

// Found by black-box runs (0.3.5–0.3.7), kept as regression storylines for what they found:
// /rename missing from the "/" menu, an empty /rename sent on as a message, the table's Copy over
// its header, the eighth tab past the window's edge, a working tab's close question unseen, and
// Full access taken mid-turn by the scripted Claude.

/// Appends a line to the storyline's notes.txt (an observation, never a failure).
struct StoryNote: Step {
    let what: String
    let value: @MainActor (StoryContext) -> String
    var label: String { "Note \(what)" }
    init(_ what: String, _ value: @escaping @MainActor (StoryContext) -> String) {
        self.what = what
        self.value = value
    }

    func run(_ story: StoryContext) async throws {
        try FileManager.default.createDirectory(at: story.outputs, withIntermediateDirectories: true)
        let file = story.outputs.appendingPathComponent("notes.txt")
        let line = "[\(story.variant?.name ?? "")] \(what): \(value(story))\n"
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try line.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor private func cliLog(_ s: StoryContext) -> String { (try? s.scriptedBackend().log.map { "\($0)" }.joined(separator: ", ")) ?? "no backend" }
@MainActor private func userRows(_ s: StoryContext) -> [String] { ((try? s.activeChat().rows) ?? []).filter { $0.kind == "user" }.map(\.text) }
@MainActor private func chatState(_ s: StoryContext) -> String {
    guard let c = s.app.chat else { return "no chat" }
    return "title=“\(c.title)” mode=\(c.mode) pill=\(c.storyModePill) running=\(c.isRunning) queued=\(c.queuedCount) "
        + "draft=“\(c.draft)” chip=\(c.command?.name ?? "-") users=\(userRows(s))"
}

/// How many messages went to the CLI.
@MainActor private func sends(_ s: StoryContext) throws -> Int {
    try s.scriptedBackend().log.filter { if case .send = $0 { true } else { false } }.count
}

private let heldCommand: Beat = .tool(name: "Bash", detail: "sleep 5", output: "ok", wait: .release)

// MARK: /rename in the "/" menu

/// "/" lists Kore's /rename whatever the CLI listed (the scripted CLI lists nothing), "/ren"
/// finds it first, and picking it puts it in the chip: the name typed after it renames the chat
/// and the CLI's session, and nothing goes to the model.
final class RenameSlashMenu: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    static let rename = Locator.id(StoryID.Composer.command(SlashCommand.rename.name))

    override func steps() -> [any Step] {
        super.steps() + [
            Send("hi"), TurnFinished(1), WaitIdle(),
            Expect("/rename offered", found: { ($0.app.chat?.storyCommands ?? []).joined(separator: ",") }) { s in
                s.app.chat?.storyCommands.contains(SlashCommand.rename.name) == true
            },
            WaitForFocus(.id(StoryID.Composer.field)), TypeText("/"), WaitIdle(),
            ExpectElement(Self.rename, .visible),
            Snapshot("slash-menu"),
            Key(.escape), Key(.cmd("a")), Key(KeyChord(.backspace)),
            TypeText("/ren"), WaitIdle(),
            ExpectElement(Self.rename, .visible),
            Expect("/rename the first row for “/ren”", found: { _ in
                StoryRegistry.ids.filter { $0.hasPrefix("composer.command[") && !$0.contains("].") }.joined(separator: ",")
            }) { _ in
                StoryRegistry.ids.filter { $0.hasPrefix("composer.command[") && !$0.contains("].") } == [StoryID.Composer.command("rename").raw]
            },
            Press(Self.rename),
            Expect("/rename in the chip, nothing typed", found: { chatState($0) }) { s in
                let c = try s.activeChat()
                return c.command?.name == SlashCommand.rename.name && c.draft.isEmpty
            },
            TypeText("Menu Name"), Key(.returnKey), WaitIdle(),
            Expect("renamed", timeout: .seconds(5), found: { chatState($0) }) { try $0.activeChat().title == "Menu Name" },
            Expect("the CLI told the name", found: { cliLog($0) }) { try $0.scriptedBackend().log.contains(.rename("Menu Name")) },
            Expect("nothing sent to the model", found: { chatState($0) }) { s in
                try sends(s) == 1 && userRows(s) == ["hi"]
            },
            Expect("composer empty", found: { chatState($0) }) { s in
                let c = try s.activeChat()
                return c.draft.isEmpty && c.command == nil
            },
        ]
    }
}

// MARK: An empty /rename

/// "/rename" with no name says how it's used and leaves the command ready for the name: typed
/// with the menu closed, "/rename " with the caret after it; picked from the menu, the chip. The
/// name typed next renames. "/rename/rename <name>" (a /rename typed again after the one left) is
/// the one command, never a message to the model.
final class RenameEmptyKeepsCommand: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let nothingSent = { (what: String) in
            Expect("\(what): nothing sent to the model", found: { s in "\(chatState(s)) log \(cliLog(s))" }) { s in
                try sends(s) == 1 && userRows(s) == ["hi"]
            }
        }
        return super.steps() + [
            Send("hi"), TurnFinished(1), WaitIdle(),
            WaitForFocus(.id(StoryID.Composer.field)),
            // Typed, the menu closed.
            TypeText("/rename"), WaitIdle(), Key(.escape), Key(.returnKey), WaitIdle(),
            Expect.rows("the usage line") { rows in rows.contains { $0.text == SlashCommand.renameUsage } },
            Expect("“/rename ” left, no chip", found: { chatState($0) }) { s in
                let c = try s.activeChat()
                return c.draft == "/rename " && c.command == nil
            },
            TypeText("Typed Name"), Key(.returnKey), WaitIdle(),
            Expect("renamed by the name typed after it", timeout: .seconds(5), found: { chatState($0) }) {
                try $0.activeChat().title == "Typed Name"
            },
            nothingSent("typed"),
            // Picked from the menu: the chip stays for the name.
            TypeText("/ren"), WaitIdle(), Key(.returnKey), WaitIdle(),
            Expect("the chip", found: { chatState($0) }) { try $0.activeChat().command?.name == SlashCommand.rename.name },
            Key(.returnKey), WaitIdle(),
            Expect("the chip kept, nothing typed", found: { chatState($0) }) { s in
                let c = try s.activeChat()
                return c.command?.name == SlashCommand.rename.name && c.draft.isEmpty
            },
            TypeText("Chip Name"), Key(.returnKey), WaitIdle(),
            Expect("renamed by the name after the chip", timeout: .seconds(5), found: { chatState($0) }) {
                try $0.activeChat().title == "Chip Name"
            },
            nothingSent("picked"),
            // Typed again after the one left.
            Do("“/rename/rename Twice” in the composer") { s in
                let c = try s.activeChat()
                c.command = nil
                c.draft = "/rename/rename Twice"
            },
            Key(.returnKey), WaitIdle(),
            Expect("renamed “Twice”", timeout: .seconds(5), found: { chatState($0) }) { try $0.activeChat().title == "Twice" },
            nothingSent("doubled"),
            StoryNote("log") { cliLog($0) },
            Snapshot("rename-empty"),
        ]
    }
}

// MARK: Table Copy by its corner

/// Copy shows by the table's top-right corner, outside it: beside it in the margin when there's
/// room, else just over its top edge. It never covers the table's text (a header-only table's
/// second cell was under it), and the table is no taller for it. It copies tabbed rows; a drag
/// across the table copies it as Markdown, as written. Links are their text in both.
class TableCopyCorner: ChatStoryline {
    override class var isFamily: Bool { self == TableCopyCorner.self }
    override class var tags: Set<Tag> { [.chat, .gate] }
    class var table: String { "" }
    /// The table as a drag across it copies it (as written, links as their text).
    class var written: String { table }
    /// The table as its Copy takes it.
    class var tabbed: String { "" }
    class var size: CGSize { CGSize(width: 1000, height: 760) }
    override class var needs: Needs { Needs(window: size) }
    override class var script: CLIScript { CLIScript(turns: [CLIScript.reply("Before table.\n\n" + table + "\n\nAfter table.")]) }

    @MainActor static func frames(_ s: StoryContext) -> String {
        let id = StoryID.Transcript.table([1])
        return "table \(String(describing: StoryRegistry.entry(id.raw)?.frame)) copy \(String(describing: StoryRegistry.entry(id.part(.copy).raw)?.frame)) "
            + "window \(String(describing: s.window?.contentView?.bounds))"
    }

    @MainActor final class Copies {
        var selection: String?
        var button: String?
        var height: CGFloat = 0
    }

    override func steps() -> [any Step] {
        let id = StoryID.Transcript.table([1])
        return super.steps() + [
            Send("Show the table"), TurnFinished(1), WaitIdle(),
            DragSelect(from: .answer(1, [0], at: "Before table.", " table."), to: .answer(1, [2], at: "After table.", " table.")),
            Do("⌘C the selection") { _ in StoryTranscript.clearCopied() },
            Key(KeyChord(.character("c"), .command)),
            Do("keep it") { s in s.stash(Copies.self) { Copies() }.selection = StoryTranscript.copied },
            Key(.escape),
            WaitForElement(.id(id)),
            Do("the table's height at rest") { s in s.stash(Copies.self) { Copies() }.height = StoryRegistry.entry(id.raw)?.frame?.height ?? 0 },
            Press(.id(id.part(.hover))),
            WaitForElement(.id(id.part(.copy))),
            Snapshot("table-hover"),
            StoryNote("frames") { Self.frames($0) },
            // Frames are the window's, y up: the table's top is its maxY.
            Expect("Copy outside the table at its top-right corner, in the window, the table no taller", found: { Self.frames($0) }) { s in
                guard let t = StoryRegistry.entry(id.raw)?.frame, let c = StoryRegistry.entry(id.part(.copy).raw)?.frame,
                    let content = s.window?.contentView?.bounds
                else { return false }
                let clear = t.intersection(c).width < 0.5 || t.intersection(c).height < 0.5
                let beside = c.minX >= t.maxX - 0.5 && c.minX <= t.maxX + 4 && abs(c.maxY - t.maxY) < 1
                let above = c.minY >= t.maxY - 0.5 && c.minY <= t.maxY + 4 && c.maxX <= t.maxX + 0.5
                let resting = s.stash(Copies.self) { Copies() }.height
                return clear && (beside || above) && content.contains(c) && abs(t.height - resting) < 0.5
            },
            Do("clear") { _ in StoryTranscript.clearCopied() },
            Click(.id(id.part(.copy))),
            Expect("the button copied something") { _ in StoryTranscript.copied != nil },
            Do("keep it") { s in s.stash(Copies.self) { Copies() }.button = StoryTranscript.copied },
            Expect("selection = “ table.⏎⏎” + the table as written + “⏎⏎After”, Copy its tabbed rows", found: { s in
                let c = s.stash(Copies.self) { Copies() }
                return "selection \(c.selection.debugDescription) button \(c.button.debugDescription)"
            }) { s in
                let c = s.stash(Copies.self) { Copies() }
                guard let sel = c.selection, let b = c.button else { return false }
                return sel == " table.\n\n" + Self.written + "\n\nAfter" && b == Self.tabbed
            },
        ]
    }
}

/// A header and no rows: the chip covered its second cell.
final class TableCopyHeaderOnly: TableCopyCorner {
    override class var table: String { "| Name | Qty |\n|---|--:|" }
    override class var tabbed: String { "Name\tQty" }
}

final class TableCopyNarrowWindow: TableCopyCorner {
    override class var table: String { "| Only |\n|---|\n| a |\n| b |" }
    override class var tabbed: String { "Only\na\nb" }
    override class var size: CGSize { CGSize(width: 520, height: 700) }
}

/// Wider than the column: it scrolls sideways, filling the column.
final class TableCopyWide: TableCopyCorner {
    override class var table: String {
        let cols = (1...12).map { "Column number \($0)" }
        let head = "| " + cols.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: "---|", count: 12)
        let rows = (1...3).map { r in "| " + (1...12).map { "row \(r) cell \($0) with some longer text" }.joined(separator: " | ") + " |" }
        return ([head, rule] + rows).joined(separator: "\n")
    }
    override class var tabbed: String {
        let head = (1...12).map { "Column number \($0)" }.joined(separator: "\t")
        let rows = (1...3).map { r in (1...12).map { "row \(r) cell \($0) with some longer text" }.joined(separator: "\t") }
        return ([head] + rows).joined(separator: "\n")
    }
}

final class TableCopyFancy: TableCopyCorner {
    override class var table: String {
        "| Key | Value |\n|:--|:-:|\n| `code` | **bold** and *it* |\n| a \\| b | 名前 🚀 |\n|  | empty left |\n| [docs](https://example.com/docs) | link |"
    }
    override class var written: String {
        "| Key | Value |\n|:--|:-:|\n| `code` | **bold** and *it* |\n| a \\| b | 名前 🚀 |\n|  | empty left |\n| docs | link |"
    }
    override class var tabbed: String { "Key\tValue\ncode\tbold and it\na | b\t名前 🚀\n\tempty left\ndocs\tlink" }
}

// MARK: Eight tabs in view

/// Eight chats in a 1000-point window: the strip shows the tabs that fit whole, `»N` counting the
/// rest, and the strip, `»N`, `+` and History are inside the window. A tab out of view (the eighth
/// sits past the strip's end, its frame past the window's edge, clipped) is still a click away:
/// scrolled to, as a person scrolls the strip, it's wholly in view and switches; the black-box
/// run's "8th tab past the window" was the harness clicking it unscrolled.
final class TabFitEight: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var needs: Needs { Needs(window: CGSize(width: 1000, height: 760)) }

    @MainActor static func row(_ s: StoryContext) -> String {
        let ids = (s.app.workspace?.tabs.indices.compactMap { s.app.workspace?.storyTabID(at: $0) } ?? [])
            + [StoryID.Tabs.strip, StoryID.Titlebar.overflow, StoryID.Titlebar.newtab, StoryID.Titlebar.history]
        return ids.map { id in StoryRegistry.entry(id.raw)?.frame.map { "\(Int($0.minX))+\(Int($0.width))" } ?? "-" }.joined(separator: " ")
            + " »\(StripCheck.shownCount() ?? -1)"
    }

    static let inWindow = Expect("the strip, »N, + and History inside the window", found: { row($0) }) { s in
        guard let b = s.window?.contentView?.bounds.insetBy(dx: -0.5, dy: -0.5) else { return false }
        return [StoryID.Tabs.strip, StoryID.Titlebar.overflow, StoryID.Titlebar.newtab, StoryID.Titlebar.history].allSatisfy { id in
            StoryRegistry.entry(id.raw)?.frame.map(b.contains) ?? false
        }
    }

    override func steps() -> [any Step] {
        var steps = super.steps() + [
            OpenTabs(7),
            Expect("eight tabs") { $0.app.workspace?.tabs.count == 8 },
            WaitIdle(),
            StoryNote("title row") { Self.row($0) },
            Self.inWindow,
            StripCheck.counted,
        ]
        for n in [1, 8, 4, 8] {
            steps += [SwitchTab(n), StripCheck.shown("tab \(n)", at: n), Self.inWindow, StripCheck.counted]
        }
        return steps + [StoryNote("title row at the end") { Self.row($0) }, Snapshot("eight-tabs")]
    }
}

/// Eight chats streaming, tabs switched a frame apart: every chat ends with its own whole answer,
/// and each tab, the eighth too, is in the window to switch to.
final class TabRapidSwitch: Storyline {
    override class var tags: Set<Tag> { [.chat] }
    override class var variants: [Variant] { [.claude, .codex] }
    static func answer(_ n: Int) -> String {
        (1...40).map { "Chat \(n) line \($0): some streamed words to lay out, `code` and **bold**." }.joined(separator: "\n\n")
    }

    struct RapidSwitch: Step {
        let count: Int
        var label: String { "Switch tabs \(count) times, a frame apart" }
        var timeout: Duration? { .seconds(60) }
        func run(_ story: StoryContext) async throws {
            guard let w = story.app.workspace else { throw StoryFailure.modelMissing("workspace") }
            for i in 0..<count {
                w.perform(i % 3 == 2 ? .previousTab : .nextTab)
                try await Task.sleep(for: .milliseconds(i % 2 == 0 ? 0 : 16))
            }
        }
    }

    override func steps() -> [any Step] {
        var steps: [any Step] = [OpenFolder()]
        for n in 1...8 {
            let script = CLIScript(turns: [[.startTurn, .stream(.answer, Self.answer(n), chunk: 12), .finishTurn(.completed)]])
            steps += [UseScript(script), StartChat(), Do("send in chat \(n)") { s in try s.activeChat().storySend("go \(n)") }]
        }
        steps += [
            RapidSwitch(count: 80),
            Expect("every chat finished", timeout: .seconds(60), found: { s in
                (s.app.workspace?.tabs ?? []).map { "\($0.chat?.isRunning ?? false)" }.joined(separator: ",")
            }) { s in
                guard let tabs = s.app.workspace?.tabs, tabs.count == 8 else { return false }
                return tabs.allSatisfy { $0.chat?.isRunning == false }
            },
            RapidSwitch(count: 40),
            WaitIdle(),
            Expect("each chat's whole answer, in its own tab", found: { s in
                (s.app.workspace?.tabs ?? []).enumerated().map { i, t in
                    "\(i + 1): \((t.chat?.rows.last { $0.kind == "assistant" }?.text.count) ?? -1)"
                }.joined(separator: " ")
            }) { s in
                guard let tabs = s.app.workspace?.tabs, tabs.count == 8 else { return false }
                return tabs.enumerated().allSatisfy { i, t in
                    t.chat?.rows.filter { $0.kind == "assistant" }.map(\.text).joined(separator: "\n\n") == Self.answer(i + 1)
                }
            },
        ]
        for n in [1, 5, 8] { steps += [SwitchTab(n), Snapshot("rapid-tab-\(n)")] }
        return steps
    }
}

// MARK: Closing a working tab with messages queued

/// ⌘W on a chat whose turn runs with two messages queued asks first, in the tab, and the strip
/// shows the question where the tab is (it showed nothing there). Cancel keeps it all; Stop closes
/// the tab, and the strip and the model agree: one tab, the chat reopenable.
final class TabCloseQueued: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, heldCommand, .finishTurn(.completed)], CLIScript.reply("r")])
    }

    /// The working chat's tab, found by its chat.
    @MainActor static func tab(_ s: StoryContext) -> StoryID? {
        guard let w = s.app.workspace, let i = w.tabs.firstIndex(where: { $0.chat?.title == "Run the command" }) else { return nil }
        return w.storyTabID(at: i)
    }

    struct AskShown: Step {
        var label: String { "Expect the close question in the strip, where the tab is" }
        func run(_ story: StoryContext) async throws {
            guard let id = TabCloseQueued.tab(story) else { throw StoryFailure.modelMissing("the working tab") }
            _ = try await story.wait("Stop and Cancel in the tab, in the strip") { () -> Bool? in
                guard let strip = StoryRegistry.entry(StoryID.Tabs.strip.raw)?.frame,
                    let stop = StoryRegistry.entry(id.part(.allow).raw)?.frame,
                    let cancel = StoryRegistry.entry(id.part(.cancel).raw)?.frame,
                    stop.width > 0, cancel.width > 0
                else { return nil }
                return strip.insetBy(dx: -0.5, dy: -0.5).contains(stop) && strip.insetBy(dx: -0.5, dy: -0.5).contains(cancel) ? true : nil
            }
        }
    }

    /// Presses the working tab's Stop (`.allow`) or Cancel.
    struct PressInTab: Step {
        let part: StoryID.Part
        var label: String { "Press the working tab's \(part == .allow ? "Stop" : "Cancel")" }
        func run(_ story: StoryContext) async throws {
            guard let id = TabCloseQueued.tab(story) else { throw StoryFailure.modelMissing("the working tab") }
            try await Press(.id(id.part(part))).run(story)
        }
    }

    override func steps() -> [any Step] {
        // The tab shows its close question (its Stop is registered).
        let asking = { (id: UUID) in StoryRegistry.entry(StoryID.Tabs.tab(id).part(.allow).raw) != nil }
        let tabs = { (s: StoryContext) -> String in
            guard let w = s.app.workspace else { return "-" }
            return w.tabs.map { t in "\(t.chat?.title ?? "new")\(t === w.activeTab ? "*" : "")\(asking(t.id) ? "?" : "")" }.joined(separator: ",")
                + " canReopen=\(w.can(.reopenClosedTab))"
        }
        return super.steps() + [
            Send("Run the command"),
            WaitForEvent("turn start") { if case .turnStarted = $0 { true } else { false } },
            Queue("queued A"), Queue("queued B"),
            Command(.newTab), Command(.previousTab),
            Expect("on the chat again") { $0.app.chat?.title == "Run the command" },
            Command(.closeTab),
            WaitIdle(),
            StoryNote("asked") { tabs($0) },
            Expect("two tabs, the working one asking, its turn and queue kept", found: { "\(tabs($0)) \(chatState($0))" }) { s in
                guard let w = s.app.workspace, w.tabs.count == 2, let c = s.app.chat else { return false }
                return asking(w.activeTab.id) && c.isRunning && c.queuedCount == 2
            },
            AskShown(),
            Snapshot("close-asks"),
            PressInTab(part: .cancel),
            Expect("asking no more, all kept", found: { "\(tabs($0)) \(chatState($0))" }) { s in
                guard let w = s.app.workspace, w.tabs.count == 2, let c = s.app.chat else { return false }
                return !asking(w.activeTab.id) && c.isRunning && c.queuedCount == 2
            },
            Command(.closeTab),
            AskShown(),
            PressInTab(part: .allow),
            WaitIdle(),
            StoryNote("stopped") { tabs($0) },
            Expect("one tab, in the model and the strip; the chat reopenable", found: { s in
                "\(tabs(s)) strip ids \(StoryRegistry.ids.filter { $0.hasPrefix("tabs.tab[") && !$0.contains("].") })"
            }) { s in
                guard let w = s.app.workspace, w.tabs.count == 1, w.tabs[0].chat == nil || w.tabs[0].chat?.title != "Run the command" else { return false }
                let shown = StoryRegistry.ids.filter { $0.hasPrefix("tabs.tab[") && !$0.contains("].") }
                return shown == [StoryID.Tabs.tab(w.tabs[0].id).raw] && w.can(.reopenClosedTab)
            },
            Snapshot("closed"),
        ]
    }
}

// MARK: Full access mid-turn

/// Full access picked while a turn runs. Claude starts again for it (`ClaudeBackend.setMode`),
/// so it's refused mid-turn, saying why, the turn going on in the mode it was in; picked after the
/// turn, the CLI starts again in it. Codex takes it in place. Lowered later, the next turn runs
/// at the lowered mode; the pill says the mode the chat is in throughout.
final class FullAccessMidTurn: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }
    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, heldCommand, .finishTurn(.completed)], CLIScript.reply("second"), CLIScript.reply("third")])
    }

    @MainActor static func modes(_ s: StoryContext) throws -> [String] {
        try s.scriptedBackend().log.compactMap { call -> String? in if case .setMode(let m) = call { m } else { nil } }
    }

    @MainActor static func relaunches(_ s: StoryContext) throws -> Int {
        try s.scriptedBackend().log.filter { $0 == .relaunch }.count
    }

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let full = codex ? CodexModes.fullAccess : ClaudeModes.fullAccess
        let first = codex ? "askForApproval" : "default"
        let pill = Locator.id(StoryID.Composer.mode)
        let popup = Locator.id(StoryID.Composer.modes)
        let row = { (id: String) in Locator.id(StoryID.Composer.modeRow(id)) }
        let honest = { (what: String) in
            Expect("\(what): the pill says the mode the chat is in", found: { chatState($0) }) { s in
                let c = try s.activeChat()
                return (c.storyModePill == "Full access") == (c.mode == full)
            }
        }
        var steps: [any Step] = super.steps() + [
            Send("Run the command"),
            WaitForEvent("turn start") { if case .turnStarted = $0 { true } else { false } },
            Press(pill), WaitForElement(popup), Press(row(full)), WaitIdle(),
            StoryNote("mid-turn") { "\(chatState($0)) log \(cliLog($0))" },
            Snapshot("full-midturn"),
            honest("mid-turn"),
            Expect("the turn still running") { try $0.activeChat().isRunning },
        ]
        if codex {
            steps += [Expect("Codex in Full access at once", timeout: .seconds(5), found: { chatState($0) }) { try $0.activeChat().mode == full }]
        } else {
            steps += [
                Expect.rows("Claude refuses, saying why") { rows in rows.contains { $0.text.contains(ClaudeBackend.fullAccessBusy) } },
                Expect("still in the mode it was in, the CLI not started again", found: { s in "\(chatState(s)) log \(cliLog(s))" }) { s in
                    try s.activeChat().mode == first && Self.relaunches(s) == 0
                },
            ]
        }
        steps += [
            Release(), TurnFinished(1), WaitIdle(),
            honest("after the turn"),
            Press(pill), WaitForElement(popup), Press(row(full)), WaitIdle(),
            Expect("Full access after the turn", timeout: .seconds(10), found: { chatState($0) }) { try $0.activeChat().mode == full },
            honest("Full access picked between turns"),
        ]
        if !codex {
            steps += [
                Expect("Claude started again for it", found: { cliLog($0) }) { s in
                    let log = try s.scriptedBackend().log
                    return try Self.relaunches(s) == 1 && log.contains(.restarted)
                },
            ]
        }
        return steps + [
            Send("in full access"), TurnFinished(2),
            Expect("still Full access after a turn in it", found: { chatState($0) }) { try $0.activeChat().mode == full },
            Press(pill), WaitForElement(popup), Press(row(first)), WaitIdle(),
            Expect("lowered", timeout: .seconds(10), found: { chatState($0) }) { try $0.activeChat().mode == first },
            honest("lowered"),
            Send("lowered now"), TurnFinished(3),
            Expect("the CLI's last mode the lowered one", found: { cliLog($0) }) { s in try Self.modes(s).last == first },
            honest("after a turn at the lowered mode"),
            StoryNote("log") { cliLog($0) },
            Snapshot("full-lowered"),
        ]
    }
}
