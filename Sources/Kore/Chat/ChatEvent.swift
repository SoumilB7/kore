import Foundation
import KoreCore

/// Kore's own vocabulary for what happens in a chat. Each provider's backend translates its
/// CLI into these, so nothing past `Providers/` knows which CLI is talking.
enum ChatEvent: Sendable {
    // MARK: Session

    /// Claude session id / Codex thread id: what `--resume` / `thread/resume` takes.
    case sessionIdentified(String)
    /// A title the CLI generated (Claude, after the first prompt).
    case titleChanged(String)
    /// Models, current model and effort, and `/` commands, once the CLI has started.
    case controlsLoaded(ChatControls)
    /// The CLI reported or switched its mode itself (e.g. after a plan is approved).
    case modeChanged(String)
    /// Providers with a plan toggle apart from their modes (Codex).
    case planModeChanged(Bool)

    // MARK: Turns

    case turnStarted(TurnID, origin: TurnOrigin, at: Date)
    /// The cause of a `.cli` turn, once the transcript shows it.
    case turnOrigin(TurnID, TurnOrigin)
    /// `turn` is nil when the CLI ended a turn Kore never saw start. `duration` is the CLI's own
    /// measure when it gives one.
    case turnFinished(TurnID?, TurnOutcome, duration: Duration?)
    /// Every file the turn changed, at its end: a git snapshot diff in git repos, else what the
    /// CLI reported.
    case turnChanges(TurnID, [FileChange])

    // MARK: Transcript

    /// The user's own message. `Chat` dispatches it at send time; backends emit it only in replay.
    case userMessage(text: String, attachments: [SentAttachment])
    /// A message from another session, placed where `turn` began (at the end when nil).
    case peerMessage(from: String, text: String, turn: TurnID?)
    /// Appends to the block, creating it if the id is new.
    case text(BlockID, TextKind, String, agent: AgentID = .main)
    /// The block is where the turn's final answer starts: what's before it is the turn's work.
    case finalAnswer(BlockID, agent: AgentID = .main)
    case toolStarted(ToolCall, agent: AgentID = .main)
    /// Live output, appended.
    case toolOutput(id: String, String, agent: AgentID = .main)
    /// `output` nil keeps what streamed.
    case toolFinished(id: String, output: String?, isError: Bool, agent: AgentID = .main)
    /// Files a tool call changed (an edit, a write, a Codex file change).
    case fileChanged(toolId: String, [FileChange], agent: AgentID = .main)
    case notice(String, isError: Bool = false)

    // MARK: Sub-agents

    case agentSpawned(AgentInfo)
    case agentProgress(id: String, AgentProgress)
    case agentFinished(id: String, AgentStatus, result: String?)

    // MARK: Approvals

    case approvalRequested(Approval)
    case approvalWithdrawn(String)
    /// The turn proposed a plan to implement (Codex Plan mode): offer "Implement this plan?".
    case planReady

    // MARK: Process

    /// The CLI process ended. The next send relaunches it and resumes the session.
    case exited(status: Int32)

    /// A resumed session's past, in order, as one event so it lands as one change.
    case replayed([ChatEvent])
}

typealias TurnID = String
typealias BlockID = String

/// Who produced something: the chat's own agent, or a sub-agent it spawned (Claude task id /
/// Codex child thread id).
enum AgentID: Hashable, Sendable {
    case main
    case sub(String)
}

/// Why a turn started. `.cli` is a turn the CLI started itself whose cause isn't known yet.
enum TurnOrigin: Sendable, Equatable {
    case user, cli, schedule, agentFinished, peer
}

enum TextKind: Sendable, Equatable {
    case answer, thinking, plan
}

enum TurnOutcome: Sendable, Equatable {
    case completed, interrupted
    case failed(String)
}

/// A tool call, already worded for display.
struct ToolCall: Sendable {
    /// Claude tool_use id / Codex item id.
    let id: String
    /// "Bash", "Edit", "Run", "Search", "server.tool"…
    let name: String
    /// The one input worth showing: a command, a path relative to the folder, a query.
    let detail: String
    /// The whole input, for an expanded view: a full command, or the input pretty-printed.
    var input: String? = nil
    /// The tool's own description of the call (Claude's Bash and Agent `description`).
    var description: String? = nil
    /// The file a file tool works on (absolute).
    var path: String? = nil
}

/// An attachment as a transcript shows it. Images travel as bytes; views make thumbnails lazily.
struct SentAttachment: Sendable {
    let name: String
    let kind: Attachment.Kind
    let url: URL?
    let image: Data?
}

struct ChatControls: Sendable {
    var models: [ModelOption]
    var model: String?
    var effort: String?
    var commands: [SlashCommand]
}

struct ModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let resolved: String
    let efforts: [String]
    var supportsAutoMode = false
}

/// An entry in the `/` menu. Picking it inserts `insertion` into the draft.
struct SlashCommand: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case command, skill }
    let name: String
    let description: String
    let hint: String
    let kind: Kind
    var id: String { name }
    /// Claude runs `/name`; Codex invokes skills by mentioning `$name`.
    var insertion: String { kind == .skill ? "$\(name) " : "/\(name) " }
}

// MARK: - Sub-agents

struct AgentInfo: Sendable {
    let id: String
    /// The agent whose tool call spawned it.
    let parent: AgentID
    /// The spawning tool call (Claude's Agent tool_use, Codex's spawn item), where its card goes.
    let toolId: String?
    /// What it was asked to do, in a few words (Claude's description, Codex's agent path).
    let name: String
    /// Claude's subagent_type; nil for Codex.
    let type: String?
    let model: String?
    let prompt: String?
    /// Runs on after its spawning call returns (Claude `run_in_background`).
    let background: Bool
}

struct AgentProgress: Sendable {
    var tokens: Int?
    var tools: Int?
    var duration: Duration?
    var lastTool: String?
}

enum AgentStatus: Sendable, Equatable {
    case completed, failed, stopped
}

// MARK: - Approvals

/// Something the CLI waits on the user for: a permission, questions, or a plan.
struct Approval: Identifiable, Sendable {
    struct Option: Sendable {
        let label: String
        let description: String
    }

    struct Question: Sendable {
        let id: String
        let text: String
        let options: [Option]
    }

    let id: String
    let title: String
    let detail: String?
    let body: String?
    let canAlwaysAllow: Bool
    /// Non-empty means render as a question card.
    let questions: [Question]
    /// Set for Claude's ExitPlanMode: the plan awaiting "Ready to code?".
    var plan: String? = nil
    /// The edit being asked about, when it is one.
    var changes: [FileChange] = []
    /// A sub-agent asking, for the card's header.
    var agent: AgentID = .main
}

enum Decision: Sendable {
    case allow, allowAlways, deny
    /// Claude's "Ready to code?": approve the plan, optionally switching to Accept edits.
    case approvePlan(autoAcceptEdits: Bool)
    case keepPlanning
    /// Keyed by `Approval.Question.id`.
    case answers([String: String])
}
