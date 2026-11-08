import Foundation

/// A command a chat runs apart from its turn's own tool rows: a background shell, a long
/// foreground command, a monitor, a scheduled job. Each CLI's backend says what it learns of one
/// in the same words (`ChatEvent.commandStarted` and the rest); `CommandsStore` keeps them.
/// Codex's in-turn commands, Claude's short foreground calls and workflows are never ones.
package struct ActiveCommand: Identifiable, Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        /// Run in the background (Claude's `run_in_background`, a Codex terminal that outlived its
        /// turn), or a foreground one moved there.
        case shell
        /// A Claude command its call waits on, long enough that the CLI registered it as a task.
        case foreground
        /// Claude's Monitor (and its MCP and WebSocket kinds).
        case monitor
        /// A Claude cron job: it fires its prompt into the chat.
        case scheduled
    }

    /// Who stopped or deleted it.
    package enum Actor: Sendable, Equatable {
        /// From Kore.
        case user
        /// The agent's own call (Claude's TaskStop or KillShell, CronDelete).
        case agent
        /// History doesn't say.
        case unknown
    }

    package enum State: Sendable, Equatable {
        /// Running; a scheduled job is armed.
        case running
        /// Exited 0, or ended well with no exit code given.
        case completed
        /// Exited non-zero; nil when the CLI said it failed without a code.
        case failed(exit: Int?)
        case stopped(by: Actor)
        /// Ended by an interrupt of its turn (Esc, or Stop on the turn).
        case interrupted
        case timedOut
        /// The chat's CLI ended with it running, or history recorded no end.
        case ended
        /// A one-shot job that has fired.
        case fired
        case deleted(by: Actor)
        /// A recurring job past the CLI's age limit.
        case expired

        package var isLive: Bool { self == .running }
    }

    /// Where its output can be read.
    package enum Output: Sendable, Equatable {
        case none
        /// A file the CLI writes it to (Claude's task output).
        case file(String)
        /// Streamed to Kore (Codex's output deltas), kept bounded in `CommandsStore`.
        case stream
    }

    /// Codex's own process for it.
    package struct Process: Sendable, Equatable {
        /// What `backgroundTerminals/terminate` takes.
        package var id: String
        package var osPid: Int?
        package var cpuPercent: Double?
        package var memoryKB: Int?

        package init(id: String, osPid: Int? = nil, cpuPercent: Double? = nil, memoryKB: Int? = nil) {
            self.id = id
            self.osPid = osPid
            self.cpuPercent = cpuPercent
            self.memoryKB = memoryKB
        }
    }

    /// A scheduled job's timing.
    package struct Schedule: Sendable, Equatable {
        /// The 5-field expression, and the CLI's own wording of it ("Every minute").
        package var cron: String
        package var human: String?
        package var recurring: Bool
        /// Kept across the CLI's restarts (written to its scheduled tasks file).
        package var durable: Bool
        package var next: Date?
        package var lastFired: Date?
        /// When a recurring job ages out: it fires once more, then it's deleted.
        package var expires: Date?

        package init(
            cron: String, human: String? = nil, recurring: Bool, durable: Bool = false, next: Date? = nil, lastFired: Date? = nil,
            expires: Date? = nil
        ) {
            self.cron = cron
            self.human = human
            self.recurring = recurring
            self.durable = durable
            self.next = next
            self.lastFired = lastFired
            self.expires = expires
        }
    }

    /// Claude task id / Codex item id / Claude cron job id.
    package let id: String
    package var kind: Kind
    /// Claude's description; Codex's command; a job's prompt.
    package var title: String
    package var command: String?
    package var folder: String?
    package var startedAt: Date?
    /// The nearest agent that started it: `.main` for the chat itself, never an ancestor. A
    /// scheduled job is always the chat's.
    package var owner: AgentID
    /// The tool call that started it (Claude's Bash or Monitor call, Codex's item): its row in the
    /// transcript, and what Claude's `background_tasks` takes.
    package var toolId: String?
    package var state: State = .running
    package var endedAt: Date?
    /// A foreground command moved to the background (by Kore, Ctrl+B elsewhere, or its own
    /// timeout): when. Its kind is `.shell` from then on.
    package var backgroundedAt: Date?
    package var output: Output = .none
    /// When it last printed, as far as Kore has seen.
    package var lastOutputAt: Date?
    package var process: Process?
    package var schedule: Schedule?
    /// The CLI's own line on how it ended ("… completed (exit code 0)").
    package var summary: String?
    /// Kore asked to stop it and the CLI hasn't confirmed yet.
    package var stopping = false
    /// The last action on it failed: its line, readable ("Couldn't stop it: …"). Cleared when
    /// the row changes state or is acted on again.
    package var failure: String?

    package init(
        id: String, kind: Kind, title: String, command: String? = nil, folder: String? = nil, startedAt: Date?, owner: AgentID,
        toolId: String? = nil, output: Output = .none, process: Process? = nil, schedule: Schedule? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.command = command
        self.folder = folder
        self.startedAt = startedAt
        self.owner = kind == .scheduled ? .main : owner
        self.toolId = toolId
        self.output = output
        self.process = process
        self.schedule = schedule
    }

    package var isLive: Bool { state.isLive }

    /// Stop applies (a job is deleted instead, which Kore has no direct way to do).
    package var canStop: Bool { isLive && kind != .scheduled }

    /// Only a long foreground command can be sent to the background.
    package var canBackground: Bool { isLive && kind == .foreground }

    /// How long it ran; nil while it runs, or when its start or end isn't known.
    package var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// What a backend learns about a command after its start.
package enum CommandChange: Sendable, Equatable {
    /// A foreground command now runs in the background.
    case backgrounded(at: Date)
    /// Codex's process for it: its id, and pid, CPU and memory as `backgroundTerminals/list` gives them.
    case process(ActiveCommand.Process)
    /// The file its output goes to.
    case outputFile(String)
    /// A scheduled job fired; `next` is when it fires again.
    case fired(at: Date, next: Date?)
    /// The CLI's line about it.
    case summary(String)
    /// Kore asked the CLI to stop it.
    case stopping
    /// Kore's action on it failed (a stop, a move to the background): the line to show, readable.
    case actionFailed(String)
}
