import Foundation
import KoreCore
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

        /// What else the line offers after its action: beside Trust, Copy (for Terminal) and Check
        /// again; after a step the user does outside Kore (a Copy), Check again right there.
        package var more: [Action] {
            switch action {
            case .trust(let offer)?: return [.copy(offer.command), .checkAgain]
            case .copy?: return [.checkAgain]
            default: return []
            }
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
        /// Kore's tailnet there as Set up's last step left it (said with "Ready").
        package var own: NetNodeWire.Own?
        /// What the machine is, as last found (kept across runs).
        package var machine: BoxMachine?
        /// What it lacks next to this Mac, as last compared.
        package var parity: BoxParity?
        package var id: String { alias }

        package init(alias: String) { self.alias = alias }

        /// kore-host before 0.3.7: no `rekey`, so a Mac's new identity key never gets in there.
        package static func beforeRekey(_ version: String) -> Bool {
            let parts = HostWire.versionParts(version)
            return !parts.isEmpty && parts.lexicographicallyPrecedes([0, 3, 7])
        }

        /// The hover card's line: what kind of machine, and how kore-host runs there.
        package var kind: String? { machine?.kind }

        /// Its folders can be browsed: kore-host answered (or answered before and is being
        /// asked again); never while it's set up, updated or can't be reached.
        package var opensFolders: Bool {
            switch status {
            case .ready: return true
            case .unknown, .probing: return !folders.isEmpty
            default: return false
            }
        }

        package var note: Note? {
            switch status {
            case .probing where folders.isEmpty: return Note(line: "Connecting…")
            case .working(let step): return Note(line: step)
            case .notSetUp:
                if let why = machine?.unsupported(alias) { return Note(line: why) }
                return Note(line: "Not set up on \(NodeNames.name(alias))", action: .setUp)
            case .stopped: return Note(line: "Stopped on \(NodeNames.name(alias))", action: .start)
            case .noGrant:
                // A box from before 0.3.7 can't take this Mac's new key: Set up updates it.
                if let version = machine?.koreHostVersion, Self.beforeRekey(version) {
                    return Note(line: "\(NodeNames.name(alias)) doesn't know this Mac · update kore-host on \(NodeNames.name(alias))", action: .setUp)
                }
                return Note(line: "\(NodeNames.name(alias)) doesn't know this Mac", action: .setUp)
            case .stale: return Note(line: "\(NodeNames.name(alias)) needs an update", action: .update)
            case .failed(let why, let action): return Note(line: why, action: action)
            case .unreachable(let why, let action): return Note(line: why, action: action)
            case .ready:
                if older { return Note(line: "\(NodeNames.name(alias)) needs an update", action: .update) }
                if let warning { return Note(line: warning) }
                if fresh {
                    guard let own else { return Note(line: "Ready") }
                    return Note(line: "Ready · " + own.line, action: own.signedIn ? nil : own.page.map { .signIn($0) })
                }
                if let machine {
                    if ![BoxAgent.claude, .codex].contains(where: { machine.has($0.rawValue) }) {
                        return Note(line: "No agents on \(NodeNames.name(alias)) yet", action: .setUpAgents)
                    }
                    if let missing = machine.missing(alias) {
                        return Note(line: missing.line, action: missing.command.map { machine.installsWithoutPassword(missing.tool) ? .install(missing.tool) : .copy($0) })
                    }
                }
                if let count = parity?.differences.count, count > 0 {
                    return Note(line: count == 1 ? "1 difference from this Mac" : "\(count) differences from this Mac", action: .differences(count))
                }
                return folders.isEmpty ? Note(line: "No folders on \(NodeNames.name(alias))") : nil
            case .unknown, .probing: return nil
            }
        }
    }

    package private(set) var boxes: [Box] = []

    package static let shared: BoxList = {
        let list = BoxList()
        list.follow(.default)
        return list
    }()

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let hosts: () -> [String]
    @ObservationIgnored private let connection: @MainActor (String) -> HostConnection
    @ObservationIgnored private let makeSetup: @MainActor (String, String) -> BoxSetup
    /// Kore's copies of the boxes (`Kore/hosts`): KoreNet's folders are beside it (`nodes/`,
    /// `net/`). Tests point it at their own.
    @ObservationIgnored package var cacheRoot: URL
    @ObservationIgnored private var probes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var rekeys: (any NSObjectProtocol)?
    @ObservationIgnored private var busy: Set<String> = []
    /// Set up, Update or Start under way, by box: the step it's on (a second press says so, and
    /// no probe meanwhile puts the box's old line back).
    @ObservationIgnored private var working: [String: String] = [:]
    /// KoreNet's switch (Kore: the shared one; tests: theirs or none): a forgotten box's pin in
    /// this Mac's book goes, and phones hear the directory.
    @ObservationIgnored package var net: @MainActor () -> KoreNetSwitch? = { KoreNetSwitch.shared }
    /// KoreNet's boxes (Kore: the shared directory; tests: theirs).
    @ObservationIgnored package var directory: @MainActor () -> NodeDirectory = { .shared }
    /// The user said yes to Swift's Linux kit this run (asked once, on the box's line).
    @ObservationIgnored private var kitConsent = false
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

    /// The kept boxes that are aliases or destinations (`BoxAddress`): any other is left out on
    /// load, and one kept twice is listed once.
    private var listed: [String] {
        var seen = Set<String>()
        let directory = directory()
        return (defaults?.stringArray(forKey: Self.listedKey) ?? []).filter { key in
            // A KoreNet id is one when its box is in this list's directory and its alias, if it
            // still has one (its SSH route forgotten, KoreNet carries it), is.
            let valid = NodeDirectory.isNodeKey(key) ? directory.all[key.lowercased()].map { $0.ssh.map(BoxAddress.valid) ?? $0.rekeyed } == true : BoxAddress.valid(key)
            return valid && seen.insert(key).inserted
        }
    }

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

    /// A box's stores moved from `old` (its alias) to `new` (its KoreNet id): its row goes by the
    /// id from now on, with what's known of it (status, folders, machine). `NodeMigration` already
    /// rewrote the kept list; a row the id has already is the one kept.
    package func rekeyed(from old: String, to new: String) {
        guard old != new, let i = boxes.firstIndex(where: { $0.alias == old }) else { return }
        if boxes.contains(where: { $0.alias == new }) {
            boxes.remove(at: i)
        } else {
            boxes[i].alias = new
        }
        reload()
    }

    /// Follows each rekey posted on `center` (`koreNodeRekeyed`): Kore's own list does, from the
    /// start.
    package func follow(_ center: NotificationCenter) {
        if let rekeys { center.removeObserver(rekeys) }
        // Posted on the main actor (`NodeRekeyer`): followed before the post returns.
        rekeys = center.addObserver(forName: .koreNodeRekeyed, object: nil, queue: nil) { [weak self] note in
            guard let old = note.userInfo?["old"] as? String, let new = note.userInfo?["new"] as? String else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.rekeyed(from: old, to: new) }
            } else {
                Task { @MainActor in self?.rekeyed(from: old, to: new) }
            }
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

    /// Forgets a box on this Mac, by any key it goes by (its alias or its KoreNet id): every
    /// trace of it here goes (`BoxForget`), so adding it again is a first add. Nothing changes on
    /// the box.
    package func remove(_ key: String) {
        let names = forgetter.forget(key, listed: listed)
        for name in names {
            probes[name]?.cancel()
            probes[name] = nil
            busy.remove(name)
            working[name] = nil
            logins[name] = nil
        }
        boxes.removeAll { names.contains($0.alias) }
    }

    /// At launch, after the rekeys are finished: KoreNet's entries and this Mac's book records of
    /// boxes no longer listed go (a Remove that left them, or a crash mid-Remove). Twice is once.
    @discardableResult
    package func dropOrphans() -> [String] {
        forgetter.dropOrphans(listed: listed)
    }

    private var forgetter: BoxForget {
        BoxForget(defaults: defaults, directory: directory(), hosts: cacheRoot, net: net())
    }

    /// The listed box `key` names: its alias as listed, or the box listed under its other key
    /// (listed by alias while KoreNet keys it by id, or the other way round).
    package func box(_ key: String) -> Box? {
        if let box = boxes.first(where: { $0.alias == key }) { return box }
        return listedAlias(key).flatMap { alias in boxes.first { $0.alias == alias } }
    }

    /// The alias a box is listed under, for a key that isn't one: the KoreNet id an alias
    /// moved to, or the alias behind an id. Nil when no listed box goes by it.
    package func listedAlias(_ key: String) -> String? {
        if boxes.contains(where: { $0.alias == key }) { return key }
        let entries = directory().all
        guard !entries.isEmpty else { return nil }
        // Its KoreNet entry, by id or by the alias it was set up by: the box goes by both.
        guard let entry = entries[key.lowercased()] ?? entries.values.first(where: { $0.ssh == key }) else { return nil }
        let names = Set([entry.id.raw, entry.ssh].compactMap { $0 })
        return boxes.first { names.contains($0.alias) }?.alias
    }

    /// The box's link, for what holds it a while (its agents popup): retain, then release.
    package func link(_ alias: String) -> HostConnection { connection(alias) }

    /// Dials the box's kore-host once: its state and folders, then the link closes unless a window
    /// holds it. A probe already under way is the one waited on.
    package func probe(_ alias: String) async {
        // A set-up's steps own the line until they end (the probe after them is its own).
        if working[listedAlias(alias) ?? alias] != nil { return }
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
        } ?? .failure(HostRefusal(message: "Can't reach \(NodeNames.name(alias))"))
    }

    private func run(_ key: String) async {
        let alias = listedAlias(key) ?? key
        // Set up is copying or granting: its own probe comes after, this one would only put the
        // box's old line ("doesn't know this Mac") back over its steps.
        guard working[alias] == nil else { return }
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
        // U0: reached over SSH, it moves to KoreNet when it isn't there yet (KoreNet on).
        if found != nil || box(alias)?.status == .stale { KoreNetSwitch.shared?.upgrades?.reached(alias, fresh: true) }
        _ = await finding?.value
    }

    // MARK: The machine

    /// Finds what the box is (one ssh session, reading only) and keeps it; compares it with this
    /// Mac again. Nil, with the line set, when ssh failed.
    @discardableResult
    package func detect(_ alias: String, deep: Bool = true) async -> BoxMachine? {
        do {
            let machine = try await makeSetup(alias, BoxSetup.grant(for: alias, defaults: defaults)).detect(deep: deep)
            machine.keep(alias, root: cacheRoot)
            if !NodeDirectory.isNodeKey(alias) { directory().noteFound(machine.hostname, alias: alias) }
            noteKeys(alias)
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

    /// Each box's logins as last said (this Mac's, the box's): a compare after a fresh look at the
    /// machine (an install's) keeps them.
    @ObservationIgnored private var logins: [String: (mac: [String: BoxLogin], box: [String: BoxLogin])] = [:]

    /// The box against this Mac, from the machines as found and the logins each side said (nil:
    /// as they were last said).
    package func compare(_ alias: String, macLogins: [String: BoxLogin]? = nil, boxLogins: [String: BoxLogin]? = nil, refresh: Bool = false) async {
        guard let key = listedAlias(alias), let machine = box(key)?.machine else { return }
        let said = (mac: macLogins ?? logins[key]?.mac ?? [:], box: boxLogins ?? logins[key]?.box ?? [:])
        logins[key] = said
        if mac == nil || refresh { mac = await findMac() }
        guard let mac else { return }
        update(key) { $0.parity = BoxParity.compare(mac: mac, box: machine, name: alias, macLogins: said.mac, boxLogins: said.box) }
    }

    /// How long one install there may run, its downloads each bounded within it.
    @ObservationIgnored package var installLimit: Duration = .seconds(900)

    /// Installs or updates a CLI there, then finds the machine again and says how it went: nil
    /// when the CLI is there and not older than this Mac's; else the failure's one line (the
    /// script's own last line, a timeout, a look afterwards that failed, a version unchanged).
    package func install(_ agent: BoxAgent, on alias: String) async -> BoxSetup.Failure? {
        guard let machine = box(alias)?.machine else { return BoxSetup.Failure(message: "Check \(NodeNames.name(alias)) first", fix: .tryAgain) }
        let name = NodeNames.name(alias)
        switch agent.install(on: machine, name: alias) {
        case .failure(let why): return why
        case .success(let script):
            let ran = await makeSetup(alias, BoxSetup.grant(for: alias, defaults: defaults)).shell.script(alias, script, limit: installLimit)
            // Every install ends with a fresh look, failed or not: the card shows what's there now.
            let found = await detect(alias)
            guard ran.ok else {
                if ran.status == AttachExit.sshFailed { return BoxSetup.sshFailure(alias, ran.output) }
                return BoxSetup.Failure(message: "\(agent.rawValue) didn't install" + (ran.lastLine.isEmpty ? "" : ": " + ran.lastLine), fix: nil)
            }
            guard let found else { return BoxSetup.Failure(message: "\(agent.rawValue) installed, but \(name) didn't answer after", fix: .tryAgain) }
            guard found.has(agent.rawValue) || found.versions[agent.rawValue] != nil else {
                return BoxSetup.Failure(message: "\(agent.rawValue) installed, but \(name) doesn't find it on its PATH", fix: nil)
            }
            // The same version as before and still older than this Mac's: the update didn't take.
            if let now = found.versions[agent.rawValue], let before = machine.versions[agent.rawValue],
                BoxMachine.versionParts(before) == BoxMachine.versionParts(now),
                let here = mac?.versions[agent.rawValue], BoxMachine.older(now, than: here), let shown = BoxMachine.majorMinor(now)
            {
                return BoxSetup.Failure(message: "\(agent.rawValue) is still \(shown) on \(name)", fix: nil)
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
        return ran.ok ? nil : BoxSetup.Failure(message: "git on \(NodeNames.name(alias)) didn't take it: \(ran.lastLine)")
    }

    // MARK: Setting a box up

    /// The line's action: set up (or grant this Mac again), start the service, update, try again,
    /// install a tool, or install Swift's Linux kit and set up again. Set up agents, Fix, Copy and
    /// Show log are the view's.
    package func act(_ action: Action, on key: String) async {
        // Devices names a box by its KoreNet id, the Welcome by its alias: the listed one.
        let alias = listedAlias(key) ?? key
        switch action {
        case .setUp, .update:
            // Restarting it ends the turns running there: asked once first.
            let working = HostConnection.live(alias)?.chats.values.filter(\.running).count ?? 0
            if working > 0 {
                let line = working == 1 ? "1 chat is working on \(NodeNames.name(alias))" : "\(working) chats are working on \(NodeNames.name(alias))"
                update(alias) { $0.status = .failed(line, action == .setUp ? .setUpAnyway : .updateAnyway) }
                return
            }
            await act(action == .setUp ? .setUpAnyway : .updateAnyway, on: alias)
        case .setUpAnyway: await setUp(alias)
        case .start: await perform(alias, grant: nil, retry: .start) { setup, _ in try await setup.start(); return nil }
        case .updateAnyway: await perform(alias, grant: nil, retry: .update) { setup, step in try await setup.run(allow: false, step: step) }
        case .trust(let offer): await trust(offer, on: alias)
        case .tryAgain, .checkAgain:
            update(alias) { $0.status = .working("Checking \(NodeNames.name(alias))…") }
            guard await detect(alias) != nil else { return }
            update(alias) { $0.status = .unknown }
            await probe(alias)
        case .install(let tool):
            update(alias) { $0.status = .working("Installing \(tool) on \(NodeNames.name(alias))…") }
            let failed = await installTool(tool, on: alias)
            update(alias) { $0.status = failed.map { .failed($0.message, $0.fix) } ?? .ready }
        case .installLinuxKit(let update):
            kitConsent = true
            await act(update ? .update : .setUp, on: alias)
        case .setUpAgents, .differences, .copy, .showLog, .signIn, .relogin: break
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
        guard box(alias) != nil else {
            // Nothing listed by that key: nothing to show a line on, so it's in the log.
            return HostLog.note(alias, "setup", "not listed here")
        }
        guard !busy.contains(alias) else {
            // Pressed again while it runs: the line says so, with the step it's on.
            let step = working[alias].map { " · " + $0 } ?? ""
            let what = retry == .start ? "Start" : retry == .update ? "Update" : "Set up"
            return update(alias) { $0.status = .working("\(what) is already running" + step) }
        }
        busy.insert(alias)
        defer {
            busy.remove(alias)
            working[alias] = nil
        }
        var setup = makeSetup(alias, grant ?? BoxSetup.grant(for: alias, defaults: defaults))
        setup.mayInstallKit = kitConsent
        // Kore's tailnet is how this Mac reaches its boxes by default: Set up signs it in there.
        setup.signInOwn = KoreNetSwitch.shared?.on == true
        setup.openURL = { BoxUpgrades.shared.openURL($0) }
        let first = retry == .start ? "Starting…" : "Checking \(NodeNames.name(alias))…"
        working[alias] = first
        update(alias) { $0.status = .working(first) }
        do {
            let done = try await work(setup) { [weak self] line in
                guard let self, self.working[alias] != nil else { return }
                self.working[alias] = line
                self.update(alias) { $0.status = .working(line) }
            }
            if let done {
                done.machine.keep(alias, root: cacheRoot)
                if !NodeDirectory.isNodeKey(alias) { directory().noteFound(done.machine.hostname, alias: alias) }
                update(alias) {
                    $0.warning = done.warning
                    $0.machine = done.machine
                    $0.own = done.own
                }
            }
        } catch {
            let why = (error as? BoxSetup.Failure) ?? BoxSetup.Failure(message: "Couldn't reach \(NodeNames.name(alias))", fix: .tryAgain)
            HostLog.note(alias, "setup failed", why.message)
            // A new host key stopped Set up: its Trust goes on with it.
            if retry == .setUp, BoxSetup.isNewKey(why.message) { setUpStopped.insert(alias) }
            update(alias) { $0.status = .failed(why.message, why.fix ?? retry) }
            return
        }
        if let grant { BoxSetup.setGrant(grant, for: alias, defaults: defaults) }
        noteKeys(alias)
        // The box's part is done: probes may say how it is from here.
        working[alias] = nil
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
        // `.offline` with a dial under way isn't an end: a first add's tailnet try turned away
        // (the box still holds this Mac's old key) falls back to SSH at once, and that SSH link
        // gives the box the new key. Only an end with no dial after it is one.
        while ContinuousClock.now < end, !connection.isOnline, connection.phase != .offline || connection.dialing {
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
        if lateHello { return .unreachable("\(NodeNames.name(alias)) waited too long for this Mac", .tryAgain) }
        if case .refused(let why) = phase {
            switch why {
            case .version: return .stale
            case .auth: return .noGrant
            // Another Kore here took over: nothing to set up, and setting up would log it out.
            case .replaced: return .unreachable(why.line(alias), nil)
            case .paused: return .unreachable(why.line(alias), nil)
            case .oldKey: return .unreachable(why.line(alias), nil)
            }
        }
        let unreachable = Status.unreachable("Can't reach \(NodeNames.name(alias))", .tryAgain)
        guard let ended = SSHTransport.exit(of: reason) else {
            // A link that ended without ssh's status: what it said.
            let said = reason?.lowercased() ?? ""
            return said.contains("not found") || said.contains("no such file") ? .notSetUp : unreachable
        }
        switch ended.status {
        case AttachExit.cantRun, AttachExit.notFound: return .notSetUp
        case AttachExit.notRunning.rawValue: return .stopped
        case AttachExit.noGrant.rawValue: return .noGrant
        case AttachExit.noRuntime.rawValue: return .unreachable("\(NodeNames.name(alias)) stops kore-host when you log out · sudo loginctl enable-linger", nil)
        case AttachExit.sshFailed:
            let why = BoxSetup.sshFailure(alias, ended.line)
            return .unreachable(why.message, why.fix)
        default: return unreachable
        }
    }

    private func update(_ key: String, _ change: (inout Box) -> Void) {
        guard let alias = listedAlias(key), let i = boxes.firstIndex(where: { $0.alias == alias }) else { return }
        change(&boxes[i])
        if let line = Self.newKeyLine(boxes[i].status) { lookForKey(alias, line: line) }
    }

    /// Puts a status on a box's line as a step would (tests).
    package func injectStatus(_ key: String, _ status: Status) { update(key) { $0.status = status } }

    // MARK: A new host key

    /// Set up was stopped by a new host key: its Trust goes on with Set up.
    @ObservationIgnored private var setUpStopped: Set<String> = []
    @ObservationIgnored private var scanning: Set<String> = []
    /// ssh-keygen (tests: a stand-in).
    @ObservationIgnored package var keygen = BoxHostKey.keygen
    /// Looks for a new host key's fingerprint (`BoxHostKey.scan`); tests set their own, and a test
    /// process without one never runs ssh for it.
    @ObservationIgnored package var scanKey: (@Sendable (String, BoxShell, String) async -> (fingerprints: [String], lines: [String])?)? =
        KoreLog.isTestProcess ? nil : { @Sendable alias, shell, keygen in await BoxHostKey.scan(alias, shell: shell, keygen: keygen) }
    /// Where Trust writes (tests: theirs); nil: the file ssh's config names.
    @ObservationIgnored package var knownHosts: String?

    /// The keys ssh trusts a box with (`BoxHostKey.known`); tests set their own, as `scanKey`.
    @ObservationIgnored package var knownKeys: (@Sendable (String, BoxShell, String) async -> Set<String>)? =
        KoreLog.isTestProcess ? nil : { @Sendable alias, shell, keygen in await BoxHostKey.known(alias, shell: shell, keygen: keygen) }
    static let keysKey = "boxHostKeys."

    /// The SSH keys a box last had over `ssh`: what a new one is compared with. None for a box
    /// Kore hasn't reached over it since it keeps them, or one forgotten.
    package func keysSeen(_ ssh: String) -> Set<String> { Set(defaults?.stringArray(forKey: Self.keysKey + ssh) ?? []) }

    /// ssh just reached the box, so its key is one known_hosts holds: kept, for when its address changes.
    private func noteKeys(_ alias: String) {
        let ssh = directory().sshAlias(forKey: alias) ?? alias
        guard let knownKeys, let defaults, !NodeDirectory.isNodeKey(ssh) else { return }
        let shell = makeSetup(alias, BoxSetup.grant(for: alias, defaults: defaults)).shell
        let keygen = keygen
        Task { @MainActor in
            let keys = await knownKeys(ssh, shell, keygen)
            guard !keys.isEmpty, box(alias) != nil else { return }
            defaults.set(keys.sorted(), forKey: Self.keysKey + ssh)
        }
    }

    /// A status that's ssh's "host key is new" (before its fingerprint is known).
    private static func newKeyLine(_ status: Status) -> String? {
        switch status {
        case .failed(let line, .copy?), .unreachable(let line, .copy?): return BoxSetup.isNewKey(line) ? line : nil
        default: return nil
        }
    }

    /// The key the box shows, captured by ssh: the line then shows its fingerprint and Trust.
    /// While ssh can't get it, the line stays as it was (Copy, Check again).
    private func lookForKey(_ alias: String, line: String) {
        guard let scanKey, scanning.insert(alias).inserted else { return }
        let ssh = directory().sshAlias(forKey: alias) ?? alias
        let shell = makeSetup(alias, BoxSetup.grant(for: alias, defaults: defaults)).shell
        let keygen = keygen
        Task { @MainActor in
            let found = await scanKey(ssh, shell, keygen)
            scanning.remove(alias)
            guard let found, let box = box(alias), Self.newKeyLine(box.status) == line else { return }
            let against = BoxHostKey.against(keysSeen(ssh), found.lines)
            if against == .different {
                HostLog.note(alias, "host key", "different: " + found.fingerprints.joined(separator: ", "))
                update(alias) { $0.status = .failed(BoxHostKey.differentLine(ssh, found.fingerprints), .copy(BoxAddress(ssh)?.command() ?? "ssh " + ssh)) }
                return
            }
            let offer = BoxHostKey.Offer(
                ssh: ssh, fingerprints: found.fingerprints, lines: found.lines, command: BoxAddress(ssh)?.command() ?? "ssh " + ssh, moved: against == .same,
                setUp: setUpStopped.contains(alias))
            HostLog.note(alias, "host key", "new: " + found.fingerprints.joined(separator: ", "))
            update(alias) { $0.status = .failed(offer.line, .trust(offer)) }
        }
    }

    /// Trust: the key added as ssh's `accept-new` adds it (only while the box still shows it),
    /// then Set up goes on, or the box is looked at again.
    private func trust(_ offer: BoxHostKey.Offer, on alias: String) async {
        update(alias) { $0.status = .working("Trusting \(offer.ssh)'s key…") }
        let shell = makeSetup(alias, BoxSetup.grant(for: alias, defaults: defaults)).shell
        let file: String
        if let knownHosts { file = knownHosts } else { file = await BoxHostKey.knownHostsFile(offer.ssh, shell: shell) }
        switch await BoxHostKey.trust(offer, shell: shell, file: file, keygen: keygen) {
        case nil:
            HostLog.note(alias, "host key", "trusted: " + offer.fingerprints.joined(separator: ", "))
            defaults?.set(Array(keysSeen(offer.ssh).union(BoxHostKey.keys(offer.lines))), forKey: Self.keysKey + offer.ssh)
            setUpStopped.remove(alias)
            await act(offer.setUp ? .setUp : .checkAgain, on: alias)
        case .changed?:
            update(alias) { $0.status = .failed("\(offer.ssh) showed another key just now · not trusted", .checkAgain) }
        case .unreachable?:
            update(alias) { $0.status = .failed("Can't reach \(offer.ssh) to check its key again", .checkAgain) }
        case .unwritable(let path)?:
            update(alias) { $0.status = .failed("Couldn't add the key to \(path)", .copy(offer.command)) }
        }
    }

    // MARK: Back from outside Kore

    @ObservationIgnored private var lookedOnReturn: [String: ContinuousClock.Instant] = [:]

    /// Kore came to the front again: a box whose line waits on something done outside Kore (a
    /// command copied for Terminal, a host key) is looked at again, at most every 10 s each.
    package func lookAgainOnReturn() {
        let now = ContinuousClock.now
        for box in boxes {
            let waits: Bool
            switch box.status {
            case .failed(_, .copy?), .unreachable(_, .copy?), .failed(_, .trust?): waits = true
            default: waits = false
            }
            guard waits, !busy.contains(box.alias), scanning.isEmpty || !scanning.contains(box.alias) else { continue }
            if let last = lookedOnReturn[box.alias], now - last < .seconds(10) { continue }
            lookedOnReturn[box.alias] = now
            let alias = box.alias
            Task { await act(.checkAgain, on: alias) }
        }
    }
}
