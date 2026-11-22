// korenet-rig: the Mac end of scripts/tests/korenet-real. One scenario per run (Kore's objects
// are process-wide, as in Kore.app): `korenet-rig <scenario>`; `korenet-rig list` names them.
// Kore's real HostClient code (Set up, the upgrade, KoreNetSwitch, the box link) runs against
// systemd boxes in Docker with real sshd and tailscaled, Kore's own tailnet is the real
// kore-tailnet helper (built `-tags koretest`: its control server is Headscale's), and this
// Mac's installed Tailscale is a userspace tailscaled. Faults are real: daemons stopped, iptables,
// reboots, Headscale removing or expiring nodes. Prints one ✔/✘ line; the whole story goes to
// $RIG_RUN/logs/<scenario>.log. Exit 0 when it passed.
#if os(macOS)
import Darwin
import Foundation
import HostClient
import KoreCore
import LinkProtocol
import Tailnet

@MainActor
final class Run {
    let name: String
    let places: RigPlaces
    let mac: MacTailscale
    let kore: Kore
    private(set) var failures: [String] = []
    private(set) var notes: [String] = []
    /// Steps that wait on the dialing/liveness work ("net-cases"), counted apart.
    private(set) var netCases: [String] = []
    let started = now()

    init(_ name: String) {
        self.name = name
        places = RigPlaces.fromEnvironment(scenario: name)
        mac = MacTailscale(places: places)
        kore = Kore(places: places, macTailscale: mac)
    }

    func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        let line = ok ? "  ok   \(what)" : "  FAIL \(what)" + (detail().isEmpty ? "" : ": \(detail())")
        say(line)
        if !ok { failures.append(what + (detail().isEmpty ? "" : ": \(detail())")) }
    }

    /// A step that waits on the dialing/liveness work: said, counted apart.
    func netCase(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { return check(what, true) }
        say("  NETC \(what): \(detail())")
        netCases.append(what)
    }

    func note(_ line: String) {
        notes.append(line)
        say("  note \(line)")
    }

    /// Waits until `condition` holds, at most `within` seconds; how long it took, or nil.
    @discardableResult
    func until(_ what: String, within: Double, every: Double = 0.2, _ condition: () async -> Bool) async -> Double? {
        let start = now()
        while true {
            if await condition() {
                let took = now() - start
                say(String(format: "  ok   %@ (%.1fs)", what, took))
                return took
            }
            if now() - start > within { break }
            try? await Task.sleep(for: .milliseconds(Int(every * 1000)))
        }
        return nil
    }

    /// `until`, failing the run when it doesn't hold in time (with the box's state then).
    @discardableResult
    func expect(_ what: String, within: Double, box: String? = nil, netCase: Bool = false, _ condition: () async -> Bool) async -> Bool {
        if await until(what, within: within, condition) != nil { return true }
        let state = box.map { kore.describe($0) } ?? "mac=\(kore.net.map { "\($0.state)" } ?? "-")"
        if netCase { self.netCase("\(what) within \(Int(within))s", false, state) } else { check("\(what) within \(Int(within))s", false, state) }
        return false
    }

    // MARK: Pieces scenarios share

    func box(_ spec: BoxSpec) async -> Bool {
        if let why = await Boxes.create(spec, places: places) {
            check("box \(spec.name) made", false, why)
            return false
        }
        say("  box \(spec.name) up (ssh 127.0.0.1:\(spec.sshPort)\(spec.tailscale ? ", tailscale \(await Boxes.tailscaleIP(spec.name) ?? "?")" : ""))")
        return true
    }

    /// Kore launches with KoreNet on; this Mac's tailnet is chosen and (Kore's own) signed in.
    func launch(installed: Bool) async -> Bool {
        if nodesBefore.isEmpty { await before() }
        if installed {
            if let why = mac.start() {
                check("this Mac's Tailscale up", false, why)
                return false
            }
        } else {
            mac.installed = false
        }
        kore.launch()
        let want: NetState = installed ? .installed : .sidecar
        return await expect("this Mac on \(installed ? "installed Tailscale" : "Kore's own tailnet"), running", within: 40) {
            kore.net.state == want && kore.net.status?.backendState == .running
        }
    }

    /// Set up from the box card; Ready, and Kore's tailnet there signed in.
    func setUp(_ alias: String) async -> Bool {
        let start = now()
        let status = await kore.addAndSetUp(alias)
        let own = BoxList.shared.box(alias)?.own
        let ok = status == .ready
        check(String(format: "Set up %@ → Ready (%.1fs)", alias, now() - start), ok, "\(status.map { "\($0)" } ?? "not listed")")
        check("Set up's last step: Kore's tailnet on \(alias) signed in", own?.signedIn == true, own.map { $0.line } ?? "nothing said")
        return ok
    }

    /// A box's line is Ready now; a check either way.
    func expectReady(_ alias: String, _ what: String) -> Bool {
        let status = BoxList.shared.box(alias)?.status
        check(what, status == .ready, status.map { "\($0)" } ?? "not listed")
        return status == .ready
    }

    /// The box's window opens; its link is up over KoreNet within `within`.
    func linkOnNet(_ alias: String, within: Double = 60, netCase: Bool = false) async -> Bool {
        kore.open(alias)
        return await expect("\(alias)'s link on KoreNet", within: within, box: alias, netCase: netCase) {
            guard let link = kore.link(alias) else { return false }
            return link.isOnline && link.route?.isNet == true
        }
    }

    func onRoute(_ alias: String, net: Bool) -> Bool {
        guard let link = kore.link(alias) else { return false }
        return link.isOnline && link.route?.isNet == net
    }

    /// A folder read and a chat call over the link as it is.
    func works(_ alias: String, _ via: String, within: Double = 20, home: String = "/home/kore") async {
        let listed = await bounded(within, or: false) { await self.kore.list(alias, home) }
        check("fs.list over \(via)", listed, listed ? "" : kore.describe(alias))
        let called: String? = await bounded(within, or: "no answer in \(Int(within))s") { await self.kore.chatCall(alias, folder: home) }
        check("chat.call over \(via)", called == nil, called ?? "")
    }

    /// A round trip that answers within `seconds` (the link really carries it).
    func answers(_ alias: String, within seconds: Double = 8, home: String = "/home/kore") async -> Bool {
        await bounded(seconds, or: false) { await self.kore.list(alias, home) }
    }

    /// `work`'s value, or `fallback` when it takes longer than `seconds` (it's left to finish).
    func bounded<T: Sendable>(_ seconds: Double, or fallback: T, _ work: @escaping @MainActor () async -> T) async -> T {
        let once = Once<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            once.hold(continuation)
            Task { @MainActor in once.resume(await work()) }
            Task {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                once.resume(fallback)
            }
        }
    }

    func row(_ alias: String) -> String {
        kore.row(alias).map { "\($0.status) · \($0.line)" } ?? "no row"
    }

    func logRow(_ alias: String) { note("row: \(row(alias)) | mac: \(kore.macLine())") }

    // MARK: The end

    /// Each box's kore-host journal, into the log (the box side of the story).
    func journals() async {
        let ran = await docker("ps", "-a", "--filter", "label=com.kore.rig.scenario=\(name)", "--format", "{{.Names}}")
        for box in ran.out.split(whereSeparator: \.isNewline) {
            let j = await run(dockerPath, ["exec", String(box), "journalctl", "-o", "short-precise", "--no-pager", "-q", "_COMM=kore-host", "+", "_COMM=kore-tailnet", "+", "_COMM=tailscaled"], timeout: 20)
            say("--- \(box) journal (kore-host, kore-tailnet, tailscaled)")
            for line in j.out.split(whereSeparator: \.isNewline).suffix(200) { say("  | " + line) }
        }
    }

    // MARK: Proof

    /// The tailnets as they are: Headscale's nodes, this Mac's tailscaled, each box's.
    func nodes() async -> String {
        var out = "# Headscale nodes (name, ips, online, expired)\n"
        for n in await Headscale.nodes() { out += "\(n.name)\t\(n.ips.joined(separator: ","))\tonline=\(n.online)\texpired=\(n.expired)\n" }
        if mac.running {
            out += "\n# this Mac's tailscaled (tailscale status)\n" + runSync(places.tailscale.path, ["--socket=\(mac.socket)", "status"]).out
        }
        let boxes = await docker("ps", "--filter", "label=com.kore.rig.scenario=\(name)", "--format", "{{.Names}}")
        for box in boxes.out.split(whereSeparator: \.isNewline) {
            let st = await run(dockerPath, ["exec", String(box), "sh", "-c", "systemctl is-active tailscaled >/dev/null && tailscale status || echo 'tailscaled not running'"], timeout: 15)
            out += "\n# \(box): tailscale status\n" + st.out
        }
        return out
    }

    private(set) var nodesBefore = ""
    func before() async { nodesBefore = await nodes() }

    /// proof/<scenario>/: the commands, Kore's log, each box's log, the tailnets before and
    /// after, the timings and the verdict.
    func writeProof(_ verdict: String) async {
        let dir = places.run.appendingPathComponent("proof/\(name)", isDirectory: true)
        // run.sh's reset.txt (the clean slate before this run) stays beside the rest.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func put(_ file: String, _ text: String) { try? text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        let commands = ranCommands.withLock { $0 }.map { String(format: "[%6.1fs] ", $0.at) + $0.line + ($0.count > 1 ? "   (×\($0.count))" : "") }
        let koreSSH = (try? String(contentsOf: places.scratch.appendingPathComponent("kore-ssh.log"), encoding: .utf8)) ?? ""
        put("commands.txt", "# The rig's commands (seconds into the run)\n" + commands.joined(separator: "\n") + "\n\n# Every ssh and scp Kore itself ran (its HostClient, through the rig's -F config)\n" + koreSSH)
        put("ssh_config", (try? String(contentsOf: places.sshConfig, encoding: .utf8)) ?? "")
        put("mac-hostclient.log", (try? String(contentsOf: KoreFolders.logs.appendingPathComponent("hosts.log"), encoding: .utf8)) ?? "(none)")
        let boxes = await docker("ps", "-a", "--filter", "label=com.kore.rig.scenario=\(name)", "--format", "{{.Names}}")
        for box in boxes.out.split(whereSeparator: \.isNewline) {
            let j = await run(dockerPath, ["exec", String(box), "sh", "-c",
                "for f in /home/*/.local/state/kore-host/kore-host.log /root/.local/state/kore-host/kore-host.log; do [ -f $f ] && { echo \"# $f\"; tail -300 $f; }; done; echo '# journal: kore-host, kore-tailnet, tailscaled'; journalctl -o short-precise --no-pager -q _COMM=kore-host + _COMM=kore-tailnet + _COMM=tailscaled | grep -v TPM | tail -300"], timeout: 20)
            put("box-\(box.replacingOccurrences(of: "kore-rig-", with: "")).txt", j.out)
        }
        put("nodes-before.txt", nodesBefore)
        put("nodes-after.txt", await nodes())
        put("timings.txt", Log.lines.filter { $0.contains("(") && ($0.contains("  ok ") || $0.contains(" in ")) || $0.contains("note") }.joined(separator: "\n") + "\n")
        put("story.txt", Log.lines.joined(separator: "\n") + "\n")
        put("verdict.txt", verdict + "\n")
    }

    func finish() async -> Never {
        let took = now() - started
        let verdict = failures.isEmpty ? String(format: "✔ %@ (%.0fs)", name, took) : String(format: "✘ %@ (%.0fs): %@", name, took, failures.joined(separator: "; "))
        // The cleanup is the rig's, bounded: a stall there (run.sh resets everything before the
        // next case) says so in the proof and never turns the case's verdict.
        let (verdictLine, ok, proofDir) = (verdict + (netCases.isEmpty ? "" : " · net-cases: " + netCases.joined(separator: "; ")), failures.isEmpty, places.run.appendingPathComponent("proof/\(name)"))
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 90)
            try? "the rig's cleanup after this case took over 90 s: stopped there (run.sh's reset cleans up)\n".write(to: proofDir.appendingPathComponent("cleanup-stalled.txt"), atomically: true, encoding: .utf8)
            print(verdictLine + " (cleanup stalled: see cleanup-stalled.txt)")
            exit(ok ? 0 : 1)
        }
        await writeProof(verdict + (netCases.isEmpty ? "" : "\nnet-cases (waits on the dialing/liveness work): " + netCases.joined(separator: "; ")))
        await journals()
        // What's left of this run goes, whatever happened (RIG_KEEP=1: left for a look).
        if ProcessInfo.processInfo.environment["RIG_KEEP"] == "1" {
            print("kept: scenario \(name) (docker ps --filter label=com.kore.rig.scenario=\(name))")
            exit(failures.isEmpty ? 0 : 1)
        }
        kore.net?.set(false)
        mac.stop()
        await Boxes.remove(scenario: name)
        await Headscale.deleteAll()
        UserDefaults.standard.removePersistentDomain(forName: KoreFolders.domain)
        try? FileManager.default.removeItem(at: places.scratch)
        let logs = places.run.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try? Log.lines.joined(separator: "\n").write(to: logs.appendingPathComponent("\(name).log"), atomically: true, encoding: .utf8)
        let tail = netCases.isEmpty ? "" : " · net-cases: " + netCases.joined(separator: "; ")
        if failures.isEmpty {
            print(String(format: "✔ %@ (%.0fs)%@", name, took, tail))
        } else {
            print(String(format: "✘ %@ (%.0fs): %@%@", name, took, failures.joined(separator: "; "), tail))
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}

