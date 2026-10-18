import AppKit
import KoreUI

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


