import AppKit
import Foundation
import HostClient
import KoreUI
import LinkProtocol
import src

// The UI at scale, its second round (scripts/ui-scale.sh): the areas the first round left out —
// the terminal, the agent map, History and both pickers at 30 tabs; a group's whole popup and
// Arsenal's tab groups; Kore's own questions and tips; Devices' one +; a command's whole output in
// the terminal; a box's History. An area whose feature a build doesn't have yet (one not on its
// base) is pending: logged, skipped, and listed apart from ✔ and ✘.

extension Tag {
    /// Every control driven once, its effect checked (the coverage audit's undriven rows):
    /// `--tag drive`, at one size.
    package static let drive: Tag = "drive"
}

// MARK: - Pending

/// The storylines in this build, by name: an area that walks one a build may not have finds it
/// here as the run starts.
@MainActor enum ScaleNamed {
    private static let all: [String: Storyline.Type] = Dictionary(
        Runner.discover().map { ($0.storyName, $0) }, uniquingKeysWith: { first, _ in first })
    static func type(_ name: String) -> Storyline.Type? { all[name] }
}

/// The area's feature isn't in this build: a "pending" line in the log, and the rest skipped.
struct ScalePending: Step {
    let element: String
    let load: String
    let what: String
    var label: String { "Pending: \(what)" }
    func run(_ story: StoryContext) async throws {
        ScaleLog.write(story, ["kind": "pending", "element": element, "load": load, "label": what])
        throw StorySkip("pending, \(what)")
    }
}

/// Pending unless `has` holds now, the area's feature known by what it put on screen or in the
/// model: a check for a feature this build doesn't have is skipped, not failed.
struct ScaleNeeds: Step {
    let element: String
    let load: String
    let what: String
    let has: @MainActor (StoryContext) -> Bool
    var label: String { "Has \(what)" }
    func run(_ story: StoryContext) async throws {
        guard has(story) else { return try await ScalePending(element: element, load: load, what: what + " (not in this build)").run(story) }
    }
}

// MARK: - Light: areas the first round left out

/// Kore's question for a chat tab's Rename….
final class ScaleAskRename: ScaleArea {
    override class var wrapsName: String? { "AskRenameChat" }
    override class var element: String { "ask rename" }
    override class var variants: [Variant] { [.claude] }
}

/// Kore's question for Move to Trash.
final class ScaleAskTrash: ScaleArea {
    override class var wrapsName: String? { "AskTrashFile" }
    override class var element: String { "ask trash" }
    override class var variants: [Variant] { [.codex] }
}

/// Kore's Save, Don't Save or Cancel for a file tab with edits.
final class ScaleAskUnsaved: ScaleArea {
    override class var wrapsName: String? { "AskUnsavedTab" }
    override class var element: String { "ask unsaved" }
    override class var variants: [Variant] { [.claude] }
}

/// A drop of several, and Replace, Keep Both or Cancel.
final class ScaleAskMove: ScaleArea {
    override class var wrapsName: String? { "AskMoveAndCollision" }
    override class var element: String { "ask move" }
    override class var variants: [Variant] { [.codex] }
    override var edges: [StoryID] { [StoryID.Titlebar.newtab, StoryID.Titlebar.history] }
}

/// Quitting with work running.
final class ScaleAskQuit: ScaleArea {
    override class var wrapsName: String? { "AskQuitWhileWorking" }
    override class var element: String { "ask quit" }
    override class var variants: [Variant] { [.claude] }
}

/// Closing a terminal running a command; Tab moves the ring.
final class ScaleAskTerminal: ScaleArea {
    override class var wrapsName: String? { "AskTerminalClose" }
    override class var element: String { "ask terminal" }
    override class var variants: [Variant] { [.codex] }
}

/// Kore's hover tip: one at a time, gone at a key.
final class ScaleTip: ScaleArea {
    override class var wrapsName: String? { "KoreTipShows" }
    override class var element: String { "tip" }
    override class var variants: [Variant] { [.claude] }
}

/// History's current row raised, the pointer's tinted beside it.
final class ScaleHistoryRow: ScaleArea {
    override class var wrapsName: String? { "HistoryCurrentRow" }
    override class var element: String { "history row" }
    override class var variants: [Variant] { [.claude] }
}

