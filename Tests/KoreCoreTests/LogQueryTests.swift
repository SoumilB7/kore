import AgentTools
import Foundation
import Testing

@testable import KoreCore

/// `kore logs` over fixture logs: every log merged by time, picked by age, chat, turn, level and
/// log, the old line shape still read, the `--since` forms, and a line `KoreLog` writes read back.
struct LogQueryTests {
    static let sessions = """
        2026-11-14T10:00:00.000Z info started cli=claude chat=4fb9acc6-c3f2 pid=81546 launch=resume
        2026-11-14T10:00:05.000Z warn connection cli=claude chat=4fb9acc6-c3f2 turn=a91f03 state=stalled quiet=95
        2026-11-14T10:00:09.500Z info turn id=a91f03 chat=4fb9acc6-c3f2 cli=claude model=haiku outcome=completed dur_ms=9500 tools=3 agents=1 in_tok=12 out_tok=480
        2026-11-14T10:00:20.000Z error start-failed cli=codex chat=01a15a98 launch=new cause=missing
        """
    static let agents = """
        2026-11-14T10:00:03.000Z info spawned cli=claude chat=4fb9acc6-c3f2 turn=a91f03 agent=toolu_01 mode=foreground parent=main
        2026-11-14T10:00:08.000Z info status cli=claude chat=4fb9acc6-c3f2 turn=a91f03 agent=toolu_01 from=running to=done source="task update"
        """
    /// The shape before levels: a tab after the time.
    static let ui = "2026-11-14T09:59:59.000Z\twindow-key folder=kore\n2026-11-14T10:00:30.000Z warn stall ms=412 busy=430 tab=chat last_event=options-open\n"
    static let hosts = "2026-11-14T10:00:10.000Z info send expired host=mybox\n"

    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("korelogs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.sessions.write(to: folder.appendingPathComponent("sessions.log"), atomically: true, encoding: .utf8)
        try Self.agents.write(to: folder.appendingPathComponent("agents.log.1"), atomically: true, encoding: .utf8)
        try Self.ui.write(to: folder.appendingPathComponent("ui.log"), atomically: true, encoding: .utf8)
        try Self.hosts.write(to: folder.appendingPathComponent("hosts.log"), atomically: true, encoding: .utf8)
        try "not a log".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    private func events(_ lines: [LogQuery.Line]) -> [String] { lines.map { "\($0.log):\($0.event)" } }

    @Test func everyLogMergesByTime() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let all = LogQuery.read(folder, LogQuery.Filter())
        #expect(
            events(all) == [
                "ui:window-key", "sessions:started", "agents:spawned", "sessions:connection", "agents:status", "sessions:turn", "hosts:send expired",
                "sessions:start-failed", "ui:stall",
            ])
        // The old shape: info, its event and fields.
        #expect(all[0].level == "info" && all[0].field("folder") == "kore")
        #expect(all[4].field("source") == "task update")
    }

    @Test func aTurnIsItsOwnLineAndEveryLineThatCarriedIt() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let turn = LogQuery.read(folder, LogQuery.Filter(turn: "a91f03"))
        #expect(events(turn) == ["agents:spawned", "sessions:connection", "agents:status", "sessions:turn"])
        #expect(turn.last?.field("dur_ms") == "9500" && turn.last?.field("out_tok") == "480")
    }

    @Test func aChatByItsIdsStart() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(LogQuery.read(folder, LogQuery.Filter(chat: "01a1")).map(\.event) == ["start-failed"])
        #expect(LogQuery.read(folder, LogQuery.Filter(chat: "4fb9")).count == 5)
    }

    @Test func aLevelAndUp() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(LogQuery.read(folder, LogQuery.Filter(level: "warn")).map(\.event) == ["connection", "start-failed", "stall"])
        #expect(LogQuery.read(folder, LogQuery.Filter(level: "error")).map(\.event) == ["start-failed"])
    }

    @Test func sinceAndOneLog() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = ISO8601DateFormatter().date(from: "2026-11-14T10:00:30Z")!
        #expect(LogQuery.read(folder, LogQuery.Filter(since: LogQuery.since("21s", now: now))).map(\.event) == ["turn", "send expired", "start-failed", "stall"])
        #expect(LogQuery.read(folder, LogQuery.Filter(logs: ["hosts"])).map(\.event) == ["send expired"])
        #expect(LogQuery.since("10m", now: now) == now - 600)
        #expect(LogQuery.since("2h", now: now) == now - 7200)
        #expect(LogQuery.since("3d", now: now) == now - 3 * 86400)
        #expect(LogQuery.since("2026-11-14T10:00:00Z") == now - 30)
        #expect(LogQuery.since("soon") == nil)
    }

    @Test func jsonCarriesTheFields() throws {
        let line = try #require(LogQuery.parse(#"2026-11-14T10:00:08.000Z info status agent=toolu_01 source="task \"update\"""#, log: "agents"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(LogQuery.json(line).utf8)) as? [String: String])
        #expect(object == ["ts": "2026-11-14T10:00:08.000Z", "level": "info", "log": "agents", "event": "status", "agent": "toolu_01", "source": #"task "update""#])
        #expect(LogQuery.shown(line, timeZone: TimeZone(identifier: "UTC")!) == #"11-14 10:00:08.000 info  agents status agent=toolu_01 source="task \"update\"""#)
    }

    /// What `KoreLog` writes, `kore logs` reads back as it was said.
    @Test func aWrittenLineReadsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("korelogs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = KoreLog(url: folder.appendingPathComponent("sessions.log"), level: .debug)
        log.write(.warn, "turn", ["id": "a91f03", "via": #"a "b" \c = d"#, "outcome": "failed"])
        log.sync()
        let lines = LogQuery.read(folder, LogQuery.Filter())
        #expect(lines.count == 1)
        #expect(lines.first?.level == "warn")
        #expect(lines.first?.event == "turn")
        #expect(lines.first?.fields.map { "\($0.0)=\($0.1)" } == ["id=a91f03", #"via=a "b" \c = d"#, "outcome=failed"])
    }
}
