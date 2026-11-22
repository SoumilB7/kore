// The rig's machinery for `korenet-rig`: processes, Docker boxes, the Mac's userspace tailscaled
// (its "installed Tailscale"), and the "browser" that finishes a sign-in page in Headscale.
// Everything it makes is labelled com.kore.rig=1 and goes at the end (scripts/tests/korenet-real).
#if os(macOS)
import Darwin
import Foundation
import KoreTrust
import Synchronization
import Tailnet

// MARK: Processes

struct Ran: Sendable {
    var status: Int32
    var out: String
    var ok: Bool { status == 0 }
}

final class Collected: @unchecked Sendable {
    var data = Data()
}

/// Every command the rig ran, for the proof folder: when (seconds into the run), the line, and
/// how many times in a row (a poll is one line).
let ranCommands = Mutex<[(at: Double, line: String, count: Int)]>([])
let rigStart = Date().timeIntervalSinceReferenceDate

func noteCommand(_ exe: String, _ args: [String]) {
    let line = ([URL(fileURLWithPath: exe).lastPathComponent] + args.map { $0.contains(" ") || $0.isEmpty ? "'\($0)'" : $0 }).joined(separator: " ")
    let at = Date().timeIntervalSinceReferenceDate - rigStart
    ranCommands.withLock { all in
        if all.last?.line == line { all[all.count - 1].count += 1 } else { all.append((at, line, 1)) }
    }
}

/// Runs a program to its end, killed after `timeout`; stdout and stderr together.
func runSync(_ exe: String, _ args: [String], input: String? = nil, timeout: Double = 120, env: [String: String]? = nil) -> Ran {
    noteCommand(exe, args)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    if let env { process.environment = env }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = out
    let inp = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : inp
    do { try process.run() } catch { return Ran(status: 127, out: "\(error)") }
    if let input {
        try? inp.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? inp.fileHandleForWriting.close()
    }
    let got = Collected()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        got.data = out.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        return Ran(status: 124, out: "timed out after \(Int(timeout))s")
    }
    process.waitUntilExit()
    return Ran(status: process.terminationStatus, out: String(decoding: got.data, as: UTF8.self))
}

func run(_ exe: String, _ args: [String], input: String? = nil, timeout: Double = 120) async -> Ran {
    await Task.detached { runSync(exe, args, input: input, timeout: timeout) }.value
}

let dockerPath = "/usr/local/bin/docker"
func docker(_ args: String..., input: String? = nil, timeout: Double = 120) async -> Ran { await run(dockerPath, args, input: input, timeout: timeout) }

func now() -> Double { Date().timeIntervalSinceReferenceDate }

// MARK: The rig's places

struct RigPlaces: Sendable {
    /// RIG_RUN: ssh config and keys, certs, this run's folders.
    let run: URL
    /// RIG_BIN: tailscaled-darwin, tailscale-darwin, kore-tailnet-darwin (koretest).
    let bin: URL
    /// RIG_HOSTBIN: kore-host-linux-aarch64, kore-tailnet-linux-aarch64 (Set up's binaries).
    let hostBin: URL
    let authKey: String
    /// Short scratch (Unix socket paths are ≤104 bytes): /tmp/kr-<pid>.
    let scratch: URL
    let scenario: String

