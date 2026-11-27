import AppKit
import Foundation
import KoreUI
import LinkProtocol

// A chat copied from its tab and pasted in any window, as History's Copy and Paste do (owner,
// 0.3.10: "right-click tabs to copy a chat and paste it somewhere else … in an open window with
// any chat open"): Copy Chat and Cut Chat on a tab, Paste Chat on a tab and the strip, landing
// right after the right-clicked tab (past its group), and ⌘V where no text field has the keys.
// In the composer, ⌘V stays the text's. Copies go to the run's own folders.

/// The other window a storyline pastes into.
@MainActor
final class PasteWindows {
    weak var other: Workspace?
    var source: UUID?
    var chat: ObjectIdentifier?
    var tabs = 0
    var transfers = 0

    func otherWorkspace() throws -> Workspace {
        guard let other, !other.isClosed else { throw StoryFailure.modelMissing("the other window") }
        return other
    }
}

enum TabPaste {
    @MainActor static func windows(_ story: StoryContext) -> PasteWindows { story.stash(PasteWindows.self) { PasteWindows() } }

    @MainActor static func workspace(_ story: StoryContext) throws -> Workspace {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the workspace") }
        return workspace
    }

    /// The tab of the chat with session `id`.
    @MainActor static func tab(_ story: StoryContext, session id: String) throws -> ChatTab {
        guard let tab = try workspace(story).tabs.first(where: { $0.chat?.sessionId == id }) else { throw StoryFailure.modelMissing("the chat \(id)'s tab") }
        return tab
    }

