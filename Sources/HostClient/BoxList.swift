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
        /// A step failed: why, and what fixes it.
        case failed(String, Action?)
        /// SSH or kore-host didn't answer: why, and what fixes it.
        case unreachable(String, Action?)
    }

    /// What a box's line offers.
    package typealias Action = BoxFix

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
        /// Set up fine, with a catch to say (linger off).
        package var warning: String?
        /// What the machine is, as last found (kept across runs).
        package var machine: BoxMachine?
        /// What it lacks next to this Mac, as last compared.
        package var parity: BoxParity?
        package var id: String { alias }

        package init(alias: String) { self.alias = alias }

        /// The hover card's line: what kind of machine, and how kore-host runs there.
        package var kind: String? { machine?.kind }

        package var note: Note? {
            switch status {
            case .probing where folders.isEmpty: return Note(line: "Connecting…")
            case .working(let step): return Note(line: step)
            case .notSetUp:
                if let why = machine?.unsupported(alias) { return Note(line: why) }
                return Note(line: "Not set up on \(alias)", action: .setUp)
            case .stopped: return Note(line: "Stopped on \(alias)", action: .start)
            case .noGrant: return Note(line: "\(alias) doesn't know this Mac", action: .setUp)
            case .stale: return Note(line: "\(alias) needs an update", action: .update)
            case .failed(let why, let action): return Note(line: why, action: action)
            case .unreachable(let why, let action): return Note(line: why, action: action)
            case .ready:
                if older { return Note(line: "\(alias) needs an update", action: .update) }
                if let warning { return Note(line: warning) }
                if fresh { return Note(line: "Ready") }
                if let machine {
                    if ![BoxAgent.claude, .codex].contains(where: { machine.has($0.rawValue) }) {
                        return Note(line: "No agents on \(alias) yet", action: .setUpAgents)
                    }
                    if let missing = machine.missing(alias) {
                        return Note(line: missing.line, action: missing.command.map { machine.installsWithoutPassword(missing.tool) ? .install(missing.tool) : .copy($0) })
                    }
                }
                if let count = parity?.differences.count, count > 0 {
                    return Note(line: count == 1 ? "1 difference from this Mac" : "\(count) differences from this Mac", action: .differences(count))
                }
                return folders.isEmpty ? Note(line: "No folders on \(alias)") : nil
            case .unknown, .probing: return nil
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

    /// The kept boxes that are aliases or destinations (`BoxAddress`): any other is left out on load.
    private var listed: [String] { (defaults?.stringArray(forKey: Self.listedKey) ?? []).filter(BoxAddress.valid) }

    /// The list again from what's kept; what's known of each box stays.
    package func reload() {
        let old = Dictionary(boxes.map { ($0.alias, $0) }, uniquingKeysWith: { a, _ in a })
        boxes = listed.map { alias in
            var box = old[alias] ?? Box(alias: alias)
            if box.folders.isEmpty { box.folders = HostCache(alias: alias, root: cacheRoot).state()?.folders ?? [] }
            if box.machine == nil { box.machine = BoxMachine.cached(alias, root: cacheRoot) }
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

    /// What's typed as a box, trimmed: an alias from the SSH config or `user@host[:port]`; nil when
    /// it can't be one. The panel, the popup and sync all check with `BoxAddress` (letters, digits,
    /// `._-`, never an option or a shell character).
    package static func alias(_ typed: String) -> String? {
        BoxAddress(typed)?.name
    }

    /// Add a box…: listed from now on (in Kore's own list, not the SSH config), answered or not.
    package func add(_ typed: String) {
        guard let alias = Self.alias(typed) else { return }
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
        // The machine, once per box (kept after): found beside the link, over its own session.
        let finding = box(alias)?.machine == nil ? Task { await detect(alias) } : nil
        let found: (folders: [BoxFolder], older: Bool)? = await linked(alias) { (await $0.listFolders(), $0.hostOlder) }
        if let found {
            update(alias) {
                $0.status = .ready
                $0.folders = found.folders
                $0.older = found.older
            }
        }
        await finding?.value
    }

    // MARK: The machine

    /// Finds what the box is (one ssh session, reading only) and keeps it; compares it with this
    /// Mac again. Nil, with the line set, when ssh failed.
    @discardableResult
    package func detect(_ alias: String, deep: Bool = true) async -> BoxMachine? {
        do {
            let machine = try await makeSetup(alias, BoxSetup.grant(for: alias, defaults: defaults)).detect(deep: deep)
            machine.keep(alias, root: cacheRoot)
            update(alias) { $0.machine = machine }
            await compare(alias)
            return machine
        } catch {
            // Only when nothing better is known: the link's own answer says more.
            if case .probing = box(alias)?.status {} else if box(alias)?.status != .ready {
                update(alias) { $0.status = .unreachable(error.message, error.fix) }
            }
            return nil
        }
    }

    /// This Mac as a box would be found: once a run, again with `refresh`.
    @ObservationIgnored private var mac: BoxMachine?
    @ObservationIgnored package var findMac: @Sendable () async -> BoxMachine? = { await MacMachine.find() }

    /// The box against this Mac, from the machines as found and the logins each side said.
    package func compare(_ alias: String, macLogins: [String: BoxLogin] = [:], boxLogins: [String: BoxLogin] = [:], refresh: Bool = false) async {
        guard let machine = box(alias)?.machine else { return }
        if mac == nil || refresh { mac = await findMac() }
        guard let mac else { return }
        update(alias) { $0.parity = BoxParity.compare(mac: mac, box: machine, name: alias, macLogins: macLogins, boxLogins: boxLogins) }
    }

    /// Installs or updates a CLI there, then finds the machine again. The failure's line, or nil.
    package func install(_ agent: BoxAgent, on alias: String) async -> BoxSetup.Failure? {
        guard let machine = box(alias)?.machine else { return BoxSetup.Failure(message: "Check \(alias) first", fix: .tryAgain) }
        switch agent.install(on: machine, name: alias) {
        case .failure(let why): return why
        case .success(let script):
            let ran = await makeSetup(alias, BoxSetup.grant(for: alias, defaults: defaults)).shell.script(alias, script)
            await detect(alias)
            guard ran.ok else {
                if ran.status == AttachExit.sshFailed { return BoxSetup.sshFailure(alias, ran.output) }
                return BoxSetup.Failure(message: "\(agent.rawValue) didn't install" + (ran.lastLine.isEmpty ? "" : ": " + ran.lastLine), fix: nil)
            }
            return nil
        }
    }

    /// A tool that installs without a password there (Homebrew), then the machine again.
    package func installTool(_ tool: String, on alias: String) async -> BoxSetup.Failure? {
        guard let machine = box(alias)?.machine, machine.installsWithoutPassword(tool), let command = machine.installCommand(tool) else { return nil }
        let ran = await makeSetup(alias, BoxSetup.grant(for: alias, defaults: defaults)).shell.script(alias, "PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\n" + command + "\n")
        await detect(alias)
        return ran.ok ? nil : BoxSetup.Failure(message: "\(tool) didn't install: \(ran.lastLine)")
    }

    /// This Mac's git name and email, set there.
    package func setGitIdentity(name: String?, email: String?, on alias: String) async -> BoxSetup.Failure? {
        let ran = await makeSetup(alias, BoxSetup.grant(for: alias, defaults: defaults)).shell.script(alias, BoxParity.gitScript(name: name, email: email))
        await detect(alias, deep: false)
        return ran.ok ? nil : BoxSetup.Failure(message: "git on \(alias) didn't take it: \(ran.lastLine)")
    }

    // MARK: Setting a box up

    /// The line's action: set up (or grant this Mac again), start the service, update, try again,
    /// or install a tool. Set up agents, Fix and Copy are the view's.
    package func act(_ action: Action, on alias: String) async {
        switch action {
        case .setUp, .update:
            // Restarting it ends the turns running there: asked once first.
            let working = HostConnection.live(alias)?.chats.values.filter(\.running).count ?? 0
            if working > 0 {
                let line = working == 1 ? "1 chat is working on \(alias)" : "\(working) chats are working on \(alias)"
                update(alias) { $0.status = .failed(line, action == .setUp ? .setUpAnyway : .updateAnyway) }
                return
            }
            await act(action == .setUp ? .setUpAnyway : .updateAnyway, on: alias)
        case .setUpAnyway: await setUp(alias)
        case .start: await perform(alias, grant: nil, retry: .start) { setup, _ in try await setup.start(); return nil }
        case .updateAnyway: await perform(alias, grant: nil, retry: .update) { setup, step in try await setup.run(allow: false, step: step) }
        case .tryAgain:
            update(alias) { $0.status = .working("Checking \(alias)…") }
            guard await detect(alias) != nil else { return }
            update(alias) { $0.status = .unknown }
            await probe(alias)
        case .install(let tool):
            update(alias) { $0.status = .working("Installing \(tool) on \(alias)…") }
            let failed = await installTool(tool, on: alias)
            update(alias) { $0.status = failed.map { .failed($0.message, $0.fix) } ?? .ready }
        case .setUpAgents, .differences, .copy: break
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
        _ work: @escaping @MainActor (BoxSetup, @escaping @MainActor @Sendable (String) -> Void) async throws -> BoxSetup.Done?
    ) async {
        guard box(alias) != nil, !busy.contains(alias) else { return }
        busy.insert(alias)
        defer { busy.remove(alias) }
        let setup = makeSetup(alias, grant ?? BoxSetup.grant(for: alias, defaults: defaults))
        update(alias) { $0.status = .working(retry == .start ? "Starting…" : "Checking \(alias)…") }
        do {
            let done = try await work(setup) { [weak self] line in self?.update(alias) { $0.status = .working(line) } }
            if let done {
                done.machine.keep(alias, root: cacheRoot)
                update(alias) {
                    $0.warning = done.warning
                    $0.machine = done.machine
                }
            }
        } catch {
            let why = (error as? BoxSetup.Failure) ?? BoxSetup.Failure(message: "Couldn't reach \(alias)", fix: .tryAgain)
            HostLog.note(alias, "setup failed", why.message)
            update(alias) { $0.status = .failed(why.message, why.fix ?? retry) }
            return
        }
        if let grant { BoxSetup.setGrant(grant, for: alias, defaults: defaults) }
        update(alias) { $0.status = .working("Connecting…") }
        // A window already on the box dials again now.
        HostConnection.live(alias)?.retry()
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: settle) }
            await probe(alias)
            guard let status = box(alias)?.status, status == .stopped || status == .probing else { break }
        }
        if box(alias)?.status == .ready {
            update(alias) { $0.fresh = true }
            await compare(alias)
        }
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
            let status = Self.status(alias, phase: connection.phase, reason: connection.lastReason, lateHello: connection.lateHello)
            update(alias) { $0.status = status }
            return nil
        }
        return await work(connection)
    }

    /// Why a box didn't link, from how its link ended: ssh's exit status (attach's own codes, the
    /// shell's 126 and 127, ssh's 255) or the box's refusal.
    package static func status(_ alias: String, phase: HostConnection.Phase, reason: String?, lateHello: Bool = false) -> Status {
        if lateHello { return .unreachable("\(alias) waited too long for this Mac", .tryAgain) }
        if case .refused(let why) = phase {
            switch why {
            case .version: return .stale
            case .auth: return .noGrant
            // Another Kore here took over: nothing to set up, and setting up would log it out.
            case .replaced: return .unreachable(why.line(alias), nil)
            }
        }
        let unreachable = Status.unreachable("Can't reach \(alias)", .tryAgain)
        guard let ended = SSHTransport.exit(of: reason) else {
            // A link that ended without ssh's status: what it said.
            let said = reason?.lowercased() ?? ""
            return said.contains("not found") || said.contains("no such file") ? .notSetUp : unreachable
        }
        switch ended.status {
        case AttachExit.cantRun, AttachExit.notFound: return .notSetUp
        case AttachExit.notRunning.rawValue: return .stopped
        case AttachExit.noGrant.rawValue: return .noGrant
        case AttachExit.noRuntime.rawValue: return .unreachable("\(alias) stops kore-host when you log out · sudo loginctl enable-linger", nil)
        case AttachExit.sshFailed:
            let why = BoxSetup.sshFailure(alias, ended.line)
            return .unreachable(why.message, why.fix)
        default: return unreachable
        }
    }

    private func update(_ alias: String, _ change: (inout Box) -> Void) {
        guard let i = boxes.firstIndex(where: { $0.alias == alias }) else { return }
        change(&boxes[i])
    }
}