    static func fromEnvironment(scenario: String) -> RigPlaces {
        let env = ProcessInfo.processInfo.environment
        func need(_ key: String) -> String {
            guard let value = env[key], !value.isEmpty else {
                FileHandle.standardError.write(Data("korenet-rig: \(key) is needed (scripts/tests/korenet-real/run.sh sets it)\n".utf8))
                exit(2)
            }
            return value
        }
        let run = URL(fileURLWithPath: need("RIG_RUN"))
        let scratch = URL(fileURLWithPath: env["RIG_SCRATCH"] ?? "/tmp/kr-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return RigPlaces(
            run: run, bin: URL(fileURLWithPath: need("RIG_BIN")), hostBin: URL(fileURLWithPath: need("RIG_HOSTBIN")),
            authKey: (try? String(contentsOf: run.appendingPathComponent("authkey"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            scratch: scratch, scenario: scenario)
    }

    var sshKey: URL { run.appendingPathComponent("id_ed25519") }
    var sshConfig: URL { scratch.appendingPathComponent("ssh_config") }
    var sshWrapper: URL { scratch.appendingPathComponent("ssh") }
    var scpWrapper: URL { scratch.appendingPathComponent("scp") }
    var macHelper: URL { bin.appendingPathComponent("kore-tailnet-darwin") }
    var tailscale: URL { bin.appendingPathComponent("tailscale-darwin") }
    var tailscaled: URL { bin.appendingPathComponent("tailscaled-darwin") }
}

// MARK: Headscale

enum Headscale {
    static let container = "kore-rig-headscale-1"
    static let controlInBoxes = "http://headscale:8080"
    static let controlOnMac = "http://127.0.0.1:18080"

    static func cli(_ args: [String]) async -> Ran { await run(dockerPath, ["exec", container, "headscale"] + args) }

    /// Every node, as Headscale lists them: name → (id, online, ips).
    static func nodes() async -> [(id: Int, name: String, online: Bool, ips: [String], nodeKey: String, expired: Bool)] {
        let ran = await cli(["nodes", "list", "-o", "json"])
        guard ran.ok, let data = ran.out.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.map { node in
            let expiry = (node["expiry"] as? [String: Any])?["seconds"] as? Double
            return (
                id: (node["id"] as? Int) ?? Int("\(node["id"] ?? 0)") ?? 0, name: node["given_name"] as? String ?? node["name"] as? String ?? "",
                online: node["online"] as? Bool ?? false, ips: node["ip_addresses"] as? [String] ?? [], nodeKey: node["node_key"] as? String ?? "",
                expired: expiry.map { $0 > 0 && $0 < Date().timeIntervalSince1970 } ?? false)
        }
    }

    /// Every node goes (between scenarios: the rig's own control server).
    static func deleteAll() async {
        for node in await nodes() { _ = await cli(["nodes", "delete", "--identifier", "\(node.id)", "--force"]) }
    }

    static func delete(named name: String) async {
        for node in await nodes() where node.name == name { _ = await cli(["nodes", "delete", "--identifier", "\(node.id)", "--force"]) }
    }

    static func expire(named name: String) async {
        for node in await nodes() where node.name == name { _ = await cli(["nodes", "expire", "--identifier", "\(node.id)", "--force"]) }
    }
}

/// The owner's browser: a sign-in page Kore opens is finished as the owner (its auth id
/// registered for user "owner" in Headscale). Each page opened is counted.
@MainActor
final class Browser {
    private(set) var opened: [String] = []
    /// Off: pages are counted, never finished (a scenario where the owner doesn't sign in).
    var signsIn = true

    func open(_ url: URL) {
        opened.append(url.absoluteString)
        say("  browser: \(url.absoluteString)")
        guard signsIn else { return }
        let id = url.lastPathComponent
        Task.detached {
            let ran = await Headscale.cli(["auth", "register", "--auth-id", id, "--user", "owner"])
            await MainActor.run { say("  browser: signed in (\(ran.ok ? "ok" : ran.out.trimmingCharacters(in: .whitespacesAndNewlines)))") }
        }
    }
}

// MARK: Boxes

/// One Linux box: a systemd container on the rig network, sshd published on the Mac's loopback.
struct BoxSpec: Sendable {
    var name: String
    var sshPort: Int
    /// System tailscaled, signed in to Headscale.
    var tailscale = false
    var tailscaleSSH = false
    var sshd = true
    var user = "kore"
}

enum Boxes {
    static func container(_ name: String) -> String { "kore-rig-\(name)" }

    static func create(_ spec: BoxSpec, places: RigPlaces) async -> String? {
        let name = container(spec.name)
        _ = await docker("rm", "-f", name)
        let made = await run(dockerPath, [
            "run", "-d", "--name", name, "--hostname", spec.name, "--label", "com.kore.rig=1", "--label", "com.kore.rig.scenario=\(places.scenario)",
            "--cpus", "1.5", "--memory", "1g", "--privileged", "--cgroupns=host", "-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw", "--tmpfs", "/run", "--tmpfs", "/run/lock", "--tmpfs", "/tmp",
            "--network", "kore-rig_rig", "-p", "127.0.0.1:\(spec.sshPort):22", "kore-rig-box:1",
        ])
        guard made.ok else { return "docker run: \(made.out)" }
        let pub = (try? String(contentsOf: places.sshKey.appendingPathExtension("pub"), encoding: .utf8)) ?? ""
        let setup = """
            set -e
            for i in $(seq 100); do s=$(systemctl is-system-running 2>/dev/null || true); case $s in running|degraded) break;; esac; sleep 0.1; done
            for u in kore nosudo root; do h=$(getent passwd $u | cut -d: -f6); install -d -m 700 -o $u -g $u $h/.ssh; printf '%s\\n' '\(pub.trimmingCharacters(in: .whitespacesAndNewlines))' > $h/.ssh/authorized_keys; chown $u:$u $h/.ssh/authorized_keys; chmod 600 $h/.ssh/authorized_keys; done
            echo 'KORE_TAILNET_CONTROL_URL=\(Headscale.controlInBoxes)' > /etc/environment.d/90-kore-rig.conf
            echo 'KORE_TAILNET_CONTROL_URL=\(Headscale.controlInBoxes)' >> /etc/environment
            """
        let ready = await docker("exec", "-i", name, "sh", "-s", input: setup)
        guard ready.ok else { return "box setup: \(ready.out)" }
        if !spec.sshd { _ = await docker("exec", name, "systemctl", "disable", "--now", "ssh.service", "ssh.socket") }
        if spec.tailscale {
            if let why = await tailscaleUp(spec, places: places) { return why }
        }
        return nil
    }

    static func tailscaleUp(_ spec: BoxSpec, places: RigPlaces) async -> String? {
        let name = container(spec.name)
        _ = await docker("exec", name, "systemctl", "enable", "--now", "tailscaled")
        var args = ["exec", name, "tailscale", "up", "--login-server", Headscale.controlInBoxes, "--authkey", places.authKey, "--hostname", spec.name, "--accept-dns=false"]
        if spec.tailscaleSSH { args.append("--ssh") }
        let up = await run(dockerPath, args, timeout: 60)
        return up.ok ? nil : "tailscale up: \(up.out)"
    }

    static func exec(_ box: String, _ script: String, user: String = "root", timeout: Double = 60) async -> Ran {
        await run(dockerPath, ["exec", "-i", "-u", user, container(box), "sh", "-s"], input: script, timeout: timeout)
    }

    static func tailscaleIP(_ box: String) async -> String? {
        let ran = await docker("exec", container(box), "tailscale", "ip", "-4")
        return ran.ok ? ran.out.split(whereSeparator: \.isNewline).first.map(String.init) : nil
    }

    static func remove(scenario: String) async {
        let ran = await docker("ps", "-aq", "--filter", "label=com.kore.rig.scenario=\(scenario)")
        for id in ran.out.split(whereSeparator: \.isNewline) { _ = await docker("rm", "-f", String(id)) }
    }
}

// MARK: The Mac's installed Tailscale

/// Installed Tailscale on this Mac, as the rig has it: open-source tailscaled in userspace
/// networking (no utun: the owner's own Tailscale keeps this Mac's routes), its own socket and
/// state, signed in to Headscale. Kore finds it by its socket (`LocalAPIClient`), as it finds
/// open-source tailscaled; it dials through its LocalAPI (`/localapi/v0/dial`) where a real one's
/// kernel route would carry the connect. Quitting it is what the app quitting is to Kore: the
/// socket goes, and `changed` (the app's launch/quit notice) is called.
final class MacTailscale: @unchecked Sendable {
    let socket: String
    let state: URL
    let places: RigPlaces
    private let lock = NSLock()
    private var process: Process?
    private var changed: (@Sendable () -> Void)?
    /// Installed at all (an uninstall reads absent; a quit app reads not running).
    var installed = true

    init(places: RigPlaces) {
        self.places = places
        socket = places.scratch.appendingPathComponent("ts.sock").path
        state = places.scratch.appendingPathComponent("ts-state", isDirectory: true)
    }

    var running: Bool { lock.withLock { process?.isRunning == true } }

    func watch(_ changed: @escaping @Sendable () -> Void) -> (@Sendable () -> Void) {
        lock.withLock { self.changed = changed }
        return { [weak self] in self?.lock.withLock { self?.changed = nil } }
    }

    private func told() { lock.withLock { changed }?() }

    /// Starts tailscaled and signs it in (the first time) as `rig-mac`.
    func start() -> String? {
        let p = Process()
        p.executableURL = places.tailscaled
        p.arguments = ["--tun=userspace-networking", "--socket=\(socket)", "--statedir=\(state.path)", "--port=0"]
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        let log = places.scratch.appendingPathComponent("tailscaled.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardError = try? FileHandle(forWritingTo: log)
        do { try p.run() } catch { return "tailscaled: \(error)" }
        lock.withLock { process = p }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) { usleep(50_000) }
        let up = runSync(places.tailscale.path, ["--socket=\(socket)", "up", "--login-server", Headscale.controlOnMac, "--authkey", places.authKey, "--hostname", "rig-mac", "--accept-dns=false"], timeout: 60)
        told()
        return up.ok ? nil : "tailscale up: \(up.out)"
    }

    /// Quits (the app quit): its daemon and socket go.
    func stop() {
        let p = lock.withLock { () -> Process? in
            defer { process = nil }
            return process
        }
        if let p, p.isRunning {
            // Bounded: a userspace tailscaled that doesn't end on SIGTERM is killed after 5 s.
            p.terminate()
            let end = Date().addingTimeInterval(5)
            while p.isRunning, Date() < end { usleep(100_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: socket)
        told()
    }

    /// `tailscale down` (stopped, still running): Kore's own takes over beside it.
    func down() -> Ran {
        let ran = runSync(places.tailscale.path, ["--socket=\(socket)", "down"])
        return ran
    }

    func up() -> Ran { runSync(places.tailscale.path, ["--socket=\(socket)", "up", "--login-server", Headscale.controlOnMac, "--hostname", "rig-mac", "--accept-dns=false"], timeout: 60) }

    /// As `LocalAPIDiscovery` finds open-source tailscaled on a Mac: its socket answering; its
    /// launch daemon there but not running is "not running"; uninstalled is absent.
    func endpoint() -> LocalAPIEndpoint {
        if LocalAPIDiscovery.socketAnswers(socket) { return .unix(socket) }
        return installed ? .unavailable(.notRunning) : .unavailable(.absent)
    }
}

/// Installed Tailscale's LocalAPI, dialling through the daemon (userspace: no kernel route).
final class RigInstalled: Tailnet {
    let local: TailnetLocal
    let socket: String

    init(local: TailnetLocal, socket: String) {
        self.local = local
        self.socket = socket
    }

    func status() throws -> TailnetStatus { try local.status() }
    func whois(_ address: String) throws -> TailnetWhoIs { try local.whois(address) }
    func events() -> AsyncStream<TailnetEvent> { local.events() }
    func listen(port: UInt16) throws -> [TailnetListenSocket] { throw TailnetError.sidecar("the rig's userspace tailscaled takes no listeners") }

    func dial(_ address: String, port: UInt16) throws -> Int32 {
        guard let ip = IPAddress(address), ip.isTailnet else { throw TailnetError.notTailnet(address) }
        let fd = try Sockets.connectUnix(socket)
        let request = "POST /localapi/v0/dial HTTP/1.1\r\nHost: local-tailscaled.sock\r\nConnection: upgrade\r\nUpgrade: ts-dial\r\nDial-Host: \(address)\r\nDial-Port: \(port)\r\nDial-Network: tcp\r\nContent-Length: 0\r\n\r\n"
        do {
            try Sockets.writeAll(fd, Data(request.utf8))
            // The head byte by byte: the stream starts right after it.
            var head = [UInt8]()
            var byte: UInt8 = 0
            while !(head.count >= 4 && head.suffix(4) == [13, 10, 13, 10]) {
                guard Darwin.read(fd, &byte, 1) == 1, head.count < 8192 else { throw TailnetError.sidecar("dial: no answer") }
                head.append(byte)
            }
            let line = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
            guard line.contains(" 101") else { throw TailnetError.sidecar("dial: \(line)") }
            return fd
        } catch {
            Sockets.closeFD(fd)
            throw error
        }
    }
}

// MARK: SSH

/// The run's own ssh config (never ~/.ssh/config) and the wrappers Kore runs as ssh and scp.
enum RigSSH {
    struct Host {
        var alias: String
        var lines: [String]
    }

    static func write(_ hosts: [Host], places: RigPlaces) {
        var text = ""
        for host in hosts {
            text += "Host \(host.alias)\n" + host.lines.map { "  \($0)\n" }.joined()
        }
        text += """
            Host *
              IdentityFile "\(places.sshKey.path)"
              IdentitiesOnly yes
              StrictHostKeyChecking no
              UserKnownHostsFile /dev/null
              LogLevel ERROR
              ConnectTimeout 8

            """
        try? text.write(to: places.sshConfig, atomically: true, encoding: .utf8)
        for (wrapper, program) in [(places.sshWrapper, "/usr/bin/ssh"), (places.scpWrapper, "/usr/bin/scp")] {
            // Each ssh and scp Kore runs, logged for the proof folder, then run with the rig's config.
            let log = places.scratch.appendingPathComponent("kore-ssh.log").path
            try? "#!/bin/sh\necho \"$(date +%H:%M:%S) \(URL(fileURLWithPath: program).lastPathComponent) $*\" >> '\(log)'\nexec \(program) -F '\(places.sshConfig.path)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
            chmod(wrapper.path, 0o755)
        }
    }

    /// `ssh <alias> <command>` with the run's config.
    static func exec(_ alias: String, _ command: String, places: RigPlaces, timeout: Double = 30) async -> Ran {
        await run(places.sshWrapper.path, ["-o", "BatchMode=yes", alias, command], timeout: timeout)
    }
}

@MainActor func say(_ line: String) {
    if ProcessInfo.processInfo.environment["RIG_VERBOSE"] == "1" || line.hasPrefix("✔") || line.hasPrefix("✘") { print(line) }
    let stamped = String(format: "[%6.1f] ", now() - Log.start) + line
    Log.lines.append(stamped)
    Log.shared.withLock { $0.append(stamped) }
}

@MainActor enum Log {
    static var lines: [String] = []
    static let start = now()
    /// The same lines, for the watchdog's thread.
    nonisolated static let shared = Mutex<[String]>([])
}
#endif
