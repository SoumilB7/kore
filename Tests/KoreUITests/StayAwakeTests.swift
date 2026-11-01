import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Stay awake's modes, its idle release, timers, the battery floor and the hold's reason, on a
/// clock moved by hand and a hold that only records; and a limit's continuation at its reset.
@MainActor
@Suite("Stay awake")
struct StayAwakeTests {
    private func awake(
        battery: PowerState = PowerState(onBattery: false, percent: 100), defaults: UserDefaults? = nil
    ) -> (StayAwake, RecordedHold, HandClock, HandPower) {
        let (hold, clock, power) = (RecordedHold(), HandClock(), HandPower(battery))
        return (StayAwake(hold: hold, clock: clock, power: power, defaults: defaults), hold, clock, power)
    }

    @Test func offHoldsNothing() {
        let (awake, hold, _, _) = awake()
        awake.update(working: 3, continuesAt: nil)
        #expect(awake.state == .off)
        #expect(hold.current == nil)
        #expect(awake.line == "Stay awake")
    }

    @Test func aClickTurnsItOnInWhileAgentsWorkAndAgainOff() {
        let (awake, hold, _, _) = awake()
        awake.toggle()
        #expect(awake.isOn && awake.mode == .whileAgentsWork)
        #expect(awake.state == .waiting)
        #expect(awake.line == "Awake while agents work")
        #expect(hold.current == nil)
        awake.toggle()
        #expect(!awake.isOn)
    }

    @Test func itHoldsWhileAgentsWorkAndLetsGoTwoMinutesAfter() {
        let (awake, hold, clock, _) = awake()
        awake.toggle()
        awake.update(working: 3, continuesAt: nil)
        #expect(awake.state == .holding)
        #expect(hold.current == "Kore: 3 agents working")
        #expect(awake.line == "Keeping awake · 3 agents")
        awake.update(working: 1, continuesAt: nil)
        #expect(hold.current == "Kore: 1 agent working")
        #expect(awake.line == "Keeping awake · 1 agent")

        awake.update(working: 0, continuesAt: nil)
        #expect(awake.state == .holding)
        #expect(awake.line == "Keeping awake · ends in 2m")
        clock.advance(by: 61)
        #expect(awake.line == "Keeping awake · ends in 1m")
        #expect(hold.current == "Kore: agents just finished")
        clock.advance(by: 60)
        #expect(awake.state == .waiting)
        #expect(hold.current == nil)
        // The hold was taken and let go, never left behind.
        #expect(hold.reasons.last == .some(nil))
    }

    @Test func workStartingAgainKeepsHolding() {
        let (awake, hold, clock, _) = awake()
        awake.toggle()
        awake.update(working: 1, continuesAt: nil)
        awake.update(working: 0, continuesAt: nil)
        clock.advance(by: 100)
        awake.update(working: 2, continuesAt: nil)
        clock.advance(by: 60)
        #expect(hold.current == "Kore: 2 agents working")
    }

    @Test func aWaitingContinuationHolds() {
        let (awake, hold, clock, _) = awake()
        awake.toggle()
        let at = clock.now.addingTimeInterval(3600)
        awake.update(working: 0, continuesAt: at)
        #expect(awake.state == .holding)
        #expect(hold.current == "Kore: a chat continues when its limit resets")
        #expect(awake.line == "Keeping awake · continues " + StayAwake.time(at, now: clock.now))
        // Agents win over it.
        awake.update(working: 2, continuesAt: at)
        #expect(awake.line == "Keeping awake · 2 agents")
    }

    @Test func alwaysHoldsUntilTurnedOff() {
        let (awake, hold, clock, _) = awake()
        awake.choose(.always)
        #expect(hold.current == "Kore: Stay awake is on")
        #expect(awake.line == "Awake until turned off")
        clock.advance(by: 10 * 3600)
        #expect(awake.state == .holding)
        awake.turnOff()
        #expect(hold.current == nil)
        // A click turns it on again in Always.
        awake.toggle()
        #expect(awake.mode == .always)
    }

