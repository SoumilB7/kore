import Foundation
import KoreCore
import Observation

/// Account-list reads use the login's own CLI folder, never an open chat's session. One read
/// at a time, only while the list is visible, with a minute's cache shared across windows.
@MainActor @Observable
final class LoginUsage {
    static let shared = LoginUsage()

    struct Key: Hashable {
        let provider: String
        let login: String?
        let email: String?
        let workspace: String?
        let signedOut: Bool
        let generation: Int

        init(_ provider: String, _ login: AccountStore.Login, generation: Int) {
            self.provider = provider
            self.login = login.id
            email = login.email?.lowercased()
            workspace = login.workspace
            signedOut = login.signedOut
            self.generation = generation
        }

        func sameIdentity(as other: Key) -> Bool {
            provider == other.provider && login == other.login && email == other.email
                && workspace == other.workspace && signedOut == other.signedOut
        }
    }

    enum State: Equatable {
        case loading
        case ready(PlanReading, Date)
        case unavailable
    }

    private(set) var states: [Key: State] = [:]
    @ObservationIgnored private var attempted: [Key: Date] = [:]
    private struct Request: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        let completion: Completion
    }
    @MainActor private final class Completion { var done = false }
    @ObservationIgnored private var requests: [Key: Request] = [:]
    @ObservationIgnored private var currentKeys: [String: Set<Key>] = [:]
    @ObservationIgnored private var waiters: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var epoch = 0
    private let read: @MainActor (String, String?) async throws -> PlanReading
    private let clock: @MainActor () -> Date

    init(
        read: @escaping @MainActor (String, String?) async throws -> PlanReading = { provider, login in
            // A storyline without a usage fixture must never fall through to a real CLI.
            if StoryHost.installed {
                guard let read = StorylineSeams.loginUsage else { throw UsageUnavailable() }
                return try await read(provider, login)
            }
            return try await CLIProfiles.$pinned.withValue(.init(cli: provider, id: login)) {
                switch provider {
                case "claude": try await PlanUsage.claude()
                case "codex": try await PlanUsage.codex()
                default: throw UsageUnavailable()
                }
            }
        },
        clock: @escaping @MainActor () -> Date = Date.init
    ) {
        self.read = read
        self.clock = clock
    }

    func state(_ key: Key) -> State { states[key] ?? confirmed(key) ?? .loading }

    /// A global account generation changes all keys, even for logins whose identity did not
    /// change. Their own last verified reading stays visible until their new read completes.
    private func confirmed(_ key: Key) -> State? {
        guard !key.signedOut, key.email != nil else { return nil }
        return states.compactMap { old, state -> (State, Date)? in
            guard old.sameIdentity(as: key),
                  case .ready(let reading, let at) = state, Self.matches(reading.account, key) else { return nil }
            return (state, at)
        }.max { $0.1 < $1.1 }?.0
    }

    func reset() {
        epoch += 1
        for request in requests.values { request.task.cancel() }
        requests = [:]
        currentKeys = [:]
        waiters = [:]
        tail = nil
        states = [:]
        attempted = [:]
    }

    /// Refresh in display order. Cancelling the view stops queued work and the current read;
    /// another window may join an existing request rather than start a second CLI.
    func refresh(_ keys: [Key]) async {
        guard !Task.isCancelled else { return }
        let epoch = epoch
        // Carry verified readings across a generation before discarding obsolete keys.
        for key in keys where states[key] == nil {
            if let reading = confirmed(key) { states[key] = reading }
        }
        // Discard removed logins and prior identities, including their old percentages.
        let kept = Set(keys)
        let providers = Set(keys.map(\.provider))
        for provider in providers { currentKeys[provider] = kept.filter { $0.provider == provider } }
        // An old identity's cancelled read can ignore cancellation until its CLI exits.
        // Remove its token now so it cannot restore a pruned reading when it returns.
        for (key, request) in requests where providers.contains(key.provider) && !kept.contains(key) {
            request.task.cancel()
            requests[key] = nil
        }
        states = states.filter { !providers.contains($0.key.provider) || kept.contains($0.key) }
        attempted = attempted.filter { !providers.contains($0.key.provider) || kept.contains($0.key) }
        for key in keys {
            guard !Task.isCancelled, self.epoch == epoch, currentKeys[key.provider]?.contains(key) == true else { return }
            guard !key.signedOut, key.email != nil else {
                states[key] = .unavailable
                continue
            }
            if let request = requests[key], !request.task.isCancelled {
                await wait(request)
                if !request.task.isCancelled { continue }
            }
            guard !Task.isCancelled, self.epoch == epoch, currentKeys[key.provider]?.contains(key) == true else { return }
            if requests[key]?.task.isCancelled == true { attempted[key] = nil }
            if let at = attempted[key], clock().timeIntervalSince(at) < 60 { continue }
            let before = tail
            let token = UUID()
            let completion = Completion()
            let task = Task {
                defer { completion.done = true }
                await before?.value
                guard !Task.isCancelled, self.epoch == epoch, requests[key]?.id == token else { return }
                if case .ready = states[key] { } else { states[key] = .loading }
                attempted[key] = clock()
                UILog.event("account-usage-read", ["cli": key.provider, "login": AccountStore.loginKey(key.login)])
                let reading = try? await read(key.provider, key.login)
                guard !Task.isCancelled else {
                    if requests[key]?.id == token {
                        if case .ready = states[key] { } else { states[key] = nil }
                        attempted[key] = nil
                    }
                    return
                }
                guard self.epoch == epoch, requests[key]?.id == token else { return }
                if let reading {
                    // A confirmed different identity must clear the old reading immediately.
                    states[key] = Self.matches(reading.account, key) ? .ready(reading, clock()) : .unavailable
                } else if case .ready = states[key] {
                    // Transient failures keep the real timestamp of the last confirmed read.
                } else {
                    states[key] = .unavailable
                }
            }
            let request = Request(id: token, task: task, completion: completion)
            requests[key] = request
            tail = task
            await wait(request)
            if self.epoch == epoch, requests[key]?.id == token { requests[key] = nil }
        }
    }

    /// A closing window releases its interest; it cancels the CLI only if no other window
    /// still needs that read. This also removes queued work before another CLI starts.
    private func wait(_ request: Request) async {
        let ticket = UUID()
        waiters[request.id, default: []].insert(ticket)
        await withTaskCancellationHandler {
            await request.task.value
        } onCancel: {
            Task { @MainActor in self.leave(request, ticket: ticket) }
        }
        leave(request, ticket: ticket)
    }

    private func leave(_ request: Request, ticket: UUID) {
        guard waiters[request.id]?.remove(ticket) != nil else { return }
        if waiters[request.id]?.isEmpty == true {
            waiters[request.id] = nil
            if !request.completion.done { request.task.cancel() }
        }
    }

    /// A folder can have been signed into as someone else since the row was built. An email
    /// is required for plan limits; Claude's organisation must also agree when known.
    static func matches(_ account: PlanAccount, _ key: Key) -> Bool {
        guard account.access != .signedOut,
            let email = key.email, !email.isEmpty, account.email?.lowercased() == email
        else { return false }
        if key.provider == "claude", let workspace = key.workspace, !workspace.isEmpty {
            return account.organization == workspace || account.organization == nil && account.plan == workspace
        }
        if key.provider == "codex", let workspace = key.workspace, !workspace.isEmpty {
            return account.plan == workspace
        }
        return true
    }

    /// The two account-wide limits keep a login compact; model-specific windows remain in
    /// Usage. These are the plan's totals, so the list never invents a Kore share or hatch.
    static func bars(_ reading: PlanReading) -> [PlanLimit] {
        Array((reading.limits?.bars ?? []).filter { $0.scope == nil }.prefix(2))
    }
}