/// The chat's own tab, clicked over the agent map, gives the chat back.
final class ScaleAgentsTabBack: ScaleArea {
    override class var wrapsName: String? { "AgentMapTabClickBack" }
    override class var element: String { "agents tab back" }
    override class var variants: [Variant] { [.codex] }
}

/// A group's chip folds and opens it; ⌃⇥ passes its tabs.
final class ScaleGroupFold: ScaleArea {
    override class var wraps: Storyline.Type? { TabGroupFold.self }
    override class var element: String { "group fold" }
    override class var variants: [Variant] { [.claude] }
}

/// A grouped tab dragged out leaves the group whole.
final class ScaleGroupDragOut: ScaleArea {
    override class var wraps: Storyline.Type? { TabGroupDragOut.self }
    override class var element: String { "group drag out" }
    override class var variants: [Variant] { [.codex] }
}

/// Close group, with a chat in it working: asked once.
final class ScaleGroupClose: ScaleArea {
    override class var wraps: Storyline.Type? { TabGroupClose.self }
    override class var element: String { "group close" }
    override class var variants: [Variant] { [.claude] }
}

/// A file and a new chat land after the group, which stays whole.
final class ScaleGroupWhole: ScaleArea {
    override class var wrapsName: String? { "GroupStaysWhole" }
    override class var element: String { "group whole" }
    override class var variants: [Variant] { [.codex] }
}

/// Arsenal's tab groups: opened silently into one group, listed in the window's view, one shown,
/// ungrouped.
final class ScaleArsenalGroups: ScaleArea {
    override class var wrapsName: String? { "ArsenalTabGroups" }
    override class var element: String { "arsenal groups" }
    override class var variants: [Variant] { [.claude] }
}

// MARK: - 30 tabs: the same walks with 29 more tabs

final class ScaleTerminal30: ScaleArea {
    override class var wraps: Storyline.Type? { WindowTerminal.self }
    override class var element: String { "terminal" }
    override class var load: String { ScaleLoad.tabs30 }
    override class var variants: [Variant] { [.claude] }
}

final class ScaleAgents30: ScaleArea {
    override class var wraps: Storyline.Type? { AgentMapOpen.self }
    override class var element: String { "agents" }
    override class var load: String { ScaleLoad.tabs30 }
    override class var variants: [Variant] { [.codex] }
}

final class ScaleHistory30: ScaleArea {
    override class var wraps: Storyline.Type? { HistorySearchesWords.self }
    override class var element: String { "history" }
    override class var load: String { ScaleLoad.tabs30 }
    override class var variants: [Variant] { [.claude] }
}

final class ScaleModel30: ScaleArea {
    override class var wraps: Storyline.Type? { ModelPicker.self }
    override class var element: String { "model picker" }
    override class var load: String { ScaleLoad.tabs30 }
}

final class ScaleMode30: ScaleArea {
    override class var wraps: Storyline.Type? { ModePicker.self }
    override class var element: String { "mode picker" }
    override class var load: String { ScaleLoad.tabs30 }
}

final class ScaleArsenal30: ScaleArea {
    override class var wraps: Storyline.Type? { ArsenalLogoTint.self }
    override class var element: String { "arsenal" }
    override class var load: String { ScaleLoad.tabs30 }
    override class var variants: [Variant] { [.claude] }
}

/// 30 tabs, three grouped: the chip's popup at its chip, named, recoloured, a new tab in the
/// group, then ungrouped with the tabs left where they were.
final class ScaleGroupPopup30: Storyline {
    override class var tags: Set<Tag> { [.scale] }
    override class var variants: [Variant] { [.codex] }
    static let element = "group popup"

