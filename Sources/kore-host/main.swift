import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import KoreHost
import KoreNet
import KoreTrust
import LinkProtocol
import Tailnet

// Small pages only, before anything is allocated (`run` and `attach` alike): a huge page touched
// once stays resident whole.
HostMemory.smallPages()

/// kore-host: Kore's chats on a headless machine, served over the link (`docs/kore-host.md`).
let usage = """
    usage: kore-host run
           kore-host join
           kore-host upgrade [--want <version>] [--grant <name>] [--relogin]
           kore-host tailnet [--within <seconds>] [--until-in]
           kore-host net on|off
           kore-host devices [allow <id|code> | remove <id|code|name> | logs <id|code|name>]   (a code: "0009 a0e9", or "0009")
           kore-host status
           kore-host attach --as <name> [--proto 2]
           kore-host mcp
           kore-host kore <command>     (Kore's chat commands for a box chat: kore help)
           kore-host install-service
           kore-host start
           kore-host uninstall [--purge]
           kore-host facts
           kore-host update [--check | --file <kore-host-linux-ARCH.xz>] [--now] [--force]
           kore-host verify <file>
           kore-host --version
    """

// The Mac's diagnostic logs (`~/Library/Logs/Kore`) aren't kept on a box: kore-host's own lines go
// to stderr, which is the journal under systemd. KORE_LOG_DIR set by hand still wins.
setenv("KORE_LOG_DIR", "off", 0)

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
// `kore` in a box chat's shell: the link kore-host puts at the front of its PATH.
if URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent == "kore" { exit(HostCommand.run(arguments)) }
let paths = HostPaths()
let grants = GrantStore(paths.grants)
let home = HostPaths.home()
var keep: [Any] = []

/// `update` and `verify`'s checker for this binary.
func releaseUpdater() -> HostUpdate {
    #if DEBUG
    // Release rehearsals only (scripts/tests/release-rehearsal.sh): a debug build takes a
    // throwaway key, version and platform. A release build has none of this.
    var updater = HostUpdate(target: URL(fileURLWithPath: HostService.executable()))
    let test = ProcessInfo.processInfo.environment
    if let key = test["KORE_TEST_RELEASE_KEY"] { updater.key = key }
    if let version = test["KORE_TEST_VERSION"] { updater.current = version }
    if let platform = test["KORE_TEST_PLATFORM"] { updater.platform = platform }
    return updater
    #else
    return HostUpdate(target: URL(fileURLWithPath: HostService.executable()))
    #endif
}

/// KoreNet on or off in config.json, and the running daemon told (SIGHUP).
func setNet(_ on: Bool) {
    var config = HostConfig.load(paths.config, home: home.path)
    config.net = on
    do { try config.save(paths.config) } catch { fail("kore-host: \(error)") }
    if HostLock.held(paths.lock), let text = try? String(contentsOf: paths.pid, encoding: .utf8),
       let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        kill(pid, SIGHUP)
    }
}

/// The running daemon's pid, for "already running".
func runningPid() -> String {
    let pid = (try? String(contentsOf: paths.pid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    return pid.map { " (pid \($0))" } ?? ""
}

switch arguments.first {
case "pipe":
    // rsync's remote shell for a copy to another box (`pipe.send`): its pipe from this daemon.
    exit(PipeClient.run(Array(arguments.dropFirst())))
case "run":
    signal(SIGPIPE, SIG_IGN)
    if let problem = paths.runtimeProblem { fail("kore-host: \(problem)") }
    if HostLock.held(paths.lock) { fail("kore-host is already running\(runningPid()); this one stops here") }
    HostAskHook.install()
    let host = HostDaemon(paths: paths)
    // `kore-host net on|off` (and `join`, and a Mac's upgrade) change config.json and signal:
    // KoreNet follows at once. Taken before start: its pid is there from the start's first
    // moment, and a SIGHUP's default would end a daemon still starting. One that comes meanwhile
    // waits on the main queue, applied as soon as start returns.
    signal(SIGHUP, SIG_IGN)
    let reload = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
    reload.setEventHandler { MainActor.assumeIsolated { host.reloadNet() } }
    reload.resume()
    keep.append(reload)
    // `kore-host devices logs`: a phone's log asked for (SIGUSR1).
    signal(SIGUSR1, SIG_IGN)
    let logs = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    logs.setEventHandler { MainActor.assumeIsolated { host.phoneLogAsks() } }
    logs.resume()
    keep.append(logs)
    #if DEBUG
    let test = ProcessInfo.processInfo.environment
    if let hold = test["KORE_TEST_HOLD_START"] {
        HostDaemon.startHeld = {
            close(open(hold + ".reached", O_WRONLY))
            close(open(hold, O_RDONLY))
        }
    }
    if let said = test["KORE_TEST_RELOADED"] { HostDaemon.reloaded = { close(open(said, O_WRONLY)) } }
    #endif
    do {
        try host.start()
    } catch HostLockError.held {
        fail("kore-host is already running\(runningPid()); this one stops here")
    } catch {
        fail("\(error)")
    }
    HostService.notifyReady()
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                // SIGINT is a person stopping it; SIGTERM may be a restart (systemd, an update).
                host.stop(restarting: number == SIGTERM && HostDaemon.restarting(paths))
                // Each link's `bye` (restart or quit) out before the process goes.
                SocketEnd.settle()
                exit(0)
            }
        }
        source.resume()
        keep.append(source)
    }
    keep.append(host)
    dispatchMain()
