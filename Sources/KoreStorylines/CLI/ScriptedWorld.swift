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
    /// What a session had before its compaction, by session id: a resume offers it as the
    /// earlier conversation, one page.
    package var earlier: [String: [ChatEvent]] = [:]
    private var made = 0
    /// The forks the scripted CLI lists in a folder's history, by session id: as the real ones
    /// do, Codex's from when the fork opens, Claude's from its first message.
    private(set) var listed: [String: (provider: String, folder: String, title: String)] = [:]
    /// Each import's history as Kore gave it to the scripted CLI, oldest first.
    package private(set) var imports: [(provider: String, plan: HandoffPlan, target: HandoffTarget)] = []

    /// Makes every chat's backend a scripted one.
    package func install() {
        StorylineSeams.backend = { [unowned self] provider, options in
            let backend = ScriptedBackend(provider: provider, options: options, script: scripts[provider] ?? script, world: self)
            backend.rate = rate
            backends.append(backend)
            return backend
        }
        HandoffWriters.standIns.value = Dictionary(uniqueKeysWithValues: HandoffWriters.all.map { ($0.id, ScriptedHandoffWriter(real: $0)) })
        // Claude's own list is the run's store; a real Codex would list the owner's threads.
        StorylineSeams.sessions = { [unowned self] provider, folder in
            let path = folder.standardizedFileURL.path
            let extra = listed.filter { $0.value.provider == provider && $0.value.folder == path }.map { id, chat in
                SessionSummary(id: id, agent: provider == "codex" ? .codex : .claude, title: chat.title, updated: .now)
            }
            return (own: provider != "codex", extra: extra)
        }
    }

    /// A session the scripted CLI now lists (named `title` unless it has a name already).
    func list(_ id: String, provider: String, folder: URL, title: String) {
        guard listed[id] == nil else { return }
        listed[id] = (provider, folder.standardizedFileURL.path, title)
    }

    /// A rename, as the CLI saves it.
    func retitle(_ id: String, _ title: String) {
        listed[id]?.title = title
    }

    /// The backend of the chat with this session id (`Chat.status.sessionId`).
    package func backend(session id: String?) -> ScriptedBackend? {
        backends.last { $0.sessionId == id && id != nil }
    }

    /// Back to no chats, no sessions, the echo script.
    package func reset() {
        backends = []
        sessions = [:]
        listed = [:]
        imports = []
        scripts = [:]
        script = .echo
        rate = nil
    }

    func newSession(_ provider: String) -> String {
        made += 1
        return "scripted-\(provider)-\(made)"
    }

    /// An import's new session: empty, as Kore shows the carried part from its own record.
    func imported(_ provider: String, _ plan: HandoffPlan, _ target: HandoffTarget) -> HandoffWritten {
        let id = newSession(provider)
        sessions[id] = []
        imports.append((provider, plan, target))
        return HandoffWritten(session: id)
    }

    /// A session's history up to (not including) event `at` (`ForkPoint.at`).
    func history(of session: String, through at: String) -> [ChatEvent] {
        let events = sessions[session] ?? []
        return Array(events.prefix(min(Int(at) ?? events.count, events.count)))
    }
}

/// The scripted CLI's side of an import, in place of the real CLI's writer: its window and
/// instruction files are the real one's, the history goes to `ScriptedWorld`.
struct ScriptedHandoffWriter: HandoffWriter {
    let real: any HandoffWriter
    var id: String { real.id }
    var product: String { real.product }
    var company: String { real.company }
    var overhead: Int { real.overhead }
    var instructionFiles: [String] { real.instructionFiles }

    func window(model: String?) -> Int { real.window(model: model) }

    func write(_ plan: HandoffPlan, into target: HandoffTarget) async throws -> HandoffWritten {
        let id = id
        return await MainActor.run { ScriptedWorld.shared.imported(id, plan, target) }
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