/// A continuation resumed once, by whichever comes first.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    func hold(_ c: CheckedContinuation<T, Never>) { lock.withLock { continuation = c } }
    func resume(_ value: T) {
        let c = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}

// MARK: Scenarios

let scenarios: [(name: String, what: String, body: @MainActor (Run) async -> Void)] = [
    ("plain-ssh", "plain SSH over the LAN to a box with no Tailscale → Set up → its own tailnet signs in → the link moves to KoreNet; SSH stays a route", plainSSH),
    ("first-contact", "a box this Mac has never met: its own empty known_hosts, ssh's own host-key check → Set up stops at the new key, its fingerprint shown with Trust; Trust → the key added as accept-new would → Set up goes on → Ready → KoreNet", firstContact),
    ("ts-ip", "SSH over the box's Tailscale IP, Tailscale on the box and the Mac → the upgrade uses installed Tailscale; the box's own signs in on standby", tsIP),
    ("box-ts-stops", "box tailscaled stops while its own is on standby → the box moves to its own, the Mac follows, SSH still works; tailscaled back → both move back, one box node online", boxTailscaleStops),
    ("mac-ts-quits", "the Mac's installed Tailscale quits → the Mac moves to its own; the box (on Tailscale) stays reachable, SSH over its Tailscale IP too; Tailscale back → the Mac moves back", macTailscaleQuits),
    ("blocked", "SSH blocked after the upgrade → KoreNet still works; KoreNet blocked → SSH fallback; both blocked → a clear offline state", blocked),
    ("reboot", "box reboot (linger on) → kore-host and its own tailnet come back by themselves, the link returns", reboot),
    ("boot-race", "box reboot with kore-host before tailscaled (tailscaled 10 s late) → kore-host waits for it: its own node never comes online, the link returns on Tailscale", bootRace),
    ("own-unreadable", "the box's own state can't be opened (its key replaced) → started afresh, said as signed out · unreadable; signed in again from the row → back on KoreNet", ownUnreadable),
    ("own-removed", "the box's own node removed in the control server while it carries the box → signed out; signed in again from the row → back on KoreNet", ownRemoved),
    ("own-expired", "the box's own key runs out while Tailscale overrides → it signs in again on standby at once (review 16); its page reaches the Mac; signed in → stopped again", ownExpired),
    ("tailscale-ssh", "Tailscale SSH only (the box's sshd off), reached over its Tailscale IP → Set up and the upgrade work; the link on KoreNet", tailscaleSSH),
    ("magicdns", "SSH to the box's MagicDNS name (Tailscale on the box and the Mac) → Set up and the upgrade work; the link on KoreNet", magicDNS),
    ("own-proxy", "no installed Tailscale on either side: SSH to the box's own-node tailnet address rides Kore's own tailnet (kore-tailnet nc, the box's port-22 forward), the LAN SSH blocked", ownProxy),
    ("proxyjump", "a box reached only through another (ProxyJump) → Set up and the upgrade work; the link on KoreNet", proxyJump),
    ("port-2222", "a typed user@host:port destination, sshd on a non-22 port → Set up and the upgrade work; the link on KoreNet", port2222),
    ("users", "a non-root user without sudo (linger off: kore-host runs on its own) and root (linger on: a systemd unit) → Set up, the upgrade, a reboot for root", users),
    ("binaries", "the box has a corrupted kore-host, then a half-installed one (.new left, no service), then an older one → Set up replaces each and the link reaches KoreNet", binaries),
    ("forgotten", "a box forgotten on this Mac (Remove) and added again → a first add: Set up, the upgrade, the link on KoreNet; no duplicate own node", forgotten),
    ("fresh-box", "scripts/tests/fresh-box.sh: backup → wipe (Kore has never seen the box, the box has no kore-host) → Set up from scratch → restore → the original box back", freshBox),
    ("fresh-phase", "(a step of fresh-box, run as its own Kore)", freshPhase),
    ("pipe-no-sshd", "a box set up over SSH, then its sshd stopped: copies both ways and the sync run over kore pipe on KoreNet, no SSH at all", pipeNoSSHD),
    ("interrupted", "the upgrade interrupted at each step (SSH killed mid-install, mid-join, mid-sign-in) → a retry completes, one own node, nothing stuck", interrupted),
    ("host-restart", "kore-host restarted (systemctl restart, as an update does) with the link on Kore's own tailnet → the Mac hears `restart` and relinks on KoreNet within seconds, never through SSH", hostRestart),
    ("dead-alias", "the box's SSH alias now names an address nothing answers (an old LAN address) while KoreNet carries it → reads, chats, copies, the sync, a probe, a window reopened and Check again take no SSH wait; the row stays online", deadAlias),
    ("host-keys", "past first contact: the box's keys made again (ssh's own changed-key refusal), the same at a moved address (Kore's own), the old key at a new address (offered as moved, trusted), a key changed between its offer and Trust → never trusted, known_hosts keeps what it had, KoreNet keeps working", hostKeys),
]

@MainActor func plainBox(_ r: Run, _ name: String, port: Int, user: String = "kore", lingerOn: Bool = false) async -> Bool {
    guard await r.box(BoxSpec(name: name, sshPort: port)) else { return false }
    if lingerOn { await linger(name, user: user) }
    RigSSH.write([RigSSH.Host(alias: name, lines: ["HostName 127.0.0.1", "Port \(port)", "User \(user)"])], places: r.places)
    guard await r.launch(installed: false) else { return false }
    guard await r.setUp(name) else { return false }
    return await r.linkOnNet(name)
}