case "allow":
    guard arguments.count >= 2 else { fail(usage) }
    var control = GrantControl.act
    if let at = arguments.firstIndex(of: "--control") {
        guard at + 1 < arguments.count, let picked = GrantControl(rawValue: arguments[at + 1]) else { fail("--control is watch, act or full") }
        control = picked
    }
    let replacing = grants.load(arguments[1]) != nil
    do {
        let book = DeviceStore(paths: paths).book
        let grant = try grants.allow(arguments[1], control: control, socket: paths.socket) { id in
            // A book that can't be read keeps the binding: only a device gone from it frees the grant.
            do { return try book.record(id) != nil } catch { return true }
        }
        print("allowed \(grant.name) (\(grant.control.rawValue))" + (replacing ? ": its old connection ends at its next command" : ""))
    } catch { fail("\(error)") }
case "revoke":
    guard arguments.count >= 2 else { fail(usage) }
    guard grants.revoke(arguments[1]) else { fail("no grant named \(arguments[1])") }
    // The daemon reads the grant again on each command: a live connection ends at its next one.
    print("revoked \(arguments[1])")
case "grants":
    for grant in grants.all() { print("\(grant.name)\t\(grant.control.rawValue)") }
case "status":
    for line in HostStatus.lines(paths: paths, home: home.path, tailnet: { HostStatus.tailnet(paths) }) { print(line) }
case "join":
    // The box's tailnet as the daemon chooses it: installed Tailscale, or Kore's own beside
    // kore-host where there's none it can use (BoxTailnet).
    let box = BoxTailnet.standard(paths)
    switch box.choice() {
    case .installed:
        let status = try? TailnetLocal().status()
        print("Using Tailscale on this box" + (status?.selfNode.map { " (" + $0.tailscaleIPs.joined(separator: ", ") + ")" } ?? ""))
    case .stopped, .signedOut:
        fail(BoxOS.here == .macos
            ? "Tailscale on this Mac is stopped or signed out: open Tailscale and sign in, then `kore-host join` again."
            : "Tailscale is stopped or signed out on this box: run `sudo tailscale up`, then `kore-host join` again.")
    case .sidecar, .beside:
        if box.helper() == nil {
            print(BoxOS.here == .macos
                ? "No Tailscale here and no kore-tailnet beside kore-host: install the Tailscale app and sign in, or set this box up again from Kore."
                : "No Tailscale here and no kore-tailnet beside kore-host: run `kore-host update`, or install Tailscale and run `sudo tailscale up`.")
        } else {
            print("Using Kore's own tailnet (kore-tailnet): kore-host starts it, and its sign-in page shows here.")
        }
    }
    do {
        let me = try BoxIdentity.loadOrCreate(paths)
        // An unclaimed box takes its owner Mac's claim for the next 10 minutes.
        try NetJoin.mark(paths, at: Date())
        setNet(true)
        print("KoreNet is on for this box (kore-host net off turns it off)")
        // Kore's own: signed in first, or no Mac can find this box.
        if case let choice = box.choice(), choice == .sidecar || choice == .beside, box.helper() != nil {
            guard BoxOwnRecord.join(wait: { BoxOwnRecord.wait(paths, within: $0, untilSignedIn: $1) }, say: { print($0) }) else { exit(1) }
            // Its 10 minutes for the claim start now that a Mac can find it.
            try NetJoin.mark(paths, at: Date())
        }
        print("device  \(me.device.uuidString.lowercased())")
        print("code    \(me.code)")
        print("Within 10 minutes, open Devices in Kore on your Mac and check the code matches before you Allow this box.")
    } catch { fail("kore-host: \(error)") }