    /// Copies read and write in the run's folders; nothing held yet. A Codex chat's rollout
    /// starts with its session line, as Codex writes one (the copy names its new session there).
    static func scratch(_ session: String, provider: String?) -> Do {
        Do("Copies read and write in the run's own folders") { story in
            ChatPasteStory.reset()
            ChatPasteStory.use(story.outputs.appendingPathComponent("chat-paste", isDirectory: true))
            guard provider == "codex" else { return }
            let file = story.outputs.appendingPathComponent("\(session).jsonl")
            let rows = try String(contentsOf: file, encoding: .utf8)
            let meta = #"{"timestamp":"2026-10-20T09:00:00.000Z","type":"session_meta","payload":{"id":"\#(session)","timestamp":"2026-10-20T09:00:00.000Z","cwd":"\#(story.folder.path)","originator":"codex_cli_rs","cli_version":"0.1.0"}}"#
            if !rows.hasPrefix(#"{"timestamp":"2026-10-20T09:00:00.000Z","type":"session_meta""#) { try (meta + "\n" + rows).write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    /// The app's own engine again, and the other window closed (its question with it).
    static func reset() -> Do {
        Do("The app's own copy engine again, the other window closed") { story in
            ChatPasteStory.reset()
            windows(story).other?.window?.close()
        }
    }

    /// Notes the source: its tab, its chat, the window's tab count.
    static func note(_ session: String) -> Do {
        Do("Note the chat's tab") { story in
            let tab = try tab(story, session: session)
            let windows = windows(story)
            windows.source = tab.id
            windows.chat = tab.chat.map(ObjectIdentifier.init)
            windows.tabs = try workspace(story).tabs.count
        }
    }

    /// The pasted chat's transcript on disk: the source's rows, under its own session (the
    /// scripted CLIs play history from memory, so its tab shows none).
    static func copied(_ session: String, into workspace: @escaping @MainActor @Sendable (StoryContext) throws -> Workspace) -> Expect {
        Expect("its transcript has the source's rows, under its own session", found: { story in
            (try? text(story, workspace)).map { String($0.prefix(300)) } ?? "no file"
        }) { story in
            guard let text = try text(story, workspace), let id = try workspace(story).activeTab.chat?.sessionId else { return false }
            return text.contains("Imported work") && text.contains("Done.") && text.contains("\"\(id)\"") && !text.contains("\"\(session)\"")
        }
    }

    @MainActor private static func text(_ story: StoryContext, _ workspace: (StoryContext) throws -> Workspace) throws -> String? {
        guard let id = try workspace(story).activeTab.chat?.sessionId, let files = FileManager.default.enumerator(at: story.outputs, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in files where file.lastPathComponent == id + ".jsonl" { return try String(contentsOf: file, encoding: .utf8) }
        return nil
    }

    /// The source as it was: its tab, its chat object, its session.
    static func sourceKept(_ session: String) -> Expect {
        Expect("the chat's own tab as it was") { story in
            let windows = windows(story)
            let tab = try tab(story, session: session)
            return tab.id == windows.source && tab.chat.map(ObjectIdentifier.init) == windows.chat
        }
    }
}

/// A right-click on a tab found when the step runs.
struct RightClickTab: Step {
    let what: String
    let tab: @MainActor (StoryContext) throws -> ChatTab
    var label: String { "Right-click \(what)" }
    init(_ what: String, _ tab: @escaping @MainActor (StoryContext) throws -> ChatTab) {
        self.what = what
        self.tab = tab
    }

    func run(_ story: StoryContext) async throws {
        let tab = try tab(story)
        try await story.input.rightClick(try await story.element(.id(StoryID.Tabs.tab(tab.id))))
    }
}

/// Another folder's window on this Mac, as File ▸ Open opens one.
struct OpenOtherWindow: Step {
    var label: String { "Open another folder's window" }
    var timeout: Duration? { .seconds(15) }

    func run(_ story: StoryContext) async throws {
        guard let model = AppModel.shared else { throw StoryFailure.other("the app model isn't up") }
        // Its own folder each run: a window another run left open is never this one.
        let folder = story.outputs.appendingPathComponent("paste-here-\(story.name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.openFolder(folder)
        let path = folder.resolvingSymlinksInPath().path
        let other = try await story.wait("its window") { () -> Workspace? in
            Workspace.all.allObjects.first { !$0.isClosed && $0.window != nil && $0.folder.resolvingSymlinksInPath().path == path }
        }
        other.window?.setContentSize(story.windowSize)
        TabPaste.windows(story).other = other
        try await story.idle()
    }
}

/// A picture of a window that isn't the storyline's own.
struct SnapshotOf: Step {
    let name: String
    let window: @MainActor (StoryContext) throws -> NSWindow?
    var label: String { "Snapshot “\(name)”" }
    init(_ name: String, _ window: @escaping @MainActor (StoryContext) throws -> NSWindow?) {
        self.name = name
        self.window = window
    }

    func run(_ story: StoryContext) async throws {
        guard let window = try window(story), let png = snapshot(window) else { throw StoryFailure.other("no window to snapshot") }
        try png.write(to: story.outputs.appendingPathComponent("\(name).png"))
    }
}

/// Copy Chat on the chat's tab; Paste Chat on another window's tab puts it there, a new tab in
/// front under its own session, the chat's own tab untouched. Back in its window, ⌘V with the
/// transcript in front pastes it again beside its tab ("(copy)", the same folder). In the
/// composer, ⌘V is the text's even with the chat copied last.
final class TabChatCopyPaste: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let session = session
        let source: @MainActor @Sendable (StoryContext) throws -> ChatTab = { story in try TabPaste.tab(story, session: session) }
        let other: @MainActor @Sendable (StoryContext) throws -> Workspace = { story in try TabPaste.windows(story).otherWorkspace() }
        return opened() + [
            TabPaste.scratch(session, provider: variant.provider),
            TabPaste.note(session),
            RightClickTab("the chat's tab", source), PickOption("Copy Chat"),
            Expect("the chat held, as a copy", found: { _ in ChatPasteStory.held.map { "\($0.id) cut \($0.cut)" } }) { _ in
                ChatPasteStory.held?.id == session && ChatPasteStory.held?.cut == false
            },
            OpenOtherWindow(),
            RightClickTab("the other window's tab") { story in try other(story).activeTab },
            PickOption("Paste Chat"),
            Expect("pasted there: in front, a chat of its own session", timeout: .seconds(10), found: { story in
                (try? other(story)).map { "\($0.tabs.count) tabs, front \($0.activeTab.chat?.sessionId ?? "none") “\($0.activeTab.chat?.title ?? "")”; bar \(ChatPasteStory.transfers(in: $0))" }
            }) { story in
                let other = try other(story)
                guard let chat = other.activeTab.chat, let id = chat.sessionId else { return false }
                let provider = try source(story).chat?.provider.id
                return id != session && chat.provider.id == provider
            },
            TabPaste.copied(session, into: other),
            Do("The other window in front") { story in try other(story).window?.makeKeyAndOrderFront(nil) },
            WaitIdle(),
            TabPaste.sourceKept(session),
            Expect("the window it came from has its tabs still") { story in try TabPaste.workspace(story).tabs.count == TabPaste.windows(story).tabs },
            SnapshotOf("tab-paste-other-window") { story in try other(story).window },
            // ⌘V where no text field has the keys: the transcript in front.
            Do("The chat's window in front, its tab selected") { story in
                let workspace = try TabPaste.workspace(story)
                workspace.window?.makeKeyAndOrderFront(nil)
                let tab = try source(story)
                workspace.storySelect(tabAt: workspace.tabs.firstIndex { $0 === tab } ?? 0)
            },
            WaitIdle(),
            Click(Self.lastAnswer),
            Expect("no text field has the keys", found: { story in story.window?.firstResponder.map { "\(type(of: $0))" } }) { story in
                !(story.window?.firstResponder is NSText)
            },
            Key(.cmd("v")),
            Expect("a copy right after the chat's tab, in front", timeout: .seconds(10), found: { story in
                (try? TabPaste.workspace(story)).map { w in "\(w.tabs.count) tabs, front \(w.tabs.firstIndex { $0 === w.activeTab } ?? -1) \(w.activeTab.chat?.sessionId ?? "none")" }
            }) { story in
                let workspace = try TabPaste.workspace(story)
                guard let index = workspace.tabs.firstIndex(where: { $0.id == TabPaste.windows(story).source }),
                    workspace.tabs.indices.contains(index + 1), workspace.tabs[index + 1] === workspace.activeTab,
                    let id = workspace.activeTab.chat?.sessionId
                else { return false }
                return id != session
            },
            TabPaste.copied(session, into: { story in try TabPaste.workspace(story) }),
            TabPaste.sourceKept(session),
            WaitIdle(), Snapshot("tab-paste-key"),
            // In the composer, ⌘V is the text's: words copied there, then the chat copied after.
            Do("The chat's tab in front") { story in
                let workspace = try TabPaste.workspace(story)
                let tab = try source(story)
                workspace.storySelect(tabAt: workspace.tabs.firstIndex { $0 === tab } ?? 0)
            },
            WaitIdle(),
            Click(.id(StoryID.Composer.field)),
            TypeText("words to paste"), Key(.cmd("a")), Key(.cmd("c")), Key(KeyChord(.backspace)),
            Expect("the composer empty") { story in try source(story).chat?.draft.isEmpty == true },
            RightClickTab("the chat's tab", source), PickOption("Copy Chat"),
            Do("Note the tabs and the bar") { story in
                let windows = TabPaste.windows(story)
                windows.tabs = try TabPaste.workspace(story).tabs.count
                windows.transfers = ChatPasteStory.transfers(in: try TabPaste.workspace(story)).count
            },
            Click(.id(StoryID.Composer.field)),
            Key(.cmd("v")),
            WaitIdle(),
            Expect("the composer took the words; no chat pasted", found: { story in try? source(story).chat?.draft }) { story in
                let workspace = try TabPaste.workspace(story)
                let windows = TabPaste.windows(story)
                return try source(story).chat?.draft.contains("words to paste") == true && workspace.activeTab.id == windows.source
                    && workspace.tabs.count == windows.tabs && ChatPasteStory.transfers(in: workspace).count == windows.transfers
            },
            TabPaste.reset(),
        ]
    }
}

/// A chat pasted on the middle tab of a group lands right after the group, which stays whole.
final class TabChatPasteAfterGroup: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let session = session
        let source: @MainActor @Sendable (StoryContext) throws -> ChatTab = { story in try TabPaste.tab(story, session: session) }
        return opened() + [
            TabPaste.scratch(session, provider: variant.provider),
            RightClickTab("the chat's tab", source), PickOption("Copy Chat"),
            Do("Four tabs at least, the first three grouped") { story in
                let workspace = try TabPaste.workspace(story)
                while workspace.tabs.count < 4 { workspace.perform(.newTab) }
                workspace.group(workspace.tabs[1], onto: workspace.tabs[0])
                workspace.group(workspace.tabs[2], onto: workspace.tabs[1])
                workspace.storySelect(tabAt: 1)
            },
            WaitIdle(),
            Expect("tabs 1–3 grouped") { try TabGroupProbe.members($0) == [0, 1, 2] },
            TabPaste.note(session),
            RightClickTab("the group's middle tab") { story in try TabGroupProbe.tab(story, 1) },
            PickOption("Paste Chat"),
            Expect("the copy right after the group (tab 4), in front", timeout: .seconds(10), found: { story in
                (try? TabPaste.workspace(story)).map { w in "front \((w.tabs.firstIndex { $0 === w.activeTab } ?? -1) + 1) \(w.activeTab.chat?.sessionId ?? "none")" }
            }) { story in
                let workspace = try TabPaste.workspace(story)
                guard let id = workspace.activeTab.chat?.sessionId, id != session else { return false }
                return workspace.tabs.firstIndex { $0 === workspace.activeTab } == 3 && workspace.tabGroups.member[workspace.activeTab.id] == nil
            },
            Expect("the group whole: tabs 1–3") { try TabGroupProbe.members($0) == [0, 1, 2] },
            Expect("one tab more") { story in try TabPaste.workspace(story).tabs.count == TabPaste.windows(story).tabs + 1 },
            TabPaste.sourceKept(session),
            WaitIdle(), Snapshot("tab-paste-after-group"),
            TabPaste.reset(),
        ]
    }
}

/// Pasted in a box's window, on its group's middle tab: the paste takes History's own way there,
/// and says so on that window's bar when it can't reach the box by SSH. When the box takes the
/// copy in, its tab lands right after the group, in front.
final class TabChatPasteInBoxWindow: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        let session = session
        let source: @MainActor @Sendable (StoryContext) throws -> ChatTab = { story in try TabPaste.tab(story, session: session) }
        let box: @MainActor @Sendable (StoryContext) -> ScriptedTabsBox = { story in story.stash(ScriptedTabsBox.self) { ScriptedTabsBox(story) } }
        return opened() + [
            TabPaste.scratch(session, provider: variant.provider),
            Do("The box has no SSH alias here") { _ in ChatPasteStory.noSSH() },
            RightClickTab("the chat's tab", source), PickOption("Copy Chat"),
            BoxStep("Open the box folder's window, the box listing four chats") { try await box($0).open($0) },
            Do("Its first three tabs grouped") { story in
                let workspace = try box(story).workspace()
                workspace.group(workspace.tabs[1], onto: workspace.tabs[0])
                workspace.group(workspace.tabs[2], onto: workspace.tabs[1])
            },
            RightClickTab("the box group's middle tab") { story in try box(story).workspace().tabs[1] },
            PickOption("Paste Chat"),
            Expect("the box window's bar says why, as History's paste does", timeout: .seconds(10), found: { story in
                (try? box(story).workspace()).map { "\(ChatPasteStory.transfers(in: $0))" }
            }) { story in
                ChatPasteStory.transfers(in: try box(story).workspace()).contains { $0.failure == "edgebox isn't an SSH alias Kore can use" }
            },
            Expect("nothing changed there", found: { try? box($0).chatIds().joined(separator: " ") }) { story in
                try box(story).chatIds() == ["c1", "c2", "c3", "c4"]
            },
            Do("The box takes a copy in (its rsync and commit), as chat c9") { story in
                let box = box(story)
                let workspace = try box.workspace()
                ChatPasteStory.landedOnBox(alias: box.alias, folder: box.folder, chatId: "c9", after: workspace.tabs[1])
                box.ids.append("c9")
                box.send(.delta(rev: box.nextRev(), windows: box.windows(), chats: box.metas(), removed: nil))
            },
            Expect("c9 right after the group (tab 4), in front", timeout: .seconds(10), found: { try? box($0).chatIds().joined(separator: " ") }) { story in
                let workspace = try box(story).workspace()
                return try box(story).chatIds() == ["c1", "c2", "c3", "c9", "c4"] && workspace.activeTab.chat?.title == ScriptedTabsBox.title("c9")
            },
            Expect("the box's group whole") { story in
                let workspace = try box(story).workspace()
                let group = workspace.tabGroups.member[workspace.tabs[0].id]
                return group != nil && workspace.tabs.indices.filter { workspace.tabGroups.member[workspace.tabs[$0].id] == group } == [0, 1, 2]
            },
            WaitIdle(),
            SnapshotOf("tab-paste-box-window") { story in try box(story).workspace().window },
            TabPaste.reset(),
        ]
    }
}

