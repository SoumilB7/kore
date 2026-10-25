import Foundation
import KoreCore

/// Kore's own vocabulary for what happens in a chat. Each provider's backend translates its
/// CLI into these, so nothing past `Providers/` knows which CLI is talking.
package enum ChatEvent: Sendable {
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
    /// Fast mode as the CLI reports it: when it starts, after each turn, and after a switch.
    case fastModeChanged(FastModeReport)

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
    /// Kore's own record of a message the user sent while a turn ran (`Chat` dispatches it): it
    /// waits at the transcript's end until its `.queuedMessage` says where it went.
    case messageQueued(id: String, text: String, attachments: [SentAttachment])

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
    /// A stopped or finished agent runs again (Claude's SendMessage, a Codex follow-up): the
    /// same agent, in its place, running.
    case agentResumed(id: String)
    /// One still running when the turn that spawned it ended runs on in the background (a Codex
    /// child thread; Claude says so at the spawn).
    case agentBackgrounded(id: String)

    // MARK: Commands

    /// A command the chat runs apart from its turn (`ActiveCommand`): a background shell, a long
    /// foreground command, a monitor, a scheduled job. In a replay, it's followed by its end.
    case commandStarted(ActiveCommand)
    case commandChanged(id: String, CommandChange)
    /// Output a running command printed (Codex streams it), appended.
    case commandOutput(id: String, String)
    /// How it ended. A later one for the same command says more (an exit code after "failed").
    case commandEnded(id: String, ActiveCommand.State, at: Date)

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
    /// the context ran full (`auto` true). `compacted`, `compactionFailed` or `compactionStopped`
    /// follows.
    case compactionStarted(auto: Bool)
    /// The summary a compaction left; the conversation goes on from it. Claude only (Codex's is
    /// encrypted), right after `.compacted`, live and in replay alike.
    case compactionSummary(String)
    case compactionFailed(String)
    /// The user's Stop ended the compaction before it was done: the conversation is as it was
    /// before it (no divider, no summary, the same context). Kore's, from how the CLI ended it.
    case compactionStopped
    /// The connection to the model, while a turn waits on it: offline (no network path), the
    /// CLI retrying a request that failed, or fine again.
    case connection(Connection)
    /// How full the context is: when the CLI comes up, after the main agent's model calls and after
    /// a compaction, and once in a replay (the last known value). Sent only when it changes.
    case contextUsage(ContextUsage)
    /// Older conversation exists before the history shown (before a compaction):
    /// `ChatBackend.earlier()` loads it.
    case earlierHistory(Bool)

    /// A resumed session's past, in order, as one event so it lands as one change.
    case replayed([ChatEvent])
    /// The history `replayed` showed, read again whole and found different (a long transcript's
    /// newest page is read from its end first): the transcript is built again from it, keeping
    /// what came after the replay.
    case historyReplaced([ChatEvent])
}

/// Who changed a mode.
package enum ModeSource: Sendable, Equatable {
    /// The mode a session started or resumed in: not a change anyone made.
    case session
    /// From Kore (the mode menu, Shift+Tab, `/plan`), or between turns in another client.
    case user
    /// The agent's doing, and why: which agent called the tool (main, or a sub-agent's id).
    case agent(ModeCause, AgentID)
    /// Kore asked for a mode and the CLI kept `mode` instead.
    case refused
}

package enum ModeCause: Sendable, Equatable {
    /// It started planning (Claude's EnterPlanMode).
    case enteredPlanMode
    /// Its plan was approved (Claude's ExitPlanMode accepted): plan mode left for the chosen mode.
    case planApproved
    /// The CLI changed it with no call Kore saw.
    case other
}

package struct ModeChange: Sendable, Equatable {
    /// The provider's mode id ("plan", "acceptEdits", "fullAccess", …).
    package let mode: String
    /// nil for the first mode a chat learns.
    package let previous: String?
    package let source: ModeSource
    /// The CLI's own time in replay (the transcript entry); when it was reported, live.
    package let at: Date

    package init(mode: String, previous: String?, source: ModeSource, at: Date) {
        self.mode = mode
        self.previous = previous
        self.source = source
        self.at = at
    }
}

package struct PlanModeChange: Sendable, Equatable {
    package let on: Bool
    package let source: ModeSource
    package let at: Date

    package init(on: Bool, source: ModeSource, at: Date) {
        self.on = on
        self.source = source
        self.at = at
    }
}

