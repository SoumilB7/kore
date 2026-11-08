import AppKit
import Foundation
import HostClient
import KoreUI
import LinkProtocol

// A tab dragged to the very first or the very last place lands there, in a window on this Mac's
// folder and in a box's: before the first tab and past the last (up to `+`) are places, not the
// end tabs' middles, where a held tab groups. Held there past the group wait, it only moves. A
// box window's order then holds through the box's next state and a reconnect.

/// Drags a tab by its middle into the first tab's leading edge, or past the last tab, and holds
/// it there past the group wait before letting go.
struct DragTabToEnd: Step {
    enum End: String { case first, last }
    let tab: Int
    let end: End
    let workspace: @MainActor (StoryContext) throws -> Workspace
    var label: String { "Drag tab \(tab + 1) to the \(end.rawValue) place and hold it there" }
    var timeout: Duration? { .seconds(10) }

    func run(_ story: StoryContext) async throws {
        let tabs = try workspace(story).tabs
        guard tabs.indices.contains(tab), let edge = end == .first ? tabs.first : tabs.last else { throw StoryFailure.modelMissing("tab \(tab + 1)") }
        let from = try await story.element(.id(StoryID.Tabs.tab(tabs[tab].id)))
        let to = try await story.element(.id(StoryID.Tabs.tab(edge.id)))
        guard let window = from.window, let a = from.frame, let b = to.frame else { throw StoryFailure.modelMissing("the tabs' frames") }
        let x = end == .first ? b.minX + 3 : b.maxX + 12
        await story.input.drag(from: CGPoint(x: a.midX, y: a.midY), to: CGPoint(x: x, y: a.midY), in: window, steps: 10, hold: .milliseconds(700))
        try await story.idle()
    }
}

enum TabEdges {
    /// The window's tabs in order, as their ids when the story began (`ids`), by those places.
    @MainActor static func order(_ workspace: Workspace, _ ids: [UUID]) -> [Int] {
        workspace.tabs.compactMap { tab in ids.firstIndex(of: tab.id) }
    }

    /// Tab 3 of four to the first place, then tab 1 (second by then) to the last: the order
    /// checked after each, and no group made.
    @MainActor static func drags(_ workspace: @escaping @MainActor (StoryContext) throws -> Workspace) -> [any Step] {
        let ids = Ids()
        return [
            Do("Note the four tabs") { story in
                let tabs = try workspace(story).tabs
                guard tabs.count == 4 else { throw StoryFailure.modelMissing("four tabs, not \(tabs.count)") }
                ids.value = tabs.map(\.id)
            },
            DragTabToEnd(tab: 2, end: .first, workspace: workspace),
            Expect("tab 3 first, the rest in order, no group", found: { story in (try? workspace(story)).map { "\(order($0, ids.value))" } }) { story in
                let workspace = try workspace(story)
                return order(workspace, ids.value) == [2, 0, 1, 3] && workspace.tabGroups.isEmpty
            },
            DragTabToEnd(tab: 1, end: .last, workspace: workspace),
            Expect("tab 1 last, no group", found: { story in (try? workspace(story)).map { "\(order($0, ids.value))" } }) { story in
                let workspace = try workspace(story)
                return order(workspace, ids.value) == [2, 1, 3, 0] && workspace.tabGroups.isEmpty
            },
        ]
    }

    @MainActor final class Ids {
        var value: [UUID] = []
    }
}

/// In a window on this Mac's folder.
final class TabDragToEnds: Storyline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        [OpenFolder(), StartChat(), OpenTabs(3)] + TabEdges.drags { try TabGroupProbe.workspace($0) } + [Snapshot("tab-drag-ends")]
    }
}

/// In a box's window: its four chats listed by a scripted box over a pipe pair (nothing dials).
/// The order holds through the box's next delta, which lists its tabs in its own order and adds a
/// chat (at the end), and through a reconnect's snapshot.
final class BoxTabDragToEnds: Storyline {
    override class var tags: Set<Tag> { [.gate] }

    override func steps() -> [any Step] {
        let box = { (story: StoryContext) in story.stash(ScriptedTabsBox.self) { ScriptedTabsBox(story) } }
        let kept = ["c3", "c2", "c4", "c1", "c5"]
        return [BoxStep("Open the box folder's window, the box listing four chats") { try await box($0).open($0) }]
            + TabEdges.drags { try box($0).workspace() } + [
                Do("The box's next state: its own order, and a chat opened elsewhere") { story in
                    let box = box(story)
                    box.ids.append("c5")
                    box.send(.delta(rev: box.nextRev(), windows: box.windows(), chats: box.metas(), removed: nil))
                },
                Expect("the order kept, the new chat last", found: { try? box($0).chatIds().joined(separator: " ") }) { try box($0).chatIds() == kept },
                BoxStep("Reconnect: the link drops and dials again") { story in
                    let box = box(story)
                    let (dials, snapshots) = (box.dials, box.snapshots)
                    box.connection.relink("story reconnect")
                    _ = try await story.wait("the next dial's snapshot") { box.dials > dials && box.snapshots > snapshots ? true : nil }
                    try await story.idle()
                },
                Expect("the order kept through the reconnect", found: { try? box($0).chatIds().joined(separator: " ") }) { story in
                    try box(story).chatIds() == kept && box(story).workspace().tabGroups.isEmpty
                },
            ]
    }
}

