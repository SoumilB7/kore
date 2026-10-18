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
    /// The mode changed (Claude permission mode / Codex permissions preset), with who changed it.
    /// Sent only when it differs from the last one, live and in replay.
    case modeChanged(ModeChange)
    /// Providers with a plan toggle apart from their modes (Codex).
    case planModeChanged(PlanModeChange)

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

    /// A message Kore sent while a turn ran, by the id Kore gave it: where the CLI took it.
    case queuedMessage(id: String, QueuedDelivery)

    /// The user's own message. `Chat` dispatches it at send time; backends emit it only in replay.
    case userMessage(text: String, attachments: [SentAttachment], id: String? = nil)
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
    /// The call ended because the turn was stopped: no output, not a failure.
    case toolStopped(id: String, agent: AgentID = .main)
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

    /// The conversation was compacted here: a divider over its summary. `from`: the tokens in
    /// context before (Claude's `pre_tokens`). `auto`: the CLI compacted by itself (true) or was
    /// asked to (false); nil when unknown (a replayed Codex compaction). Also ends
    /// `compactionStarted`.
    case compacted(at: Date, from: Int? = nil, auto: Bool? = nil)
    /// The CLI started compacting: on `ChatBackend.compact()` (`auto` false), or by itself when
    /// the context ran full (`auto` true). `compacted` or `compactionFailed` follows.
    case compactionStarted(auto: Bool)
    /// The summary a compaction left; the conversation goes on from it. Claude only (Codex's is
    /// encrypted), right after `.compacted`, live and in replay alike.
    case compactionSummary(String)
    case compactionFailed(String)
    /// How full the context is: when the CLI comes up, after the main agent's model calls and after
    /// a compaction, and once in a replay (the last known value). Sent only when it changes.
    case contextUsage(ContextUsage)
    /// Older conversation exists before the history shown (before a compaction):
    /// `ChatBackend.earlier()` loads it.
    case earlierHistory(Bool)

    /// A resumed session's past, in order, as one event so it lands as one change.
    case replayed([ChatEvent])
}

/// Who changed a mode.
enum ModeSource: Sendable, Equatable {
    /// The mode a session started or resumed in: not a change anyone made.
    case session
    /// From Kore (the mode menu, Shift+Tab, `/plan`), or between turns in another client.
    case user
    /// The agent's doing, and why: which agent called the tool (main, or a sub-agent's id).
    case agent(ModeCause, AgentID)
    /// Kore asked for a mode and the CLI kept `mode` instead.
    case refused
}

enum ModeCause: Sendable, Equatable {
    /// It started planning (Claude's EnterPlanMode).
    case enteredPlanMode
    /// Its plan was approved (Claude's ExitPlanMode accepted): plan mode left for the chosen mode.
    case planApproved
    /// The CLI changed it with no call Kore saw.
    case other
}

struct ModeChange: Sendable, Equatable {
    /// The provider's mode id ("plan", "acceptEdits", "fullAccess", …).
    let mode: String
    /// nil for the first mode a chat learns.
    let previous: String?
    let source: ModeSource
    /// The CLI's own time in replay (the transcript entry); when it was reported, live.
    let at: Date
}

struct PlanModeChange: Sendable, Equatable {
    let on: Bool
    let source: ModeSource
    let at: Date
}

struct ContextUsage: Sendable, Equatable {
    /// Tokens in context now.
    let used: Int
    /// What the fill is measured against, as each CLI's own extension does: Claude's effective
    /// window (contextWindow − min(maxOutputTokens, 20k) − 13k, where it auto-compacts), Codex's
    /// model context window. nil until the CLI says.
    let window: Int?
    /// The CLI compacts by itself when `used` reaches `window`; nil when it doesn't say.
    let autoCompacts: Bool?
    let at: Date
}

/// Where a message sent while a turn ran went (`ChatBackend.send(_:files:queued:)`).
enum QueuedDelivery: Sendable, Equatable {
    /// The CLI took it into the running turn, after `after` (the last main tool call or text
    /// block; nil when the turn had none yet).
    case inTurn(after: String?)
    /// It started this next turn (its `.turnStarted` follows, origin `.user`).
    case nextTurn(TurnID)
    /// Stop dropped it before the CLI took it: its text goes back to the composer.
    case dropped
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
    /// Only reads, searches or lists: consecutive ones group into "Explored N".
    var readOnly = false
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
