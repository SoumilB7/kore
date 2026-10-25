import Foundation
import KoreCore
import Testing

@testable import KoreUI

@MainActor
@Suite("Codex terminal polling")
struct CodexTerminalPollingTests {
    private let owner = AgentID.main

    private func item(status: String = "inProgress") -> CodexItem {
        CodexItem([
            "id": "i1", "type": "commandExecution", "status": .string(status),
            "processId": "31", "command": "sleep 60", "exitCode": 0,
        ])
    }

    private func runningCommands() -> CodexCommands {
        var commands = CodexCommands()
        commands.started(item(), agent: owner, at: .now)
        var events: [ChatEvent] = []
        commands.turnCompleted(agent: owner, folder: URL(fileURLWithPath: "/tmp"), at: .now, into: &events)
        return commands
    }

    private func terminal(process: String = "31", pid: Int = 4242, cpu: Double = 1.5, memory: Int = 2048) -> JSONValue {
        [
            "itemId": "i1", "processId": .string(process), "osPid": .number(Double(pid)),
            "cpuPercent": .number(cpu), "rssKb": .number(Double(memory)),
        ]
    }

    /// Unchanged successful lists used to emit commandChanged every time, keeping the backend's
    /// pending-event check true and restarting its 10/30/60/120-second backoff at 10 seconds.
    @Test func repeatedTerminalSnapshotsProduceNoPollingNews() {
        var commands = runningCommands()
        var events: [ChatEvent] = []
        commands.listed([terminal()], owner: owner, at: .now, into: &events)
        #expect(events.count == 1)
        events = []
        for _ in 0..<5 {
            commands.listed([terminal()], owner: owner, at: .now, into: &events)
            #expect(events.isEmpty)
        }
        #expect(commands.hasLive)
    }

    @Test func changedProcessDetailsAreAnnouncedImmediately() {
        var commands = runningCommands()
        let states = [
            ActiveCommand.Process(id: "31", osPid: 4242, cpuPercent: 1.5, memoryKB: 2048),
            ActiveCommand.Process(id: "31", osPid: 4243, cpuPercent: 1.5, memoryKB: 2048),
            ActiveCommand.Process(id: "31", osPid: 4243, cpuPercent: 2, memoryKB: 2048),
            ActiveCommand.Process(id: "31", osPid: 4243, cpuPercent: 2, memoryKB: 4096),
            ActiveCommand.Process(id: "32", osPid: 4243, cpuPercent: 2, memoryKB: 4096),
        ]
        for state in states {
            var events: [ChatEvent] = []
            let snapshot = terminal(process: state.id, pid: state.osPid!, cpu: state.cpuPercent!, memory: state.memoryKB!)
            commands.listed([snapshot], owner: owner, at: .now, into: &events)
            let changed = events.compactMap { event -> ActiveCommand.Process? in
                if case .commandChanged("i1", .process(let process)) = event { process } else { nil }
            }
            #expect(changed == [state])
        }
        #expect(commands.terminal("i1")?.process == "32")
    }

    @Test func missingTelemetryIsStableToo() {
        var commands = runningCommands()
        var events: [ChatEvent] = []
        let snapshot: JSONValue = ["itemId": "i1", "processId": "31"]
        commands.listed([snapshot], owner: owner, at: .now, into: &events)
        #expect(events.count == 1)
        events = []
        commands.listed([snapshot], owner: owner, at: .now, into: &events)
        #expect(events.isEmpty)
    }

    @Test func anUnchangedPresentTerminalResetsItsMissingListCount() {
        var commands = runningCommands()
        var events: [ChatEvent] = []
        commands.listed([terminal()], owner: owner, at: .now, into: &events)
        events = []
        commands.listed([], owner: owner, at: .now, into: &events)
        commands.listed([terminal()], owner: owner, at: .now, into: &events)
        #expect(events.isEmpty)
        commands.listed([], owner: owner, at: .now, into: &events)
        #expect(events.isEmpty)
        #expect(commands.hasLive)
        commands.listed([], owner: owner, at: .now, into: &events)
        #expect(events.contains { if case .commandEnded("i1", .completed, _) = $0 { true } else { false } })
        #expect(!commands.hasLive)
    }

    @Test func completionStillEndsACommandAfterRepeatedUnchangedLists() {
        var commands = runningCommands()
        var events: [ChatEvent] = []
        commands.listed([terminal()], owner: owner, at: .now, into: &events)
        events = []
        commands.listed([terminal()], owner: owner, at: .now, into: &events)
        commands.completed(item(status: "completed"), at: .now, into: &events)
        #expect(events.count == 1)
        #expect(events.contains { if case .commandEnded("i1", .completed, _) = $0 { true } else { false } })
        #expect(!commands.hasLive)
        events = []
        commands.listed([terminal()], owner: owner, at: .now, into: &events)
        #expect(events.isEmpty)
    }
}
