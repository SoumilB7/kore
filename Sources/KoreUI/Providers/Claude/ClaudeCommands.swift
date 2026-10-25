import Foundation
import KoreCore

/// Claude's commands (`ActiveCommand`), as `ClaudeTranslator` meets them:
/// - non-agent tasks: the `task_*` system events of a shell (`local_bash`) or a monitor, each
///   linked to the Bash or Monitor call that started it (`tool_use_id`) for its command and kind;
/// - in a transcript, which has no task events: the Bash or Monitor result naming its task, and
///   the `<task-notification>` that ended it;
/// - cron jobs: CronCreate and CronDelete calls (no task events), and the turns they fire.
/// The CLI's own stops come as `killed`: Kore's `stop_task` and the agent's TaskStop are told
/// apart by what asked first. Verified on haiku, 2026-10-25 (`cli-background-tasks`).
struct ClaudeCommands {
    private struct Call {
        let name: String
        let input: JSONValue
        let agent: AgentID
        let at: Date
    }

    private struct Tracked {
        var kind: ActiveCommand.Kind
        var owner: AgentID = .main
        var foreground: Bool
        var state: ActiveCommand.State = .running
        var toolId: String?
        /// A recurring job's prompt, expression and age limit; nil for a task.
        var job: (prompt: String, schedule: CronSchedule?, recurring: Bool, expires: Date?)?
    }

    /// The calls a command can come from or be ended by, by tool_use id.
    private var calls: [String: Call] = [:]
    private var tracked: [String: Tracked] = [:]
    /// Tasks Kore asked to stop, and those the agent's own TaskStop or KillShell named.
    private var stopAsked: Set<String> = []
    private var agentStops: Set<String> = []
    /// Kore asked the turn to stop: a foreground command killed meanwhile was interrupted.
    var interrupting = false

    static let commandTools: Set<String> = ["Bash", "Monitor", "CronCreate", "CronDelete", "TaskStop", "KillShell", "KillBash"]
    /// Recurring jobs fire one last time after this, then the CLI deletes them.
    static let jobLifetime: TimeInterval = 7 * 24 * 3600

    func knows(_ id: String) -> Bool { tracked[id] != nil }

    func isLive(_ id: String) -> Bool { tracked[id]?.state.isLive == true }

    /// The Bash call a live foreground command came from (what `background_tasks` takes).
    func toolId(of id: String) -> String? { tracked[id]?.toolId }

    // MARK: - Calls and results

    mutating func call(_ id: String, _ name: String, _ input: JSONValue, agent: AgentID, at: Date) {
        guard Self.commandTools.contains(name) else { return }
        calls[id] = Call(name: name, input: input, agent: agent, at: at)
        if ["TaskStop", "KillShell", "KillBash"].contains(name), let task = input["task_id"]?.string ?? input["shell_id"]?.string {
            agentStops.insert(task)
        }
    }

    /// A call's result. Live, a task's own events came first; in a transcript this is all there is.
    mutating func result(
        _ id: String, text: String, isError: Bool, result: JSONValue?, folder: URL, session: String?, at: Date,
        into out: inout [ChatEvent]
    ) {
        guard let call = calls[id] else { return }
        switch call.name {
        case "Bash":
            if let task = result?["backgroundTaskId"]?.string {
                let moved = result?["backgroundedByUser"]?.bool == true || result?["timedOutAfterMs"] != nil
                if tracked[task] == nil {
                    start(
                        task, kind: moved ? .foreground : .shell, title: Self.title(call.input), command: call.input["command"]?.string,
                        owner: call.agent, toolId: id, folder: folder, at: call.at, file: Self.outputPath(in: text), into: &out)
                }
                if moved { background(task, at: at, into: &out) }
                if let file = Self.outputPath(in: text) { out.append(.commandChanged(id: task, .outputFile(file))) }
            } else if let task = tracked.first(where: { $0.value.toolId == id && $0.value.foreground })?.key {
                // A long foreground command's call returned: its end, unless its task said it.
                let state: ActiveCommand.State =
                    !isError ? .completed
                    : text.hasPrefix(ClaudeTranslator.stoppedCall) ? .interrupted
                    : .failed(exit: Self.exitCode(in: text))
                end(task, state, at: at, into: &out)
            }
        case "Monitor":
            guard let task = result?["taskId"]?.string, tracked[task] == nil else { return }
            start(
                task, kind: .monitor, title: Self.title(call.input), command: call.input["command"]?.string, owner: call.agent,
                toolId: id, folder: folder, at: call.at, file: nil, into: &out)
        case "CronCreate":
            guard !isError, let job = result?["id"]?.string, tracked[job] == nil, let cron = call.input["cron"]?.string else { return }
            let prompt = call.input["prompt"]?.string ?? ""
            let recurring = result?["recurring"]?.bool ?? call.input["recurring"]?.bool ?? true
            let schedule = CronSchedule(cron)
            let expires = recurring ? call.at.addingTimeInterval(Self.jobLifetime) : nil
            tracked[job] = Tracked(kind: .scheduled, owner: call.agent, foreground: false, toolId: id, job: (prompt, schedule, recurring, expires))
            let title = prompt.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? prompt
            out.append(
                .commandStarted(
                    ActiveCommand(
                        id: job, kind: .scheduled, title: title, command: prompt, folder: folder.path, startedAt: call.at, owner: call.agent,
                        toolId: id,
                        schedule: ActiveCommand.Schedule(
                            cron: cron, human: result?["humanSchedule"]?.string, recurring: recurring,
                            durable: result?["durable"]?.bool ?? false, next: schedule?.next(after: call.at), expires: expires))))
        case "CronDelete":
            guard !isError, let job = call.input["id"]?.string ?? call.input["job_id"]?.string else { return }
            end(job, .deleted(by: .agent), at: at, into: &out)
        default:
            break
        }
    }

