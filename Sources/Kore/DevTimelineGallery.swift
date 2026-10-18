import AppKit
import KoreCore
import SwiftUI

/// KORE_GALLERY=timeline: the transcript timeline over a sample conversation, with every item
/// kind (folded and open turns, tools with IN / OUT, edits with diffs, agents running and done,
/// an interrupted turn), so its look can be snapshotted without a live CLI.
/// KORE_GALLERY=changes: the changes modal over the same sample's changed files.
@MainActor
enum DevTimelineGallery {
    /// True when it showed (the other gallery then stays closed).
    static func showIfRequested() -> Bool {
        let mode = ProcessInfo.processInfo.environment["KORE_GALLERY"]
        guard mode == "timeline" || mode == "changes" || mode == "timeline-agents" else { return false }
        if mode == "timeline-agents" {
            showAgents()
            return true
        }
        let store = sample()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: mode == "changes" ? 700 : 2000), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.title = mode == "changes" ? "Changes" : "Timeline"
        if mode == "changes" {
            window.contentView = NSHostingView(
                rootView: ChangesView(changes: store.changes(ofTurn: "t2"), folder: folder, close: {})
                    .environment(\.colorScheme, .dark))
        } else {
            window.contentView = NSHostingView(
                rootView: TranscriptTimeline(store: store, actions: actions(store))
                    .background(Theme.background)
                    .environment(\.colorScheme, .dark))
        }
        window.orderFront(nil)
        DevSnapshot.captureIfRequested()
        return true
    }

    private static func actions(_ store: TranscriptStore) -> TranscriptActions {
        var actions = TranscriptActions()
        actions.toggleTurn = { store.toggle(turn: $0) }
        actions.toggle = { store.toggle($0) }
        actions.folder = folder
        return actions
    }

    private static let folder = URL(fileURLWithPath: "/Users/dev/kore")

    private static let edit = """
        diff --git a/Sources/Kore/Chat/ChatView.swift b/Sources/Kore/Chat/ChatView.swift
        --- a/Sources/Kore/Chat/ChatView.swift
        +++ b/Sources/Kore/Chat/ChatView.swift
        @@ -12,6 +12,7 @@ struct ChatView: View {
             var body: some View {
                 VStack(spacing: 0) {
        -            TranscriptView(chat: chat) { view($0, pending: false) }
        +            TranscriptTimeline(store: chat.transcript, actions: actions)
        +                .equatable()
                     VStack(spacing: Space.lg) {
                         ApprovalsView(chat: chat)
        """

    private static let multi = """
        diff --git a/README.md b/README.md
        new file mode 100644
        --- /dev/null
        +++ b/README.md
        @@ -0,0 +1,3 @@
        +# Kore
        +
        +A native macOS app over the claude and codex CLIs.
        diff --git a/notes.txt b/notes.txt
        --- a/notes.txt
        +++ b/notes.txt
        @@ -1,2 +1,2 @@
        -hello
        +hello, world
         second line
        """

    private static func sample() -> TranscriptStore {
        let store = TranscriptStore()
        let root = URL(fileURLWithPath: "/Users/dev/kore")
        let start = Date().addingTimeInterval(-600)
        store.batch {
            // A replayed turn: starts folded.
            store.user("What does the composer do on Return?", attachments: [])
            store.turnStarted("t1", at: start)
            store.text("b1", .thinking, "Return sends unless the slash menu is open.")
            store.toolStarted(id: "r1", name: "Read", detail: "ComposerView.swift", input: "Sources/Kore/Chat/Composer/ComposerView.swift:40-90", path: "Sources/Kore/Chat/Composer/ComposerView.swift")
            store.toolFinished(id: "r1", output: "51 lines", isError: false)
            store.text("b2", .answer, "Return sends the draft. While the **slash menu** is open it accepts the highlighted command instead.")
            store.turnFinished("t1", .completed, duration: 14)
        }
        // A live-looking turn, finished and opened.
        store.user("Make the transcript a timeline like the extension.", attachments: [])
        store.turnStarted("t2", at: start.addingTimeInterval(60))
        store.text("b3", .thinking, "The timeline needs a dot per item and a line that joins runs.")
        store.toolStarted(
            id: "c1", name: "Bash", detail: "rg -n 'EntryView' Sources", input: "rg -n 'EntryView' Sources",
            summary: "Find where entries are drawn")
        store.toolFinished(
            id: "c1",
            output: """
                Sources/Kore/Chat/Transcript/TranscriptView.swift:27:  EntryView(entry: entry, openImage: openImage)
                Sources/Kore/Chat/Transcript/EntryViews.swift:3:struct EntryView: View {
                Sources/Kore/DevGallery.swift:62:  ForEach(entries) { EntryView(entry: $0, openImage: { _ in }) }
                Sources/Kore/Chat/Transcript/TranscriptView.swift:53:extension EntryView: Equatable {
                Sources/Kore/Chat/Transcript/EntryViews.swift:61:}
                """, isError: false)
        store.toolStarted(id: "e1", name: "Edit", detail: "ChatView.swift", path: "Sources/Kore/Chat/ChatView.swift")
        store.fileChanged(tool: "e1", UnifiedDiff.files(edit, root: root))
        store.toolFinished(id: "e1", output: nil, isError: false)
        store.toolStarted(id: "c2", name: "Bash", detail: "swift build", input: "swift build", summary: "Build")
        store.toolFinished(id: "c2", output: "error: cannot find 'TranscriptTimeline' in scope", isError: true)
        store.agentSpawned(id: "a1", name: "Map reads of entries", type: "Explore", model: "haiku", tool: nil, at: start.addingTimeInterval(80))
        store.toolStarted(id: "a1r", name: "Grep", detail: "entries\\[ in Sources/Kore", input: "entries\\[  in Sources/Kore", agent: "a1")
        store.toolFinished(id: "a1r", output: "12 matches", isError: false)
        store.agentProgress(id: "a1", tokens: 18_240, tools: 9, lastTool: "Grep", duration: nil)
        store.agentFinished(id: "a1", status: .finished, result: "Entries are read in TranscriptView (ForEach), ChatModel (append / index) and the gallery.", at: start.addingTimeInterval(121))
        store.text("b4", .answer, "Done. Each item now hangs off one line with a dot for its state; edits show their diff.")
        store.turnFinished("t2", .completed, duration: 72)
        store.turnChanges("t2", UnifiedDiff.files(edit + "\n" + multi, root: root))
        store.toggle(turn: "t2")
        for row in store.rows {
            if case .agent(let e, _, _) = row { store.toggle(e.id.uuidString) }
        }

        // An interrupted turn with a Codex multi-file edit and a running agent.
        store.user("Add a README and fix notes.txt", attachments: [])
        store.turnStarted("t3")
        store.text("b5", .answer, "Adding the README first.")
        store.toolStarted(id: "f1", name: "Edit", detail: "2 files")
        store.fileChanged(tool: "f1", UnifiedDiff.files(multi, root: root))
        store.toolFinished(id: "f1", output: nil, isError: false)
        store.agentSpawned(id: "a2", name: "Check links in docs", type: "general-purpose", model: "gpt-6-luna", tool: nil)
        store.toolStarted(id: "a2r", name: "Bash", detail: "rg -n 'http' z-docs", input: "rg -n 'http' z-docs", agent: "a2")
        store.toolStarted(id: "c3", name: "Bash", detail: "swift test", input: "swift test", summary: "Run the tests")
        return store
    }

    // MARK: Agents

    /// KORE_GALLERY=timeline-agents: one turn where the main agent spawns three sub-agents in
    /// parallel (finished, running, failed), one of which spawns its own; a Codex child; main
    /// commands between them; and an approval card asked for by a sub-agent.
    private static func showAgents() {
        let store = agentsSample()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 2400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.title = "Agents"
        let approval = Approval(
            id: "ap", title: "wants to run Bash", detail: "Run the scroll tests", body: "swift test --filter Scroll",
            canAlwaysAllow: true, questions: [], agent: .sub("a2"))
        let asker = store.agent("a2").map { (index: $0.index, name: $0.name) }
        window.contentView = NSHostingView(
            rootView: VStack(spacing: Space.lg) {
                TranscriptTimeline(store: store, actions: actions(store))
                PermissionCard(approval: approval, asker: asker, folder: folder) { _ in }
                    .padding(.horizontal, ChatColumn.window.padding)
                    .padding(.bottom, Space.xxxl)
            }
            .background(Theme.background)
            .environment(\.colorScheme, .dark))
        window.orderFront(nil)
        DevSnapshot.captureIfRequested()
    }

    private static let smallEdit = """
        diff --git a/Sources/Kore/Chat/Transcript/TranscriptStore.swift b/Sources/Kore/Chat/Transcript/TranscriptStore.swift
        --- a/Sources/Kore/Chat/Transcript/TranscriptStore.swift
        +++ b/Sources/Kore/Chat/Transcript/TranscriptStore.swift
        @@ -40,3 +40,4 @@
             private var blocks: [String: UUID] = [:]
        -    private var tools: [String: Int] = [:]
        +    private var tools: [String: UUID] = [:]
        +    private var lanes: [String: [Entry]] = [:]
        """

    private static func agentsSample() -> TranscriptStore {
        let store = TranscriptStore()
        let now = Date()
        func tool(_ id: String, _ name: String, _ detail: String, input: String? = nil, summary: String? = nil,
                  path: String? = nil, out: String?, error: Bool = false, agent: String? = nil) {
            store.toolStarted(id: id, name: name, detail: detail, input: input, summary: summary, path: path, agent: agent)
            if let out { store.toolFinished(id: id, output: out, isError: error) }
        }
        store.user("Audit the transcript three ways in parallel, then summarise what to change.", attachments: [])
        store.turnStarted("t", at: now.addingTimeInterval(-95))
        store.text("th", .thinking, "Three independent questions: reads, scroll cost, tests. Spawn one agent each.")
        tool("m1", "Bash", "git status --short", input: "git status --short", summary: "Check the tree is clean",
             out: " M Sources/Kore/Chat/Chat.swift")

        // 1. Finished, open, with its own sub-agent.
        store.agentSpawned(id: "a1", name: "Map reads of entries", type: "Explore", model: "haiku", tool: nil,
                           at: now.addingTimeInterval(-90))
        tool("a1-1", "Read", "TranscriptStore.swift", input: "Sources/Kore/Chat/Transcript/TranscriptStore.swift:1-80",
             path: "/Users/dev/kore/Sources/Kore/Chat/Transcript/TranscriptStore.swift", out: "80 lines", agent: "a1")
        tool("a1-2", "Grep", "entries\\[ in Sources/Kore", input: "entries\\[  in Sources/Kore", out: "12 matches", agent: "a1")
        tool("a1-3", "Bash", "rg -c 'entries' Sources", input: "rg -c 'entries' Sources/Kore", summary: "Count reads per file",
             out: "Sources/Kore/Chat/Chat.swift:4\nSources/Kore/Chat/Transcript/TranscriptStore.swift:31", agent: "a1")
        store.agentSpawned(id: "a4", name: "Find entry writers", type: "Explore", model: "haiku", tool: nil,
                           parent: "a1", at: now.addingTimeInterval(-70))
        tool("a4-1", "Grep", "entries.append in Sources", input: "entries.append  in Sources/Kore", out: "3 matches", agent: "a4")
        store.agentFinished(id: "a4", status: .finished, result: "Only TranscriptStore appends; nothing else writes.",
                            at: now.addingTimeInterval(-62))
        tool("a1-4", "Edit", "TranscriptStore.swift", path: "/Users/dev/kore/Sources/Kore/Chat/Transcript/TranscriptStore.swift",
             out: nil, agent: "a1")
        store.fileChanged(tool: "a1-4", UnifiedDiff.files(smallEdit, root: folder))
        store.toolFinished(id: "a1-4", output: nil, isError: false)
        store.agentProgress(id: "a1", tokens: 18_240, tools: 6, lastTool: "Edit", duration: nil)
        store.agentFinished(id: "a1", status: .finished,
                            result: "Entries are read in three places: the store's row builder, the dump hook, and the gallery. Writes happen only in TranscriptStore.",
                            at: now.addingTimeInterval(-49))

        // 2. Running, closed: its latest command shows under the header.
        store.agentSpawned(id: "a2", name: "Check scroll performance", type: "general-purpose", model: "haiku", tool: nil,
                           at: now.addingTimeInterval(-88))
        tool("a2-1", "Read", "TranscriptTimeline.swift", path: "/Users/dev/kore/Sources/Kore/Chat/Transcript/TranscriptTimeline.swift",
             out: "112 lines", agent: "a2")
        tool("a2-2", "Bash", "swift build -c release", input: "swift build -c release", summary: "Build for timing", out: nil,
             agent: "a2")
        store.agentProgress(id: "a2", tokens: 7_900, tools: 2, lastTool: "Bash", duration: nil)

        tool("m2", "Grep", "laneAgents in Sources", input: "laneAgents  in Sources/Kore", out: "4 matches")

        // 3. Failed, open: its error is the last thing in its lane.
        store.agentSpawned(id: "a3", name: "Port tests to the timeline", type: "general-purpose", model: "haiku", tool: nil,
                           at: now.addingTimeInterval(-85))
        tool("a3-1", "Bash", "swift test", input: "swift test --filter Transcript", summary: "Run the transcript tests",
             out: "error: no such module 'XCTest'", error: true, agent: "a3")
        store.agentFinished(id: "a3", status: .failed, result: "Couldn't run the tests: XCTest isn't installed with the Command Line Tools.",
                            at: now.addingTimeInterval(-60))

        // 4. A Codex child, closed.
        store.agentSpawned(id: "a5", name: "count_lines", type: nil, model: "gpt-6-luna", tool: nil, at: now.addingTimeInterval(-58))
        tool("a5-1", "Bash", "wc -l a.txt", input: "wc -l a.txt", out: "3 a.txt", agent: "a5")
        store.agentFinished(id: "a5", status: .finished, result: "3", at: now.addingTimeInterval(-52))

        tool("m3", "Bash", "rg -n 'TODO' Sources", input: "rg -n 'TODO' Sources/Kore", summary: "Leftover TODOs", out: "(no matches)")
        store.text("ans", .answer, "Two of three agents are back; waiting on the scroll check before summarising.")

        for id in ["a1", "a4", "a3"] { store.toggle(agent: id) }
        return store
    }
}