    override func steps() -> [any Step] {
        let load = ScaleLoad.tabs30
        let members = { (story: StoryContext) in (try? TabGroupProbe.members(story)) ?? [] }
        let chip: @MainActor @Sendable (StoryContext) -> StoryID? = { story in (try? TabGroupProbe.group(story)).map { StoryID.TabGroups.chip($0.id) } }
        let work: [any Step] = [
            RightClickChip(),
            WaitForElement(.id(StoryID.TabGroups.popup)),
            ScaleAnchoredInside(what: "the group's popup", popup: StoryID.TabGroups.popup, anchor: chip),
            Click(.id(StoryID.TabGroups.name)),
            Key(.cmd("a")),
            TypeText("Scale"),
            Expect("named Scale", found: { (try? TabGroupProbe.group($0).name) ?? "-" }) { try TabGroupProbe.group($0).name == "Scale" },
            Press(.id(StoryID.TabGroups.swatch(TabGroupColor.teal.rawValue))),
            Expect("teal", found: { (try? TabGroupProbe.group($0).color.rawValue) ?? "-" }) { try TabGroupProbe.group($0).color == .teal },
            Press(.id(StoryID.TabGroups.newTab)),
            ExpectElement(.id(StoryID.TabGroups.popup), .absent),
            Expect("a new tab in the group, 31 tabs", found: { story in "\(members(story)) of \(story.app.workspace?.tabs.count ?? -1)" }) { story in
                members(story) == [0, 1, 2, 3] && story.app.workspace?.tabs.count == 31 && story.app.workspace?.activeTab === story.app.workspace?.tabs[3]
            },
            RightClickChip(),
            WaitForElement(.id(StoryID.TabGroups.popup)),
            Press(.id(StoryID.TabGroups.ungroup)),
            Expect("no group, 31 tabs left as they were", found: { "\($0.app.workspace?.tabGroups.groups.count ?? -1) groups" }) { story in
                story.app.workspace?.tabGroups.isEmpty == true && story.app.workspace?.tabs.count == 31
            },
        ]
        return [
            ScaleBegin(element: Self.element, load: load),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])), OpenFolder(), StartChat(), OpenTabs(29),
            TabGroupProbe.make(1, onto: 0), TabGroupProbe.make(2, onto: 1),
            Expect("tabs 1–3 grouped") { try TabGroupProbe.members($0) == [0, 1, 2] },
        ] + Timed.wrap(work, Self.element, load) + scaleLook(Self.element, load)
    }
}

/// `AnchoredInside` for an anchor known only once the run has it (a group's chip).
struct ScaleAnchoredInside: Step {
    let what: String
    let popup: StoryID
    let anchor: @MainActor (StoryContext) -> StoryID?
    var label: String { "\(what): whole in the window, at its anchor" }
    func run(_ story: StoryContext) async throws {
        guard let id = anchor(story) else { throw StoryFailure.modelMissing("\(what)'s anchor") }
        try await AnchoredInside(what: what, popup: popup, anchor: id).run(story)
    }
}

// MARK: - Devices' one +

/// Devices' header +: one Kore popup at it, "Add a box" and "Add a phone"; Esc closes it. On a
/// build with the two add buttons (net.addbox) it's pending.
final class ScaleDevicesPlus: Storyline {
    override class var tags: Set<Tag> { [.scale] }
    override class var variants: [Variant] { [.claude] }
    static let element = "devices plus"

    override func steps() -> [any Step] {
        let load = ScaleLoad.light
        let work: [any Step] = [
            Press(.id(StoryID.Net.icon)),
            WaitForElement(.id(StoryID.Net.panel)),
            ScaleNeeds(element: Self.element, load: load, what: "Devices' one + (net.add, no net.addbox)") { _ in
                StoryElement(StoryID.Net.add)?.frame != nil && StoryRegistry.entry("titlebar.net.addbox")?.frame == nil
            },
            Press(.id(StoryID.Net.add)),
            WaitForElement(.id(StoryID.Options.panel)),
            AnchoredInside(what: "the + popup", popup: StoryID.Options.panel, anchor: StoryID.Net.add),
            Expect("Add a box, Add a phone", found: { _ in StoryID.Options.rows.map(\.title).joined(separator: ", ") }) { _ in
                StoryID.Options.rows.map(\.title) == ["Add a box", "Add a phone"]
            },
            Key(.escape),
            ExpectElement(.id(StoryID.Options.panel), .absent),
            Press(.id(StoryID.Net.icon)),
            ExpectElement(.id(StoryID.Net.panel), .absent),
        ]
        return [
            ScaleBegin(element: Self.element, load: load),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])), OpenFolder(), StartChat(), DevicesSetUp(),
        ] + Timed.wrap(work, Self.element, load) + scaleLook(Self.element, load)
    }
}

