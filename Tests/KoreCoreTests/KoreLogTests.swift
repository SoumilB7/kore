import Foundation
import Testing

@testable import KoreCore

/// One line shape for every log: the format and its escaping, levels, the throttle on a clock
/// moved by hand, what a line may say (the key allowlist, paths, emails, tokens), and the folder
/// kept within its week and cap whenever a log moves aside.
struct KoreLogTests {
    /// A clock the test moves.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 1_800_000_000)
        var read: Date { lock.withLock { now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { now += seconds } }
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("korelog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: The line

    @Test func aLineIsTimeLevelEventAndFieldsWithBackslashEscapes() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let log = KoreLog(url: folder.appendingPathComponent("t.log"), level: .info, now: { clock.read })
        log.write(.warn, "status", ["cli": "claude", "via": #"a "quoted" b\c"#, "to": "", "state": "x=y", "turn": nil, "id": "line\nbreak"])
        log.sync()
        let written = lines(folder.appendingPathComponent("t.log"))
        #expect(written == [#"2027-01-15T08:00:00.000Z warn status cli=claude via="a \"quoted\" b\\c" to="" state="x=y" id="line break""#])
        #expect(KoreLog.value("plain-id_1.2") == "plain-id_1.2")
        #expect(KoreLog.value(String(repeating: "a", count: 300)).count == 120)
        #expect(KoreLog.value("tab\there") == #""tab here""#)
    }

    /// Read back, a line is its time and body, past the level; a line from before levels too.
    @Test func aLineSplitsIntoTimeAndBodyInEitherShape() {
        let now = KoreLog.split("2027-01-15T08:00:00.000Z info started cli=claude chat=a")
        #expect(now.map { [String($0.stamp), String($0.body)] } == ["2027-01-15T08:00:00.000Z", "started cli=claude chat=a"])
        let before = KoreLog.split("2026-10-23T18:46:00.000Z\tstarted cli=claude chat=a")
        #expect(before.map { [String($0.stamp), String($0.body)] } == ["2026-10-23T18:46:00.000Z", "started cli=claude chat=a"])
        #expect(KoreLog.split("2027-01-15T08:00:00.000Z started cli=claude") == nil)
        #expect(KoreLog.split("nothing") == nil)
    }

    // MARK: Levels

    @Test func levelsBelowTheLogsAreLeftOut() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("t.log")
        let log = KoreLog(url: url, level: .warn)
        log.write(.debug, "a", [:])
        log.write("b", [:])
        log.write(.warn, "c", [:])
        log.write(.error, "d", [:])
        log.sync()
        #expect(lines(url).map { $0.split(separator: " ").dropFirst().joined(separator: " ") } == ["warn c", "error d"])
        #expect(KoreLog.Level(name: "WARN") == .warn)
        #expect(KoreLog.Level(name: "loud") == nil)
        #expect(KoreLog.Level.debug < .info && KoreLog.Level.warn < .error)
    }

    // MARK: Throttling

    @Test func aNoisyEventIsOneLinePerTenSecondsWithItsCount() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ui.log")
        let clock = Clock()
        let log = KoreLog(url: url, level: .info, now: { clock.read })
        log.throttled("window-occlusion", ["visible": "no"])
        for _ in 0..<40 {
            clock.advance(0.2)
            log.throttled("window-occlusion", ["visible": "yes"])
        }
        // Another event isn't held by this one's window.
        log.throttled("screens-changed")
        clock.advance(10)
        log.throttled("window-occlusion", ["visible": "no"])
        log.sync()
        let bodies = lines(url).map { $0.split(separator: " ").dropFirst(2).joined(separator: " ") }
        #expect(bodies == ["window-occlusion visible=no n=1", "screens-changed n=1", "window-occlusion visible=no n=41"])

        // The count itself: what was held back since the last line, this one too.
        var throttle = LogThrottle()
        let start = Date()
        #expect(throttle.pass("a", at: start, every: 10) == 1)
        #expect(throttle.pass("a", at: start + 9.9, every: 10) == nil)
        #expect(throttle.pass("a", at: start + 9.95, every: 10) == nil)
        #expect(throttle.pass("b", at: start + 9.95, every: 10) == 1)
        #expect(throttle.pass("a", at: start + 10, every: 10) == 3)
        #expect(throttle.pass("a", at: start + 25, every: 10) == 1)
    }

    @Test func atDebugEveryNoisyEventIsWritten() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ui.log")
        let log = KoreLog(url: url, level: .debug)
        for _ in 0..<3 { log.throttled("screens-changed") }
        log.sync()
        #expect(lines(url).map { $0.split(separator: " ").dropFirst().joined(separator: " ") } == Array(repeating: "debug screens-changed", count: 3))
    }