package struct ContextUsage: Sendable, Equatable {
    /// Tokens in context now.
    package let used: Int
    /// What the fill is measured against, as each CLI's own extension does: Claude's effective
    /// window (contextWindow − min(maxOutputTokens, 20k) − 13k, where it auto-compacts), Codex's
    /// model context window. nil until the CLI says.
    package let window: Int?
    /// The CLI compacts by itself when `used` reaches `window`; nil when it doesn't say.
    package let autoCompacts: Bool?
    package let at: Date
    /// Kore's estimate, not the CLI's reading (an imported chat before its first turn): shown
    /// with "~", and the CLI's first report replaces it.
    package var approximate = false

    package init(used: Int, window: Int?, autoCompacts: Bool?, at: Date) {
        self.used = used
        self.window = window
        self.autoCompacts = autoCompacts
        self.at = at
    }
}

/// Where a message sent while a turn ran went (`ChatBackend.send(_:files:queued:)`).
package enum QueuedDelivery: Sendable, Equatable {
    /// The CLI took it into the running turn, after `after` (the last main tool call or text
    /// block; nil when the turn had none yet).
    case inTurn(after: String?)
    /// It started this next turn (its `.turnStarted` follows, origin `.user`).
    case nextTurn(TurnID)
    /// Stop dropped it before the CLI took it: its text goes back to the composer.
    case dropped
}

package typealias TurnID = String
package typealias BlockID = String

/// Who produced something: the chat's own agent, or a sub-agent it spawned (Claude task id /
/// Codex child thread id).
package enum AgentID: Hashable, Sendable {
    case main
    case sub(String)
}

/// Why a turn started. `.cli` is a turn the CLI started itself whose cause isn't known yet.
package enum TurnOrigin: Sendable, Equatable {
    case user, cli, schedule, agentFinished, peer
}

package enum TextKind: Sendable, Equatable {
    case answer, thinking, plan
}

package enum TurnOutcome: Sendable, Equatable {
    case completed, interrupted
    case failed(String)
    /// The CLI's login was refused (Claude's `authentication_failed`, Codex's 401): the CLI's
    /// own line.
    case authFailed(String)
    /// The plan's limit was hit: the CLI's line, and when the limit resets when it said.
    case limited(String, resetsAt: Date?)
    /// It failed while the Mac slept, or just after it woke (`Chat` decides): the CLI's line.
    case slept(String)
}

/// A tool call, already worded for display.
package struct ToolCall: Sendable {
    /// Claude tool_use id / Codex item id.
    package let id: String
    /// "Bash", "Edit", "Run", "Search", "server.tool"…
    package let name: String
    /// The one input worth showing: a command, a path relative to the folder, a query.
    package let detail: String
    /// The whole input, for an expanded view: a full command, or the input pretty-printed.
    package var input: String? = nil
    /// The tool's own description of the call (Claude's Bash and Agent `description`).
    package var description: String? = nil
    /// The file a file tool works on (absolute).
    package var path: String? = nil
    /// Only reads, searches or lists: consecutive ones group into "Explored N".
    package var readOnly = false

    package init(id: String, name: String, detail: String, input: String? = nil, description: String? = nil, path: String? = nil, readOnly: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.input = input
        self.description = description
        self.path = path
        self.readOnly = readOnly
    }
}

/// An attachment as a transcript shows it. Images travel as bytes; views make thumbnails lazily.
package struct SentAttachment: Sendable {
    package let name: String
    package let kind: Attachment.Kind
    package let url: URL?
    package let image: Data?

    package init(name: String, kind: Attachment.Kind, url: URL?, image: Data?) {
        self.name = name
        self.kind = kind
        self.url = url
        self.image = image
    }
}

package struct ChatControls: Sendable {
    package var models: [ModelOption]
    package var model: String?
    package var effort: String?
    package var commands: [SlashCommand]

    package init(models: [ModelOption], model: String? = nil, effort: String? = nil, commands: [SlashCommand]) {
        self.models = models
        self.model = model
        self.effort = effort
        self.commands = commands
    }
}

package struct ModelOption: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let resolved: String
    package let efforts: [String]
    package var supportsAutoMode = false
    /// Claude's fast mode, Codex's fast service tier.
    package var supportsFastMode = false

    package init(
        id: String, name: String, resolved: String, efforts: [String], supportsAutoMode: Bool = false, supportsFastMode: Bool = false
    ) {
        self.id = id
        self.name = name
        self.resolved = resolved
        self.efforts = efforts
        self.supportsAutoMode = supportsAutoMode
        self.supportsFastMode = supportsFastMode
    }
}

