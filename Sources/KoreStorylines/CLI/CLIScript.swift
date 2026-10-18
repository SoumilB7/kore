import Foundation
import KoreCore
import KoreUI

/// What the scripted CLI does in one chat (phase 12, package C): what it plays when the chat
/// starts, on each send, on a compaction, and for each sub-agent's card. `ScriptedBackend` plays
/// it, one beat per main run-loop pass and no timers, so a storyline's waits see every event in
/// order.
package struct CLIScript: Sendable {
    /// After `start()`: the chat's controls (models, effort, commands), then anything else.
    package var start: [Beat]
    /// The nth send plays the nth entry; sends past the last play the last again (`reply("OK")`
    /// when there are none).
    package var turns: [[Beat]]
    /// `compact()` (the context wheel, or a typed /compact).
    package var compact: [Beat]
    /// A sub-agent's card, by agent id (`ChatBackend.agentHistory`).
    package var agents: [String: [ChatEvent]]
    /// What the CLI answers when Kore reads the account's limits (the usage popup); nil: it fails.
    package var usage: UsageAnswer?

    package init(
        start: [Beat] = [.controls()], turns: [[Beat]] = [], compact: [Beat] = CLIScript.compaction(), agents: [String: [ChatEvent]] = [:],
        usage: UsageAnswer? = nil
    ) {
        self.start = start
        self.turns = turns
        self.compact = compact
        self.agents = agents
        self.usage = usage
    }

    /// Every send answered with one line of text.
    package static let echo = CLIScript()

    /// A compaction as both CLIs report one when asked.
    package static func compaction(summary: String = "The conversation so far, in brief.") -> [Beat] {
        [.event(.compactionStarted(auto: false)), .event(.compacted(at: Date(), auto: false)), .event(.compactionSummary(summary))]
    }
}

/// The replies a CLI sends when Kore reads the account and its limits, as it sends them: Kore
/// parses them with its own code.
package enum UsageAnswer: Sendable {
    /// `initialize`'s `account`, and the `get_usage` control request's answer.
    case claude(account: JSONValue, usage: JSONValue)
    /// `account/read`'s and `account/rateLimits/read`'s results; `account/rateLimitResetCredit/consume`'s
    /// (nil: it fails), and the limits read after a reset.
    case codex(account: JSONValue, rateLimits: JSONValue, consume: JSONValue? = nil, afterReset: JSONValue? = nil)
}

/// One step of a script.
package enum Beat: Sendable {
    /// One event, as is.
    case event(ChatEvent)
    /// Text arriving the way a model streams it: `chunk` characters a pass, in a block of its own.
    case stream(TextKind, String, chunk: Int = 8, agent: AgentID = .main)
    /// Opens the turn the current send started (`.turnStarted`, origin `.user`).
    case startTurn
    /// Ends it.
    case finishTurn(TurnOutcome)
    /// A tool call that starts, then finishes with `output`. `wait` holds it running until Kore
    /// makes that call (`.interrupt`: Stop), then it ends as stopped.
    case tool(name: String, detail: String, output: String? = nil, isError: Bool = false, wait: Call? = nil)
    /// Pauses the script until Kore makes the call. The call is in `ScriptedBackend.log` either way.
    case wait(Call)
    /// Asks for an approval and waits for the answer: `allow` plays for allow or always, `deny`
    /// for deny.
    case approval(Approval, allow: [Beat], deny: [Beat])
    /// A message Kore queued while this turn runs goes into it, after the last tool or text
    /// (Claude at a tool boundary, Codex's steer). Waits for the queued send if none came yet.
    case takeQueued
    /// An edit tool that writes `content` to `path` (relative to the chat's folder) for real, and
    /// reports it: `.fileChanged` on its row, and the turn's `.turnChanges` once it finishes.
    case fileEdit(path: String, content: String)
    /// A sub-agent: its card, what it says (streamed, tagged with its id), and how it ends. Its
    /// card's history (`agentHistory`) is what it said.
    case agent(id: String, name: String, says: String, result: String? = "Done")
    /// How full the context is.
    case context(used: Int, window: Int? = 200_000)

    /// The answer, streamed, marked final.
    package static func answer(_ text: String) -> [Beat] {
        [.stream(.answer, text)]
    }

    /// The chat's controls for a provider: a cheap model and the efforts both CLIs offer.
    package static func controls(model: String = "haiku") -> Beat {
        .event(.controlsLoaded(ChatControls(
            models: [ModelOption(id: model, name: model.capitalized, resolved: model, efforts: ["low", "medium", "high"])],
            model: model, effort: "medium", commands: [])))
    }
}

extension CLIScript {
    /// A whole turn: start, the answer streamed, finish.
    package static func reply(_ text: String) -> [Beat] {
        [.startTurn] + Beat.answer(text) + [.finishTurn(.completed)]
    }
}

/// What Kore asks of the backend, as the script waits for it and the log records it.
package enum Call: Sendable, Equatable {
    case send(String)
    /// A send made while a turn ran (the composer's queue): its text.
    case queued(String)
    case interrupt
    case respond(approval: String, allowed: Bool)
    case setMode(String)
    case setPlanMode(Bool)
    case setModel(String)
    case setEffort(String)
    case rename(String)
    case stopAgent(String)
    case compact
    /// The usage popup read the account's limits.
    case usage
    /// The usage popup used a full reset: the credit it named.
    case useReset(credit: String?)
    case fork(message: String?)
    /// Not Kore's: a test's go-ahead (`ScriptedBackend.release()`), to hold a script mid-way.
    case release

    /// Whether a call matches what a `.wait` names: the same kind, and for sends and agents the
    /// same text or id when the wait names one (an empty text matches any).
    func satisfies(_ wanted: Call) -> Bool {
        switch (self, wanted) {
        case (.send(let a), .send(let b)), (.queued(let a), .queued(let b)): b.isEmpty || a == b
        case (.stopAgent(let a), .stopAgent(let b)): b.isEmpty || a == b
        case (.respond(let a, _), .respond(let b, _)): a == b
        default: self == wanted
        }
    }
}