    // MARK: What a line may say

    @Test func onlyAllowedKeysGoInAndTitlesAndDetailsDont() {
        let safe = KoreLog.safe(["cli": "claude", "name": "Scout the secret plan", "detail": "moving the link", "agent": "toolu_1", "prompt": "hi"])
        #expect(safe.map(\.0) == ["cli", "agent"])
    }

    @Test func pathsAreTheirLastPartAndAHash() {
        let safe = KoreLog.safe(["path": "/Users/me/Clients/acme/notes.md", "folder": "kore"])
        #expect(safe[0].1 == "notes.md#" + KoreLog.hash("/Users/me/Clients/acme/notes.md"))
        #expect(safe[0].1.count == "notes.md#".count + 6)
        #expect(safe[1].1 == "kore")
        #expect(KoreLog.hash("a") == KoreLog.hash("a") && KoreLog.hash("a") != KoreLog.hash("b"))
    }

    @Test func tokensAndEmailsAreRedacted() {
        #expect(KoreLog.redacted("key sk-ant-api03-AbCdEf123456 here") == "key [redacted] here")
        #expect(KoreLog.redacted("ghp_ABCDEFabcdef0123456789") == "[redacted]")
        #expect(KoreLog.redacted("Authorization: Bearer eyJhbGciOi.payload.sig") == "Authorization: [redacted]")
        #expect(KoreLog.redacted("xoxb-1234-5678-abcdef") == "[redacted]")
        #expect(KoreLog.redacted("AKIAIOSFODNN7EXAMPLE") == "[redacted]")
        #expect(KoreLog.redacted("toolu_01Caw8 4fb9acc6-c3f2") == "toolu_01Caw8 4fb9acc6-c3f2")
        let safe = KoreLog.safe(["login": "soumil@example.com", "reason": "token sk-live-0123456789"])
        #expect(safe[0].1 == "h" + KoreLog.hash("soumil@example.com"))
        #expect(safe[1].1 == "token [redacted]")
    }

    // MARK: The folder

    @Test func movingAsidePrunesTheFolderButNeverALiveLog() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func make(_ name: String, bytes: Int, modified: Date) throws {
            let url = folder.appendingPathComponent(name)
            try Data(repeating: 0x61, count: bytes).write(to: url)
            try FileManager.default.setAttributes([.creationDate: modified, .modificationDate: modified], ofItemAtPath: url.path)
        }
        // Moved aside 8 days ago: goes. A retired log: goes. Another live log begun long ago: stays.
        try make("agents.log.1", bytes: 100, modified: now - 8 * 86400)
        try make("relay.log", bytes: 100, modified: now)
        try make("sessions.log", bytes: 100, modified: now - 9 * 86400)
        let log = KoreLog(url: folder.appendingPathComponent("ui.log"), limit: 200, prunes: true)
        for i in 0..<6 { log.write("resumed", ["agent": "a\(i)"]) }
        log.sync()
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["ui.log", "sessions.log", "agents.log.1", "relay.log"])
        log.write("resumed", ["agent": "after"])
        log.sync()
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["ui.log", "ui.log.1", "sessions.log"])

        // A log of its own outside Kore's folder (`prunes` false) leaves that folder be.
        let other = try scratch()
        defer { try? FileManager.default.removeItem(at: other) }
        let old = other.appendingPathComponent("other.log.1")
        try Data("x".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date() - 30 * 86400], ofItemAtPath: old.path)
        let own = KoreLog(url: other.appendingPathComponent("t.log"), limit: 100)
        for i in 0..<10 {
            own.write("resumed", ["agent": "a\(i)"])
            own.sync()
        }
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func pruneAtLaunchLetsRetiredLogsGo() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["relay.log", "remote-activity.log", "phone-addon.log", "ui.log"] { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        KoreLog.prune(folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["ui.log"])
    }
}
