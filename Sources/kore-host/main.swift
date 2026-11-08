import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import KoreHost
import LinkProtocol

// Small pages only, before anything is allocated (`run` and `attach` alike): a huge page touched
// once stays resident whole.
HostMemory.smallPages()

/// kore-host: Kore's chats on a headless machine, served over the link (`docs/kore-host.md`).
let usage = """
    usage: kore-host run
           kore-host allow <name> [--control watch|act|full]
           kore-host revoke <name>
           kore-host grants
           kore-host status
           kore-host attach --as <name>
           kore-host install-service
           kore-host start
           kore-host uninstall [--purge]
           kore-host facts
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
case "attach":
    guard arguments.count >= 3, arguments[1] == "--as" else { fail(usage, code: AttachExit.usage.rawValue) }
    if let problem = paths.runtimeProblem { fail("kore-host: \(problem)", code: AttachExit.noRuntime.rawValue) }
    guard let grant = grants.load(arguments[2]) else { fail("kore-host: no grant named \(arguments[2])", code: AttachExit.noGrant.rawValue) }
    signal(SIGPIPE, SIG_IGN)
    MainActor.assumeIsolated {
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
case "--version", "-v", "version":
    print("kore-host \(HostVersion.string) (link \(HostVersion.link))")
default:
    fail(usage)
}