    // MARK: - Task events (live)

    /// A non-agent `task_started`: a shell or a monitor. Workflows and other task types aren't
    /// commands. `owner`: the agent a `parent_task_id` names.
    mutating func taskStarted(
        _ json: JSONValue, owner parentAgent: AgentID?, folder: URL, session: String?, at: Date, into out: inout [ChatEvent]
    ) {
        guard let task = json["task_id"]?.string, let type = json["task_type"]?.string, type == "local_bash" || type.hasPrefix("monitor")
        else { return }
        let tool = json["tool_use_id"]?.string
        let call = tool.flatMap { calls[$0] }
        if let known = tracked[task] {
            // Started again (a backgrounded task reports once more): only the move.
            if known.foreground, json["is_backgrounded"]?.bool == true { background(task, at: at, into: &out) }
            return
        }
        let kind: ActiveCommand.Kind =
            call?.name == "Monitor" || type.hasPrefix("monitor") ? .monitor
            : json["is_backgrounded"]?.bool == false ? .foreground : .shell
        let title = json["description"]?.string ?? call.map { Self.title($0.input) } ?? "Command"
        let file = session.map { ClaudeHistory.taskOutput(task: task, sessionId: $0, in: folder).path }
        start(
            task, kind: kind, title: title, command: call?.input["command"]?.string, owner: parentAgent ?? call?.agent ?? .main,
            toolId: tool, folder: folder, at: call?.at ?? at, file: file, into: &out)
    }

    mutating func taskUpdated(_ json: JSONValue, at: Date, into out: inout [ChatEvent]) {
        guard let task = json["task_id"]?.string, tracked[task] != nil, let patch = json["patch"] else { return }
        if patch["is_backgrounded"]?.bool == true { background(task, at: at, into: &out) }
        let ended = patch["end_time"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? at
        switch patch["status"]?.string {
        case "killed": end(task, stopped(task), at: ended, into: &out)
        case "completed": end(task, .completed, at: ended, into: &out)
        case "failed": end(task, .failed(exit: patch["error"]?.string.flatMap(Self.exitCode)), at: ended, into: &out)
        default: break
        }
    }

    /// A task's end as its notification says it (stdout's `task_notification`, or the
    /// `<task-notification>` a transcript keeps): the status, its summary's exit code, the file.
    /// A Monitor's events notify too, with no status.
    mutating func notification(task: String, status: String?, summary: String?, file: String?, at: Date, into out: inout [ChatEvent]) {
        guard tracked[task] != nil else { return }
        if let file { out.append(.commandChanged(id: task, .outputFile(file))) }
        guard let status else { return }
        if let summary { out.append(.commandChanged(id: task, .summary(summary))) }
        let lowered = summary?.lowercased() ?? ""
        let exit = summary.flatMap(Self.exitCode)
        let state: ActiveCommand.State
        switch status {
        case _ where lowered.contains("timed out"): state = .timedOut
        case "completed", "success": state = exit.map { $0 == 0 ? .completed : .failed(exit: $0) } ?? .completed
        case "failed", "error": state = .failed(exit: exit)
        case "stopped", "killed", "cancelled": state = stopped(task)
        default: return
        }
        end(task, state, at: at, into: &out)
    }

    /// `background_tasks_changed`: every live background task. One of ours missing from it ended
    /// unheard (its notification may still come, saying more).
    mutating func liveTasks(_ tasks: [String], at: Date, into out: inout [ChatEvent]) {
        let live = Set(tasks)
        for (id, command) in tracked.sorted(by: { $0.key < $1.key })
        where command.state.isLive && command.kind != .scheduled && !command.foreground && !live.contains(id) {
            end(id, .completed, at: at, into: &out)
        }
    }

    // MARK: - Jobs

    /// A turn a cron job fired (its prompt, the transcript's `turnOrigin: scheduled` entry): a
    /// recurring job goes on, past its age limit it has expired; a one-shot one has fired.
    mutating func fired(prompt: String, at: Date, into out: inout [ChatEvent]) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobs = tracked.compactMap { entry in entry.value.job.map { (id: entry.key, job: $0) } }
        guard let found = jobs.first(where: { isLive($0.id) && $0.job.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == prompt })
        else { return }
        let (id, job) = found
        if !job.recurring {
            end(id, .fired, at: at, into: &out)
        } else if let expires = job.expires, at >= expires {
            end(id, .expired, at: at, into: &out)
        } else {
            out.append(.commandChanged(id: id, .fired(at: at, next: job.schedule?.next(after: at))))
        }
    }