@MainActor func macTailscaleQuits(_ r: Run) async {
    guard await tsBox(r, "b4", port: 22104) else { return }
    guard await r.setUp("b4") else { return }
    guard await r.linkOnNet("b4") else { return }
    let t0 = now()
    r.mac.stop()
    await r.expect("this Mac on Kore's own tailnet after its Tailscale quit", within: 20) { r.kore.net.state == .sidecar && r.kore.net.status?.backendState == .running }
    r.note(String(format: "Mac moved to its own in %.1fs", now() - t0))
    await r.expect("b4's link on KoreNet over the Mac's own, answering", within: 60, box: "b4", netCase: true) {
        if !r.onRoute("b4", net: true) { return false }
        return await r.answers("b4")
    }
    let ssh = await RigSSH.exec("b4", "true", places: r.places, timeout: 20)
    r.note("ssh b4 (plain, user's config) with this Mac's Tailscale gone: \(ssh.ok ? "works" : "fails (expected: no route)")")
    let viaKore = await r.kore.sshThroughKore("b4")
    r.check("Kore's SSH to b4 rides Kore's own tailnet", viaKore.ok, viaKore.out)
    r.logRow("b4")
    let t1 = now()
    _ = r.mac.start()
    await r.expect("this Mac back on installed Tailscale; its own node offline", within: 40) {
        guard r.kore.net.state == .installed else { return false }
        return await Headscale.nodes().first { $0.name == "rig-mac-kore" }?.online == false
    }
    r.note(String(format: "Mac moved back in %.1fs", now() - t1))
    await r.expect("b4's link on KoreNet over installed again, answering", within: 60, box: "b4", netCase: true) {
        if !r.onRoute("b4", net: true) { return false }
        return await r.answers("b4")
    }
}

@MainActor func blocked(_ r: Run) async {
    guard await plainBox(r, "b5", port: 22105) else { return }
    // SSH blocked (not the box's own loopback).
    _ = await Boxes.exec("b5", "iptables -I INPUT -p tcp --dport 22 ! -i lo -j DROP")
    await r.works("b5", "KoreNet with SSH blocked")
    _ = await Boxes.exec("b5", "iptables -D INPUT -p tcp --dport 22 ! -i lo -j DROP")
    // KoreNet blocked: the box's tailnet (DERP through its forward, and UDP) cut.
    _ = await Boxes.exec("b5", "systemctl stop rig-forward; iptables -I OUTPUT -p udp ! --dport 53 -j DROP; iptables -I INPUT -p udp ! --sport 53 -j DROP; ss -K dport = 13340 >/dev/null 2>&1; ss -K sport = 13340 >/dev/null 2>&1; true")
    // The window on screen, nothing asked: its beat notices the dead tailnet and SSH takes over.
    let t0 = now()
    await r.expect("b5's link falls back to SSH by itself (window on screen) and answers", within: 20, box: "b5", netCase: true) {
        r.onRoute("b5", net: false)
    }
    r.note(String(format: "fell back to SSH in %.1fs (window on screen, nothing asked)", now() - t0))
    r.check("b5 answers over SSH", await r.answers("b5"))
    // KoreNet back: the link moves back by itself (its hold, ≤ 30 s).
    _ = await Boxes.exec("b5", "iptables -F; systemctl start rig-forward")
    await r.expect("b5's link back on KoreNet by itself", within: 60, box: "b5", netCase: true) { r.onRoute("b5", net: true) }
    // Off screen: nothing runs; the first command on a dead tailnet notices it (watchdog + probe).
    r.kore.show("b5", false)
    _ = await Boxes.exec("b5", "systemctl stop rig-forward; iptables -I OUTPUT -p udp ! --dport 53 -j DROP; iptables -I INPUT -p udp ! --sport 53 -j DROP; ss -K dport = 13340 >/dev/null 2>&1; ss -K sport = 13340 >/dev/null 2>&1; true")
    let t1 = now()
    let first = Task { @MainActor in await r.kore.list("b5", "/home/kore") }
    await r.expect("b5's dead tailnet noticed on the first command (window off screen), and SSH up", within: 20, box: "b5", netCase: true) {
        r.onRoute("b5", net: false)
    }
    r.note(String(format: "first command noticed it and fell back to SSH in %.1fs (window off screen)", now() - t1))
    _ = await first.value
    r.kore.show("b5", true)
    // Both blocked: a clear state, never "Reconnecting…" for good.
    _ = await Boxes.exec("b5", "iptables -I INPUT -p tcp --dport 22 ! -i lo -j DROP")
    r.kore.link("b5")?.probe("rig")
    await r.expect("b5 with both routes blocked: offline, said plainly", within: 120, box: "b5", netCase: true) {
        guard let link = r.kore.link("b5"), !link.isOnline else { return false }
        return !(r.kore.row("b5")?.line ?? "").contains("Reconnecting")
    }
    r.logRow("b5")
    _ = await Boxes.exec("b5", "iptables -F; systemctl start rig-forward")
    await r.expect("b5 back once both are open", within: 120, box: "b5", netCase: true) { await r.answers("b5") }
}

/// The box's user has linger, as `sudo loginctl enable-linger` leaves it.
@MainActor func linger(_ box: String, user: String = "kore") async { _ = await Boxes.exec(box, "loginctl enable-linger \(user)") }

@MainActor func rebootBox(_ box: String) async -> Bool {
    let ran = await docker("restart", "-t", "5", Boxes.container(box), timeout: 90)
    _ = await Boxes.exec(box, "for i in $(seq 100); do s=$(systemctl is-system-running 2>/dev/null || true); case $s in running|degraded) break;; esac; sleep 0.1; done")
    return ran.ok
}

