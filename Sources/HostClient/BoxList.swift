import Foundation
import LinkProtocol
import Observation

/// The boxes this Mac lists: the hosts whose kore-host has answered once, and the ones added by
/// hand, each with what a probe last found and its folders. Nothing dials until a box is asked
/// about (its row opened): never on a timer. The other SSH hosts are suggestions for adding one.
@MainActor @Observable
package final class BoxList {
    package enum Status: Equatable, Sendable {
        /// Not probed this run.
        case unknown
        case probing
        /// kore-host answered.
        case ready
        /// SSH worked, but kore-host isn't on the box (or can't run there).
        case notSetUp
        /// kore-host is on the box, but its service isn't running.
        case stopped
        /// The box has no grant for this Mac, or turned its grant away.
        case noGrant
        /// The box's kore-host is too old to talk to this Kore.
        case stale
        /// Setting up, updating or starting: the step under way.
        case working(String)
        /// A setup step failed: why, and what tries again.
        case failed(String, Action)
        /// SSH or kore-host didn't answer.
        case unreachable(String)
    }

    /// What a box's line offers.
    package enum Action: Equatable, Sendable {
        /// Copy kore-host there, install its service and grant this Mac.
        case setUp
        /// `systemctl --user start kore-host`.
        case start
        /// Copy this Kore's kore-host there and restart it.
        case update

        package var title: String {
            switch self {
            case .setUp: "Set up"
            case .start: "Start"
            case .update: "Update"
            }
        }
    }

    /// The one line under an opened box, and the action beside it.
    package struct Note: Equatable, Sendable {
        package var line: String
        package var action: Action?

        package init(line: String, action: Action? = nil) {
            self.line = line
            self.action = action
        }
    }

    package struct Box: Identifiable, Equatable, Sendable {
        package var alias: String
        package var status = Status.unknown
        package var folders: [BoxFolder] = []
        /// Its kore-host answered, but is older than this Kore's.
        package var older = false
        /// Set up or updated a moment ago: "Ready" until the next probe.
        package var fresh = false
        package var id: String { alias }

        package init(alias: String) { self.alias = alias }

        package var note: Note? {
            switch status {
            case .probing where folders.isEmpty: Note(line: "Connecting…")
            case .working(let step): Note(line: step)
            case .notSetUp: Note(line: "Not set up on \(alias)", action: .setUp)
            case .stopped: Note(line: "Stopped on \(alias)", action: .start)
            case .noGrant: Note(line: "\(alias) doesn't know this Mac", action: .setUp)
            case .stale: Note(line: "\(alias) needs an update", action: .update)
            case .failed(let why, let action): Note(line: why, action: action)
            case .unreachable(let why): Note(line: why)
            case .ready where older: Note(line: "\(alias) needs an update", action: .update)
            case .ready where fresh: Note(line: "Ready")
            case .ready where folders.isEmpty: Note(line: "No folders on \(alias)")
            default: nil
            }
        }
    }

    package private(set) var boxes: [Box] = []

    package static let shared = BoxList()

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let hosts: () -> [String]
    @ObservationIgnored private let connection: @MainActor (String) -> HostConnection
    @ObservationIgnored private let makeSetup: @MainActor (String, String) -> BoxSetup
    @ObservationIgnored private let cacheRoot: URL
    @ObservationIgnored private var probes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var busy: Set<String> = []
    /// How long a probe waits for kore-host's state.
    @ObservationIgnored package var patience: Duration = .seconds(20)
    /// Between tries to reach a box its setup just started.
    @ObservationIgnored package var settle: Duration = .seconds(1)

    private static let listedKey = "boxHosts"
    /// Set once the boxes listed before each Mac named its own grant keep the name they were set
    /// up with by hand.
    private static let grantsNamedKey = "boxGrantsNamed"
    private static let handGrant = "laptop"

    package init(
        defaults: UserDefaults? = .standard, hosts: @escaping () -> [String] = { SSHHosts.aliases() },
        cacheRoot: URL = HostCache.root(), connection: (@MainActor (String) -> HostConnection)? = nil,
        setup: @escaping @MainActor (String, String) -> BoxSetup = { BoxSetup(alias: $0, grant: $1) }
    ) {
        self.defaults = defaults
        self.hosts = hosts
        self.cacheRoot = cacheRoot
        self.connection =
            connection ?? { alias in
                HostConnection.named(alias, grant: BoxSetup.grant(for: alias, defaults: defaults), command: BoxSetup.command(for: alias, defaults: defaults))
            }
        makeSetup = setup
        if let defaults, !defaults.bool(forKey: Self.grantsNamedKey) {
            for alias in defaults.stringArray(forKey: Self.listedKey) ?? [] where defaults.string(forKey: "boxGrant." + alias) == nil {
                BoxSetup.setGrant(Self.handGrant, for: alias, defaults: defaults)
            }
            defaults.set(true, forKey: Self.grantsNamedKey)
        }
        reload()
    }

    /// The kept aliases that are aliases (`SyncBox.validAlias`): any other is left out on load.
    private var listed: [String] { (defaults?.stringArray(forKey: Self.listedKey) ?? []).filter(SyncBox.validAlias) }

    /// The list again from what's kept; what's known of each box stays.
    package func reload() {
        let old = Dictionary(boxes.map { ($0.alias, $0) }, uniquingKeysWith: { a, _ in a })
        boxes = listed.map { alias in
            var box = old[alias] ?? Box(alias: alias)
            if box.folders.isEmpty { box.folders = HostCache(alias: alias, root: cacheRoot).state()?.folders ?? [] }
            return box
        }
    }

    /// SSH hosts not listed yet, for Add a box…, those starting with `typed` first.
    package func suggestions(_ typed: String = "") -> [String] {
        let shown = Set(listed)
        let typed = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let rest = hosts().filter { !shown.contains($0) }
        return typed.isEmpty ? rest : rest.filter { $0.lowercased().hasPrefix(typed) } + rest.filter { !$0.lowercased().hasPrefix(typed) && $0.lowercased().contains(typed) }
    }

    /// Add a box…: listed from now on, answered or not. An alias is a name from the SSH config,
    /// never an option (`-…`).
    package func add(_ alias: String) {
        let alias = alias.trimmingCharacters(in: .whitespaces)
        guard SyncBox.validAlias(alias) else { return }
        if !listed.contains(alias) { defaults?.set(listed + [alias], forKey: Self.listedKey) }
        if box(alias) == nil { boxes.append(Box(alias: alias)) }
    }

    /// Forgets a box on this Mac: its row, its copy of the box's state and its settings. Nothing
    /// changes on the box.
    package func remove(_ alias: String) {
        defaults?.set(listed.filter { $0 != alias }, forKey: Self.listedKey)
        BoxSetup.forget(alias, defaults: defaults)
        try? FileManager.default.removeItem(at: HostCache(alias: alias, root: cacheRoot).folder)
        boxes.removeAll { $0.alias == alias }
    }

    package func box(_ alias: String) -> Box? { boxes.first { $0.alias == alias } }

    /// Dials the box's kore-host once: its state and folders, then the link closes unless a window
    /// holds it. A probe already under way is the one waited on.
    package func probe(_ alias: String) async {
        if let running = probes[alias] { return await running.value }
        let task = Task { await run(alias) }
        probes[alias] = task
        await task.value
        probes[alias] = nil
    }

    /// A folder already on the box, added to what it serves.
    package func addFolder(_ alias: String, path: String) async -> Result<BoxFolder, HostRefusal> {
        await linked(alias) { connection in
            let result = await connection.addFolder(path)
            if case .success = result { self.update(alias) { $0.folders = connection.folders } }
            return result
        } ?? .failure(HostRefusal(message: "Can't reach \(alias)"))
    }

    private func run(_ alias: String) async {
        update(alias) {
            $0.status = .probing
            $0.fresh = false
        }
        let found: (folders: [BoxFolder], older: Bool)? = await linked(alias) { (await $0.listFolders(), $0.hostOlder) }
        if let found {
            update(alias) {
                $0.status = .ready
                $0.folders = found.folders
                $0.older = found.older
            }
        }
    }

    // MARK: Setting a box up

    /// The line's action: set up (or grant this Mac again), start the service, or update.
    package func act(_ action: Action, on alias: String) async {
        switch action {
        case .setUp: await setUp(alias)
        case .start: await perform(alias, grant: nil, retry: .start) { setup, _ in try await setup.start() }
        case .update: await perform(alias, grant: nil, retry: .update) { setup, step in try await setup.run(allow: false, step: step) }
        }
    }

    /// kore-host on the box, its service, and this Mac's grant (named after this Mac), then the link.
    package func setUp(_ alias: String) async {
        let grant = BoxSetup.macGrantName()
        await perform(alias, grant: grant, retry: .setUp) { setup, step in try await setup.run(allow: true, step: step) }
    }

    /// Runs one of the box's steps, then reaches it, a few times while its service comes up.
    private func perform(
        _ alias: String, grant: String?, retry: Action,
        _ work: @escaping @MainActor (BoxSetup, @escaping @MainActor @Sendable (String) -> Void) async throws -> Void
    ) async {
        guard box(alias) != nil, !busy.contains(alias) else { return }
        busy.insert(alias)
        defer { busy.remove(alias) }
        let setup = makeSetup(alias, grant ?? BoxSetup.grant(for: alias, defaults: defaults))
        update(alias) { $0.status = .working(retry == .start ? "Starting…" : "Checking \(alias)…") }
        do {
            try await work(setup) { [weak self] line in self?.update(alias) { $0.status = .working(line) } }
        } catch {
            let why = (error as? BoxSetup.Failure)?.message ?? "Couldn't reach \(alias)"
            HostLog.note(alias, "setup failed", why)
            update(alias) { $0.status = .failed(why, retry) }
            return
        }
        if let grant { BoxSetup.setGrant(grant, for: alias, defaults: defaults) }
        // A window already on the box dials again now.
        HostConnection.live(alias)?.retry()
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: settle) }
            await probe(alias)
            guard let status = box(alias)?.status, status == .stopped || status == .probing else { break }
        }
        if box(alias)?.status == .ready { update(alias) { $0.fresh = true } }
    }

    // MARK: Reaching a box

    /// Runs `work` while the box is linked (dialling it if no window holds it), or says why it
    /// can't be: nil then, the status set.
    private func linked<T>(_ alias: String, _ work: (HostConnection) async -> T) async -> T? {
        let connection = connection(alias)
        connection.retain()
        defer { connection.release() }
        let end = ContinuousClock.now + patience
        while ContinuousClock.now < end, !connection.isOnline, connection.phase != .offline {
            if case .refused = connection.phase { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard connection.isOnline else {
            let status = Self.status(alias, phase: connection.phase, reason: connection.lastReason)
            update(alias) { $0.status = status }
            return nil
        }
        return await work(connection)
    }

    /// Why a box didn't link, from how its link ended: ssh's exit status (attach's own codes, the
    /// shell's 126 and 127, ssh's 255) or the box's refusal.
    package static func status(_ alias: String, phase: HostConnection.Phase, reason: String?) -> Status {
        if case .refused(let why) = phase {
            switch why {
            case .version: return .stale
            case .auth: return .noGrant
            // Another Kore here took over: nothing to set up, and setting up would log it out.
            case .replaced: return .unreachable(why.line(alias))
            }
        }
        let unreachable = Status.unreachable("Can't reach \(alias)")
        guard let ended = SSHTransport.exit(of: reason) else {
            // A link that ended without ssh's status: what it said.
            let said = reason?.lowercased() ?? ""
            return said.contains("not found") || said.contains("no such file") ? .notSetUp : unreachable
        }
        switch ended.status {
        case AttachExit.cantRun, AttachExit.notFound: return .notSetUp
        case AttachExit.notRunning.rawValue: return .stopped
        case AttachExit.noGrant.rawValue: return .noGrant
        case AttachExit.noRuntime.rawValue: return .unreachable("\(alias) stops Kore when you log out · see the setup doc")
        default: return unreachable
        }
    }

    private func update(_ alias: String, _ change: (inout Box) -> Void) {
        guard let i = boxes.firstIndex(where: { $0.alias == alias }) else { return }
        change(&boxes[i])
    }
}
