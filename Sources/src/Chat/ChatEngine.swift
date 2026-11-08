import Foundation
import KoreCore

/// What the app around a chat supplies to it: the backend (the real CLI, or a storyline's or
/// the dev feed's stand-in), the transcript's view side and the chat's view state, the account,
/// stay awake, the network, logs and taps. A headless host supplies its own.
@MainActor
package protocol ChatServices: AnyObject {
    /// The chat's backend, made as it first needs one.
    func makeBackend(_ provider: ProviderDescriptor, _ options: BackendOptions) -> any ChatBackend
    /// The plan's windows a turn reported (`BackendOptions.planWindows`).
    func planWindows(_ cli: String, _ snapshot: PlanSnapshot?)
    /// The chat's CLI gets Kore's own tools (`kore`, its MCP server, Arsenal's notes): the Mac's do;
    /// a box has none.
    var agentTools: Bool { get }
    /// Instructions every chat's CLI starts with when it has none of its own (a box says where it runs).
    var instructions: URL? { get }
    /// A transcript as the app shows it, over its own `TranscriptLog`.
    func makeTranscript() -> any ChatTranscript
    /// A chat's view state (its popups, the agent map), kept by the chat for the app.
    func makeViewState() -> AnyObject
    /// A new chat: the account and stay awake follow it; its view state takes it.
    func register(_ chat: Chat)
    /// Its tab closed.
    func closed(_ chat: Chat)
    /// The CLI's login was refused: its status is read again.
    func refreshAccount(_ cli: String)
    /// A CLI's model list came (Arsenal keeps one per CLI).
    func modelsListed(_ cli: String, _ models: [ModelOption])
    /// Where the chat's CLI runs, for sharing model lists (`ModelCatalog`): nil for this
    /// machine's own CLIs; a box's chats share only that box's lists.
    var modelScope: String? { get }
    /// The chat's mode changed: an Arsenal it can't keep goes off.
    func arsenalFollowMode(_ chat: Chat)
    /// Every event, after the chat took it: storylines, the local link, the agent channel.
    func tap(_ chat: Chat, _ event: ChatEvent)
    /// One line in the app's interface log.
    func log(_ name: String, _ fields: KeyValuePairs<String, String?>)
    /// Replays are timed (a dev hook).
    var timeReplay: Bool { get }
    func logReplay(_ took: Duration)

    // MARK: Network
    var isOnline: Bool { get }
    /// Posted as the network goes or comes back.
    var networkChanged: Notification.Name { get }
    /// Returns once the network is back.
    func online() async

    // MARK: Stay awake
    /// Stay awake's clock, while it's set up.
    var awakeClock: (any AwakeClock)? { get }
    /// Stay awake is on.
    var stayingAwake: Bool { get }
    /// Stay awake goes on for a message set to go at a limit's reset; false when it was on already.
    func stayAwakeForReset() -> Bool
    /// That message went or was cancelled: Stay awake goes off, unless another chat waits on it.
    func releaseAwake(besides chat: Chat)
    /// The Mac slept since `date`.
    func sleptThrough(since date: Date) -> Bool

    // MARK: Files
    /// Composer attachments for files on disk.
    func attachments(_ urls: [URL]) -> [Attachment]
    /// A sent message's files, to attach again: those still on disk, and pictures known only as
    /// they were sent, saved again.
    func reattach(_ sent: [Attachment]) -> [Attachment]
}

extension ChatServices {
    package var modelScope: String? { nil }
}

/// What a chat asks of its transcript beyond the log: the rows' side of sending, drawing,
/// paging and unloading. The app's transcript store is one.
@MainActor
package protocol ChatTranscript: AnyObject {
    var log: TranscriptLog { get }
    var entries: [TranscriptLog.Entry] { get }
    var providerName: String { get set }
    var chatID: (() -> String?)? { get set }
    var provider: ProviderDescriptor? { get set }
    var pendingSendSince: Date? { get }
    var retryableTurn: String? { get }
    var workRunning: Bool { get }
    var earlierAvailable: Bool { get }
    var loadingEarlier: Bool { get }
    var mayHaveLeft: Bool { get }
    var userTurns: Int { get }
    /// The running sub-agents' ids, as the Agents button last drew them.
    var runningAgents: [String] { get }
    func apply(_ event: ChatEvent)
    func apply(_ event: ChatEvent, preserving observed: Set<String>)
    func sending(_ on: Bool, at date: Date)
    func drawNow()
    func compacting(_ on: Bool, at point: Int?)
    func connected(_ state: Connection)
    func forkedFrom(_ title: String)
    func continued(_ text: String, help: String)
    func carriedFrom(_ text: String, help: String)
    func compactionSummary(_ text: String, title: String?)
    func continues(turn: String?, at: Date?, sends: String?)
    func actionDenied()
    func approvalSettled(_ approval: String)
    func agent(_ id: String) -> TranscriptLog.AgentInfo?
    func keepLane(of id: String)
    func needsHistory(_ id: String) -> Bool
    func replaceLane(of id: String, with events: [ChatEvent])
    func prompt(of turn: String) -> String?
    func chips(_ entry: TranscriptLog.Entry) -> [Attachment]
    func startLoadingEarlier()
    func prepend(_ events: [ChatEvent], more: Bool)
    func earlierMessages(_ messages: [EarlierMessage])
    func unloadPoint(opening: Bool) -> TranscriptLog.Entry?
    func unload(before id: UUID, earlier marks: [EarlierMessage])
}

extension ChatTranscript {
    func sending(_ on: Bool) { sending(on, at: Date()) }
    func compacting(_ on: Bool) { compacting(on, at: nil) }
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
    /// Sees each of the backend's events as it came, before the chat takes it: a box hands them
    /// on to the Mac following the chat (link 1.5's `chat.events`).
    package var rawTap: (@MainActor (ChatEvent) -> Void)?

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
                rawTap?(event)
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
