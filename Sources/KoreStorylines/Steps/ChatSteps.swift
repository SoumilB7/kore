import Foundation
import KoreUI

// Chat steps. Each does what its control does (Send, Stop, an approval card's buttons, a Fork
// button) through the chat's own calls; once the controls can be pressed by identifier, the
// steps press them and storylines don't change.

extension StoryContext {
    /// The active chat's events since the storyline began.
    package func chatEvents(_ chat: Chat? = nil) -> [ChatEvent] {
        guard let id = (chat ?? app.chat)?.id else { return [] }
        return events.filter { $0.chat == id }.map(\.event)
    }

    /// The active chat, or a failure naming what's missing.
    package func activeChat() throws -> Chat {
        guard let chat = app.chat else { throw StoryFailure.modelMissing("a chat in the active tab") }
        return chat
    }
}

/// Sets what the scripted CLI plays for the chats this storyline starts. Set it before the chat
/// connects (before `StartChat`'s chat sends).
package struct UseScript: Step {
    let script: CLIScript
    let provider: String?
    package var label: String { "Use the script" + (provider.map { " for \($0)" } ?? "") }
    package init(_ script: CLIScript, for provider: String? = nil) {
        self.script = script
        self.provider = provider
    }

    package func run(_ story: StoryContext) async throws {
        if let provider { ScriptedWorld.shared.scripts[provider] = script } else { ScriptedWorld.shared.script = script }
    }
}

/// Types a message and sends it, as the composer's Send does; waits until the chat shows it.
package struct Send: Step {
    let text: String
    package var label: String { "Send “\(text)”" }
    package init(_ text: String) { self.text = text }

    package func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        chat.storySend(text)
        try await story.until("“\(text)” in the chat") {
            story.chatEvents(chat).contains { event in
                switch event {
                case .userMessage(let body, _, _), .messageQueued(_, let body, _): body == text
                default: false
                }
            }
        }
    }
}

/// Sends while a turn runs: the message waits as queued until the CLI takes it.
package struct Queue: Step {
    let text: String
    package var label: String { "Queue “\(text)”" }
    package init(_ text: String) { self.text = text }

    package func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        guard chat.isRunning else { throw StoryFailure.expectation("a turn running to queue behind") }
        chat.storySend(text)
        try await story.until("“\(text)” queued") {
            story.chatEvents(chat).contains { if case .messageQueued(_, let body, _) = $0 { body == text } else { false } }
        }
    }
}

/// Presses Stop.
package struct Stop: Step {
    package var label: String { "Press Stop" }
    package init() {}
    package func run(_ story: StoryContext) async throws { try story.activeChat().storyStop() }
}

/// Waits until the active chat has finished `n` turns since the storyline began.
package struct TurnFinished: Step {
    let n: Int
    package var label: String { "Wait for turn \(n) to finish" }
    package init(_ n: Int = 1) { self.n = n }

    package func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        try await story.until("turn \(n) to finish") {
            story.chatEvents(chat).filter { if case .turnFinished = $0 { true } else { false } }.count >= n
        }
    }
}

/// Waits for an approval card and answers it.
package struct Answer: Step {
    package enum Choice: String, Sendable { case allow, always, deny }
    let choice: Choice
    package var label: String { "Answer the approval: \(choice.rawValue)" }
    package init(_ choice: Choice) { self.choice = choice }

    package func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        let approval = try await story.wait("an approval card") { chat.pendingApprovals.first }
        let decision: Decision = switch choice {
        case .allow: .allow
        case .always: .allowAlways
        case .deny: .deny
        }
        chat.storyAnswer(approval, decision)
        try await story.until("the card to go") { !chat.pendingApprovals.contains { $0.id == approval.id } }
    }
}

/// A Fork button: from the nth user message, or through the nth answer's turn. Waits for the
/// fork's tab and its history.
package struct Fork: Step {
    enum From { case message(Int), answer(Int) }
    let from: From
    package var label: String {
        switch from {
        case .message(let n): "Fork from message \(n)"
        case .answer(let n): "Fork from answer \(n)"
        }
    }

    package static func fromMessage(_ n: Int) -> Fork { Fork(from: .message(n)) }
    package static func fromAnswer(_ n: Int) -> Fork { Fork(from: .answer(n)) }

    package func run(_ story: StoryContext) async throws {
        guard let workspace = story.app.workspace else { throw StoryFailure.modelMissing("the folder's workspace") }
        let original = try story.activeChat()
        let tabs = workspace.tabs.count
        let forked: Bool = switch from {
        case .message(let n): await workspace.storyFork(original, message: n)
        case .answer(let n): await workspace.storyFork(original, answer: n)
        }
        guard forked else { throw StoryFailure.modelMissing(label.lowercased()) }
        let fork = try await story.wait("the fork's tab") {
            workspace.tabs.count == tabs + 1 ? workspace.activeTab.chat.flatMap { $0 === original ? nil : $0 } : nil
        }
        // A fork from the first message is a fresh chat, with no history to read back.
        if case .message(1) = from { return }
        try await story.until("the fork's history") {
            story.chatEvents(fork).contains { if case .replayed = $0 { true } else { false } }
        }
    }
}

extension Expect {
    /// A check on the active chat's rows.
    package static func rows(_ what: String, _ check: @escaping @MainActor ([StoryRow]) -> Bool) -> Expect {
        Expect(what) { story in check(try story.activeChat().rows) }
    }
}

/// Picks a mode in the mode menu; waits until the composer shows it.
package struct SetMode: Step {
    let id: String
    package var label: String { "Switch the mode to \(id)" }
    package init(_ id: String) { self.id = id }

    package func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        chat.storySetMode(id)
        try await story.until("the mode \(id)") { chat.mode == id }
    }
}

/// Clicks the context wheel to compact; waits for the compaction to finish.
package struct Compact: Step {
    package var label: String { "Compact with the context wheel" }
    package init() {}

    package func run(_ story: StoryContext) async throws {
        let chat = try story.activeChat()
        chat.storyCompact()
        try await story.until("the compaction to finish") {
            !chat.isCompacting && story.chatEvents(chat).contains { if case .compacted = $0 { true } else { false } }
        }
    }
}

extension StoryContext {
    /// The scripted backend of the active chat (`--cli scripted`).
    package func scriptedBackend() throws -> ScriptedBackend {
        let chat = try activeChat()
        guard let backend = ScriptedWorld.shared.backend(session: chat.sessionId) else {
            throw StoryFailure.modelMissing("a scripted backend for this chat")
        }
        return backend
    }
}
