import Foundation
import KoreCore

/// What the app around a chat supplies to its engine. The Mac app's: a backend from the real
/// CLI (or a storyline's or the dev feed's stand-in), and a turn's plan windows for its usage
/// mark. A headless host supplies its own.
@MainActor
package protocol ChatServices: AnyObject {
    /// The chat's backend, made as it first needs one.
    func makeBackend(_ provider: ProviderDescriptor, _ options: BackendOptions) -> any ChatBackend
    /// The plan's windows a turn reported (`BackendOptions.planWindows`).
    func planWindows(_ cli: String, _ snapshot: PlanSnapshot?)
}

/// One chat's line to its CLI: the backend, made on first use; the pump that hands each of its
/// events on, in order; the CLI's start, tried again when it won't; and the send chain, where
/// each send waits for the one before to reach the CLI. Every piece of async work belongs to
/// one transport lifetime (`workEpoch`): starting again or closing ends what the old one had
/// under way. What the events mean is the chat's.
@MainActor
package final class ChatEngine {
    package let provider: ProviderDescriptor
    private let services: any ChatServices

    package private(set) var backend: (any ChatBackend)?
    private var pump: Task<Void, Never>?
    /// The latest send: each waits for the one before to reach the CLI, so a message sent while
    /// the CLI is still starting can't overtake the first.
    package private(set) var sending: Task<Void, Never>?
    /// Every asynchronous send/start belongs to one transport lifetime. Cancelling the last
    /// task alone cannot stop earlier tasks waiting in the send chain.
    package private(set) var workEpoch: UInt64 = 0
    /// Its tab closed: nothing of it counts as running any more.
    package private(set) var closed = false
    /// The CLI's start under way, its retries included, and the work it's for: whatever needs
    /// the CLI meanwhile waits on this one (an account's change starts work of its own).
    private var launching: (epoch: UInt64, task: Task<Error?, Never>)?
    /// Runs before the first replayed (or corrected) history is handed on, while set: what it
    /// returns runs after, if the work is still current. An imported chat reads its carried part
    /// here, so it shows before the chat's own history.
    package var beforeHistory: (@MainActor () async -> @MainActor () -> Void)?

    /// Waits before each start again of a CLI that wouldn't start. A storyline sets them shorter.
    package static let startRetries = HostSetting<[Duration]>([.seconds(2), .seconds(5), .seconds(10)])

    package init(provider: ProviderDescriptor, services: any ChatServices) {
        self.provider = provider
        self.services = services
    }

    package func currentWork(_ epoch: UInt64) -> Bool { !closed && workEpoch == epoch }

    /// A new transport lifetime: work of the old one stops at its next check.
    @discardableResult
    package func newWork() -> UInt64 {
        workEpoch &+= 1
        return workEpoch
    }

    /// The backend, made on first use with `options`; its events go to `handle`, one at a time.
    package func connect(_ options: () -> BackendOptions, handle: @escaping @MainActor (ChatEvent) -> Void) -> any ChatBackend {
        if let backend { return backend }
        var options = options()
        let (cli, services) = (provider.id, services)
        options.planWindows = { services.planWindows(cli, $0) }
        let backend = services.makeBackend(provider, options)
        self.backend = backend
        pump = Task {
            for await event in backend.events {
                guard !Task.isCancelled, !closed else { break }
                let epoch = workEpoch
                if let before = beforeHistory, Self.isReplay(event) || Self.isCorrection(event) {
                    let after = await before()
                    guard currentWork(epoch), !Task.isCancelled else { continue }
                    after()
                }
                handle(event)
            }
        }
        return backend
    }

    /// Starts the CLI; one that won't (being updated, just removed, ending at once) is tried
    /// again a few times (`startRetries`) before it's given up on, `retrying` said once, at the
    /// first. Nil once it's up, else the last failure; the next call tries again.
    package func launch(_ connect: () -> any ChatBackend, retrying: @escaping @MainActor (Error) -> Void) async -> Error? {
        let epoch = workEpoch
        if let launching, launching.epoch == epoch { return await launching.task.value }
        let backend = connect()
        let task = Task { [weak self] () -> Error? in
            let retries = Self.startRetries.value
            var waits = retries[...]
            while true {
                do {
                    try await backend.start()
                    return nil
                } catch {
                    guard let self, self.currentWork(epoch), Self.retriable(error), let wait = waits.popFirst() else { return error }
                    if waits.count == retries.count - 1 { retrying(error) }
                    try? await Task.sleep(for: wait)
                    if Task.isCancelled || !self.currentWork(epoch) { return CancellationError() }
                }
            }
        }
        launching = (epoch, task)
        let error = await task.value
        if launching?.epoch == epoch { launching = nil }
        return error
    }

    /// A start that may work a moment later: not one the CLI refused (it would again), one
    /// cancelled, or one held by an account's change.
    private static func retriable(_ error: Error) -> Bool {
        !["refused", "stopping", "cancelled"].contains(SessionLog.cause(error))
    }

    /// Puts `work` on the send chain: it runs after `previous` has, while `epoch` is current
    /// and it isn't cancelled.
    package func chain(after previous: Task<Void, Never>?, _ epoch: UInt64, _ work: @escaping @MainActor () async -> Void) {
        sending = Task {
            guard currentWork(epoch), !Task.isCancelled else { return }
            await previous?.value
            guard currentWork(epoch), !Task.isCancelled else { return }
            await work()
        }
    }

    package func cancelSending() { sending?.cancel() }

    /// Its tab closed: no work of it is current any more, and the send under way stops.
    package func close() {
        closed = true
        workEpoch &+= 1
        sending?.cancel()
    }

    /// The pump stops and the CLI ends.
    package func shutDown() {
        pump?.cancel()
        let backend = backend
        self.backend = nil
        Task { await backend?.close() }
    }

    package static func isReplay(_ event: ChatEvent) -> Bool {
        if case .replayed = event { return true }
        return false
    }

    package static func isCorrection(_ event: ChatEvent) -> Bool {
        if case .historyReplaced = event { return true }
        return false
    }
}
