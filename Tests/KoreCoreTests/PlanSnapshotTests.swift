import Foundation
import Testing

@testable import KoreCore

/// The plan's windows as each CLI reports them in passing, the log Kore keeps of them, and the
/// list of Kore's own sessions.
@Suite("Plan snapshots")
struct PlanSnapshotTests {
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func claudesRateLimitEventGivesBothWindows() throws {
        let json = try JSONValue.parse(
            Data(
                #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1792659000,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.03,"resetsAt":1792659000},"seven_day":{"utilization":0.37,"resetsAt":1792702800}}},"session_id":"s"}"#
                    .utf8))
        let snapshot = try #require(PlanSnapshot.claude(rateLimitEvent: json, account: "abc"))
        #expect(snapshot.cli == "claude" && snapshot.source == "stream" && snapshot.account == "abc")
        #expect(snapshot.windows.map(\.minutes) == [300, 10080])
        #expect(abs(snapshot.windows[0].used - 3) < 1e-9)
        #expect(abs(snapshot.windows[1].used - 37) < 1e-9)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_792_659_000))
        #expect(snapshot.windows[0].start == Date(timeIntervalSince1970: 1_792_659_000 - 5 * 3600))
        // Anything else isn't one.
        #expect(PlanSnapshot.claude(rateLimitEvent: ["type": "assistant"], account: nil) == nil)
    }

    @Test func claudesUsageAnswerKeepsScopedWeeks() {
        let usage: JSONValue = [
            "rate_limits_available": true,
            "rate_limits": [
                "five_hour": ["utilization": 30, "resets_at": "2026-10-23T14:50:00.353124+00:00"],
                "seven_day": ["utilization": 44, "resets_at": "2026-10-29T21:00:00+00:00"],
                "model_scoped": [["display_name": "Scoped", "utilization": 5, "resets_at": "2026-10-29T21:00:00+00:00"]],
            ],
        ]
        let snapshot = PlanSnapshot.claude(usage: usage, account: nil)
        #expect(snapshot?.windows.map(\.used) == [30, 44, 5])
        #expect(snapshot?.windows.map(\.limit) == [nil, nil, "Scoped"])
        #expect(PlanSnapshot.claude(usage: ["rate_limits_available": false], account: nil) == nil)
    }

    @Test func codexWindowsAreKeyedByLength() {
        // The week first, as the current plans send it; a second limit id of its own.
        let read: JSONValue = [
            "rateLimitsByLimitId": [
                "codex": ["limitId": "codex", "planType": "prolite", "primary": ["usedPercent": 7, "windowDurationMins": 10080, "resetsAt": 1_793_335_108]],
                "codex_other": ["limitId": "codex_other", "primary": ["usedPercent": 2, "windowDurationMins": 300, "resetsAt": 1_793_000_000]],
            ]
        ]
        let snapshot = PlanSnapshot.codex(rateLimits: read, account: nil, source: "read")
        #expect(snapshot?.account == "plan:prolite")
        #expect(snapshot?.windows.map(\.minutes) == [10080, 300])
        #expect(snapshot?.windows.map(\.limit) == [nil, "codex_other"])
        // A pushed update with one window.
        let pushed: JSONValue = ["rateLimits": ["primary": ["usedPercent": 9, "windowDurationMins": 10080, "resetsAt": 1_793_335_108]]]
        #expect(PlanSnapshot.codex(rateLimits: pushed, account: nil, source: "stream")?.windows.first?.used == 9)
    }

    @Test func rolloutRateLimitsReadSnakeCase() {
        let windows = PlanSnapshot.codexRollout([
            "limit_id": "codex", "primary": ["used_percent": 6.0, "window_minutes": 10080, "resets_at": 1_793_335_108],
            "secondary": NSNull(),
        ])
        #expect(windows == [PlanSnapshot.Window(minutes: 10080, used: 6, resetsAt: Date(timeIntervalSince1970: 1_793_335_108))])
    }

    @Test func accountIsAHashNeverTheEmail() throws {
        let key = try #require(PlanSnapshot.account(email: "You@Example.com"))
        #expect(key == PlanSnapshot.account(email: "you@example.com"))
        #expect(!key.contains("example") && key.count == 16)
        #expect(PlanSnapshot.account(email: "") == nil)
    }

    @Test func theLogKeepsOneLinePerWindowAndDropsRepeats() throws {
        let url = try Self.scratch().appendingPathComponent("snapshots.jsonl")
        let log = PlanSnapshotLog(url: url)
        let now = Date()
        let window = PlanSnapshot.Window(minutes: 300, used: 4, resetsAt: now.addingTimeInterval(3600))
        log.append(PlanSnapshot(at: now, cli: "claude", account: "a", source: "stream", windows: [window]))
        // The same reading from a second chat a moment later isn't written again.
        log.append(PlanSnapshot(at: now.addingTimeInterval(5), cli: "claude", account: "a", source: "read", windows: [window]))
        var later = window
        later.used = 5
        log.append(PlanSnapshot(at: now.addingTimeInterval(10), cli: "claude", account: "a", source: "stream", windows: [later]))
        log.sync()
        let entries = log.entries(since: now.addingTimeInterval(-60))
        #expect(entries.map(\.used) == [4, 5])
        #expect(entries.allSatisfy { $0.win == 300 && $0.acct == "a" })
    }

    @Test func theLogDropsWhatIsOlderThanItKeeps() throws {
        let url = try Self.scratch().appendingPathComponent("snapshots.jsonl")
        let old = Date().addingTimeInterval(-PlanSnapshotLog.keep - 86400).timeIntervalSince1970
        let recent = Date().addingTimeInterval(-86400).timeIntervalSince1970
        let lines = [old, recent].map { #"{"cli":"codex","src":"read","t":\#($0),"used":1,"win":300}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let log = PlanSnapshotLog(url: url)
        #expect(log.entries(since: .distantPast).map(\.t) == [recent])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test func koreSessionsStartFromTheSessionsLog() throws {
        let folder = try Self.scratch()
        let logs = folder.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = """
            2026-10-23T18:46:00.000Z\tstarted cli=claude chat=aaa pid=1 launch=resume
            2026-10-23T19:00:00.000Z\tstarted cli=codex chat=- pid=2 launch=new
            2026-10-23T19:01:00.000Z\texited cli=claude chat=bbb pid=1 status=0 asked=yes
            2026-10-23T19:02:00.000Z\tstarted cli=codex chat=ccc pid=3 launch=again

            """
        try log.write(to: logs.appendingPathComponent("sessions.log"), atomically: true, encoding: .utf8)
        let sessions = KoreSessions(url: folder.appendingPathComponent("sessions.jsonl"), logs: logs)
        var known = sessions.known()
        #expect(known.ids == ["claude": ["aaa"], "codex": ["ccc"]])
        #expect(known.since == ISO8601DateFormatter().date(from: "2026-10-23T18:46:00Z"))
        sessions.record(cli: "claude", session: "ddd", folder: folder, launch: "new")
        sessions.record(cli: "claude", session: "ddd", folder: folder, launch: "again")
        sessions.sync()
        // Read again from the file: each id once, the log's ids kept.
        known = KoreSessions(url: folder.appendingPathComponent("sessions.jsonl"), logs: nil).known()
        #expect(known.ids == ["claude": ["aaa", "ddd"], "codex": ["ccc"]])
        let text = try String(contentsOf: folder.appendingPathComponent("sessions.jsonl"), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 3)
    }
}