    @Test func aTimerHoldsThenTurnsOff() {
        let (awake, hold, clock, _) = awake()
        awake.choose(.fourHours)
        #expect(hold.current == "Kore: Stay awake for 4 hours")
        clock.advance(by: 4 * 3600 - (2 * 3600 + 14 * 60))
        #expect(awake.line == "Awake · 2h 14m left")
        #expect(awake.timeLeft == "2h 14m left")
        clock.advance(by: 2 * 3600 + 2 * 60)
        #expect(awake.line == "Awake · 12m left")
        // Picked again, it starts over.
        awake.choose(.hour)
        #expect(awake.line == "Awake · 1h left")
        clock.advance(by: 59 * 60 + 30)
        #expect(awake.line == "Awake · 1m left")
        clock.advance(by: 31)
        #expect(!awake.isOn)
        #expect(hold.current == nil)
        // A timer doesn't stay the mode.
        #expect(awake.mode == .whileAgentsWork)
    }

    @Test func lowBatteryPausesAndPluggingInResumes() {
        let (awake, hold, _, power) = awake(battery: PowerState(onBattery: true, percent: 30))
        awake.choose(.always)
        #expect(hold.current != nil)
        power.set(PowerState(onBattery: true, percent: 18))
        #expect(awake.state == .paused(18))
        #expect(awake.line == "Paused · battery 18%")
        #expect(hold.current == nil)
        power.set(PowerState(onBattery: false, percent: 18))
        #expect(awake.state == .holding)
        #expect(hold.current == "Kore: Stay awake is on")
    }

    @Test func onAndTheModeAreKeptButNotATimer() {
        let defaults = HandDefaults()
        let (first, _, _, _) = awake(defaults: defaults)
        first.choose(.always)
        let (second, hold, _, _) = awake(defaults: defaults)
        #expect(second.isOn && second.mode == .always)
        #expect(hold.current == "Kore: Stay awake is on")
        second.choose(.hour)
        let (third, _, _, _) = awake(defaults: defaults)
        #expect(!third.isOn && third.mode == .whileAgentsWork)
    }

    @Test func aFailureCountsAsTheSleepsUntilAMinuteAfterTheWake() {
        let (awake, _, clock, _) = awake()
        let start = clock.now
        #expect(!awake.sleptThrough(since: start))
        clock.advance(by: 10)
        awake.willSleep()
        #expect(awake.sleptThrough(since: start))
        clock.advance(by: 3600)
        awake.didWake()
        clock.advance(by: 30)
        #expect(awake.sleptThrough(since: start))
        // A turn that began after the sleep isn't the sleep's.
        #expect(!awake.sleptThrough(since: clock.now.addingTimeInterval(-5)))
        clock.advance(by: 31)
        #expect(!awake.sleptThrough(since: start))
    }

