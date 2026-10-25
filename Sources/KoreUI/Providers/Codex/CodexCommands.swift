import Foundation
import KoreCore

/// Codex's commands (`ActiveCommand`): background terminals. A `commandExecution` item is the
/// turn's own tool row while its turn runs; one still running when its thread's turn completes
/// outlived it and becomes a row, kept by its thread (the chat's, or a child's). Its end is its
/// `item/completed`, which comes even after the turn; `thread/backgroundTerminals/list` keeps
/// the rows true (and would give CPU and memory, null so far). Read back, an item that ran longer
/// than its turn was one. Verified on gpt-6-luna, 2026-10-25 (`cli-background-tasks`).
struct CodexCommands {
    private struct Item {
        let command: String
        let cwd: String?
        let process: String
        let owner: AgentID
        let at: Date
    }

    /// In-turn items with a process, still running.
    private var running: [String: Item] = [:]
    /// Rows: item id → its process, owner and whether it still runs.
    private var rows: [String: (process: String, owner: AgentID, live: Bool)] = [:]
    /// Last process state announced by a list. An unchanged list must let polling back off.
    private var listedProcesses: [String: ActiveCommand.Process] = [:]
    /// Lists in a row a live row was missing from.
    private var missing: [String: Int] = [:]
    private var stopAsked: Set<String> = []

    func isRow(_ id: String) -> Bool { rows[id] != nil }

    /// The live rows' owners, whose lists to read.
    var liveOwners: Set<AgentID> { Set(rows.values.filter(\.live).map(\.owner)) }

    var hasLive: Bool { rows.values.contains(where: \.live) }

    /// What `terminate` takes for a live row.
    func terminal(_ id: String) -> (process: String, owner: AgentID)? {
        rows[id].flatMap { $0.live ? ($0.process, $0.owner) : nil }
    }

    mutating func started(_ item: CodexItem, agent: AgentID, at: Date) {
        guard item.type == "commandExecution", item.status == "inProgress", let process = item.raw["processId"]?.string else { return }
        running[item.id] = Item(
            command: CodexTranslator.command(item.raw) ?? item.command ?? "", cwd: item.raw["cwd"]?.string, process: process,
            owner: agent, at: at)
    }

    mutating func completed(_ item: CodexItem, at: Date, into out: inout [ChatEvent]) {
        guard item.type == "commandExecution" else { return }
        running[item.id] = nil
        guard let row = rows[item.id], row.live else { return }
        end(item.id, Self.state(status: item.status, exit: item.exitCode, stopAsked: stopAsked.contains(item.id)), at: at, into: &out)
    }

    /// A thread's turn completed: what it still runs outlived it.
    mutating func turnCompleted(agent: AgentID, folder: URL, at: Date, into out: inout [ChatEvent]) {
        for (id, item) in running.sorted(by: { $0.key < $1.key }) where item.owner == agent {
            running[id] = nil
            rows[id] = (item.process, item.owner, true)
            listedProcesses[id] = nil
            out.append(
                .commandStarted(
                    ActiveCommand(
                        id: id, kind: .shell, title: item.command, command: item.command, folder: item.cwd ?? folder.path,
                        startedAt: item.at, owner: item.owner, toolId: id, output: .stream, process: ActiveCommand.Process(id: item.process)))
            )
        }
    }

    /// A thread's `backgroundTerminals/list`: the process of each row, and a row missing from two
    /// lists in a row ended unheard. Terminals of commands still in a turn aren't rows.
    mutating func listed(_ terminals: [JSONValue], owner: AgentID, at: Date, into out: inout [ChatEvent]) {
        var seen: Set<String> = []
        for terminal in terminals {
            guard let id = terminal["itemId"]?.string, let row = rows[id], row.live else { continue }
            seen.insert(id)
            missing[id] = nil
            let process = ActiveCommand.Process(
                id: terminal["processId"]?.string ?? row.process, osPid: terminal["osPid"]?.int, cpuPercent: terminal["cpuPercent"]?.double,
                memoryKB: terminal["rssKb"]?.int)
            guard listedProcesses[id] != process else { continue }
            listedProcesses[id] = process
            rows[id] = (process.id, row.owner, true)
            out.append(.commandChanged(id: id, .process(process)))
        }
        for (id, row) in rows.sorted(by: { $0.key < $1.key }) where row.live && row.owner == owner && !seen.contains(id) {
            missing[id, default: 0] += 1
            if missing[id]! >= 2 { end(id, .completed, at: at, into: &out) }
        }
    }

    mutating func stopRequested(_ id: String) { stopAsked.insert(id) }

    mutating func stopRefused(_ id: String) { stopAsked.remove(id) }

    /// `terminate` answered that it wasn't running: it ended unheard, done.
    mutating func gone(_ id: String, at: Date, into out: inout [ChatEvent]) {
        guard rows[id]?.live == true else { return }
        end(id, .completed, at: at, into: &out)
    }

    /// The app-server ended: its processes did too.
    mutating func endAll(at: Date, into out: inout [ChatEvent]) {
        running = [:]
        for (id, row) in rows.sorted(by: { $0.key < $1.key }) where row.live { end(id, .ended, at: at, into: &out) }
    }

    /// A read-back turn's item: one that ran longer than its turn outlived it, a row ended as it
    /// was recorded (a thread keeps only ended ones; started when its turn did, as near as known).
    mutating func replayed(_ item: CodexItem, turnStart: Date, turnDuration: Int?, owner: AgentID, folder: URL, into out: inout [ChatEvent]) {
        guard item.type == "commandExecution", let duration = item.raw["durationMs"]?.int, let turnDuration, duration > turnDuration,
            item.status != "declined", rows[item.id] == nil
        else { return }
        let command = CodexTranslator.command(item.raw) ?? item.command ?? ""
        rows[item.id] = (item.raw["processId"]?.string ?? "", owner, false)
        out.append(
            .commandStarted(
                ActiveCommand(
                    id: item.id, kind: .shell, title: command, command: command, folder: item.raw["cwd"]?.string ?? folder.path,
                    startedAt: turnStart, owner: owner, toolId: item.id, output: .none)))
        let state = item.status == "inProgress" ? .ended : Self.state(status: item.status, exit: item.exitCode, stopAsked: false)
        out.append(.commandEnded(id: item.id, state, at: turnStart.addingTimeInterval(Double(duration) / 1000)))
    }

    private mutating func end(_ id: String, _ state: ActiveCommand.State, at: Date, into out: inout [ChatEvent]) {
        guard let row = rows[id], row.live else { return }
        rows[id] = (row.process, row.owner, false)
        listedProcesses[id] = nil
        missing[id] = nil
        stopAsked.remove(id)
        out.append(.commandEnded(id: id, state, at: at))
    }

    /// Codex's ending: completed is exit 0; failed with exit -1 was killed (`terminate`, an
    /// interrupt), anything else exited non-zero.
    private static func state(status: String?, exit: Int?, stopAsked: Bool) -> ActiveCommand.State {
        if status == "completed" { return exit.map { $0 == 0 ? .completed : .failed(exit: $0) } ?? .completed }
        if exit == -1 { return .stopped(by: stopAsked ? .user : .unknown) }
        return exit == 0 ? .completed : .failed(exit: exit)
    }
}