/// 0.3.10: the box's `bye restart` went down with its tailnet (kore-tailnet stopped, then exit,
/// before the bye crossed), so the Mac found the link dead by probe, relinked over SSH and moved
/// back ~30 s later. Now the bye goes first: the Mac's restart path, KoreNet straight back.
@MainActor func hostRestart(_ r: Run) async {
    guard await plainBox(r, "b25", port: 22125, lingerOn: true) else { return }
    await r.works("b25", "KoreNet before the restart")
    guard let link = r.kore.link("b25") else { return r.check("b25's link", false, "") }
    let t0 = now()
    let ran = await Boxes.exec("b25", "XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user restart kore-host", user: "kore")
    r.check("kore-host restarted by systemd", ran.ok, ran.out)
    // Watched every 100 ms until it's back: the reason the link ended, and any time on SSH.
    var heard: [String] = []
    var onSSH = false
    var back: Double?
    while now() - t0 < 30 {
        if let why = link.lastReason, heard.last != why { heard.append(why) }
        if link.isOnline, let route = link.route {
            if !route.isNet { onSSH = true }
            if route.isNet, now() - t0 > 0.5, await r.answers("b25") { back = now() - t0; break }
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    r.note("the link said: " + heard.joined(separator: " → "))
    r.check("the Mac heard kore-host restarting", heard.contains { $0.contains("restarting") }, heard.joined(separator: " → "))
    r.check("never through SSH meanwhile", !onSSH, "")
    r.check(String(format: "back on KoreNet, answering, within 15 s (%.1fs)", back ?? -1), (back ?? 99) < 15, r.kore.describe("b25"))
    await r.works("b25", "KoreNet after the restart")
    r.logRow("b25")
}

@MainActor func reboot(_ r: Run) async {
    guard await plainBox(r, "b6", port: 22106, lingerOn: true) else { return }
    let t0 = now()
    r.check("b6 rebooted", await rebootBox("b6"))
    await r.expect("b6's kore-host running after the reboot", within: 30) { await Boxes.exec("b6", "pgrep -u kore -x kore-host").ok }
    await r.expect("b6's own node online again", within: 40) { await Headscale.nodes().first { $0.name == "b6-kore" }?.online == true }
    await r.expect("b6's link back on KoreNet, answering", within: 90, box: "b6", netCase: true) {
        if !r.onRoute("b6", net: true) { return false }
        return await r.answers("b6")
    }
    r.note(String(format: "back %.1fs after the reboot", now() - t0))
}

@MainActor func bootRace(_ r: Run) async {
    guard await tsBox(r, "b7", port: 22107, lingerOn: true) else { return }
    guard await r.setUp("b7") else { return }
    guard await r.linkOnNet("b7") else { return }
    _ = await Boxes.exec("b7", "mkdir -p /etc/systemd/system/tailscaled.service.d && printf '[Service]\\nExecStartPre=/bin/sleep 10\\n' > /etc/systemd/system/tailscaled.service.d/late.conf && systemctl daemon-reload")
    r.check("b7 rebooted", await rebootBox("b7"))
    var ownOnline = false
    var start = now()
    while now() - start < 40 {
        if await Headscale.nodes().first(where: { $0.name == "b7-kore" })?.online == true { ownOnline = true }
        try? await Task.sleep(for: .milliseconds(500))
    }
    r.check("b7's own node never came online during the boot (one node)", !ownOnline)
    start = now()
    await r.expect("b7's link back on KoreNet over Tailscale, answering", within: 90, box: "b7", netCase: true) {
        if !r.onRoute("b7", net: true) { return false }
        return await r.answers("b7")
    }
    let j = await Boxes.exec("b7", "journalctl -q --no-pager -o cat | grep -E 'tailscale starting|korenet on' | tail -4")
    r.note("b7 journal: " + j.out.replacingOccurrences(of: "\n", with: " | "))
}

/// The row's "Sign in" pressed: the box's own page (from its `net.node`) opened. The page
/// reaches the row in `net.node` over a link that works: one whose tailnet node is gone moves to
/// SSH first (the removal heard on the bus, then a probe).
@MainActor func signInFromRow(_ r: Run, _ box: String, within: Double = 60) async -> Bool {
    await r.expect("\(box)'s row offers its Kore's tailnet sign-in page", within: within, box: box) {
        r.kore.picture().devices.contains { [box, HostConnection.current(box), r.kore.entry(box)?.id.raw].compactMap { $0 }.contains($0.id) && $0.ownPage != nil }
    } ? {
        let row = r.kore.picture().devices.first { [box, HostConnection.current(box), r.kore.entry(box)?.id.raw].compactMap { $0 }.contains($0.id) }
        if let page = row?.ownPage, let url = URL(string: page) { r.kore.browser.open(url) }
        return true
    }() : false
}

@MainActor func ownUnreadable(_ r: Run) async {
    guard await plainBox(r, "b8", port: 22108) else { return }
    _ = await Boxes.exec("b8", "head -c 32 /dev/urandom > /home/kore/.local/state/kore-host/tailnet.key; chown kore:kore /home/kore/.local/state/kore-host/tailnet.key; chmod 600 /home/kore/.local/state/kore-host/tailnet.key; pkill -u kore -x kore-host; sleep 1; su - kore -c '~/.local/bin/kore-host start'")
    await r.expect("b8 says its own is signed out · unreadable", within: 30) {
        (await Boxes.exec("b8", "cat /home/kore/.local/state/kore-host/tailnet-own.json")).out.contains("unreadable")
    }
    r.logRow("b8")
    // The link's over SSH meanwhile (the box isn't on any tailnet): its row says sign in.
    guard await signInFromRow(r, "b8", within: 90) else { return }
    await r.expect("b8 back on KoreNet after its sign-in, answering", within: 90, box: "b8", netCase: true) {
        if !r.onRoute("b8", net: true) { return false }
        return await r.answers("b8")
    }
    // Its old node's key was in the state that can't be opened: it can't sign out, so it stays
    // (offline) for the owner to remove; the new one carries the box.
    let b8nodes = await Headscale.nodes().filter { $0.name.hasPrefix("b8-kore") }
    r.check("a new b8-kore node online, the old one offline", b8nodes.count == 2 && b8nodes.filter(\.online).count == 1, "\(b8nodes.map { "\($0.name) online=\($0.online)" })")
}

@MainActor func ownRemoved(_ r: Run) async {
    guard await plainBox(r, "b9", port: 22109) else { return }
    let t0 = now()
    await Headscale.delete(named: "b9-kore")
    await r.expect("b9 says its own is signed out", within: 60) {
        (await Boxes.exec("b9", "cat /home/kore/.local/state/kore-host/tailnet-own.json")).out.contains("\"out\"")
    }
    r.logRow("b9")
    guard await signInFromRow(r, "b9", within: 90) else { return }
    let paged = now() - t0
    r.note(String(format: "the page on b9's row %.1fs after its node was deleted", paged))
    r.check("the page on b9's row within 20 s of the delete", paged <= 20, String(format: "%.1fs", paged))
    await r.expect("b9 back on KoreNet after its sign-in, answering", within: 90, box: "b9", netCase: true) {
        if !r.onRoute("b9", net: true) { return false }
        return await r.answers("b9")
    }
}

@MainActor func ownExpired(_ r: Run) async {
    guard await tsBox(r, "b10", port: 22110) else { return }
    guard await r.setUp("b10") else { return }
    guard await r.linkOnNet("b10") else { return }
    await r.expect("b10's own on standby (offline)", within: 30) { await Headscale.nodes().first { $0.name == "b10-kore" }?.online == false }
    // Its key runs out: expired at the control server, and the box's timer (as it read the
    // expiry at its sign-in) fires 8 s from its restart.
    await Headscale.expire(named: "b10-kore")
    // The box's record as kore-host keeps it (its node key kept: no start to read it), its
    // expiry 8 s from the restart, in kore-host's own date form (seconds since 2001).
    let f = "/home/kore/.local/state/kore-host/tailnet-own.json"
    let kept = (await Boxes.exec("b10", "cat \(f)")).out
    var record = (try? JSONSerialization.jsonObject(with: Data(kept.utf8))) as? [String: Any] ?? [:]
    let expires = Date().addingTimeInterval(8)
    record["expiry"] = expires.timeIntervalSinceReferenceDate
    r.check("b10's record holds its own node's key", record["nodeKey"] != nil, kept)
    let b64 = ((try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data()).base64EncodedString()
    _ = await Boxes.exec("b10", "echo \(b64) | base64 -d > \(f); chown kore:kore \(f); chmod 600 \(f); pkill -u kore -x kore-host; sleep 1; su - kore -c '~/.local/bin/kore-host start'")
    await r.expect("b10's link on KoreNet after the restart", within: 60, box: "b10", netCase: true) {
        if !r.onRoute("b10", net: true) { return false }
        return await r.answers("b10")
    }
    await r.expect("b10 says its own expired, then signs in again on standby", within: 40) {
        let j = await Boxes.exec("b10", "{ journalctl -q --no-pager -o cat; cat /home/kore/.local/state/kore-host/kore-host.log 2>/dev/null; } | grep -c 'why=expired'")
        return (Int(j.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) >= 1
    }
    guard await signInFromRow(r, "b10", within: 60) else { return }
    let paged = now() - expires.timeIntervalSinceReferenceDate
    r.note(String(format: "the page on b10's row %.1fs after its key ran out", paged))
    r.check("the page on b10's row within 20 s of its key running out", paged <= 20, String(format: "%.1fs", paged))
    let signedIn = now()
    await r.expect("b10's row quiet within 5 s of the browser sign-in", within: 5) {
        guard let row = r.kore.picture().devices.first(where: { ["b10", HostConnection.current("b10"), r.kore.entry("b10")?.id.raw].compactMap { $0 }.contains($0.id) }) else { return false }
        return row.own?.signedIn == true
    }
    r.note(String(format: "b10's row quiet %.1fs after the browser sign-in", now() - signedIn))
    await r.expect("b10's own signed in again and stopped (standby)", within: 60) {
        let rec = (await Boxes.exec("b10", "cat /home/kore/.local/state/kore-host/tailnet-own.json")).out
        guard rec.contains("\"in\"") else { return false }
        return await Headscale.nodes().first { $0.name == "b10-kore" }?.online == false
    }
}

@MainActor func tailscaleSSH(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b19", sshPort: 22119, tailscale: true, tailscaleSSH: true, sshd: false)), let ip = await Boxes.tailscaleIP("b19") else { return }
    guard await r.launch(installed: true) else { return }
    RigSSH.write([RigSSH.Host(alias: "b19", lines: ["HostName \(ip)", "User kore", "ProxyCommand '\(r.places.tailscale.path)' --socket=\(r.mac.socket) nc %h %p"])], places: r.places)
    let plain = await RigSSH.exec("b19", "true", places: r.places)
    let sshdOn = await Boxes.exec("b19", "systemctl is-active ssh").ok
    r.check("b19's sshd is off; Tailscale SSH answers on its Tailscale IP", plain.ok && !sshdOn, plain.out)
    guard await r.setUp("b19") else { return }
    if await r.linkOnNet("b19") { await r.works("b19", "KoreNet (set up over Tailscale SSH)") }
}

@MainActor func magicDNS(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b22", sshPort: 22122, tailscale: true)) else { return }
    guard await r.launch(installed: true) else { return }
    let name = "b22.rig.example"
    RigSSH.write([RigSSH.Host(alias: "b22", lines: ["HostName \(name)", "User kore", "ProxyCommand '\(r.places.tailscale.path)' --socket=\(r.mac.socket) nc %h %p"])], places: r.places)
    let reach = await RigSSH.exec("b22", "true", places: r.places)
    r.check("ssh b22 by its MagicDNS name \(name)", reach.ok, reach.out)
    guard reach.ok, await r.setUp("b22") else { return }
    if await r.linkOnNet("b22") { await r.works("b22", "KoreNet (MagicDNS alias)") }
}

@MainActor func ownProxy(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b23", sshPort: 22123)) else { return }
    RigSSH.write([RigSSH.Host(alias: "b23", lines: ["HostName 127.0.0.1", "Port 22123", "User kore"])], places: r.places)
    guard await r.launch(installed: false) else { return }
    guard await r.setUp("b23"), await r.linkOnNet("b23") else { return }
    guard let ip = await Headscale.nodes().first(where: { $0.name == "b23-kore" })?.ips.first(where: { !$0.contains(":") }) else {
        return r.check("b23's own node has an address", false)
    }
    // The alias at the box's tailnet address, as one written for Tailscale: this Mac has no route there.
    RigSSH.write([
        RigSSH.Host(alias: "b23", lines: ["HostName 127.0.0.1", "Port 22123", "User kore"]),
        RigSSH.Host(alias: "b23-tn", lines: ["HostName \(ip)", "User kore"]),
    ], places: r.places)
    _ = await Boxes.exec("b23", "iptables -I INPUT -p tcp --dport 22 -i eth0 -j DROP")
    let lan = await RigSSH.exec("b23", "true", places: r.places, timeout: 15)
    r.check("the LAN SSH is blocked", !lan.ok, lan.out)
    let plain = await RigSSH.exec("b23-tn", "true", places: r.places, timeout: 15)
    r.check("plain ssh to \(ip) has no route from this Mac (no installed Tailscale)", !plain.ok, plain.out)
    let t0 = now()
    let kore = await r.kore.sshThroughKore("b23-tn")
    r.check(String(format: "Kore's ssh to \(ip) rides Kore's own tailnet (%.1fs)", now() - t0), kore.ok, kore.out)
    let shell = BoxShell()
    let version = await shell.run("b23-tn", "~/.local/bin/kore-host --version")
    r.check("a command over it: kore-host --version", version.ok && version.output.contains("kore-host "), version.output)
    let file = r.places.scratch.appendingPathComponent("probe.txt")
    try? "korenet-rig".write(to: file, atomically: true, encoding: .utf8)
    let copied = await shell.copy(file, to: "b23-tn", path: "probe.txt")
    let there = await Boxes.exec("b23", "cat /home/kore/probe.txt")
    r.check("scp over it", copied.ok && there.out.contains("korenet-rig"), copied.output)
    await r.works("b23", "KoreNet (LAN SSH blocked)")
}

@MainActor func proxyJump(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b13", sshPort: 22113)), await r.box(BoxSpec(name: "b14", sshPort: 22114)) else { return }
    RigSSH.write([RigSSH.Host(alias: "b14", lines: ["HostName b14", "User kore", "ProxyJump kore@127.0.0.1:22113"])], places: r.places)
    guard await r.launch(installed: false) else { return }
    let reach = await RigSSH.exec("b14", "hostname", places: r.places)
    r.check("ssh b14 through b13 (ProxyJump)", reach.ok && reach.out.contains("b14"), reach.out)
    if await r.setUp("b14"), await r.linkOnNet("b14") { await r.works("b14", "KoreNet (ProxyJump)") }
}

@MainActor func port2222(_ r: Run) async {
    // sshd on 2222 only, published as 22213.
    let made = await run(dockerPath, ["run", "-d", "--name", Boxes.container("b13"), "--hostname", "b13", "--label", "com.kore.rig=1", "--label", "com.kore.rig.scenario=\(r.name)",
        "--cpus", "1.5", "--memory", "1g", "--privileged", "--cgroupns=host", "-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw", "--tmpfs", "/run", "--tmpfs", "/run/lock", "--tmpfs", "/tmp",
        "--network", "kore-rig_rig", "-p", "127.0.0.1:22213:2222", "kore-rig-box:1"])
    r.check("b13 made", made.ok, made.out)
    let pub = ((try? String(contentsOf: r.places.sshKey.appendingPathExtension("pub"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    _ = await Boxes.exec("b13", "for i in $(seq 100); do s=$(systemctl is-system-running 2>/dev/null || true); case $s in running|degraded) break;; esac; sleep 0.1; done; sed -i 's/^#\\?Port .*/Port 2222/' /etc/ssh/sshd_config; grep -q '^Port 2222' /etc/ssh/sshd_config || echo 'Port 2222' >> /etc/ssh/sshd_config; systemctl restart ssh; install -d -m 700 -o kore -g kore /home/kore/.ssh; echo '\(pub)' > /home/kore/.ssh/authorized_keys; chown kore:kore /home/kore/.ssh/authorized_keys; chmod 600 /home/kore/.ssh/authorized_keys; echo KORE_TAILNET_CONTROL_URL=\(Headscale.controlInBoxes) > /etc/environment.d/90-kore-rig.conf; echo KORE_TAILNET_CONTROL_URL=\(Headscale.controlInBoxes) >> /etc/environment")
    RigSSH.write([], places: r.places)
    guard await r.launch(installed: false) else { return }
    let typed = "kore@127.0.0.1:22213"
    guard let alias = BoxList.alias(typed) else { return r.check("\(typed) is a box destination", false) }
    let reach = await r.kore.sshThroughKore(alias)
    r.check("ssh \(typed) (port 2222 inside)", reach.ok, reach.out)
    if await r.setUp(alias), await r.linkOnNet(alias) { await r.works(alias, "KoreNet (\(typed))") }
}

@MainActor func users(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b15", sshPort: 22115)), await r.box(BoxSpec(name: "b16", sshPort: 22116)) else { return }
    RigSSH.write([
        RigSSH.Host(alias: "b15", lines: ["HostName 127.0.0.1", "Port 22115", "User nosudo"]),
        RigSSH.Host(alias: "b16", lines: ["HostName 127.0.0.1", "Port 22116", "User root"]),
    ], places: r.places)
    guard await r.launch(installed: false) else { return }
    if await r.setUp("b15") {
        r.note("b15 (no sudo) warning: \(BoxList.shared.box("b15")?.warning ?? "none")")
        if await r.linkOnNet("b15") { await r.works("b15", "KoreNet (non-root, no sudo)", home: "/home/nosudo") }
        // The daemon outlives the sessions (linger off): still there 20 s after the last one.
        try? await Task.sleep(for: .seconds(20))
        r.check("b15's kore-host still runs 20 s after the last SSH session", await Boxes.exec("b15", "pgrep -u nosudo -x kore-host").ok)
    }
    if await r.setUp("b16") {
        r.check("b16 (root) has no linger warning", BoxList.shared.box("b16")?.warning == nil, BoxList.shared.box("b16")?.warning ?? "")
        if await r.linkOnNet("b16") { await r.works("b16", "KoreNet (root)", home: "/root") }
        r.check("b16 rebooted", await rebootBox("b16"))
        let t0 = now()
        await r.expect("b16's link back on KoreNet after its reboot, answering", within: 60, box: "b16", netCase: true) {
            if !r.onRoute("b16", net: true) { return false }
            // Root's home: the folder its link serves (not /home/kore, which root's box doesn't).
            return await r.answers("b16", home: "/root")
        }
        r.note(String(format: "root's link back %.1fs after its reboot", now() - t0))
    }
}

@MainActor func binaries(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b17", sshPort: 22117)) else { return }
    RigSSH.write([RigSSH.Host(alias: "b17", lines: ["HostName 127.0.0.1", "Port 22117", "User kore"])], places: r.places)
    guard await r.launch(installed: false) else { return }
    let bin = "/home/kore/.local/bin"
    let cases: [(String, String)] = [
        ("corrupted", "mkdir -p \(bin); head -c 4096 /dev/urandom > \(bin)/kore-host; chmod 755 \(bin)/kore-host"),
        ("half-installed", "~kore/.local/bin/kore-host uninstall >/dev/null 2>&1; pkill -x kore-host; cp \(bin)/kore-host \(bin)/kore-host.new; head -c 1000 \(bin)/kore-host.new > /tmp/k && mv /tmp/k \(bin)/kore-host.new; rm -f \(bin)/kore-host"),
        ("older", "pkill -x kore-host; printf '#!/bin/sh\\ncase \"$1\" in --version) echo \"kore-host 0.3.1 (link 1.9)\";; *) echo \"kore-host 0.3.1: unknown command\" >&2; exit 2;; esac\\n' > \(bin)/kore-host; chmod 755 \(bin)/kore-host"),
    ]
    for (what, script) in cases {
        _ = await Boxes.exec("b17", script + "; chown -R kore:kore /home/kore/.local")
        r.kore.close("b17")
        guard await r.setUp("b17") else { continue }
        if await r.linkOnNet("b17", within: 60) { await r.works("b17", "KoreNet (after a \(what) kore-host)") }
        let v = await Boxes.exec("b17", "su - kore -c '~/.local/bin/kore-host --version'; ls \(bin)")
        r.check("b17 runs this Mac's kore-host, nothing left over (\(what))", v.out.contains("kore-host \(macVersion) ") && !v.out.contains(".new"), v.out)
    }
    r.check("one b17-kore node", (await Headscale.nodes()).filter { $0.name.hasPrefix("b17-kore") }.count == 1)
}

/// The version this Mac's kore-host says: the package's `VERSION`, as kore-host embeds it.
let macVersion: String = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)) ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}()

@MainActor func forgotten(_ r: Run) async {
    guard await plainBox(r, "b18", port: 22118) else { return }
    let key = HostConnection.current("b18")
    r.kore.close("b18")
    BoxList.shared.remove(key)
    r.check("b18 forgotten here: not listed, no KoreNet entry", BoxList.shared.boxes.isEmpty && NodeDirectory.shared.all.isEmpty, "\(BoxList.shared.boxes.map(\.alias))")
    guard await r.setUp("b18") else { return }
    if await r.linkOnNet("b18") { await r.works("b18", "KoreNet (re-added)") }
    r.check("one b18-kore node", (await Headscale.nodes()).filter { $0.name.hasPrefix("b18-kore") }.count == 1)
}

// MARK: fresh-box.sh

/// The test's Kore: a copy of this binary named korenet-rig-fresh (its own settings domain and
/// process name, as Kore.app's are), its folders and tailnet state kept across its launches.
@MainActor func freshBox(_ r: Run) async {
    let fresh = r.places.run.appendingPathComponent("fresh", isDirectory: true)
    try? FileManager.default.removeItem(at: fresh)
    try? FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let copy = fresh.appendingPathComponent("korenet-rig-fresh")
    try? FileManager.default.copyItem(at: me, to: copy)
    let scratch = "/tmp/kr-fresh"
    try? FileManager.default.removeItem(atPath: scratch)
    defer {
        _ = runSync("/usr/bin/defaults", ["delete", "korenet-rig-fresh"])
        try? FileManager.default.removeItem(atPath: scratch)
    }
    guard await r.box(BoxSpec(name: "b12", sshPort: 22112)) else { return }
    // The children's ssh config (written once, kept in their scratch).
    var env = ProcessInfo.processInfo.environment
    env["RIG_SCRATCH"] = scratch
    env["RIG_KORE_BASE"] = fresh.appendingPathComponent("kore").path
    env["RIG_KEEP"] = "1"
    env["RIG_KEEP_DEFAULTS"] = "1"
    env["RIG_VERBOSE"] = "1"
    let child = RigPlaces(run: r.places.run, bin: r.places.bin, hostBin: r.places.hostBin, authKey: r.places.authKey, scratch: URL(fileURLWithPath: scratch), scenario: "fresh-phase")
    try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    RigSSH.write([RigSSH.Host(alias: "b12", lines: ["HostName 127.0.0.1", "Port 22112", "User kore"])], places: child)
    func phase(_ n: Int) async -> Bool {
        var e = env
        e["RIG_PHASE"] = "\(n)"
        let ran = await Task.detached { runSync(copy.path, ["fresh-phase"], timeout: 400, env: e) }.value
        for line in ran.out.split(whereSeparator: \.isNewline) { say("  [kore \(n)] " + line) }
        r.check("Kore launch \(n) (\(["", "set up", "after the wipe: unknown box, set up from scratch", "after the restore: the original box"][n]))", ran.ok, ran.out.split(whereSeparator: \.isNewline).filter { $0.contains("FAIL") }.joined(separator: "; "))
        return ran.ok
    }
    let script = r.places.run.deletingLastPathComponent().path
    _ = script
    let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/tests/fresh-box.sh").path
    func freshBoxSh(_ args: [String], yes: Bool = false) async -> Ran {
        var e = env
        e["FRESH_KORE_DOMAIN"] = "korenet-rig-fresh"
        e["FRESH_KORE_SUPPORT"] = fresh.appendingPathComponent("kore/support").path
        e["FRESH_KORE_PROCESS"] = "korenet-rig-fresh"
        e["FRESH_SSH"] = child.sshWrapper.path
        e["FRESH_TEST_SSH_GLOB"] = "/tmp/kr-[0-9]*/ssh_config"
        if yes { e["FRESH_YES"] = "1" }
        let ran = await Task.detached { runSync("/bin/zsh", [tool] + args, timeout: 120, env: e) }.value
        for line in ran.out.split(whereSeparator: \.isNewline) { say("  [fresh-box \(args[0])] " + line) }
        return ran
    }
    guard await phase(1) else { return }
    let backup = await freshBoxSh(["--backup", "b12"])
    r.check("fresh-box.sh --backup b12", backup.ok, backup.out)
    guard let folder = backup.out.split(whereSeparator: \.isNewline).last.map(String.init), FileManager.default.fileExists(atPath: folder + "/mac.json") else { return }
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let refused = await freshBoxSh(["--wipe", "b12"])
    r.check("--wipe without a yes changes nothing", !refused.ok && refused.out.contains("Nothing changed"), refused.out)
    let wiped = await freshBoxSh(["--wipe", "b12"], yes: true)
    r.check("fresh-box.sh --wipe b12", wiped.ok, wiped.out)
    let left = await Boxes.exec("b12", "ls -a /home/kore/.local/bin /home/kore/.local/state /home/kore/.config/systemd/user 2>/dev/null; pgrep -u kore -x kore-host")
    r.check("b12 has no kore-host (binary, state, unit, daemon)", !left.out.contains("kore-host"), left.out)
    let prefs = runSync("/usr/bin/defaults", ["export", "korenet-rig-fresh", "-"]).out
    r.check("Kore's settings name b12 nowhere", !prefs.contains("b12"), prefs.split(whereSeparator: \.isNewline).filter { $0.contains("b12") }.prefix(6).joined(separator: " "))
    let verify = await freshBoxSh(["--verify", "b12", "--expect", "fresh"])
    r.check("fresh-box.sh --verify b12 --expect fresh: clean", verify.ok, verify.out)
    let proof = r.places.run.appendingPathComponent("proof/fresh-box", isDirectory: true)
    try? FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
    try? verify.out.write(to: proof.appendingPathComponent("reset-after-wipe.txt"), atomically: true, encoding: .utf8)
    guard await phase(2) else { return }
    let restored = await freshBoxSh(["--restore", "b12", folder])
    r.check("fresh-box.sh --restore b12", restored.ok, restored.out)
    let back = await freshBoxSh(["--verify", "b12", "--expect", "installed"])
    try? back.out.write(to: r.places.run.appendingPathComponent("proof/fresh-box/verify-after-restore.txt"), atomically: true, encoding: .utf8)
    r.check("fresh-box.sh --verify b12 --expect installed", back.ok, back.out)
    _ = await phase(3)
}

/// One launch of the fresh-box test's Kore (RIG_PHASE 1, 2 or 3).
@MainActor func freshPhase(_ r: Run) async {
    let phase = ProcessInfo.processInfo.environment["RIG_PHASE"] ?? "1"
    let idFile = r.places.run.appendingPathComponent("fresh/phase1-id")
    guard await r.launch(installed: false) else { return }
    switch phase {
    case "1":
        guard await r.setUp("b12"), await r.linkOnNet("b12") else { return }
        await r.works("b12", "KoreNet")
        try? (r.kore.entry("b12")?.id.raw ?? "").write(to: idFile, atomically: true, encoding: .utf8)
    case "2":
        r.check("Kore lists no box, knows no KoreNet box", BoxList.shared.boxes.isEmpty && NodeDirectory.shared.all.isEmpty, "\(BoxList.shared.boxes.map(\.alias)) \(NodeDirectory.shared.all.keys)")
        guard await r.setUp("b12"), await r.linkOnNet("b12") else { return }
        await r.works("b12", "KoreNet (set up from scratch)")
        let before = (try? String(contentsOf: idFile, encoding: .utf8)) ?? ""
        r.check("a new box id (the box started afresh)", r.kore.entry("b12")?.id.raw != before)
    default:
        let before = (try? String(contentsOf: idFile, encoding: .utf8)) ?? ""
        r.check("b12 listed again, as the original box", BoxList.shared.box("b12") != nil || BoxList.shared.boxes.contains { $0.alias == before }, "\(BoxList.shared.boxes.map(\.alias))")
        r.check("its KoreNet entry is the original id", NodeDirectory.shared.all[before] != nil, "\(NodeDirectory.shared.all.keys)")
        guard await r.linkOnNet(before.isEmpty ? "b12" : before, within: 90) else { return }
        await r.works(before, "KoreNet (restored)")
    }
}

@MainActor func interrupted(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b11", sshPort: 22111)) else { return }
    RigSSH.write([RigSSH.Host(alias: "b11", lines: ["HostName 127.0.0.1", "Port 22111", "User kore"])], places: r.places)
    guard await r.launch(installed: false) else { return }
    BoxList.shared.add("b11")
    // 1. ssh killed mid-install (the copy of kore-host).
    let killer = Task.detached {
        for _ in 0..<600 {
            if await Boxes.exec("b11", "pgrep -f 'scp -t .local/bin/kore-host.new' >/dev/null && pkill -f 'sshd: kore' ; true").ok,
               await Boxes.exec("b11", "test -e /home/kore/.local/bin/kore-host.new").ok { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    await BoxList.shared.setUp("b11")
    _ = await killer.value
    r.note("first Set up (ssh killed mid-copy): \(BoxList.shared.box("b11").map { "\($0.status)" } ?? "-")")
    // 2. A retry; ssh killed mid-sign-in (while `kore-host tailnet --until-in` waits).
    r.kore.browser.signsIn = false
    let killer2 = Task.detached {
        for _ in 0..<600 {
            if await Boxes.exec("b11", "pgrep -f 'tailnet --until-in' >/dev/null").ok {
                _ = await Boxes.exec("b11", "pkill -f 'sshd: kore'")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    await BoxList.shared.setUp("b11")
    _ = await killer2.value
    r.note("second Set up (ssh killed mid-sign-in): \(BoxList.shared.box("b11").map { "\($0.status)" } ?? "-")")
    // 3. The retry completes; the page signed in this time.
    r.kore.browser.signsIn = true
    guard await r.setUp("b11") else { return }
    guard await r.linkOnNet("b11") else { return }
    await r.works("b11", "KoreNet after the interrupted runs")
    let nodes = await Headscale.nodes()
    r.check("one b11-kore node", nodes.filter { $0.name.hasPrefix("b11-kore") }.count == 1, "\(nodes.map(\.name))")
    let leftover = await Boxes.exec("b11", "ls /home/kore/.local/bin/")
    r.check("nothing half-installed left", !leftover.out.contains(".new"), leftover.out)
}

/// A box with Tailscale, reached over its Tailscale IP from a Mac running Tailscale.
@MainActor func tsBox(_ r: Run, _ name: String, port: Int, lingerOn: Bool = false) async -> Bool {
    guard await r.box(BoxSpec(name: name, sshPort: port, tailscale: true)), let ip = await Boxes.tailscaleIP(name) else { return false }
    if lingerOn { await linger(name) }
    guard await r.launch(installed: true) else { return false }
    // ssh to the box's Tailscale IP: a real Mac's kernel route, here the userspace daemon's.
    RigSSH.write([RigSSH.Host(alias: name, lines: ["HostName \(ip)", "User kore", "ProxyCommand '\(r.places.tailscale.path)' --socket=\(r.mac.socket) nc %h %p"])], places: r.places)
    let reach = await RigSSH.exec(name, "true", places: r.places)
    r.check("ssh \(name) over its Tailscale IP", reach.ok, reach.out)
    return reach.ok
}

@MainActor func tsIP(_ r: Run) async {
    guard await tsBox(r, "b2", port: 22102) else { return }
    guard await r.setUp("b2") else { return }
    guard await r.linkOnNet("b2") else { return }
    await r.works("b2", "KoreNet (installed Tailscale)")
    let said = await Boxes.exec("b2", "su - kore -c '~/.local/bin/kore-host tailnet --within 5'")
    r.note("b2 kore-host tailnet: " + said.out.replacingOccurrences(of: "\n", with: " | "))
    let nodes = await Headscale.nodes()
    await r.expect("b2's own node signed in, on standby (offline)", within: 20) { await Headscale.nodes().first { $0.name == "b2-kore" }?.online == false }
    r.check("b2's installed node online", nodes.first { $0.name == "b2" }?.online == true)
    r.logRow("b2")
}

@MainActor func boxTailscaleStops(_ r: Run) async {
    guard await tsBox(r, "b3", port: 22103) else { return }
    guard await r.setUp("b3") else { return }
    guard await r.linkOnNet("b3") else { return }
    let t0 = now()
    _ = await Boxes.exec("b3", "systemctl stop tailscaled")
    await r.expect("b3's own node online after tailscaled stopped", within: 30) { await Headscale.nodes().first { $0.name == "b3-kore" }?.online == true }
    r.note(String(format: "b3 moved to its own in %.1fs", now() - t0))
    await r.expect("Mac's link back on KoreNet (b3's own node), answering", within: 60, box: "b3", netCase: true) { if !r.onRoute("b3", net: true) { return false }; return await r.answers("b3") }
    let ssh = await r.kore.sshThroughKore("b3")
    r.check("Kore's SSH to b3 (its Tailscale IP is gone) still works", ssh.ok, ssh.out)
    r.logRow("b3")
    await filesThroughKore(r, "b3")
    let t1 = now()
    _ = await Boxes.exec("b3", "systemctl start tailscaled")
    await r.expect("b3 back on installed Tailscale: own offline, installed online", within: 60) {
        let nodes = await Headscale.nodes()
        return nodes.first { $0.name == "b3" }?.online == true && nodes.first { $0.name == "b3-kore" }?.online == false
    }
    r.note(String(format: "b3 moved back in %.1fs", now() - t1))
    await r.expect("Mac's link on KoreNet over installed again, answering", within: 60, box: "b3", netCase: true) { if !r.onRoute("b3", net: true) { return false }; return await r.answers("b3") }
    await r.works("b3", "KoreNet after the moves")
    r.logRow("b3")
}

/// The box's Tailscale gone, its alias still naming that address, the link on Kore's own
/// tailnet: the sync (a pair, both ways), a copy's rsync (as moves, copies and carries run it) and
/// a shell over SSH ride the same route (0.3.10: they went to the dead address and paused on
/// "rsync: unexpected end of file").
@MainActor func filesThroughKore(_ r: Run, _ alias: String, shell: Bool = true) async {
    guard let link = r.kore.link(alias), let box = SyncBox.box(link) else { return r.check("\(alias)'s link and SSH alias", false, "") }
    let home = "/home/kore"
    // A copy's rsync and a shell, as ChatMoves, ChatCopies and FileCarry run them.
    let local = r.places.scratch.appendingPathComponent("carry-\(alias)")
    try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    try? "carried".write(to: local.appendingPathComponent("carried.txt"), atomically: true, encoding: .utf8)
    let pushed = await SyncProcess.run("/usr/bin/rsync", ["-a"] + box.rsyncOptions(false) + [local.path + "/", box.spec(home + "/carry/")])
    r.check("a copy's rsync to \(alias) rides Kore's tailnet", pushed.status == 0, pushed.said)
    if shell {
        let read = await box.shell(#"cat "$1""#, [home + "/carry/carried.txt"])
        r.check("a shell over SSH reads it back", read.status == 0 && read.out.contains("carried"), read.said)
    } else {
        let there = await Boxes.exec(alias, "[ \"$(cat \(home)/carry/carried.txt)\" = carried ]", user: "kore")
        r.check("the copy landed on \(alias)", there.ok, there.out)
        let back = r.places.scratch.appendingPathComponent("back-\(alias)")
        let pulled = await SyncProcess.run("/usr/bin/rsync", ["-a"] + box.rsyncOptions(false) + [box.spec(home + "/carry/"), back.path + "/"])
        let landed = (try? String(contentsOf: back.appendingPathComponent("carried.txt"), encoding: .utf8)) ?? ""
        r.check("a copy's rsync from \(alias) rides the pipe back", pulled.status == 0 && landed == "carried", pulled.said)
    }
    // The sync: a pair, a file each way.
    _ = await Boxes.exec(alias, "mkdir -p \(home)/pair", user: "kore")
    _ = await link.addFolder(home + "/pair")
    let mac = r.places.scratch.appendingPathComponent("pair-\(alias)")
    try? FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
    let pair = SyncPair(mac: mac.path, alias: alias, box: home + "/pair")
    guard let sync = HostSync(pair: pair, connection: link, root: r.places.scratch.appendingPathComponent("sync-cache")) else {
        return r.check("a sync for \(alias)", false, "")
    }
    sync.start()
    defer { sync.stop() }
    try? "from the Mac".write(to: mac.appendingPathComponent("from-mac.txt"), atomically: true, encoding: .utf8)
    await r.expect("the sync carries a Mac file to \(alias)", within: 45) {
        await Boxes.exec(alias, "cat \(home)/pair/from-mac.txt", user: "kore").out.contains("from the Mac")
    }
    _ = await Boxes.exec(alias, "echo from-box > \(home)/pair/from-box.txt", user: "kore")
    await r.expect("the sync carries a box file here", within: 45) { FileManager.default.fileExists(atPath: mac.appendingPathComponent("from-box.txt").path) }
    r.check("no paused line", sync.notice?.hasPrefix("Sync paused") != true, sync.notice ?? "")
}

@MainActor func firstContact(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b24", sshPort: 22124)) else { return }
    let known = r.places.scratch.appendingPathComponent("known_hosts")
    FileManager.default.createFile(atPath: known.path, contents: nil)
    RigSSH.write([RigSSH.Host(alias: "b24", lines: ["HostName 127.0.0.1", "Port 22124", "User kore", "StrictHostKeyChecking ask", "UserKnownHostsFile \(known.path)"])], places: r.places)
    guard await r.launch(installed: false) else { return }
    let status = await r.kore.addAndSetUp("b24")
    let said: String
    if case .failed(let line, let fix)? = status { said = line + " · fix: \(fix.map { "\($0)" } ?? "none")" } else { said = "\(status.map { "\($0)" } ?? "-")" }
    r.check("Set up stops at the new host key", said.contains("host key is new"), said)
    r.note("Set up said: \(said)")
    // The line then shows the key's fingerprint, as ssh prints it, and Trust (no Terminal).
    var offer: BoxHostKey.Offer?
    guard await r.expect("b24's line shows its key's fingerprint and Trust", within: 30, box: "b24", {
        if case .failed(_, .trust(let shown))? = BoxList.shared.box("b24")?.status { offer = shown }
        return offer != nil
    }), let offer else { return }
    r.note("the line: \(offer.line)")
    // The box's own keys, read apart from Kore: what's shown is one of them.
    let scanned = await run("/bin/sh", ["-c", "ssh-keyscan -p 22124 127.0.0.1 2>/dev/null | ssh-keygen -lf -"])
    let prints = offer.fingerprints.compactMap { $0.split(separator: " ").last.map(String.init) }
    r.check("the fingerprint shown is b24's own key", !prints.isEmpty && prints.allSatisfy { scanned.out.contains($0) }, scanned.out)
    r.check("known_hosts is still empty before Trust", ((try? String(contentsOf: known, encoding: .utf8)) ?? "").isEmpty)
    let start = now()
    await BoxList.shared.act(.trust(offer), on: "b24")
    let after = BoxList.shared.box("b24")?.status
    r.check(String(format: "Trust → Set up goes on → Ready (%.1fs)", now() - start), after == .ready, "\(after.map { "\($0)" } ?? "-")")
    let kept = (try? String(contentsOf: known, encoding: .utf8)) ?? ""
    r.check("known_hosts holds b24's key as accept-new writes it", kept.contains("[127.0.0.1]:22124") && offer.lines.allSatisfy(kept.contains), kept)
    guard after == .ready else { return }
    if await r.linkOnNet("b24") { await r.works("b24", "KoreNet (first contact, Trust)") }
}

@MainActor func plainSSH(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b1", sshPort: 22101)) else { return }
    RigSSH.write([RigSSH.Host(alias: "b1", lines: ["HostName 127.0.0.1", "Port 22101", "User kore"])], places: r.places)
    guard await r.launch(installed: false) else { return }
    guard await r.setUp("b1") else { return }
    guard await r.linkOnNet("b1") else { return }
    await r.works("b1", "KoreNet")
    let ssh = await RigSSH.exec("b1", "true", places: r.places)
    r.check("SSH still reaches b1", ssh.ok, ssh.out)
    r.check("sign-in pages opened: this Mac's once, b1's once", r.kore.browser.opened.count == 2, "\(r.kore.browser.opened.count) opened")
    r.logRow("b1")
}

/// Cell B: no sshd once set up. The link on KoreNet, every copy goes over `kore pipe` (owner,
/// 2026-11-24); none waits on the alias, which now answers nothing.
@MainActor func pipeNoSSHD(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b26", sshPort: 22126)) else { return }
    RigSSH.write([RigSSH.Host(alias: "b26", lines: ["HostName 127.0.0.1", "Port 22126", "User kore", "ConnectTimeout 5"])], places: r.places)
    guard await r.launch(installed: false) else { return }
    guard await r.setUp("b26") else { return }
    guard await r.linkOnNet("b26") else { return }
    _ = await Boxes.exec("b26", "systemctl stop ssh.socket ssh 2>/dev/null; systemctl stop ssh")
    let ssh = await RigSSH.exec("b26", "true", places: r.places, timeout: 10)
    r.check("b26's sshd is off", !ssh.ok, ssh.out)
    await r.works("b26", "KoreNet, sshd off")
    if let link = r.kore.link("b26") {
        r.check("b26 serves pipes", link.caps.contains(LinkPipe.cap), "\(link.caps)")
        r.check("its copies choose the pipe", SyncBox.box(link)?.overPipe == true)
    }
    let t0 = now()
    await filesThroughKore(r, "b26", shell: false)
    r.note(String(format: "copies and the sync over the pipe in %.1fs", now() - t0))
    r.logRow("b26")
}

/// 0.3.10: a box's alias left on an address that no longer answers (mybox's `Host mybox` on its
/// old LAN address) while KoreNet carries the box. Nothing Kore does for it waits on an SSH
/// connect there (Kore's are 5–10 s each), and its row doesn't say it can't be reached.
@MainActor func deadAlias(_ r: Run) async {
    guard await plainBox(r, "b28", port: 22128) else { return }
    await r.works("b28", "KoreNet before the alias went dead")
    // TEST-NET-1: routed nowhere, so a connect there waits out its timeout, as a dead LAN address does.
    RigSSH.write([RigSSH.Host(alias: "b28", lines: ["HostName 192.0.2.1", "User kore"])], places: r.places)
    let probe = now()
    let ssh = await RigSSH.exec("b28", "true", places: r.places, timeout: 15)
    r.check(String(format: "ssh b28 gets no answer now (%.1fs)", now() - probe), !ssh.ok, ssh.out)
    let log = r.places.scratch.appendingPathComponent("kore-ssh.log")
    let sshBefore = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").count
    /// One action, timed: within `limit`, well under an SSH connect's wait.
    func quick(_ what: String, limit: Double = 3, _ work: () async -> String?) async {
        let t0 = now()
        let failed = await work()
        let took = now() - t0
        r.check(String(format: "%@ (%.1fs, under %.0fs)", what, took, limit), failed == nil && took < limit, failed ?? r.kore.describe("b28"))
    }
    await quick("fs.list over KoreNet, alias dead") { await r.kore.list("b28", "/home/kore") ? nil : "fs.list failed" }
    await quick("chat.call over KoreNet, alias dead") { await r.kore.chatCall("b28", folder: "/home/kore") }
    await quick("a probe of b28 finds it Ready") {
        await BoxList.shared.probe("b28")
        return BoxList.shared.box("b28")?.status == .ready ? nil : "status \(BoxList.shared.box("b28").map { "\($0.status)" } ?? "-")"
    }
    await quick("its window closed and opened again: online on KoreNet") {
        r.kore.close("b28")
        try? await Task.sleep(for: .milliseconds(500))
        r.kore.open("b28")
        let up = await r.until("b28 back online", within: 10) { r.onRoute("b28", net: true) }
        return up == nil ? "not back on KoreNet" : nil
    }
    let files = now()
    await filesThroughKore(r, "b28", shell: false)
    let filesTook = now() - files
    r.check(String(format: "copies both ways and the sync took no SSH wait (%.1fs, under 10s)", filesTook), filesTook < 10)
    let row = r.kore.row("b28")
    r.check("b28's row online, not \"can't reach\"", row?.status == .connected && row?.line.lowercased().contains("reach") != true, row.map { "\($0.status) · \($0.line)" } ?? "no row")
    let spawned = String(((try? String(contentsOf: log, encoding: .utf8)) ?? "").dropFirst(sshBefore))
        .split(whereSeparator: \.isNewline).filter { $0.contains("b28") }
    r.check("Kore ran no ssh to b28 for any of it", spawned.isEmpty, spawned.prefix(5).joined(separator: " | "))
    // Check again on its line: what's asked of a box that's working, and its line after.
    await quick("Check again on b28: no SSH wait, its line stays Ready") {
        await BoxList.shared.act(.checkAgain, on: "b28")
        return BoxList.shared.box("b28")?.status == .ready ? nil : "status \(BoxList.shared.box("b28").map { "\($0.status)" } ?? "-")"
    }
    r.check("the link stayed on KoreNet throughout", r.onRoute("b28", net: true), r.kore.describe("b28"))
    r.logRow("b28")
}

/// A box's line as it is: its words and what it offers.
@MainActor func boxLine(_ alias: String) -> (line: String, fix: BoxList.Action?) {
    switch BoxList.shared.box(alias)?.status {
    case .failed(let line, let fix)?, .unreachable(let line, let fix)?: return (line, fix)
    case let other?: return ("\(other)", nil)
    case nil: return ("not listed", nil)
    }
}

/// The Trust offer a box's line comes to, within `within`.
@MainActor func trustOffer(_ r: Run, _ alias: String, _ what: String, within: Double = 30) async -> BoxHostKey.Offer? {
    var offer: BoxHostKey.Offer?
    _ = await r.expect(what, within: within, box: alias) {
        if case .failed(_, .trust(let shown))? = BoxList.shared.box(alias)?.status { offer = shown }
        return offer != nil
    }
    return offer
}

/// 0.3.10's host keys past first contact (first-contact has the new key and Trust). A box showing
/// another key than before is never offered Trust, whether ssh knows the old key (its own refusal)
/// or Kore does (the alias moved to an address known_hosts has nothing for); the box's old key at
/// a new address is offered as moved; a key that changes between its offer and Trust isn't added.
/// known_hosts keeps what it had through each, and KoreNet keeps carrying the box.
@MainActor func hostKeys(_ r: Run) async {
    guard await r.box(BoxSpec(name: "b27", sshPort: 22127)) else { return }
    let known = r.places.scratch.appendingPathComponent("known_hosts")
    FileManager.default.createFile(atPath: known.path, contents: nil)
    func alias(_ lines: [String]) {
        RigSSH.write([RigSSH.Host(alias: "b27", lines: lines + ["Port 22127", "User kore", "StrictHostKeyChecking ask", "UserKnownHostsFile \(known.path)"])], places: r.places)
    }
    func kept() -> String { (try? String(contentsOf: known, encoding: .utf8)) ?? "" }
    /// The box's host keys made again (a reinstall, or someone in the middle); `keep` saves the old.
    func newKeys(keep: Bool = false) async -> Bool {
        let save = keep ? "mkdir -p /root/k1 && cp -p /etc/ssh/ssh_host_* /root/k1/ && " : ""
        return await Boxes.exec("b27", save + "rm -f /etc/ssh/ssh_host_* && ssh-keygen -A >/dev/null && (systemctl restart ssh 2>/dev/null; true)").ok
    }
    alias(["HostName 127.0.0.1"])
    guard await r.launch(installed: false) else { return }
    // First contact, trusted: Kore has seen this key over b27.
    _ = await r.kore.addAndSetUp("b27")
    guard let first = await trustOffer(r, "b27", "b27's new key offered with Trust") else { return }
    await BoxList.shared.act(.trust(first), on: "b27")
    guard r.expectReady("b27", "Trust → Set up → Ready") else { return }
    guard await r.linkOnNet("b27") else { return }
    let trusted = kept()

    // 1. Its keys made again, known_hosts holding the old. Check again asks the KoreNet link (no
    // SSH: still Ready); what needs SSH (Update) meets ssh's own refusal, said as a possible attack.
    r.check("b27's keys made again (old ones kept aside)", await newKeys(keep: true))
    await BoxList.shared.act(.checkAgain, on: "b27")
    _ = r.expectReady("b27", "Check again over KoreNet: still Ready, SSH not asked")
    await BoxList.shared.act(.update, on: "b27")
    var said = boxLine("b27")
    r.check("Update over SSH: b27's key changed, could be an attack", said.line.contains("host key changed") && said.line.contains("attack"), said.line)
    r.check("no Trust offered for a changed key", { if case .trust? = said.fix { return false }; return true }(), "\(said.fix.map { "\($0)" } ?? "-")")
    r.check("known_hosts unchanged", kept() == trusted)
    await r.works("b27", "KoreNet with its SSH key changed")

    // 2. The alias moved to an address known_hosts has nothing for, the box on its new key: Kore's
    // own comparison with the key it saw before.
    alias(["HostName localhost"])
    await BoxList.shared.act(.checkAgain, on: "b27")
    let different = await r.expect("b27 at a new address shows a different key than before: no Trust", within: 30, box: "b27") {
        let now = boxLine("b27")
        if case .trust? = now.fix { return false }
        return now.line.contains("shows a different key than before")
    }
    said = boxLine("b27")
    r.note("b27 said: \(said.line)")
    r.check("still no Trust after looking again", { if case .trust? = said.fix { return false }; return true }() && different)
    r.check("known_hosts unchanged", kept() == trusted)

    // 3. The box's old key back, at the new address: the alias moved, the box is the one it was.
    r.check("b27's old keys back", await Boxes.exec("b27", "cp -p /root/k1/* /etc/ssh/ && (systemctl restart ssh 2>/dev/null; true)").ok)
    await BoxList.shared.act(.checkAgain, on: "b27")
    if let moved = await trustOffer(r, "b27", "b27's old key at a new address offered with Trust") {
        r.check("said as moved: \(moved.line)", moved.moved && moved.line.contains("now points at a new address"), moved.line)
        await BoxList.shared.act(.trust(moved), on: "b27")
        r.check("Trust → b27 Ready at its new address", BoxList.shared.box("b27")?.status == .ready, boxLine("b27").line)
        r.check("known_hosts gained the new address's lines", kept() != trusted && moved.lines.allSatisfy(kept().contains), kept())
    }
    let movedKept = kept()

    // 4. A key offered (to what needs SSH: Update), then changed before Trust: Trust looks again
    // and adds nothing.
    alias(["HostName 127.0.0.1", "HostKeyAlias b27-elsewhere"])
    await BoxList.shared.act(.update, on: "b27")
    if let offered = await trustOffer(r, "b27", "b27 under another known_hosts name offered with Trust") {
        r.check("b27's keys made again before Trust", await newKeys())
        let t0 = now()
        await BoxList.shared.act(.trust(offered), on: "b27")
        said = boxLine("b27")
        r.check(String(format: "Trust refused: another key just now, not trusted (%.1fs)", now() - t0), said.line.contains("another key just now") && said.line.contains("not trusted"), said.line)
        r.check("known_hosts unchanged by the refused Trust", kept() == movedKept, kept())
    }
    await r.works("b27", "KoreNet after every key")
    r.logRow("b27")
}

// MARK: Main

let args = CommandLine.arguments.dropFirst()
if args.first == "list" || args.isEmpty {
    for s in scenarios where s.name != "fresh-phase" { print("\(s.name)\t\(s.what)") }
    exit(0)
}
let wanted = args.first!
guard let scenario = scenarios.first(where: { $0.name == wanted }) else {
    FileHandle.standardError.write(Data("korenet-rig: no scenario \(wanted) (korenet-rig list)\n".utf8))
    exit(2)
}
signal(SIGPIPE, SIG_IGN)
if ProcessInfo.processInfo.environment["RIG_KEEP_DEFAULTS"] != "1" { UserDefaults.standard.removePersistentDomain(forName: KoreFolders.domain) }
// A hang leaves its evidence: before run.sh's bound, the story so far and the last step go to
// the proof folder (from a thread of its own: the main actor may be the one stuck).
let limit = Double(ProcessInfo.processInfo.environment["RIG_SCENARIO_LIMIT"] ?? "600").map { $0 - 20 } ?? 580
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: limit)
    let lines = Log.shared.withLock { $0 }
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RIG_RUN"] ?? "/tmp").appendingPathComponent("proof/\(scenario.name)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let last = lines.last ?? "nothing said"
    try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("story.txt"), atomically: true, encoding: .utf8)
    try? "✘ \(scenario.name): hung after \(Int(limit))s at: \(last)\n".write(to: dir.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
    print("✘ \(scenario.name) (\(Int(limit))s): hung at: \(last)")
    exit(1)
}
Task { @MainActor in
    let r = Run(scenario.name)
    say("scenario \(scenario.name): \(scenario.what)")
    await scenario.body(r)
    await r.finish()
}
dispatchMain()
#else
print("korenet-rig runs on a Mac")
#endif