// MARK: - A command's whole output

/// A running command opened in the terminal mid-run shows all 1,500 lines so far, not its last
/// 500, and the lines written after; a command with no output yet says it may print only when it
/// ends (read off the model: the window's OCR misses that faint line). Claude's output is a file, Codex's a stream. Pending on a build whose terminal shows a
/// command's tail only (no `OutputFollower`).
final class ScaleCommandOutput: Storyline {
    override class var tags: Set<Tag> { [.scale] }
    override class var variants: [Variant] { [.claude, .codex] }
    static let element = "command output"
    static let big = "scale-big", quiet = "scale-quiet"

    static func lines(_ range: Range<Int>) -> String { range.map { "line \($0)\n" }.joined() }

    /// The terminal's lines, trimmed.
    static func shown(_ story: StoryContext) -> Set<String> {
        let text = story.app.workspace?.storyTerminal.text ?? ""
        return Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// The window's terminal entries follow their command's output (bg output, 0.3.10).
    static func follows(_ story: StoryContext) -> Bool {
        guard let workspace = story.app.workspace,
            let panel = ScaleMirror.child(workspace, "terminals"), let entries = ScaleMirror.child(panel, "entries")
        else { return false }
        return Mirror(reflecting: entries).children.contains { ScaleMirror.child($0.value, "follower") != nil }
    }

    /// The terminal in front is a live command with no output yet: what its footer's "No output
    /// yet — this command may print only when it ends" shows for (`TerminalEntry.waiting`).
    static func waiting(_ story: StoryContext) -> Bool? {
        guard let workspace = story.app.workspace, let panel = ScaleMirror.child(workspace, "terminals"),
            let id = workspace.storyTerminal.id, let entries = ScaleMirror.child(panel, "entries")
        else { return nil }
        for entry in Mirror(reflecting: entries).children.map(\.value) where ScaleMirror.child(entry, "id") as? UUID == id {
            return ScaleMirror.child(entry, "waiting") as? Bool
        }
        return nil
    }

    override func steps() -> [any Step] {
        let load = ScaleLoad.light
        let file = variant == .claude
        let output = { (story: StoryContext, name: String) in story.folder.appendingPathComponent(".kore-scale-\(name).output") }
        let start = { (story: StoryContext, id: String, title: String, text: String) throws in
            guard let chat = story.app.chat else { throw StoryFailure.modelMissing("the chat") }
            let path = output(story, id)
            if file { try Data(text.utf8).write(to: path) }
            chat.commands.apply(.commandStarted(ActiveCommand(id: id, kind: .shell, title: title, command: title, startedAt: .now,
                                                             owner: .main, output: file ? .file(path.path) : .stream)))
            if !file, !text.isEmpty { chat.commands.apply(.commandOutput(id: id, text)) }
        }
        let open = { (id: String) -> [any Step] in
            [
                Press(.id(StoryID.Titlebar.commands)),
                Press(.id(StoryID.AgentMap.command(id).part(.open))),
                ExpectElement(.id(StoryID.Terminal.panel), .visible),
                Do("Make the offscreen test terminal readable") { $0.app.workspace?.storyTerminalVisible() },
            ]
        }
        var work: [any Step] = open(Self.big)
        work += [
            ScaleNeeds(element: Self.element, load: load, what: "a command's whole output (OutputFollower)", has: Self.follows),
            Expect("all 1,500 lines so far, the first one too", timeout: .seconds(5), found: { story in
                let shown = Self.shown(story)
                return "line 0 \(shown.contains("line 0") ? "shown" : "missing"), line 1499 \(shown.contains("line 1499") ? "shown" : "missing")"
            }) { story in
                let shown = Self.shown(story)
                return shown.contains("line 0") && shown.contains("line 1499")
            },
            Do("500 more lines written") { story in
                let more = Self.lines(1500..<2000)
                if file {
                    let handle = try FileHandle(forWritingTo: output(story, Self.big))
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(more.utf8))
                    try handle.close()
                } else {
                    story.app.chat?.commands.apply(.commandOutput(id: Self.big, more))
                }
            },
            Expect("the new lines under the old, line 0 still there", timeout: .seconds(5), found: { story in
                Self.shown(story).contains("line 1999") ? "line 1999 shown" : "line 1999 missing"
            }) { story in
                let shown = Self.shown(story)
                return shown.contains("line 0") && shown.contains("line 1999")
            },
        ]
        work += open(Self.quiet)
        work += [
            Expect("the quiet one says it may print only when it ends (its footer)", timeout: .seconds(5),
                   found: { "waiting: \(Self.waiting($0).map(String.init) ?? "-")" }) { Self.waiting($0) == true },
            Snapshot("command-output-no-output-yet"),
        ]
        return [
            ScaleBegin(element: Self.element, load: load),
            UseScript(CLIScript(turns: [CLIScript.reply("OK")])), OpenFolder(), StartChat(),
            Do("Use an isolated shell home") { try $0.app.workspace?.storyPrepareTerminals() },
            Do("A running command with 1,500 lines so far") { try start($0, Self.big, "Count to 2000", Self.lines(0..<1500)) },
            Do("A running command with no output yet") { try start($0, Self.quiet, "Build quietly", "") },
        ] + Timed.wrap(work, Self.element, load) + scaleLook(Self.element, load)
    }
}

