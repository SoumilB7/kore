import AppKit
import IOKit.ps
import Observation

/// Stay awake (caffeinated mode): while on, Kore keeps the Mac from idle sleep so agents keep
/// working. The display may still sleep. One per app, made as the app starts (`start()`); the
/// cup in every window's title row and Kore ▸ Stay Awake show and change it.
///
/// While Agents Work holds while any chat in any window has a turn, an agent or a Codex child
/// thread running, or waits for its plan limit to reset, and lets go two minutes after the last
/// one. Always holds until it's turned off; a timer holds for its length, then turns it off. On
/// battery below 20% it pauses until the Mac is plugged in. Whether it's on and its mode are
/// kept; a timer isn't.
@MainActor @Observable
final class StayAwake {
    enum Mode: String, CaseIterable, Identifiable {
        case whileAgentsWork = "agents", always, hour = "1h", fourHours = "4h"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .whileAgentsWork: "While Agents Work"
            case .always: "Always"
            case .hour: "For 1 Hour"
            case .fourHours: "For 4 Hours"
            }
        }

        /// A timer's length; nil for the modes that hold until turned off.
        var length: TimeInterval? {
            switch self {
            case .hour: 3600
            case .fourHours: 4 * 3600
            default: nil
            }
        }
    }

    enum State: Equatable {
        case off
        /// Holding the Mac awake.
        case holding
        /// On, with nothing to keep awake for (While Agents Work).
        case waiting
        /// On battery and below the floor: the percent left.
        case paused(Int)
    }

    /// The running app's; nil in tests and anything else that never started it.
    private(set) static var current: StayAwake?

    private(set) var isOn = false
    /// The mode a click or ⌥⌘A turns it on in: the last one picked, a timer's mode only while
    /// it runs.
    private(set) var mode = Mode.whileAgentsWork
    /// When the running timer turns it off.
    private(set) var endsAt: Date?
    /// Turns, agents and Codex child threads running in every window.
    private(set) var working = 0
    /// The soonest a chat waits to continue at, after its plan limit resets.
    private(set) var continuesAt: Date?
    /// The two minutes after the last agent ended, while it still holds.
    private(set) var idleUntil: Date?
    private(set) var battery = PowerState(onBattery: false, percent: nil)
    /// Bumped each minute while a time is counting down, so the hover line follows it.
    private(set) var tick = 0

    /// How long it holds after the last agent ends; a storyline shortens it.
    var grace: TimeInterval = 120
    /// The battery level it pauses below, on battery.
    static let batteryFloor = 20

    @ObservationIgnored let hold: any AwakeHold
    @ObservationIgnored let clock: any AwakeClock
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var held: String?
    @ObservationIgnored private var timer: AwakeTimer?
    @ObservationIgnored private var idleTimer: AwakeTimer?
    @ObservationIgnored private var ticker: AwakeTimer?
    /// The last system sleep: when it began, and when the Mac woke (nil while asleep).
    @ObservationIgnored private(set) var slept: (from: Date, woke: Date?)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var power: (any PowerSource)?
    @ObservationIgnored private var tracking = 0

    private static let onKey = "stayAwake.on"
    private static let modeKey = "stayAwake.mode"

    /// `defaults` nil keeps and reads nothing.
    init(hold: any AwakeHold, clock: any AwakeClock = SystemClock(), power: (any PowerSource)? = nil, defaults: UserDefaults? = nil) {
        self.hold = hold
        self.clock = clock
        self.defaults = defaults
        self.power = power
        if let saved = defaults?.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)), saved.length == nil { mode = saved }
        isOn = defaults?.bool(forKey: Self.onKey) ?? false
        if let power {
            battery = power.state
            power.watch { [weak self] in
                guard let self, let power = self.power else { return }
                self.battery = power.state
                self.apply()
            }
        }
        apply()
    }

    /// Made once, as the app starts. Storylines and dev runs (any KORE_ hook) hold nothing real
    /// under a storyline host, and keep nothing in the owner's defaults.
    static func start() {
        guard current == nil else { return }
        let dev = StoryHost.installed || ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("KORE_") }
        let awake =
            StoryHost.installed
            ? StayAwake(hold: RecordedHold(), defaults: nil)
            : StayAwake(hold: ActivityHold(), power: BatteryWatch(), defaults: dev ? nil : .standard)
        current = awake
        awake.watchSleep()
        awake.track()
    }

    // MARK: Turning it on and off

    /// The cup's click and ⌥⌘A: on in the last mode, or off.
    func toggle() {
        if isOn { turnOff() } else { choose(mode) }
    }

    /// A mode picked in a menu: turns it on in that mode. A timer picked again starts over.
    func choose(_ picked: Mode) {
        mode = picked
        isOn = true
        endsAt = picked.length.map { clock.now.addingTimeInterval($0) }
        timer = endsAt.map { end in clock.at(end) { [weak self] in self?.timerEnded() } }
        idleUntil = nil
        save()
        apply()
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        // A timer doesn't stay the mode: the next click is While Agents Work.
        if mode.length != nil { mode = .whileAgentsWork }
        endsAt = nil
        timer = nil
        idleUntil = nil
        idleTimer = nil
        save()
        apply()
        for chat in Self.chats.compactMap(\.chat) { chat.cancelContinue() }
    }

    private func timerEnded() {
        guard isOn, let end = endsAt, end <= clock.now.addingTimeInterval(1) else { return }
        turnOff()
    }

    private func save() {
        // A timer isn't kept: the next launch starts off, in While Agents Work.
        let timed = mode.length != nil
        defaults?.set(isOn && !timed, forKey: Self.onKey)
        defaults?.set(timed ? Mode.whileAgentsWork.rawValue : mode.rawValue, forKey: Self.modeKey)
    }

    // MARK: What it holds for

    /// What's running, and the soonest continuation, from every chat (`track()`), or a test.
    func update(working: Int, continuesAt: Date?) {
        let ended = self.working > 0 && working == 0
        self.working = working
        self.continuesAt = continuesAt
        if working > 0 {
            idleUntil = nil
            idleTimer = nil
        } else if ended, isOn, mode == .whileAgentsWork {
            let until = clock.now.addingTimeInterval(grace)
            idleUntil = until
            idleTimer = clock.at(until) { [weak self] in
                guard let self, self.idleUntil == until else { return }
                self.idleUntil = nil
                self.apply()
            }
        }
        apply()
    }

    var paused: Bool {
        guard battery.onBattery, let percent = battery.percent else { return false }
        return percent < Self.batteryFloor
    }

    var state: State {
        guard isOn else { return .off }
        if paused { return .paused(battery.percent ?? 0) }
        return reason == nil ? .waiting : .holding
    }

    /// Why it holds, as `pmset -g assertions` shows it; nil when it doesn't.
    var reason: String? {
        guard isOn, !paused else { return nil }
        switch mode {
        case .always: return "Kore: Stay awake is on"
        case .hour, .fourHours: return "Kore: Stay awake \(mode == .hour ? "for 1 hour" : "for 4 hours")"
        case .whileAgentsWork:
            if working > 0 { return "Kore: \(Self.agents(working)) working" }
            if continuesAt != nil { return "Kore: a chat continues when its limit resets" }
            if idleUntil != nil { return "Kore: agents just finished" }
            return nil
        }
    }

    /// The cup's one line.
    var line: String {
        _ = tick
        let now = clock.now
        switch state {
        case .off: return "Stay awake"
        case .paused(let percent): return "Paused · battery \(percent)%"
        case .waiting: return "Awake while agents work"
        case .holding:
            switch mode {
            case .always: return "Awake until turned off"
            case .hour, .fourHours: return "Awake · " + Self.left(until: endsAt ?? now, now: now)
            case .whileAgentsWork:
                if working > 0 { return "Keeping awake · \(Self.agents(working))" }
                if let at = continuesAt { return "Keeping awake · continues \(Self.time(at, now: now))" }
                return "Keeping awake · ends in \(Self.minutes(until: idleUntil ?? now, now: now))m"
            }
        }
    }

    /// The running timer's time left, for its menu item.
    var timeLeft: String? {
        _ = tick
        guard isOn, let endsAt else { return nil }
        return Self.left(until: endsAt, now: clock.now)
    }

    nonisolated static func agents(_ count: Int) -> String { count == 1 ? "1 agent" : "\(count) agents" }

    /// "2h 14m left", "1h left", "12m left", "1m left".
    nonisolated static func left(until end: Date, now: Date) -> String {
        let minutes = minutes(until: end, now: now)
        guard minutes >= 60 else { return "\(minutes)m left" }
        return minutes % 60 == 0 ? "\(minutes / 60)h left" : "\(minutes / 60)h \(minutes % 60)m left"
    }

    /// Whole minutes left, rounded up, and at least 1.
    nonisolated static func minutes(until end: Date, now: Date) -> Int {
        max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// "3:00 PM" today, else "Thu 9:00 AM".
    nonisolated static func time(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let clock = date.formatted(.dateTime.hour().minute().locale(locale))
        guard !calendar.isDate(date, inSameDayAs: now) else { return clock }
        return date.formatted(.dateTime.weekday(.abbreviated).locale(locale)) + " " + clock
    }

    /// Takes, changes or lets go of the hold to match the state, and keeps a minute ticker while
    /// a time counts down.
    private func apply() {
        let want = reason
        if want != held {
            held = want
            hold.hold(want)
        }
        let counting = isOn && (endsAt != nil || idleUntil != nil)
        if counting, ticker == nil {
            scheduleTick()
        } else if !counting {
            ticker = nil
        }
    }

    private func scheduleTick() {
        ticker = clock.at(clock.now.addingTimeInterval(60)) { [weak self] in
            guard let self else { return }
            self.tick &+= 1
            self.ticker = nil
            self.apply()
        }
    }

    // MARK: Chats

    private struct WeakChat {
        weak var chat: Chat?
    }

    private static var chats: [WeakChat] = []

    /// Every chat counts toward While Agents Work, in any window.
    static func register(_ chat: Chat) {
        chats.removeAll { $0.chat == nil }
        chats.append(WeakChat(chat: chat))
        current?.track()
    }

    /// Reads every chat's work and continuation, and again whenever one changes.
    private func track() {
        tracking &+= 1
        let generation = tracking
        let chats = Self.chats.compactMap(\.chat)
        let (working, next) = withObservationTracking {
            (chats.reduce(0) { $0 + $1.awakeWork }, chats.compactMap(\.continuesAt).min())
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.tracking == generation else { return }
                self.track()
            }
        }
        if working != self.working || next != continuesAt { update(working: working, continuesAt: next) }
    }

    // MARK: Sleep and wake

    private func watchSleep() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
    }

    func willSleep() { slept = (clock.now, nil) }

    func didWake() {
        if let from = slept?.from { slept = (from, clock.now) }
        if let endsAt, endsAt <= clock.now { turnOff() }
        if let idleUntil, idleUntil <= clock.now { self.idleUntil = nil }
        apply()
    }

    /// How long after a wake a failure still counts as the sleep's.
    static let wakeSettle: TimeInterval = 60

    /// A turn that started at `start` and failed now: the Mac slept in between, and woke at most
    /// a minute ago (or hasn't yet).
    func sleptThrough(since start: Date) -> Bool {
        guard let slept, slept.from >= start else { return false }
        guard let woke = slept.woke else { return true }
        return clock.now.timeIntervalSince(woke) <= Self.wakeSettle
    }
}

