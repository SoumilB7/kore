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
        guard mode == "timeline" || mode == "changes" else { return false }
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
}