/// A property of a model object read by its name, for a feature a build may not have.
enum ScaleMirror {
    static func child(_ value: Any, _ name: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: value)
        while let m = mirror {
            if let hit = m.children.first(where: { $0.label == name || $0.label == "_" + name }) {
                // An optional that's nil isn't there.
                let inner = Mirror(reflecting: hit.value)
                if inner.displayStyle == .optional { return inner.children.first?.value }
                return hit.value
            }
            mirror = m.superclassMirror
        }
        return nil
    }
}

// MARK: - A box's History

/// A box window's History: the popup lists the box's past chats (asked with history.list), whole
/// in the window; one picked asks the box to open it (history.open) and comes up as a tab.
final class ScaleBoxHistory: Storyline {
    override class var tags: Set<Tag> { [.scale] }
    static let element = "box history"

    override func steps() -> [any Step] {
        let load = ScaleLoad.light
        let box: @MainActor @Sendable (StoryContext) -> ScriptedHistoryBox = { story in story.stash(ScriptedHistoryBox.self) { ScriptedHistoryBox(story) } }
        let window: @MainActor @Sendable (StoryContext) -> NSWindow? = { story in (try? box(story).workspace())?.window }
        let row = StoryID.History.row(ScriptedHistoryBox.past)
        let work: [any Step] = [
            Press(.id(StoryID.Titlebar.history)),
            WaitForElement(.id(row)),
            Expect("asked the box for its past chats", found: { box($0).asked.joined(separator: " ") }) { box($0).asked.contains("history.list") },
            Expect("its rows whole in the box window", found: { story in
                guard let w = window(story), let frame = StoryRegistry.entry(row.raw, in: w)?.frame else { return "no row" }
                return AnchoredInside.text(frame)
            }) { story in
                guard let w = window(story), let bounds = w.contentView?.bounds, let frame = StoryRegistry.entry(row.raw, in: w)?.frame else { return false }
                return bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
            },
            Press(.id(row)),
            Expect("asked the box to open it", found: { box($0).asked.joined(separator: " ") }) { story in
                box(story).asked.contains("history.open " + ScriptedHistoryBox.past)
            },
            Expect("it comes up as a tab", timeout: .seconds(5), found: { story in
                (try? box(story).workspace().tabs.map(\.title).joined(separator: ", ")) ?? "no window"
            }) { story in
                try box(story).workspace().tabs.contains { $0.title == ScriptedHistoryBox.title }
            },
        ]
        return [
            ScaleBegin(element: Self.element, load: load),
            BoxStep("Open the box folder's window, linked") { try await box($0).open($0) },
        ] + Timed.wrap(work, Self.element, load) + [
            ScaleBegin(element: Self.element + " layout", load: load),
            Look(name: "box-history", frames: 2, window: window),
        ]
    }
}