case "upgrade":
    // U1–U3 of the SSH → KoreNet upgrade, each only when not done yet (HostUpgrade).
    func option(_ name: String) -> String? {
        guard let at = arguments.firstIndex(of: name) else { return nil }
        guard at + 1 < arguments.count else { fail(usage) }
        return arguments[at + 1]
    }
    let want = option("--want"), grant = option("--grant")
    if let grant, !Grant.valid(grant) { fail("kore-host: \(GrantError.badName)") }
    // `--relogin`: Kore's own tailnet here signs out first, for a sign-in with the Mac's account.
    let relogin = arguments.contains("--relogin")
    let report = HostUpgrade.standard(paths: paths, home: home).run(want: want, grant: grant, relogin: relogin)
    for line in report.text { print(line) }
    if report.updated {
        // The new binary runs the rest: it is the version wanted now.
        fflush(stdout)
        let next = ["kore-host", "upgrade"] + (grant.map { ["--grant", $0] } ?? []) + (relogin ? ["--relogin"] : [])
        let argv = next.map { strdup($0) } + [nil]
        execv(HostService.executable(), argv)
        fail("kore-host: the new kore-host didn't start (\(String(cString: strerror(errno))))", code: 1)
    }
    exit(report.exit)
case "tailnet":
    // Kore's own tailnet here as the daemon last heard it: `own: in|out` (or `own: none` without
    // `kore-tailnet`), `login:`, `why:`, `page:`. `--within <s>` waits for a sign-in page or a
    // sign-in; `--until-in` for the sign-in alone.
    let within = arguments.firstIndex(of: "--within").flatMap { at in at + 1 < arguments.count ? TimeInterval(arguments[at + 1]) : nil } ?? 0
    guard BoxTailnet.helper(executable: URL(fileURLWithPath: HostService.executable()), environment: ProcessInfo.processInfo.environment) != nil else {
        print("own: none")
        exit(0)
    }
    let record = BoxOwnRecord.wait(paths, within: max(0, min(within, 900)), untilSignedIn: arguments.contains("--until-in"))
    for line in (record?.own ?? .signedOut(.never)).report { print(line) }
case "net":
    switch arguments.dropFirst().first {
    case "on":
        setNet(true)
        print("KoreNet on: kore-host listens on this box's Tailscale addresses (port \(HostNet.port))")
    case "off":
        setNet(false)
        print("KoreNet off: no port, no Tailscale watching; SSH attach keeps working")
    case nil:
        print(HostConfig.load(paths.config, home: home.path).netOn ? "on" : "off")
    default:
        fail(usage)
    }
