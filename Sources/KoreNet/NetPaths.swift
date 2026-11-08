import Foundation
import KoreTrust
import Synchronization

/// The services a KoreNet port serves, by the name a hello asks for; any other name is refused.
package struct ServiceTable: Sendable {
    package struct Entry: Sendable, Equatable {
        package var policy: PolicyTable.Service
        /// The queue the policy table is asked about when the session opens.
        package var queue: PolicyTable.Queue
    }

    package var entries: [String: Entry]

    package init(_ entries: [String: Entry]) { self.entries = entries }

    /// v1: the link (ctl connection) and the bulk pipe.
    package static let v1 = ServiceTable([
        "link": Entry(policy: .link, queue: .interactive),
        "pipe": Entry(policy: .pipe, queue: .bulk),
    ])

    package subscript(name: String) -> Entry? { entries[name] }
}

/// The ways from this device to another, best first (phase 18 §1 "Liveness"): the tailnet, then
/// SSH `attach` (Mac → box only). Redial backoff 1, 2, 5, 10, 30, 60 s; a peer seen online on
/// the bus redials at once.
package enum NetPaths {
    package static let order: [Binding.Route] = [.tailnet, .ssh]

    /// The routes to try, in order, among those this pair has.
    package static func ordered(_ available: Set<Binding.Route>) -> [Binding.Route] { order.filter(available.contains) }

    /// Whether a new session on `incoming` replaces one up on `existing` for the same device: a
    /// tailnet hello replaces a zombie SSH attach, never the reverse; the same route replaces
    /// (the device reconnected).
    package static func replaces(incoming: Binding.Route, existing: Binding.Route) -> Bool {
        incoming == existing || (incoming == .tailnet && existing == .ssh)
    }

    package struct Backoff: Sendable, Equatable {
        package static let steps: [TimeInterval] = [1, 2, 5, 10, 30, 60]
        package private(set) var attempt = 0

        package init() {}

        /// The wait before the next dial.
        package mutating func next() -> TimeInterval {
            defer { attempt += 1 }
            return Self.steps[min(attempt, Self.steps.count - 1)]
        }

        /// Connected (or the peer came online): the next failure starts over.
        package mutating func reset() { attempt = 0 }
    }
}

/// Resume tickets a server hands out in welcomes: one live ticket per device, spent when a hello
/// presents it.
package final class ResumeTickets: Sendable {
    package static let size = 16
    private let live = Mutex<[UUID: Data]>([:])
    private let random: @Sendable (Int) -> Data

    package init(random: @escaping @Sendable (Int) -> Data = { secureRandom($0) }) { self.random = random }

    package func issue(for device: UUID) -> Data {
        let ticket = random(Self.size)
        live.withLock { $0[device] = ticket }
        return ticket
    }

    /// Whether `ticket` is the device's live one; spent either way.
    package func redeem(_ ticket: Data, for device: UUID) -> Bool {
        live.withLock { $0.removeValue(forKey: device) } == ticket
    }
}

/// Pre-auth connections per source address: at most `perMinute` in any 60 s, judged on the
/// injected clock.
package final class PreAuthLimiter: Sendable {
    package static let perMinute = 3
    package static let maxSources = 1024
    private let seen = Mutex<[String: [Date]]>([:])
    private let clock: @Sendable () -> Date

    package init(clock: @escaping @Sendable () -> Date = { Date() }) { self.clock = clock }

    package func admit(_ source: String) -> Bool {
        let now = clock()
        return seen.withLock { all in
            var times = (all[source] ?? []).filter { now.timeIntervalSince($0) < 60 }
            guard times.count < Self.perMinute else {
                all[source] = times
                return false
            }
            times.append(now)
            all[source] = times
            if all.count > Self.maxSources {
                all = all.filter { $0.value.contains { now.timeIntervalSince($0) < 60 } }
            }
            return true
        }
    }
}
