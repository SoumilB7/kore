import AppKit
import KoreCore
import Observation

/// Each CLI's login, app-wide: who it's signed in as, the one sign-in (or sign-out) under way
/// for it, and a generation that goes up whenever the account changes, so every chat of that
/// CLI starts its CLI again (with resume) at its next turn boundary. A flow lives here, not in
/// a popup: closing the popup never cancels it, and the next open shows it. Changes made
/// outside Kore are caught by watching each CLI's login file and by a check when Kore becomes
/// active; they show nothing but the restart.
@MainActor @Observable
package final class AccountStore {
    package static let shared = AccountStore()

    /// The longest a sign-in waits for the browser before it's cancelled.
    static let patience: Duration = .seconds(10 * 60)
    /// A device code's: Codex's own expiry ends it first.
    static let deviceExpiry: Duration = .seconds(15 * 60)

    package enum Status: Equatable {
        case unknown
        case signedIn(AccountIdentity)
        case signedOut
        /// The read failed: the CLI's reason, in a line, if it gave one.
        case unreadable(String?)
    }

    /// The action row's state while it isn't at rest.
    package enum Step: Equatable {
        case starting
        case browser(URL)
        case code(String, URL)
        /// Handed to Terminal; ends when the account changes.
        case terminal
        /// The `awsAuthRefresh` script running.
        case refreshing
        /// A typed key on its way (it takes under a second: no Cancel).
        case signingIn
        case signingOut
        case signedIn
        case switched
        case same
        case refreshed
        /// A platform form saved.
        case saved
        /// A platform or Kore's key removed, a login still underneath: its name.
        case signedOutOf(String)
        case failed(String?)
        /// A typed key refused: the field comes back, saying why.
        case keyFailed(String?)
        case refreshFailed(String?)
        case signOutFailed(String?)
        case timedOut

        /// A sign-in or sign-out under way, not an outcome.
        var live: Bool {
            switch self {
            case .starting, .browser, .code, .terminal, .refreshing, .signingIn, .signingOut: true
            default: false
            }
        }

        /// It can be cancelled.
        var cancellable: Bool {
            switch self {
            case .starting, .browser, .code, .terminal, .refreshing: true
            default: false
            }
        }
    }

    package struct Flow: Equatable {
        /// The method it runs; nil for a sign-out.
        let method: String?
        var step: Step
        /// Over an account already signed in.
        let switching: Bool
    }

    private(set) var statuses: [String: Status] = [:]
    /// What each CLI's settings allow, from its last status read.
    private(set) var policies: [String: LoginPolicy] = [:]
    private(set) var flows: [String: Flow] = [:]
    private(set) var generations: [String: Int] = [:]
    /// Providers being read now.
    private(set) var reading: Set<String> = []

    /// The method each CLI last ran from Kore, for the ⌄ menu's ✓ and a plain Sign in.
    @ObservationIgnored private var lastMethod: [String: String] = [:]
    /// The last account each CLI was known to have ("" signed out), for telling a change.
    @ObservationIgnored private var known: [String: String] = [:]
    @ObservationIgnored private var handles: [String: SignInHandle] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    /// Each flow's own number: an answer for a flow cancelled or replaced since is dropped.
    @ObservationIgnored private var serials: [String: Int] = [:]
    @ObservationIgnored private var reads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var chats: [WeakChat] = []
    @ObservationIgnored private var watches: [String: FileWatch] = [:]
    @ObservationIgnored private var stamps: [String: String?] = [:]
    @ObservationIgnored private var settling: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activation = Throttle(interval: 30)
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    /// Goes up with each `reset()`: a read begun before it is dropped.
    @ObservationIgnored private var epoch = 0

    // MARK: Reading

    func status(_ provider: String) -> Status { statuses[provider] ?? .unknown }
    func flow(_ provider: String) -> Flow? { flows[provider] }
    func generation(_ provider: String) -> Int { generations[provider] ?? 0 }
    func isReading(_ provider: String) -> Bool { reading.contains(provider) }

    /// The CLI's login operations: a storyline host's scripted ones, else the CLI's own.
    private func ops(_ provider: String) -> AccountOps? {
        guard let ops = Registry.provider(provider)?.account else { return nil }
        guard let calls = StorylineSeams.accounts?(provider) else { return ops }
        return AccountOps(methods: ops.methods, parse: ops.parse, calls: calls, loginFile: ops.loginFile, stamp: ops.stamp)
    }

    /// Every method the CLI's login has.
    func allMethods(_ provider: String) -> [SignInMethod] { ops(provider)?.methods ?? [] }

    func policy(_ provider: String) -> LoginPolicy { policies[provider] ?? LoginPolicy() }

    /// The methods the CLI's policy lets the menu list, in its order.
    func methods(_ provider: String) -> [SignInMethod] {
        let policy = policy(provider)
        return allMethods(provider).filter { $0.allowed(by: policy) }
    }

    /// The ⌄ menu: those methods in their submenus, the current one checked.
    func menu(_ provider: String) -> [MethodMenuItem] {
        MethodMenuItem.build(allMethods(provider), policy: policy(provider), current: currentMethod(provider)?.id)
    }

    /// The method a plain Sign in runs: the last one Kore ran, else the account's own, else the
    /// first.
    func currentMethod(_ provider: String) -> SignInMethod? {
        let runnable = methods(provider)
        let current: String? =
            if case .signedIn(let identity) = status(provider) { identity.methodID } else { nil }
        for id in [lastMethod[provider], current].compactMap({ $0 }) {
            if let method = runnable.first(where: { $0.id == id }) { return method }
        }
        return runnable.first
    }

    /// Reads the CLI's status once (a read already under way is waited for).
    func refresh(_ provider: String) async {
        if let read = reads[provider] { return await read.value }
        guard let ops = ops(provider) else { return }
        reading.insert(provider)
        let epoch = epoch
        let read = Task {
            let result: Result<JSONValue, any Error>
            do { result = .success(try await ops.calls.status()) } catch { result = .failure(error) }
            guard self.epoch == epoch else { return }
            switch result {
            case .success(let reply):
                policies[provider] = LoginPolicy(reply)
                note(provider, ops.parse(reply))
            case .failure(let error): statuses[provider] = .unreadable(AccountReason.of(error))
            }
            reading.remove(provider)
            reads[provider] = nil
        }
        reads[provider] = read
        await read.value
    }

    /// What a read found. A new account (or a sign-out) raises the generation, and the CLI's
    /// chats start again at their next turn boundary.
    private func note(_ provider: String, _ reading: AccountReading) {
        let key: String
        switch reading {
        case .signedIn(let identity):
            statuses[provider] = .signedIn(identity)
            key = [identity.email?.lowercased() ?? "", identity.organization ?? "", identity.method].joined(separator: "\u{1F}")
        case .signedOut:
            statuses[provider] = .signedOut
            key = ""
        }
        defer { known[provider] = key }
        guard let before = known[provider], before != key else { return }
        bump(provider)
        // A Terminal hand-off ends when the account it was for shows up.
        if flows[provider]?.step == .terminal, case .signedIn = reading {
            serials[provider, default: 0] += 1
            let handle = end(provider)
            Task { await handle?.cancel() }
            flows[provider]?.step = before.isEmpty ? .signedIn : .switched
        }
    }

    /// The account (or how the CLI reaches it) changed: every chat of the CLI starts again at its
    /// next turn boundary.
    private func bump(_ provider: String) {
        generations[provider, default: 0] += 1
        for chat in liveChats(provider) { chat.accountChanged() }
    }

    // MARK: Signing in and out

    /// Starts a sign-in by `method` (nil: `currentMethod`). Over an account, it's a switch: the
    /// old login works until the new one lands. One flow at a time per CLI.
    func signIn(_ provider: String, method: SignInMethod? = nil, in folder: URL) {
        guard flows[provider]?.step.live != true, let ops = ops(provider), let method = method ?? currentMethod(provider), method.runs,
            !method.opensEditor
        else { return }
        let serial = (serials[provider] ?? 0) + 1
        serials[provider] = serial
        let before: AccountIdentity? = if case .signedIn(let identity) = status(provider) { identity } else { nil }
        lastMethod[provider] = method.id
        let refreshing = method.mechanism == .awsRefresh
        flows[provider] = Flow(method: method.id, step: refreshing ? .refreshing : .starting, switching: before != nil && !refreshing)
        Task {
            do {
                let handle = try await ops.calls.signIn(method.mechanism, SignInContext(folder: folder))
                guard serials[provider] == serial else { return await handle.cancel() }
                handles[provider] = handle
                if let url = handle.url {
                    if !handle.opensItself { Self.open(url) }
                    flows[provider]?.step = handle.code.map { .code($0, url) } ?? .browser(url)
                } else if !refreshing {
                    flows[provider]?.step = .terminal
                }
                // The store lives as long as the app.
                timers[provider] = Task {
                    try? await Task.sleep(for: handle.code == nil ? Self.patience : Self.deviceExpiry)
                    guard !Task.isCancelled else { return }
                    timeOut(provider, serial: serial)
                }
                let reply = try await handle.wait()
                guard serials[provider] == serial else { return }
                end(provider)
                if refreshing {
                    flows[provider]?.step = .refreshed
                    await refresh(provider)
                    return
                }
                let reading: AccountReading
                if let reply { reading = ops.parse(reply) } else { reading = ops.parse(try await ops.calls.status()) }
                guard serials[provider] == serial else { return }
                note(provider, reading)
                let step: Step
                if let before {
                    step = if case .signedIn(let now) = reading, now.isSameAccount(as: before) { .same } else { .switched }
                } else {
                    step = .signedIn
                }
                flows[provider]?.step = step
            } catch {
                guard serials[provider] == serial else { return }
                end(provider)
                flows[provider]?.step = refreshing ? .refreshFailed(AccountReason.of(error)) : .failed(AccountReason.of(error))
            }
        }
    }

    /// A typed key, sent once: the CLI takes it (Codex), or Kore keeps it in the Keychain for
    /// Claude's helper. `done` says whether it landed; on failure the row says why and the field
    /// comes back. The key goes nowhere else.
    func useKey(_ provider: String, _ key: String, done: @escaping @MainActor (Bool) -> Void) {
        guard flows[provider]?.step.live != true, let ops = ops(provider), let method = allMethods(provider).first(where: \.isKey)
        else { return done(false) }
        let serial = (serials[provider] ?? 0) + 1
        serials[provider] = serial
        let before: AccountIdentity? = if case .signedIn(let identity) = status(provider) { identity } else { nil }
        lastMethod[provider] = method.id
        flows[provider] = Flow(method: method.id, step: .signingIn, switching: before != nil)
        Task {
            do {
                let reply = try await ops.calls.useKey(key)
                let reading: AccountReading
                if let reply { reading = ops.parse(reply) } else { reading = ops.parse(try await ops.calls.status()) }
                guard serials[provider] == serial else { return }
                note(provider, reading)
                bumpIfSame(provider, before, reading)
                flows[provider]?.step = before == nil ? .signedIn : .switched
                done(true)
            } catch {
                guard serials[provider] == serial else { return }
                flows[provider]?.step = .keyFailed(AccountReason.of(error))
                done(false)
            }
        }
    }

    /// Saves a platform form into Claude's settings: then the status again, and every chat of the
    /// CLI starts again. `done` has the reason when it couldn't save.
    func save(_ provider: String, _ setup: ClaudeSettings.Setup, done: @escaping @MainActor (String?) -> Void) {
        guard flows[provider]?.step.live != true, let ops = ops(provider) else { return done(nil) }
        let serial = (serials[provider] ?? 0) + 1
        serials[provider] = serial
        let before: AccountIdentity? = if case .signedIn(let identity) = status(provider) { identity } else { nil }
        do {
            try ClaudeSettingsStore.change { ClaudeSettings.saving(setup, in: $0) }
        } catch {
            return done(AccountReason.of(error) ?? "Claude's settings couldn't be written.")
        }
        lastMethod[provider] = setup.platform.rawValue
        Task {
            let reading = (try? ops.parse(await ops.calls.status())) ?? .signedOut
            guard serials[provider] == serial else { return }
            note(provider, reading)
            bumpIfSame(provider, before, reading)
            flows[provider] = Flow(method: setup.platform.rawValue, step: .saved, switching: false)
            done(nil)
        }
    }

    /// The settings changed though the account reads the same (a key replaced, a region
    /// moved back): the chats still start again, to pick the settings up.
    private func bumpIfSame(_ provider: String, _ before: AccountIdentity?, _ reading: AccountReading) {
        if case .signedIn(let now) = reading, let before, now.isSameAccount(as: before) { bump(provider) }
    }

    /// Stops a sign-in: back to rest, nothing said, the old login as it was.
    func cancel(_ provider: String) {
        guard let flow = flows[provider], flow.step.cancellable else { return }
        serials[provider, default: 0] += 1
        let handle = end(provider)
        flows[provider] = nil
        Task { await handle?.cancel() }
    }

    private func timeOut(_ provider: String, serial: Int) {
        guard serials[provider] == serial, flows[provider]?.step.live == true else { return }
        serials[provider, default: 0] += 1
        let handle = end(provider)
        flows[provider]?.step = .timedOut
        Task { await handle?.cancel() }
    }

    @discardableResult
    private func end(_ provider: String) -> SignInHandle? {
        timers.removeValue(forKey: provider)?.cancel()
        return handles.removeValue(forKey: provider)
    }

    /// Signs the CLI out everywhere on this Mac, after interrupting its working chats; then the
    /// popup is the signed-out row.
    func signOut(_ provider: String) {
        guard flows[provider]?.step.live != true, let ops = ops(provider) else { return }
        let serial = (serials[provider] ?? 0) + 1
        serials[provider] = serial
        let setting: AccountIdentity? = if case .signedIn(let identity) = status(provider), identity.isKoreSetting { identity } else { nil }
        flows[provider] = Flow(method: nil, step: .signingOut, switching: false)
        for chat in liveChats(provider) where chat.isWorking { chat.stop() }
        Task {
            do {
                if let setting {
                    // Kore's own setting: exactly what it wrote comes out of Claude's settings.
                    if let platform = setting.methodID.flatMap(ClaudeSettings.Platform.init(rawValue:)) {
                        try ClaudeSettingsStore.change { ClaudeSettings.removing(platform, from: $0) }
                    } else {
                        try ClaudeSettingsStore.removeKey()
                    }
                } else {
                    try await ops.calls.signOut()
                }
                let reading = (try? ops.parse(await ops.calls.status())) ?? .signedOut
                guard serials[provider] == serial else { return }
                note(provider, reading)
                if let setting {
                    bump(provider)
                    if case .signedIn = reading {
                        flows[provider] = Flow(method: nil, step: .signedOutOf(AccountText.header(setting)), switching: false)
                        return
                    }
                }
                flows[provider] = nil
            } catch {
                guard serials[provider] == serial else { return }
                flows[provider]?.step = .signOutFailed(AccountReason.of(error))
            }
        }
    }

    /// The popup closed: an outcome goes, and the next open shows rest. A flow under way goes on.
    func dismissOutcome(_ provider: String) {
        guard let flow = flows[provider], !flow.step.live else { return }
        flows[provider] = nil
    }

    /// How many of the CLI's chats, in any window, have a turn or a background agent running.
    func workingChats(_ provider: String) -> Int { liveChats(provider).filter(\.isWorking).count }

    // MARK: Chats

    func register(_ chat: Chat) {
        chats.removeAll { $0.chat == nil }
        chats.append(WeakChat(chat: chat))
    }

    private func liveChats(_ provider: String) -> [Chat] {
        chats.compactMap(\.chat).filter { $0.provider.id == provider }
    }

    // MARK: The browser and the clipboard

    /// Opens a sign-in page in the browser. Under a storyline host nothing opens: the host
    /// is told instead.
    private static func open(_ url: URL) {
        if StoryHost.installed {
            StorylineSeams.opened?(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Copy link / Copy code. A storyline host's copies go to a pasteboard of its own.
    func copy(_ text: String) {
        let board = StoryHost.installed ? NSPasteboard(name: .init("kore-storylines")) : .general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    // MARK: Changes outside Kore

    /// Watches each CLI's login file, and checks again when Kore becomes active (at most once a
    /// 30 s). Not under a storyline host, whose CLIs are scripted.
    func watch() {
        guard !StoryHost.installed, activeObserver == nil else { return }
        for provider in Registry.all.map(\.id) {
            guard let ops = ops(provider) else { continue }
            let file = ops.loginFile()
            stamps[provider] = ops.stamp.flatMap { stamp in (try? Data(contentsOf: file)).flatMap(stamp) }
            watches[provider] = FileWatch(file) { [weak self] in self?.fileChanged(provider) }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
    }

    /// Settles for a second (a login writes the file more than once), then reads the status if
    /// the account in it changed.
    private func fileChanged(_ provider: String) {
        settling[provider]?.cancel()
        settling[provider] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.settling[provider] = nil
            guard self.accountMoved(provider) else { return }
            await self.refresh(provider)
        }
    }

    /// Whether the file's account changed since last seen; always, for a file Kore doesn't read.
    private func accountMoved(_ provider: String) -> Bool {
        guard let ops = ops(provider) else { return false }
        guard let stamp = ops.stamp else { return true }
        let now = (try? Data(contentsOf: ops.loginFile())).flatMap(stamp)
        defer { stamps[provider] = now }
        return stamps[provider] != .some(now)
    }

    private func becameActive() {
        for watch in watches.values { watch.rearm() }
        checkHandOffs()
        guard activation.pass() else { return }
        for provider in statuses.keys where flows[provider]?.step.live != true {
            Task { await refresh(provider) }
        }
    }

    /// Back in Kore during a Terminal hand-off: read at once, whatever the throttle says.
    private func checkHandOffs() {
        for (provider, flow) in flows where flow.step == .terminal {
            Task { await refresh(provider) }
        }
    }

    // MARK: Storylines

    /// Back to nothing known, nothing under way (a storyline's start).
    package func reset() {
        epoch += 1
        for provider in Array(handles.keys) { let handle = end(provider); Task { await handle?.cancel() } }
        for provider in serials.keys { serials[provider, default: 0] += 1 }
        statuses = [:]
        policies = [:]
        flows = [:]
        known = [:]
        lastMethod = [:]
        reads = [:]
        reading = []
    }
}

private struct WeakChat {
    weak var chat: Chat?
}