// MARK: - The hold

/// What keeps the Mac awake.
@MainActor
protocol AwakeHold: AnyObject {
    /// Holds for `reason`, or lets go (nil). Called only when it changes.
    func hold(_ reason: String?)
}

/// A process activity: no idle system sleep and no App Nap for Kore, and no sudden or automatic
/// termination. The display may still sleep. `pmset -g assertions` shows its reason.
final class ActivityHold: AwakeHold {
    private var activity: NSObjectProtocol?

    func hold(_ reason: String?) {
        let previous = activity
        activity = reason.map {
            ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled], reason: $0)
        }
        // The new one is taken before the old one goes, so a changed reason never lets go.
        if let previous { ProcessInfo.processInfo.endActivity(previous) }
    }
}

/// Holds nothing, and keeps what it was asked: a storyline host's and the tests'.
package final class RecordedHold: AwakeHold {
    package private(set) var reasons: [String?] = []
    /// What it would hold for now.
    package var current: String? { reasons.last ?? nil }

    package init() {}

    func hold(_ reason: String?) { reasons.append(reason) }
}

// MARK: - The clock

/// When things happen: the system's, or a test's that moves by hand.
@MainActor
protocol AwakeClock: AnyObject {
    var now: Date { get }
    /// Runs `action` at `date`, or as soon as it can when that's past; until the timer is let go.
    func at(_ date: Date, _ action: @escaping @MainActor () -> Void) -> AwakeTimer
}