    @Test func timesReadAsTheClockDoes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let us = Locale(identifier: "en_US")
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))!
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9))!
        let format = { (date: Date) in ContinueText.line(date, now: now, calendar: calendar, locale: us) }
        let utc = { (text: String) in text.replacingOccurrences(of: "\u{202F}", with: " ") }
        // The formatter's own zone is the system's; only the words are checked here.
        #expect(utc(format(today)).hasPrefix("Continues at "))
        #expect(utc(format(thursday)).hasPrefix("Continues Thu "))
    }

    // MARK: The continuation

    private func reading(_ used: Double, resets: Date?) -> PlanReading {
        PlanReading(account: PlanAccount(access: .plan), limits: PlanLimits(bars: [PlanLimit(title: "Session (5hr)", used: used, resetsAt: resets)]))
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func atTheResetItReadsThenSendsContinueOnce() async {
        let clock = HandClock()
        let continuation = LimitContinuation(clock: clock)
        var sent = 0
        var reads = 0
        continuation.read = {
            reads += 1
            return self.reading(3, resets: clock.now.addingTimeInterval(5 * 3600))
        }
        continuation.send = { sent += 1 }
        let at = clock.now.addingTimeInterval(3600)
        continuation.schedule(turn: "t1", at: at)
        #expect(continuation.pending == .init(turn: "t1", at: at))
        clock.advance(by: 3599)
        await settle()
        #expect(reads == 0 && sent == 0)
        clock.advance(by: 1)
        await settle()
        #expect(reads == 1 && sent == 1)
        #expect(continuation.pending == nil)
        clock.advance(by: 7200)
        await settle()
        #expect(sent == 1)
    }

    @Test func stillLimitedMovesToTheNextResetAndSendsNothing() async {
        let clock = HandClock()
        let continuation = LimitContinuation(clock: clock)
        var sent = 0
        let week = clock.now.addingTimeInterval(3 * 86_400)
        var limited = true
        continuation.read = { self.reading(limited ? 100 : 10, resets: limited ? week : nil) }
        continuation.send = { sent += 1 }
        continuation.schedule(turn: "t1", at: clock.now.addingTimeInterval(60))
        clock.advance(by: 60)
        await settle()
        #expect(sent == 0)
        #expect(continuation.pending == .init(turn: "t1", at: week))
        limited = false
        clock.advance(by: 3 * 86_400)
        await settle()
        #expect(sent == 1)
    }

    @Test func aLimitSayingNoResetIsLookedAtLessAndLessOften() async {
        let clock = HandClock()
        let continuation = LimitContinuation(clock: clock)
        var reads = 0
        continuation.read = {
            reads += 1
            return self.reading(100, resets: nil)
        }
        continuation.schedule(turn: "t1", at: clock.now.addingTimeInterval(60))
        clock.advance(by: 60)
        await settle()
        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            guard let at = continuation.pending?.at else { break }
            let wait = at.timeIntervalSince(clock.now)
            waits.append(wait)
            clock.advance(by: wait)
            await settle()
        }
        #expect(waits == [1800, 3600, 7200, 14_400, 14_400])
        #expect(reads == 6)
    }

    @Test func cancelledItNeverSends() async {
        let clock = HandClock()
        let continuation = LimitContinuation(clock: clock)
        var sent = 0
        var changes: [LimitContinuation.Pending?] = []
        continuation.read = { self.reading(0, resets: nil) }
        continuation.send = { sent += 1 }
        continuation.changed = { changes.append($0) }
        continuation.schedule(turn: "t1", at: clock.now.addingTimeInterval(60))
        continuation.cancel()
        clock.advance(by: 120)
        await settle()
        #expect(sent == 0)
        #expect(changes.last == .some(nil))
    }

    @Test func noResetSaidReadsTheLimitsForIt() async {
        let clock = HandClock()
        let continuation = LimitContinuation(clock: clock)
        let reset = clock.now.addingTimeInterval(2 * 3600)
        continuation.read = { self.reading(100, resets: reset) }
        continuation.schedule(turn: "t1", at: nil)
        await settle()
        #expect(continuation.pending == .init(turn: "t1", at: reset))
    }

    @Test func unreadableLimitsAreTriedAgainThenItContinues() async {
        let clock = HandClock()
        let continuation = LimitContinuation(clock: clock)
        var sent = 0
        continuation.read = { nil }
        continuation.send = { sent += 1 }
        continuation.schedule(turn: "t1", at: clock.now)
        for _ in 0...LimitContinuation.retries {
            clock.advance(by: LimitContinuation.retry)
            await settle()
        }
        #expect(sent == 1)
    }

    /// The real hold, for a few seconds, when asked (`KORE_REAL_HOLD=1`): `pmset -g assertions`
    /// lists its reason while it's held and not after. Never part of an ordinary run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KORE_REAL_HOLD"] == "1"))
    func theRealHoldShowsInPmset() async throws {
        let hold = ActivityHold()
        hold.hold("Kore: 3 agents working")
        try await Task.sleep(for: .seconds(2))
        let held = try Self.pmset()
        hold.hold(nil)
        try await Task.sleep(for: .seconds(1))
        let after = try Self.pmset()
        print("held:\n" + held + "\nafter:\n" + after)
        #expect(held.contains("Kore: 3 agents working"))
        #expect(!after.contains("Kore: 3 agents working"))
    }

    /// `pmset -g assertions`' lines naming Kore.
    private static func pmset() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains("Kore") }.joined(separator: "\n")
    }

    // MARK: From each CLI

    private func limited(_ events: [ChatEvent]) -> (String, Date?)? {
        events.lazy.compactMap { if case .turnFinished(_, .limited(let said, let at), _) = $0 { (said, at) } else { nil } }.first
    }

    @Test func claudesRefusedTurnEndsLimited() throws {
        let translator = ClaudeTranslator(folder: Drive.folder, sessionId: nil)
        translator.openTurn(.user)
        let lines = [
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1793100000,"rateLimitType":"five_hour"}}"#,
            #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your session limit · resets 3pm (Asia/Kolkata)","duration_ms":120}"#,
        ]
        for line in lines { translator.translate(ClaudeEvent(message: try JSONValue.parse(Data(line.utf8)))) }
        let hit = limited(translator.take().events)
        #expect(hit?.0 == "You've hit your session limit · resets 3pm (Asia/Kolkata)")
        #expect(hit?.1 == Date(timeIntervalSince1970: 1_793_100_000))
    }

    @Test func codexsUsageLimitEndsLimited() throws {
        let translator = CodexTranslator(folder: Drive.folder)
        translator.translate(.threadStarted(threadId: "th1", model: nil, raw: .null))
        let started: JSONValue = ["threadId": "th1", "turn": ["id": "t1", "status": "inProgress"]]
        translator.translate(CodexEvent(notification: "turn/started", params: started))
        let error: JSONValue = ["message": "You've hit your usage limit. Try again in 2 hours.", "codexErrorInfo": "usageLimitExceeded"]
        let completed: JSONValue = ["threadId": "th1", "turn": ["id": "t1", "status": "failed", "error": error]]
        let before = Date()
        translator.translate(CodexEvent(notification: "turn/completed", params: completed))
        let hit = limited(translator.take().events)
        #expect(hit?.0 == "You've hit your usage limit. Try again in 2 hours.")
        #expect(hit?.1.map { abs($0.timeIntervalSince(before) - 7200) < 5 } == true)
    }

    // MARK: In the transcript

    @Test func aSleptTurnShowsItsNoticeAndALimitItsContinuation() {
        let script = Script()
        script.send("Go on")
        script.start("t1")
        script.finish("t1", .slept("API Error: Connection error."))
        script.send("And then")
        script.start("t2")
        script.finish("t2", .limited("You've hit your session limit", resetsAt: nil))
        let at = Date().addingTimeInterval(3600)
        script.store.continues(turn: "t2", at: at)
        #expect(script.lines == ["§ Go on", "message Go on", "slept API Error: Connection error.", "§ And then", "message And then", "outcome You've hit your session limit"])
        #expect(script.items.map(\.row).contains(.outcome(turn: "t2", text: "You've hit your session limit", continues: at, retry: true)))
        script.store.continues(turn: nil, at: nil)
        #expect(script.items.map(\.row).contains(.outcome(turn: "t2", text: "You've hit your session limit", retry: true)))
    }
    /// The Mac sleeping isn't a failure: the turn is cut short as an interrupted one is.
    @Test func aSleptTurnIsCalm() {
        let script = Script()
        script.send("Go on")
        script.start("t1")
        script.tool("t1-tool")
        script.done("t1-tool")
        script.finish("t1", .slept("API Error: Connection error."))
        let slept = script.items.first { if case .slept = $0.row { true } else { false } }
        #expect(slept?.dot == .warning)
        #expect(script.lines.contains("fold interrupted"))
    }
}