/// Fast mode as the CLI says it is.
package struct FastModeReport: Sendable, Equatable {
    package var on: Bool
    /// On, at standard speed for now after a rate limit (Claude's cooldown).
    package var paused = false
    /// Whether the account can have it; nil when this report can't say, which keeps what an
    /// earlier one said.
    package var offered: Bool?
    /// A user-facing reason from the CLI's reported blocker, never its raw identifier.
    package var unavailable: String?

    package init(on: Bool, paused: Bool = false, offered: Bool?, unavailable: String? = nil) {
        self.on = on
        self.paused = paused
        self.offered = offered
        self.unavailable = unavailable
    }
}

/// An entry in the `/` menu. Picking it inserts `insertion` into the draft.
package struct SlashCommand: Identifiable, Hashable, Sendable {
    /// `kore`: Kore's own entries (Usage, Account), which open a popup and send the CLI nothing.
    package enum Kind: Sendable { case command, skill, kore }
    package let name: String
    package let description: String
    package let hint: String
    package let kind: Kind
    /// The SF Symbol drawn where the sigil goes (Kore's entries).
    package let glyph: String?
    package var id: String { name }
    /// Claude runs `/name`; Codex invokes skills by mentioning `$name`.
    package var insertion: String { kind == .skill ? "$\(name) " : "/\(name) " }

    package init(name: String, description: String, hint: String, kind: Kind, glyph: String? = nil) {
        self.name = name
        self.description = description
        self.hint = hint
        self.kind = kind
        self.glyph = glyph
    }

    /// What the command does in a few words, for the menu's row; the whole description is its
    /// tooltip. The CLIs' descriptions run to sentences ("Deep research harness — fan-out web
    /// searches, …"): the source tag goes, then everything after the first clause, then, while
    /// it is still long, everything from the first joining word.
    package var summary: String { Self.summary(of: description) }

    package static func summary(of description: String) -> String {
        var text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // "(plugin) Analyze …" and "… (user)": where it comes from, not what it does.
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        for stop in [" — ", " – ", " - ", ": ", "; ", ". ", " (", "\n"] {
            if let range = text.range(of: stop) { text = String(text[..<range.lowerBound]) }
        }
        if text.count > summaryLength {
            let joins = [" focused on ", " with ", " for ", " that ", " using ", " and ", " but ", " to ", " of ", " as ", " on ", " in ", " via ", " from ", ", "]
            let cuts = joins.compactMap { text.range(of: $0) }.filter { text.distance(from: text.startIndex, to: $0.lowerBound) >= 14 }
            if let first = cuts.min(by: { $0.lowerBound < $1.lowerBound }) { text = String(text[..<first.lowerBound]) }
        }
        while let last = text.last, ".,;:".contains(last) { text.removeLast() }
        return text.isEmpty ? description : text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Longer than this, a summary is cut at its first joining word.
    static let summaryLength = 32
}

// MARK: - Sub-agents

package struct AgentInfo: Sendable {
    package let id: String
    /// The agent whose tool call spawned it.
    package let parent: AgentID
    /// The spawning tool call (Claude's Agent tool_use, Codex's spawn item), where its card goes.
    package let toolId: String?
    /// What it was asked to do, in a few words (Claude's description, Codex's agent path).
    package let name: String
    /// Claude's subagent_type; nil for Codex.
    package let type: String?
    package let model: String?
    package let prompt: String?
    /// Runs on after its spawning call returns (Claude `run_in_background`). A Codex child thread
    /// becomes one when it outlives its parent's turn (`agentBackgrounded`).
    package let background: Bool

    package init(id: String, parent: AgentID, toolId: String?, name: String, type: String?, model: String?, prompt: String?, background: Bool) {
        self.id = id
        self.parent = parent
        self.toolId = toolId
        self.name = name
        self.type = type
        self.model = model
        self.prompt = prompt
        self.background = background
    }
}

package struct AgentProgress: Sendable {
    package var tokens: Int?
    package var tools: Int?
    package var duration: Duration?
    package var lastTool: String?
    /// Its tokens were read from its transcript, not reported (Claude's agents ended by their
    /// files): "~239k".
    package var approximate: Bool

    package init(
        tokens: Int? = nil, tools: Int? = nil, duration: Duration? = nil, lastTool: String? = nil, approximate: Bool = false
    ) {
        self.tokens = tokens
        self.tools = tools
        self.duration = duration
        self.lastTool = lastTool
        self.approximate = approximate
    }
}

package enum AgentStatus: Sendable, Equatable {
    case completed, failed, stopped
}

// MARK: - Approvals

/// Something the CLI waits on the user for: a permission, questions, or a plan.
package struct Approval: Identifiable, Sendable {
    package struct Option: Sendable {
        package let label: String
        package let description: String
        /// What picking it would look like (Claude's `preview`): monospace text, nil for none.
        package let preview: String?

        package init(label: String, description: String, preview: String? = nil) {
            self.label = label
            self.description = description
            self.preview = preview
        }
    }

    package struct Question: Sendable {
        package let id: String
        package let text: String
        /// The CLI's short name for it (`header`), for the card's tabs; empty when it sent none.
        package let header: String
        package let options: [Option]
        /// Any number of options can be picked (Claude's multiSelect).
        package let multiple: Bool
        /// What's typed is hidden as it's typed (a Codex secret).
        package let secret: Bool
        /// It takes a typed answer, Other (always for Claude; Codex's isOther).
        package let other: Bool

        package init(
            id: String, text: String, header: String = "", options: [Option], multiple: Bool = false, secret: Bool = false,
            other: Bool = true
        ) {
            self.id = id
            self.text = text
            self.header = header
            self.options = options
            self.multiple = multiple
            self.secret = secret
            self.other = other || options.isEmpty
        }

        /// Its tab's name: the header, else the question's first words, else "Q<n>".
        package func tabName(_ index: Int) -> String {
            let header = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if !header.isEmpty { return header }
            var name = ""
            for word in text.split(whereSeparator: \.isWhitespace) {
                if !name.isEmpty && name.count + word.count >= Self.tabNameMax { break }
                name += (name.isEmpty ? "" : " ") + word
            }
            name = name.trimmingCharacters(in: .punctuationCharacters)
            return name.isEmpty ? "Q\(index + 1)" : name
        }

        /// A header-less tab's name stops at about this many characters, on a word.
        static let tabNameMax = 16
    }

    package let id: String
    package let title: String
    package let detail: String?
    package let body: String?
    package let canAlwaysAllow: Bool
    /// Non-empty means render as a question card.
    package let questions: [Question]
    /// Set for Claude's ExitPlanMode: the plan awaiting "Ready to code?".
    package var plan: String? = nil
    /// The edit being asked about, when it is one.
    package var changes: [FileChange] = []
    /// A sub-agent asking, for the card's header.
    package var agent: AgentID = .main
    /// A sign-in or an MCP server's own request: Kore never answers it for the user.
    package var signIn = false

    package init(id: String, title: String, detail: String?, body: String?, canAlwaysAllow: Bool, questions: [Question], plan: String? = nil, changes: [FileChange] = [], agent: AgentID = .main) {
        self.id = id
        self.title = title
        self.detail = detail
        self.body = body
        self.canAlwaysAllow = canAlwaysAllow
        self.questions = questions
        self.plan = plan
        self.changes = changes
        self.agent = agent
    }

    /// A plain permission (a command, tool, file or web access): not a plan, questions or a sign-in.
    package var isPermission: Bool { plan == nil && questions.isEmpty && !signIn }
}

package enum Decision: Sendable {
    case allow, allowAlways, deny
    /// Claude's "Ready to code?": approve the plan, optionally switching to Accept edits.
    case approvePlan(autoAcceptEdits: Bool)
    case keepPlanning
    /// Keyed by `Approval.Question.id`: the options picked, or what was typed under Other.
    case answers([String: [String]])
}

/// How a turn's connection to its model stands (`ChatEvent.connection`).
package enum Connection: Sendable, Equatable {
    case ok
    case offline
    /// The CLI's own retry of a request that failed: which try of how many, when it says.
    case retrying(attempt: Int?, of: Int?)
    /// Online, waiting on the model, and nothing heard for `Chat.stallAfter` (Kore's watchdog):
    /// the connection likely died without the CLI noticing.
    case stalled
    /// A tool/agent is still marked running, but has been quiet. This offers a manual escape
    /// without claiming a long-running command has failed or stopping it automatically.
    case quietWork

    /// What the running turn's spinner says for it; nil when fine.
    var word: String? {
        switch self {
        case .ok: nil
        case .offline: "Offline · waiting for the network"
        case .retrying(let attempt?, let of?): "Connection unstable · retrying (\(attempt) of \(of))"
        case .retrying: "Connection unstable · retrying"
        case .stalled: "No response · the connection may have dropped"
        case .quietWork: "No recent updates · work may still be running"
        }
    }

    /// Offline or stalled: the spinner holds still and the tab shows ⚠. Retrying is the CLI at
    /// work, and keeps moving.
    var stuck: Bool { self == .offline || self == .stalled }
}