/// A scheduled action, cancelled when it's let go.
final class AwakeTimer: Sendable {
    private let cancel: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }

    deinit { cancel() }
}

/// Wall time. A task's sleep counts time the Mac spent asleep, so one that came due during a
/// sleep runs at the wake.
final class SystemClock: AwakeClock {
    var now: Date { Date() }

    func at(_ date: Date, _ action: @escaping @MainActor () -> Void) -> AwakeTimer {
        let task = Task { @MainActor in
            let wait = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .milliseconds(Int(min(wait, 365 * 86_400) * 1000)))
            guard !Task.isCancelled else { return }
            action()
        }
        return AwakeTimer { task.cancel() }
    }
}

// MARK: - The battery

struct PowerState: Equatable {
    var onBattery: Bool
    /// Charge left, 0–100; nil without a battery.
    var percent: Int?
}

@MainActor
protocol PowerSource: AnyObject {
    var state: PowerState { get }
    /// Calls `changed` whenever the power source or the charge changes.
    func watch(_ changed: @escaping @MainActor () -> Void)
}

/// IOKit's power sources: what powers the Mac, and the internal battery's charge.
final class BatteryWatch: PowerSource {
    private var changed: (@MainActor () -> Void)?
    private var source: CFRunLoopSource?

    var state: PowerState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerState(onBattery: false, percent: nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var percent: Int?
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            percent = current * 100 / max
        }
        return PowerState(onBattery: providing == kIOPSBatteryPowerValue, percent: percent)
    }

    func watch(_ changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let made = IOPSNotificationCreateRunLoopSource(
                { context in
                    guard let context else { return }
                    let watch = Unmanaged<BatteryWatch>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { watch.changed?() }
                }, context)?.takeRetainedValue()
        else { return }
        source = made
        CFRunLoopAddSource(CFRunLoopGetMain(), made, .defaultMode)
    }
}