/// A clock moved by hand: due actions run in order as it passes them.
@MainActor
final class HandClock: AwakeClock {
    private(set) var now = Date(timeIntervalSince1970: 1_793_000_000)
    private var due: [(at: Date, id: Int, action: @MainActor () -> Void)] = []
    private var next = 0
    private let cancelled = Cancelled()

    func at(_ date: Date, _ action: @escaping @MainActor () -> Void) -> AwakeTimer {
        next += 1
        let id = next
        due.append((date, id, action))
        let cancelled = cancelled
        return AwakeTimer { cancelled.add(id) }
    }

    func advance(by seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let first = due.filter({ $0.at <= end && !cancelled.contains($0.id) }).min(by: { $0.at < $1.at }) {
            due.removeAll { $0.id == first.id }
            now = max(now, first.at)
            first.action()
        }
        now = end
    }

    private final class Cancelled: @unchecked Sendable {
        private var ids: Set<Int> = []
        private let lock = NSLock()
        func add(_ id: Int) { lock.withLock { _ = ids.insert(id) } }
        func contains(_ id: Int) -> Bool { lock.withLock { ids.contains(id) } }
    }
}

@MainActor
final class HandPower: PowerSource {
    private(set) var state: PowerState
    private var changed: (@MainActor () -> Void)?

    init(_ state: PowerState) { self.state = state }

    func watch(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }

    func set(_ state: PowerState) {
        self.state = state
        changed?()
    }
}

/// Defaults that stay in memory.
private final class HandDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
}
