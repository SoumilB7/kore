import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import KoreHost
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
           kore-host net on|off
           kore-host devices [allow <id|code> | remove <id|code|name>]
           kore-host status
           kore-host attach --as <name> [--proto 2]
           kore-host mcp
           kore-host install-service
           kore-host start
           kore-host uninstall [--purge]
           kore-host facts
           kore-host update [--file <kore-host-linux-ARCH.xz>] [--force]
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
let paths = HostPaths()
let grants = GrantStore(paths.grants)
let home = HostPaths.home()
var keep: [Any] = []

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
case "run":
    signal(SIGPIPE, SIG_IGN)
    if let problem = paths.runtimeProblem { fail("kore-host: \(problem)") }
    if HostLock.held(paths.lock) { fail("kore-host is already running\(runningPid()); this one stops here") }
    let host = HostDaemon(paths: paths)
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
                host.stop()
                exit(0)
            }
        }
        source.resume()
        keep.append(source)
    }
    // `kore-host net on|off` (and `join`) change config.json and signal: KoreNet follows at once.
    signal(SIGHUP, SIG_IGN)
    let reload = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
    reload.setEventHandler { MainActor.assumeIsolated { host.reloadNet() } }
    reload.resume()
    keep.append(reload)
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
        let grant = try grants.allow(arguments[1], control: control, socket: paths.socket)
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
    for line in HostStatus.lines(paths: paths, home: home.path) { print(line) }
case "join":
    // System Tailscale only for now: Kore's own tailnet (`kore-tailnet`) comes in a later release.
    do {
        let status = try TailnetLocal().status()
        guard status.backendState == .running else {
            fail("Tailscale is \(status.backendState.rawValue) on this box: run `sudo tailscale up`, then `kore-host join` again.")
        }
        print("Using Tailscale on this box" + (status.selfNode.map { " (" + $0.tailscaleIPs.joined(separator: ", ") + ")" } ?? ""))
    } catch {
        print("Tailscale isn't reachable here (\(error)).")
        print("Kore's own tailnet (kore-tailnet) comes in a later release; for now install Tailscale and run `sudo tailscale up`.")
    }
    do {
        let me = try BoxIdentity.loadOrCreate(paths)
        setNet(true)
        print("KoreNet is on for this box (kore-host net off turns it off)")
        print("device  \(me.device.uuidString.lowercased())")
        print("code    \(me.code)")
        print("Open Devices in Kore on your Mac and check the code matches before you Allow this box.")
    } catch { fail("kore-host: \(error)") }
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
            let record = try store.allow(arguments[2], at: Date())
            HostJournal.audit("allow", ["device": record.id.uuidString.lowercased(), "kind": record.kind.rawValue, "how": "cli"])
            print("allowed \(record.name) (\(record.kind.rawValue), \(record.abilities.names.joined(separator: "+")))")
        } catch { fail("kore-host: \(error)") }
    case "remove":
        guard arguments.count >= 3 else { fail(usage) }
        do {
            switch try store.remove(arguments[2]) {
            case .device(let record, let dropped):
                HostJournal.audit("revoke", ["device": record.id.uuidString.lowercased(), "kind": record.kind.rawValue, "how": "cli"])
                // The daemon reads the book on each command: its links end at their next one.
                print("removed \(record.name)" + (dropped.isEmpty ? "" : " and what it added: " + dropped.map(\.name).joined(separator: ", ")))
            case .pending(let entry):
                HostJournal.audit("deny", ["node": entry.nodeKey, "device": entry.device.map { $0.uuidString.lowercased() }, "how": "cli"])
                print("denied \(entry.name)")
            }
        } catch { fail("kore-host: \(error)") }
    default:
        fail(usage)
    }
case "attach":
    guard arguments.count >= 3, arguments[1] == "--as" else { fail(usage, code: AttachExit.usage.rawValue) }
    if let problem = paths.runtimeProblem { fail("kore-host: \(problem)", code: AttachExit.noRuntime.rawValue) }
    guard let grant = grants.load(arguments[2]), !grant.expired(at: Date()) else {
        fail("kore-host: no grant named \(arguments[2])", code: AttachExit.noGrant.rawValue)
    }
    // `--proto 2`: link 2.0 over SSH (the KoreNet upgrade); 1.11 stays the default.
    let proto2: Bool
    if let at = arguments.firstIndex(of: "--proto") {
        guard at + 1 < arguments.count, ["1", "2"].contains(arguments[at + 1]) else { fail(usage, code: AttachExit.usage.rawValue) }
        proto2 = arguments[at + 1] == "2"
    } else {
        proto2 = false
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
    // The file's SHA256SUMS and SHA256SUMS.sig are beside it; without one, the latest release's.
    let updater = HostUpdate(target: URL(fileURLWithPath: HostService.executable()))
    var file: URL?
    if let at = arguments.firstIndex(of: "--file") {
        guard at + 1 < arguments.count else { fail(usage) }
        file = URL(fileURLWithPath: arguments[at + 1])
    }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kore-host-update-\(getpid())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    do {
        if file == nil {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            file = try updater.download(into: scratch)
        }
        switch try updater.apply(file!, force: arguments.contains("--force")) {
        case .same(let version):
            print("kore-host \(version) is this release already")
        case .updated(let from, let to):
            print("kore-host \(from) → \(to) (\(updater.target.path))")
            print(HostUpdate.restart(paths: paths, home: home))
        }
    } catch { try? FileManager.default.removeItem(at: scratch); fail("kore-host: \(error)") }
case "verify":
    guard arguments.count == 2 else { fail(usage) }
    do {
        for line in try HostUpdate(target: URL(fileURLWithPath: HostService.executable())).verify(URL(fileURLWithPath: arguments[1])) { print(line) }
    } catch { fail("kore-host: \(error)", code: 1) }
case "--version", "-v", "version":
    print("kore-host \(HostVersion.string) (link \(HostVersion.link))")
default:
    fail(usage)
}
