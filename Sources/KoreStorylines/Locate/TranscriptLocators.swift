import Foundation
import KoreUI

// Locators for the active chat's transcript (phase 12, §3), counted as the user sees them:
// 1-based, in order. Each resolves through the transcript store to the row's StoryID and, when
// the row isn't built (above the window, or folded away), brings it into view from the model side.

extension Locator {
    /// The final answer of the active chat's `turn`-th turn.
    package static func answer(turn: Int) -> Locator {
        entry("answer \(turn)") { transcript in
            let turns = transcript.turns
            guard turns.indices.contains(turn - 1) else { return .failure(LocatorMiss("answer \(turn): the chat has \(turns.count) turns")) }
            let id = turns[turn - 1]
            guard let answer = transcript.entries.last(where: { $0.turn == id && $0.kind == .answer }) else {
                return .failure(LocatorMiss("answer \(turn): turn \(id) has no answer yet"))
            }
            return .success((answer.id, StoryID.Transcript.answer(answer.id)))
        }
    }

    /// The `n`-th message the user sent in the active chat.
    package static func userMessage(_ n: Int) -> Locator {
        entry("message \(n)") { transcript in
            let messages = transcript.entries.filter { $0.kind == .user }
            guard messages.indices.contains(n - 1) else { return .failure(LocatorMiss("message \(n): the chat has \(messages.count) messages")) }
            return .success((messages[n - 1].id, StoryID.Transcript.user(messages[n - 1].id)))
        }
    }

    /// The fold ("Worked for …") of the active chat's `turn`-th turn.
    package static func fold(turn: Int) -> Locator {
        entry("turn \(turn)'s fold") { transcript in
            let turns = transcript.turns
            guard turns.indices.contains(turn - 1) else { return .failure(LocatorMiss("turn \(turn): the chat has \(turns.count) turns")) }
            let id = turns[turn - 1]
            guard let first = transcript.entries.first(where: { $0.turn == id }) else { return .failure(LocatorMiss("turn \(turn) has no rows")) }
            return .success((first.id, StoryID.Transcript.fold(id)))
        }
    }

    /// The card of the sub-agent with this name (its description, as the card shows it).
    package static func agentCard(name: String) -> Locator {
        entry("agent “\(name)”") { transcript in
            let agents = transcript.entries.filter { $0.kind == .agent }
            guard let agent = agents.last(where: { $0.agentName == name }), let id = agent.agentID else {
                let names = agents.compactMap(\.agentName)
                return .failure(LocatorMiss("agent “\(name)”: the chat's agents are \(names.isEmpty ? "none" : names.joined(separator: ", "))"))
            }
            return .success((agent.id, StoryID.Transcript.agent(id)))
        }
    }

    /// The row of the `n`-th tool call named `tool` (Bash, Read, …) in the active chat.
    package static func tool(_ tool: String, _ n: Int = 1) -> Locator {
        entry("\(tool) call \(n)") { transcript in
            let calls = transcript.entries.filter { $0.kind == .tool && $0.toolName == tool }
            guard calls.indices.contains(n - 1) else { return .failure(LocatorMiss("\(tool) call \(n): the chat has \(calls.count)")) }
            let call = calls[n - 1]
            return .success((call.id, StoryID.Transcript.tool(call.toolID ?? call.id.uuidString)))
        }
    }

    /// A transcript locator: `find` names the entry to reveal and the element's id.
    private static func entry(
        _ description: String, _ find: @escaping @MainActor (StoryTranscript) -> Result<(UUID, StoryID), LocatorMiss>
    ) -> Locator {
        Locator(
            description,
            key: { app in
                guard let chat = app.chat else { return .failure(LocatorMiss("\(description): the active tab has no chat")) }
                return find(chat.storyTranscript).map(\.1)
            },
            reveal: { app in
                guard let transcript = app.chat?.storyTranscript, case .success(let (entry, _)) = find(transcript) else { return }
                transcript.show(entry)
            })
    }
}