/// A step of the scripted box's that waits.
struct BoxStep: Step {
    let label: String
    let action: @MainActor (StoryContext) async throws -> Void
    var timeout: Duration? { .seconds(15) }
    init(_ label: String, _ action: @escaping @MainActor (StoryContext) async throws -> Void) {
        self.label = label
        self.action = action
    }

    func run(_ story: StoryContext) async throws { try await action(story) }
}

/// A box for one storyline: answers each dial's hello with a snapshot of one folder's window,
/// its chats in the box's own order. Its window closes when the storyline ends.
@MainActor
final class ScriptedTabsBox: StoryFinishing {
    /// Not a box the other storylines name (`mybox`): this one's connection stays adopted.
    let alias = "edgebox"
    let folder = "/home/me/app"
    var ids = ["c1", "c2", "c3", "c4"]
    let connection: HostConnection
    private(set) var dials = 0
    private(set) var snapshots = 0
    private var transport: PipeTransport?
    private var pump: Task<Void, Never>?
    private var rev = 10

    init(_ story: StoryContext) {
        let cache = HostCache(alias: alias, root: story.outputs.appendingPathComponent("box-\(story.name)", isDirectory: true))
        weak var box: ScriptedTabsBox?
        connection = HostConnection(alias: alias, cache: cache) { box?.dial() ?? PipeTransport(input: .nullDevice, output: .nullDevice) }
        box = self
        HostConnection.adopt(connection)
    }

    func open(_ story: StoryContext) async throws {
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        model.storyOpenBox(alias: alias, folder: folder)
        let window = try await story.wait("the box window with four tabs") { () -> NSWindow? in
            guard let workspace = try? self.workspace(), workspace.tabs.count == 4 else { return nil }
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

    /// The window's tabs as the box's chat ids, in order.
    func chatIds() throws -> [String] {
        try workspace().tabs.compactMap { tab in tab.chat.flatMap { chat in ids.first { chat.title == Self.title($0) } } }
    }

    static func title(_ id: String) -> String { "Chat " + id }

    func metas() -> [ChatMeta] {
        ids.map { id in
            ChatMeta(
                id: id, provider: "claude", title: Self.title(id), state: .idle, mode: .init(id: "default", level: .manual), modeIds: ["default"],
                allowedModeIds: ["default"], model: "Haiku", queued: 0, running: false, cards: [], can: .init(send: true, stop: false))
        }
    }

    func windows() -> [LinkWindow] {
        let tabs = ids.enumerated().map { LinkTab(id: "t\($0.offset)", kind: .chat, title: Self.title($0.element), chatId: $0.element) }
        return [LinkWindow(id: BoxFolder.windowId(folder), name: "app", path: "~/app", tabs: tabs, activeTabId: nil)]
    }

    func send(_ message: LinkMessage) { transport?.send((try? message.encoded()) ?? Data()) }

    func nextRev() -> Int {
        rev += 1
        return rev
    }

    /// A dial: a new pipe pair, the box's end answering the hello with its snapshot.
    private func dial() -> any HostTransport {
        let toHost = Pipe(), toMac = Pipe()
        let mac = PipeTransport(input: toMac.fileHandleForReading, output: toHost.fileHandleForWriting)
        let end = PipeTransport(input: toHost.fileHandleForReading, output: toMac.fileHandleForWriting)
        try? end.start()
        pump?.cancel()
        transport = end
        dials += 1
        pump = Task { [weak self] in
            for await event in end.events {
                guard case .frame(let data) = event, let self, self.transport === end else { continue }
                let type = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["t"] as? String
                guard type == "hello" else { continue }
                self.send(.snapshot(rev: self.nextRev(), windows: self.windows(), chats: self.metas()))
                self.snapshots += 1
            }
        }
        end.send((try? LinkMessage.challenge(nonce: "bm9uY2U=").encoded()) ?? Data())
        return mac
    }

    func finish() {
        (try? workspace())?.window?.close()
        pump?.cancel()
        transport = nil
    }
}