/// A box for one storyline: a welcome that says it keeps history, a window of one folder, one
/// past chat in its History, and `history.open` answered with a chat id. Other commands go
/// unanswered (a chat it opens has no turns to send).
@MainActor
final class ScriptedHistoryBox: StoryFinishing {
    let alias = "historybox"
    static let folder = "/home/me/ledger"
    static let past = "past-scale-1"
    static let title = "Past ledger fix"
    private(set) var asked: [String] = []
    let connection: HostConnection
    private var transport: PipeTransport?
    private var pump: Task<Void, Never>?

    init(_ story: StoryContext) {
        let cache = HostCache(alias: alias, root: story.outputs.appendingPathComponent("box-\(story.name)", isDirectory: true))
        weak var box: ScriptedHistoryBox?
        connection = HostConnection(alias: alias, cache: cache) { box?.dial() ?? PipeTransport(input: .nullDevice, output: .nullDevice) }
        box = self
        HostConnection.adopt(connection)
    }

    func open(_ story: StoryContext) async throws {
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        model.storyOpenBox(alias: alias, folder: Self.folder)
        let window = try await story.wait("the box window, linked") { () -> NSWindow? in
            guard let workspace = try? self.workspace(), self.connection.isOnline else { return nil }
            return workspace.window
        }
        window.setContentSize(story.windowSize)
        try await story.idle()
    }

    func workspace() throws -> Workspace {
        guard let workspace = Workspace.all.allObjects.first(where: { !$0.isClosed && $0.boxAlias == alias }) else {
            throw StoryFailure.modelMissing("the box window")
        }
        return workspace
    }

    private func send(_ message: LinkMessage) { transport?.send((try? message.encoded()) ?? Data()) }

    private func dial() -> any HostTransport {
        let toHost = Pipe(), toMac = Pipe()
        let mac = PipeTransport(input: toMac.fileHandleForReading, output: toHost.fileHandleForWriting)
        let end = PipeTransport(input: toHost.fileHandleForReading, output: toMac.fileHandleForWriting)
        try? end.start()
        pump?.cancel()
        transport = end
        pump = Task { [weak self] in
            for await event in end.events {
                guard case .frame(let data) = event, let self, self.transport === end else { continue }
                self.arrived(data)
            }
        }
        end.send((try? LinkMessage.challenge(nonce: "bm9uY2U=").encoded()) ?? Data())
        return mac
    }

    private func arrived(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = object["t"] as? String else { return }
        switch type {
        case "hello":
            send(.welcome(.init(
                proto: LinkVersion(major: LinkProto.major, minor: LinkProto.boxMinor), epoch: "e1",
                host: .init(name: alias, koreVersion: "1", kind: "box"), providers: [],
                policy: .init(sendMaxLevel: .danger, control: .full),
                caps: ["tx", "attn", "commands", "control", "box", "history"])))
            let window = LinkWindow(id: BoxFolder.windowId(Self.folder), name: "ledger", path: "~/ledger", tabs: [], activeTabId: nil)
            send(.snapshot(rev: 1, windows: [window], chats: []))
        case "history.list":
            asked.append("history.list")
            let id = object["id"] as? String ?? ""
            let session = HistorySession(id: Self.past, provider: "claude", title: Self.title,
                                         updatedAt: Int64(Date.now.timeIntervalSince1970 * 1000) - 3_600_000, archived: false, open: false)
            send(.historyPage(id: id, windowId: BoxFolder.windowId(Self.folder), sessions: [session], more: false))
        case "cmd":
            guard let id = object["id"] as? String, let cmd = object["cmd"] as? [String: Any], let kind = cmd["type"] as? String else { return }
            asked.append(kind == "history.open" ? "history.open " + (cmd["sessionId"] as? String ?? "") : kind)
            if kind == "history.open" { send(.result(.init(id: id, ok: true, chatId: "chat-" + Self.past))) }
        default:
            break
        }
    }

    func finish() {
        (try? workspace())?.window?.close()
        pump?.cancel()
        transport = nil
    }
}