/// A working chat copied from its tab is copied as History copies one: at once, no question. Cut
/// while it works, its paste asks first (“Stop and move”), as History's does.
final class TabChatPasteWorking: OpenEndStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override class var script: CLIScript {
        CLIScript(turns: [[.startTurn, .tool(name: "Bash", detail: "sleep 9", output: "woke", wait: .release), .stream(.answer, "Done."), .finishTurn(.completed)]])
    }

    override func steps() -> [any Step] {
        let session = session
        let source: @MainActor @Sendable (StoryContext) throws -> ChatTab = { story in try TabPaste.tab(story, session: session) }
        let other: @MainActor @Sendable (StoryContext) throws -> Workspace = { story in try TabPaste.windows(story).otherWorkspace() }
        return opened() + [
            TabPaste.scratch(session, provider: variant.provider),
            Send("Go on"),
            WaitForEvent("the command running") { if case .toolStarted(let call, _) = $0 { call.detail == "sleep 9" } else { false } },
            Expect("the chat working") { story in try source(story).chat?.isWorking == true },
            TabPaste.note(session),
            RightClickTab("the working chat's tab", source), PickOption("Copy Chat"),
            Expect("the chat held, as a copy", found: { _ in "\(ChatPasteStory.held.map { "\($0.id) cut \($0.cut)" } ?? "none"); menu \(StoryMenus.open)" }) { _ in
                ChatPasteStory.held?.id == session && ChatPasteStory.held?.cut == false
            },
            OpenOtherWindow(),
            RightClickTab("the other window's tab") { story in try other(story).activeTab },
            PickOption("Paste Chat"),
            Expect("copied there at once, no question", timeout: .seconds(10), found: { story in
                (try? other(story)).map { "front \($0.activeTab.chat?.sessionId ?? "none"), ask \(ChatPasteStory.ask(in: $0) ?? "none")" }
            }) { story in
                let other = try other(story)
                guard let id = other.activeTab.chat?.sessionId else { return false }
                return id != session && ChatPasteStory.ask(in: other) == nil
            },
            Expect("the chat still working, in its tab") { story in try source(story).chat?.isWorking == true },
            TabPaste.sourceKept(session),
            RightClickTab("the working chat's tab", source), PickOption("Cut Chat"),
            Expect("the chat held, as a cut") { _ in ChatPasteStory.held?.id == session && ChatPasteStory.held?.cut == true },
            RightClickTab("the other window's tab") { story in try other(story).activeTab },
            PickOption("Paste Chat"),
            Expect("the paste asks first: Stop and move", found: { story in (try? other(story)).flatMap { ChatPasteStory.ask(in: $0) } }) { story in
                ChatPasteStory.ask(in: try other(story)) == "Stop and move"
            },
            ExpectElement(.id(StoryID.History.pasteLine)),
            Expect("the line at the top of the other window") { story in
                guard let element = StoryElement(StoryID.History.pasteLine), let frame = element.frame else { return false }
                return element.window === (try other(story)).window && frame.width > 0 && frame.height > 0
            },
            Expect("nothing moved meanwhile") { story in try source(story).chat?.isWorking == true },
            TabPaste.sourceKept(session),
            Do("The other window in front") { story in try other(story).window?.makeKeyAndOrderFront(nil) },
            WaitIdle(),
            // Its fade.
            Rest(milliseconds: 400),
            SnapshotOf("tab-paste-working-ask") { story in try other(story).window },
            Do("The command ends") { story in ScriptedWorld.shared.backend(session: session)?.release() },
            TabPaste.reset(),
        ]
    }
}