case "devices":
    let store = DeviceStore(paths: paths)
    switch arguments.dropFirst().first {
    case nil:
        let devices = store.all()
        if devices.isEmpty { print("no devices yet") }
        for device in devices {
            print([DeviceRecord.code(device.id), device.name, device.kind.rawValue, device.abilities.names.joined(separator: "+"), device.owner ? "owner" : ""]
                .filter { !$0.isEmpty }.joined(separator: "\t"))
        }
        for waiting in store.pending() {
            print(["pending", waiting.code ?? "-", waiting.name, waiting.kind?.rawValue ?? "?", waiting.login, waiting.claim ? "claim" : ""]
                .filter { !$0.isEmpty }.joined(separator: "\t"))
        }
    case "allow":
        guard arguments.count >= 3 else { fail(usage) }
        do {
            // The code as `status` shows it, quoted or not ("0009 a0e9"), or its first 4 digits.
            let record = try store.allow(arguments[2...].joined(separator: " "), at: Date())
            HostJournal.audit("allow", ["device": record.id.uuidString.lowercased(), "kind": record.kind.rawValue, "how": "cli"])
            print("allowed \(record.name) (\(record.kind.rawValue), \(record.abilities.names.joined(separator: "+")))")
        } catch { fail("kore-host: \(error)") }
    case "remove":
        guard arguments.count >= 3 else { fail(usage) }
        do {
            switch try store.remove(arguments[2...].joined(separator: " ")) {
            case .device(let record, let dropped):
                HostJournal.audit("revoke", ["device": record.id.uuidString.lowercased(), "kind": record.kind.rawValue, "how": "cli"])
                // The daemon reads the book on each command: its links end at their next one.
                print("removed \(record.name)" + (dropped.isEmpty ? "" : " and what it added: " + dropped.map(\.name).joined(separator: ", ")))
            case .pending(let entry):
                HostJournal.audit("deny", ["node": entry.nodeKey, "device": entry.device.map { $0.uuidString.lowercased() }, "how": "cli"])
                print("denied \(entry.name)")
            }
        } catch { fail("kore-host: \(error)") }
    case "logs":
        // A linked phone's own content-free log (1.13): the running daemon reads it over the
        // phone's live link (asked by a file and SIGUSR1) and writes it under the state folder.
        guard arguments.count >= 3 else { fail(usage) }
        let which = arguments[2...].joined(separator: " ")
        let digits = DeviceRecord.codePrefix(which)
        let matches = store.all().filter { r in
            r.kind == .phone && (UUID(uuidString: which) == r.id || (digits.map { r.id.uuidString.lowercased().hasPrefix($0) } ?? false) || r.name == which)
        }
        guard matches.count == 1, let phone = matches.first else { fail(matches.isEmpty ? "kore-host: no phone \(which)" : "kore-host: \(which) names more than one phone") }
        guard HostLock.held(paths.lock), let text = try? String(contentsOf: paths.pid, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { fail("kore-host isn't running") }
        let name = phone.id.uuidString.lowercased()
        let asks = paths.state.appendingPathComponent("asks", isDirectory: true)
        let out = paths.state.appendingPathComponent("phone-logs", isDirectory: true)
        let log = out.appendingPathComponent(name + ".log"), none = out.appendingPathComponent(name + ".none")
        try? FileManager.default.removeItem(at: log)
        try? FileManager.default.removeItem(at: none)
        try? FileManager.default.createDirectory(at: asks, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: asks.appendingPathComponent("phone-logs-" + name).path, contents: Data())
        kill(pid, SIGUSR1)
        // Its answer: the log, or a mark that it didn't come (the phone must have Kore open).
        for _ in 0..<160 {
            if FileManager.default.fileExists(atPath: log.path) { print(log.path); exit(0) }
            if FileManager.default.fileExists(atPath: none.path) { fail("\(phone.name) didn't send its logs: open Kore on it, then try again") }
            usleep(250_000)
        }
        fail("kore-host: no answer from the daemon")
    default:
        fail(usage)
    }
case "attach":
    guard arguments.count >= 3, arguments[1] == "--as" else { fail(usage, code: AttachExit.usage.rawValue) }
    if let problem = paths.runtimeProblem { fail("kore-host: \(problem)", code: AttachExit.noRuntime.rawValue) }
    // `--proto 2`: link 2.0 over SSH (the KoreNet upgrade); 1.11 stays the default.
    let proto2: Bool
    if let at = arguments.firstIndex(of: "--proto") {
        guard at + 1 < arguments.count, ["1", "2"].contains(arguments[at + 1]) else { fail(usage, code: AttachExit.usage.rawValue) }
        proto2 = arguments[at + 1] == "2"
    } else {
        proto2 = false
    }
    guard let grant = grants.load(arguments[2]), NetAttach.admits(grant, proto2: proto2, at: Date()) else {
        fail("kore-host: no grant named \(arguments[2])", code: AttachExit.noGrant.rawValue)
    }
    signal(SIGPIPE, SIG_IGN)
    MainActor.assumeIsolated {
        if proto2 {
            @MainActor func dial() -> NetAttach? { try? NetAttach(grant: grant, socket: paths.netSocket) { code in exit(code) } }
            var net = dial()
            if net == nil, let kind = HostService.installed(paths) {
                HostService.start(kind, executable: HostService.executable(), home: home, paths: paths)
                if HostService.waitForDaemon(paths) { net = dial() }
            }
            guard let net else { fail("kore-host isn't running", code: AttachExit.notRunning.rawValue) }
            net.start()
            keep.append(net)
            return
        }
        @MainActor func connect() -> Attach? { try? Attach(grant: grant, socket: paths.socket) { code in exit(code) } }
        var attach = connect()
        // Without systemd, nothing else starts the daemon: the first attach does, and it stays.
        if attach == nil, let kind = HostService.installed(paths) {
            HostService.start(kind, executable: HostService.executable(), home: home, paths: paths)
            if HostService.waitForDaemon(paths) { attach = connect() }
        }
        guard let attach else {
            let how = HostService.installed(paths) == nil ? " (systemctl --user start kore-host)" : " (see \(paths.state.path)/kore-host.log)"
            fail("kore-host isn't running" + how, code: AttachExit.notRunning.rawValue)
        }
        attach.start()
        keep.append(attach)
    }
    dispatchMain()
case "kore":
    // The Mac's `kore` commands for a box chat (`kore` on its PATH is this).
    exit(HostCommand.run(Array(arguments.dropFirst())))
case "hook" where arguments.dropFirst().first == "pretool":
    // A box Auto chat's PreToolUse hook: "ask" only for a Run once pass (`--once`), else nothing.
    exit(HostAskHook.run(Array(arguments.dropFirst(2))))
case "mcp":
    // A box chat's `kore_app` server, which kore-host starts its CLI with while Arsenal is on.
    exit(HostToolServer.run())
case "install-service":
    do {
        let kind = HostService.kind()
        for line in try HostService.install(kind, executable: HostService.executable(), home: home, user: HostService.user(), paths: paths) { print(line) }
    } catch { fail("kore-host: \(error)") }
case "start":
    let kind = HostService.installed(paths)
    guard HostService.start(kind, executable: HostService.executable(), home: home, paths: paths) else {
        fail("kore-host: systemctl --user start kore-host failed (see `journalctl --user -u kore-host`)")
    }
    print(HostService.waitForDaemon(paths) ? "kore-host is running" : "kore-host is starting")
case "facts":
    // Names only, never a value from inside a config: the Mac compares them with its own.
    print(String(decoding: AgentFacts.read(home: home).json(), as: UTF8.self))
case "uninstall":
    var lines = HostService.uninstall(home: home, paths: paths)
    if arguments.contains("--purge") { lines += HostService.purge(paths) }
    for line in lines { print(line) }
    print("the binary stays at \(HostService.executable()): delete it to finish")
case "update":
    // From the latest release (KORE_RELEASE_URL for another), or a file with SHA256SUMS and its
    // .sig beside it; `--by <Mac>` is a Mac's push (host.update), run by the daemon.
    let updater = releaseUpdater()
    func value(_ flag: String) -> String? {
        guard let at = arguments.firstIndex(of: flag) else { return nil }
        guard at + 1 < arguments.count else { fail(usage) }
        return arguments[at + 1]
    }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kore-host-update-\(getpid())")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let oldPid = (try? String(contentsOf: paths.pid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let flow = UpdateFlow(
        updater: updater, paths: paths, base: ProcessInfo.processInfo.environment["KORE_RELEASE_URL"] ?? HostUpdate.latest,
        scratch: scratch, tty: isatty(1) == 1, say: { print($0) }, chats: { HostUpdate.chats(paths) },
        restart: {
            let wasRunning = HostLock.held(paths.lock)
            let said = HostUpdate.restart(paths: paths, home: home)
            let kind = HostService.installed(paths)
            if kind == .onDemand { return (false, "kore-host starts on the new one when Kore connects") }
            // No service and no daemon: nothing to wait for.
            if !wasRunning, kind == nil, !FileManager.default.fileExists(atPath: HostService.unitFile(home: home).path) { return (false, said) }
            // Up again: a new daemon holds the lock.
            for _ in 0..<100 {
                let pid = (try? String(contentsOf: paths.pid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                // Its pid is written as it starts: up once its socket is there too.
                if HostLock.held(paths.lock), pid != oldPid, FileManager.default.fileExists(atPath: paths.socket.path) { return (true, "") }
                usleep(100_000)
            }
            return (false, said.split(separator: "\n").last.map(String.init) ?? "restart it: kore-host start")
        })
    let code = arguments.contains("--check")
        ? flow.check()
        : flow.update(file: value("--file").map { URL(fileURLWithPath: $0) }, now: arguments.contains("--now"), force: arguments.contains("--force"), by: value("--by"))
    try? FileManager.default.removeItem(at: scratch)
    exit(code)
case "verify":
    guard arguments.count == 2 else { fail(usage) }
    do {
        for line in try releaseUpdater().verify(URL(fileURLWithPath: arguments[1])) { print(line) }
    } catch { fail("kore-host: \(error)", code: 1) }
case "--version", "-v", "version":
    print("kore-host \(HostVersion.string) (link \(HostVersion.link))")
default:
    fail(usage)
}