    // MARK: - Kore's actions and lifecycle

    mutating func stopRequested(_ id: String) { stopAsked.insert(id) }

    mutating func stopRefused(_ id: String) { stopAsked.remove(id) }

    /// A stop the CLI answered "not running": it had ended unheard, done.
    mutating func gone(_ id: String, at: Date, into out: inout [ChatEvent]) {
        guard isLive(id) else { return }
        end(id, .completed, at: at, into: &out)
    }

    /// A stopped turn: the foreground commands it ran end with it (background ones go on).
    mutating func turnInterrupted(at: Date, into out: inout [ChatEvent]) {
        interrupting = false
        for (id, command) in tracked.sorted(by: { $0.key < $1.key }) where command.state.isLive && command.foreground {
            end(id, .interrupted, at: at, into: &out)
        }
    }

    /// The CLI ended (or a replay did): what it ran ended with it, armed jobs too.
    mutating func endAll(at: Date, preserving observed: Set<String> = [], state: ActiveCommand.State = .ended, into out: inout [ChatEvent]) {
        for (id, command) in tracked.sorted(by: { $0.key < $1.key })
        where command.state.isLive && command.owner.sub.map(observed.contains) != true {
            end(id, state, at: at, into: &out)
        }
    }

    /// What `agents` ran, ended: work read from their last lines after their CLI ended.
    mutating func endAll(of agents: Set<String>, at: Date, into out: inout [ChatEvent]) {
        for (id, command) in tracked.sorted(by: { $0.key < $1.key })
        where command.state.isLive && command.owner.sub.map(agents.contains) == true {
            end(id, .ended, at: at, into: &out)
        }
    }

    // MARK: - Helpers

    private mutating func start(
        _ id: String, kind: ActiveCommand.Kind, title: String, command: String?, owner: AgentID, toolId: String?, folder: URL, at: Date,
        file: String?, into out: inout [ChatEvent]
    ) {
        tracked[id] = Tracked(kind: kind, owner: owner, foreground: kind == .foreground, toolId: toolId)
        out.append(
            .commandStarted(
                ActiveCommand(
                    id: id, kind: kind, title: title, command: command, folder: folder.path, startedAt: at, owner: owner, toolId: toolId,
                    output: file.map(ActiveCommand.Output.file) ?? .none)))
    }

    private mutating func background(_ id: String, at: Date, into out: inout [ChatEvent]) {
        guard var command = tracked[id], command.foreground, command.state.isLive else { return }
        command.foreground = false
        command.kind = .shell
        tracked[id] = command
        out.append(.commandChanged(id: id, .backgrounded(at: at)))
    }

    /// Ends it once. A later end says more only where the first knew less: a failure's exit
    /// code, or how one that vanished from the live set (read as done) really ended.
    private mutating func end(_ id: String, _ state: ActiveCommand.State, at: Date, into out: inout [ChatEvent]) {
        guard var command = tracked[id], command.state != state else { return }
        if !command.state.isLive {
            let refines =
                switch (command.state, state) {
                case (.failed(nil), .failed(_?)), (.completed, _): true
                default: false
                }
            guard refines else { return }
        }
        command.state = state
        command.foreground = false
        tracked[id] = command
        out.append(.commandEnded(id: id, state, at: at))
    }

    /// Killed: by Kore's stop, the agent's, an interrupt of the turn it waits in, or unknown.
    private func stopped(_ id: String) -> ActiveCommand.State {
        if stopAsked.contains(id) { return .stopped(by: .user) }
        if agentStops.contains(id) { return .stopped(by: .agent) }
        if interrupting, tracked[id]?.foreground == true { return .interrupted }
        return .stopped(by: .unknown)
    }

    private static func title(_ input: JSONValue) -> String {
        input["description"]?.string ?? input["command"]?.string ?? "Command"
    }

    /// "Exit code 137" (a Bash result), "(exit code 1)" (a notification's summary).
    static func exitCode(in text: String) -> Int? {
        guard let range = text.range(of: "exit code ", options: .caseInsensitive) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }

    /// The file a Bash result says its output goes to ("Output is being written to: <path>").
    static func outputPath(in text: String) -> String? {
        guard let range = text.range(of: "Output is being written to: ") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.range(of: ".output") else { return nil }
        return String(rest[..<end.upperBound])
    }
}
