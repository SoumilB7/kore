import Foundation
import KoreCore

/// A chat whose turn ended on its plan's limit, continued at the reset while Stay awake is on.
/// At the reset it reads the plan's limits again (the usage popup's read): clear, it sends
/// "Continue" once; still limited, it moves to the next reset and sends nothing. The ×, the owner
/// sending, and Stay awake turned off cancel it.
@MainActor
final class LimitContinuation {
    struct Pending: Equatable {
        let turn: String
        var at: Date
    }

    private(set) var pending: Pending? {
        didSet { if pending != oldValue { changed(pending) } }
    }

    /// Reads the plan's limits; nil when they couldn't be read.
    var read: () async -> PlanReading? = { nil }
    var send: () -> Void = {}
    var changed: (Pending?) -> Void = { _ in }

    /// A limit still spent but saying no reset is looked at again after this.
    static let recheck: TimeInterval = 30 * 60
    /// Limits that can't be read (the network not back after a wake) are tried again after this,
    /// up to `retries` times; then it continues anyway, and a new limit failure starts it over.
    static let retry: TimeInterval = 60
    static let retries = 3

    private let clock: any AwakeClock
    private var timer: AwakeTimer?
    private var attempt = 0
    /// Bumped by every schedule and cancel, so a read that comes back late is dropped.
    private var generation = 0

    init(clock: any AwakeClock) {
        self.clock = clock
    }

    /// The turn ended on the plan's limit, which resets `at`; nil when the CLI didn't say, and
    /// the plan's limits tell.
    func schedule(turn: String, at: Date?) {
        generation &+= 1
        attempt = 0
        timer = nil
        guard let at else {
            pending = nil
            let generation = generation
            Task {
                let reading = await read()
                guard generation == self.generation,
                    case .limited(let until?) = reading?.limits?.blocked(now: clock.now)
                else { return }
                arm(Pending(turn: turn, at: until))
            }
            return
        }
        arm(Pending(turn: turn, at: at))
    }

    func cancel() {
        generation &+= 1
        timer = nil
        pending = nil
    }

    private func arm(_ next: Pending) {
        pending = next
        let generation = generation
        timer = clock.at(next.at) { [weak self] in
            guard let self, generation == self.generation else { return }
            Task { await self.due() }
        }
    }

    /// The reset came: read the limits, then continue or wait for the next reset.
    func due() async {
        guard let current = pending else { return }
        let generation = generation
        let reading = await read()
        guard generation == self.generation, pending == current else { return }
        let now = clock.now
        switch reading?.limits?.blocked(now: now) {
        case .limited(let until):
            var next = current
            next.at = until.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(Self.recheck)
            attempt = 0
            arm(next)
        case nil where attempt < Self.retries:
            attempt += 1
            var next = current
            next.at = now.addingTimeInterval(Self.retry)
            arm(next)
        default:
            self.generation &+= 1
            timer = nil
            pending = nil
            send()
        }
    }
}
