import Foundation
import KoreCore
import KoreUI

/// The scripted CLI for a whole run: which script each new chat plays, every backend made (with
/// its call log), and each session's history, so resuming or forking a scripted session replays
/// what it played.
@MainActor
package final class ScriptedWorld {
    package static let shared = ScriptedWorld()

    /// The script for chats started from here on, by provider id ("claude", "codex"); `script`
    /// for any other.
    package var scripts: [String: CLIScript] = [:]
    package var script = CLIScript.echo
    /// Text deltas a second for new chats (`CLIScript.feed`); nil: one a run-loop pass.
    package var rate: Double?

    /// Every backend made, oldest first.
    package private(set) var backends: [ScriptedBackend] = []
    /// What each session played, by session id.
    var sessions: [String: [ChatEvent]] = [:]
    private var made = 0

    /// Makes every chat's backend a scripted one.
    package func install() {
        StorylineSeams.backend = { [unowned self] provider, options in
            let backend = ScriptedBackend(provider: provider, options: options, script: scripts[provider] ?? script, world: self)
            backend.rate = rate
            backends.append(backend)
            return backend
        }
    }

    /// The backend of the chat with this session id (`Chat.status.sessionId`).
    package func backend(session id: String?) -> ScriptedBackend? {
        backends.last { $0.sessionId == id && id != nil }
    }

    /// Back to no chats, no sessions, the echo script.
    package func reset() {
        backends = []
        sessions = [:]
        scripts = [:]
        script = .echo
        rate = nil
    }

    func newSession(_ provider: String) -> String {
        made += 1
        return "scripted-\(provider)-\(made)"
    }

    /// A session's history up to (not including) event `at` (`ForkPoint.at`).
    func history(of session: String, through at: String) -> [ChatEvent] {
        let events = sessions[session] ?? []
        return Array(events.prefix(min(Int(at) ?? events.count, events.count)))
    }
}

extension CLIScript {
    /// A Claude session from its transcript, played as if it were streaming (what `KORE_FEED`
    /// does): all but the last `turns` user turns replay at once, then those stream. Pair it
    /// with `ScriptedWorld.rate` to stream at a fixed pace, as the bench does.
    package static func feed(claudeSession id: String, folder: URL, turns: Int = 3) async -> CLIScript {
        let all = await Task.detached {
            let page = ClaudeHistory.page(sessionId: id, in: folder)
            return ClaudeTranslator(folder: folder, sessionId: id).replay(page.messages)
        }.value
        let starts = all.indices.filter { if case .turnStarted = all[$0] { true } else { false } }
        let first = turns <= 0 ? all.count : starts.count >= turns ? starts[starts.count - turns] : starts.first ?? all.count
        let split = min(max(first, 0), all.count)
        let streamed: [Beat] = all[split...].map { event in
            if case .text(_, let kind, let text, let agent) = event { .stream(kind, text, agent: agent) } else { .event(event) }
        }
        return CLIScript(start: [.controls(), .event(.replayed(Array(all[..<split])))] + streamed)
    }
}
