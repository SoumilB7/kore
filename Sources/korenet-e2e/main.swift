// korenet-e2e: the Mac end of `scripts/tests/korenet-e2e.sh`. Drives KoreNet's own code
// (`TailnetLocal` over this Mac's installed Tailscale, `NetSession`, KoreTrust's identity proofs)
// against an isolated kore-host on a box: enroll over SSH (`attach --proto 2`), dial over the
// tailnet, WhoIs and both identity proofs, ping/pong, `fs.list`, a resume after a dropped TCP
// connection, `chat.call` dedupe, and the box daemon idle. The identity is made for the run in a
// temp folder: no Keychain item, no defaults domain. Prints a line per check; exits 1 on any ✘.
//
// `--embedded <kore-tailnet>`: this Mac's tailnet is Kore's own (the `kore-tailnet` helper, an
// ephemeral node named for the run, its state in the temp folder under a random key), as when
// installed Tailscale is gone. The one manual step is its browser sign-in: the page is printed.
// When installed Tailscale also runs here, the box first meets this Mac on it, so the embedded
// dial is a real node-key rotation. Then the Mac's own listener on the embedded node takes a
// connection from the box. The node is signed out (and so deleted) at the end, pass, fail or ^C.
// `--ssh-host <ip>` reaches the box at that address (its LAN one) without touching ~/.ssh/config.
#if os(macOS)
import Darwin
import Foundation
import KoreNet
import KoreTrust
import Tailnet

let usage = """
    usage: korenet-e2e --ssh <alias> --remote '<env…> <kore-host>' --grant <name> --box-ip <100.x> --port <n>
                       --box-device <uuid> --box-key <base64 scalar> --folder <served folder> --pid <daemon pid> [--idle <s>]
                       [--embedded <kore-tailnet>] [--ssh-host <ip>] [--state <box state folder>] [--sign-in-wait <s>]
    """

var options: [String: String] = [:]
do {
    var args = CommandLine.arguments.dropFirst()
    while let key = args.popFirst() {
        guard key.hasPrefix("--"), let value = args.popFirst() else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
        options[String(key.dropFirst(2))] = value
    }
}

@MainActor func need(_ key: String) -> String {
    guard let value = options[key], !value.isEmpty else {
        FileHandle.standardError.write(Data("korenet-e2e: --\(key) is needed\n\(usage)\n".utf8))
        exit(2)
    }
    return value
}

let alias = need("ssh")
let remote = need("remote")
let grant = need("grant")
let boxIP = need("box-ip")
let folder = need("folder")
let daemonPid = need("pid")
let idle = Double(options["idle"] ?? "30") ?? 30
let embeddedHelper = options["embedded"]
/// ssh's own options for the box: its LAN address when given (`-o HostName`), the alias's
/// known-hosts entry kept (`HostKeyAlias`).
let sshOptions: [String] = ["-o", "BatchMode=yes"] + (options["ssh-host"].map { ["-o", "HostName=\($0)", "-o", "HostKeyAlias=\(alias)"] } ?? [])
let boxState = options["state"]
let signInWait = Double(options["sign-in-wait"] ?? "600") ?? 600
guard let port = UInt16(need("port")), let boxDevice = UUID(uuidString: need("box-device")),
      let boxScalar = Data(base64Encoded: need("box-key")), let boxKey = try? SoftwareIdentity(raw: boxScalar).publicKey
else {
    FileHandle.standardError.write(Data("korenet-e2e: a bad --port, --box-device or --box-key\n".utf8))
    exit(2)
}

// MARK: Checks and numbers

var fails = 0
var numbers: [(String, String)] = []

@MainActor func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("✔ \(name)")
    } else {
        fails += 1
        let said = detail()
        print("✘ \(name)" + (said.isEmpty ? "" : ": \(said)"))
    }
}

/// Stops the run: what follows needs this.
@MainActor func stop(_ name: String, _ detail: String) -> Never {
    check(name, false, detail)
    finish()
}

@MainActor func note(_ name: String, _ value: String) {
    numbers.append((name, value))
    print("  \(name): \(value)")
}

func ms(_ seconds: Double) -> String { String(format: "%.1f ms", seconds * 1000) }
func now() -> Double { Date().timeIntervalSinceReferenceDate }

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("korenet-e2e-\(getpid())", isDirectory: true)

/// Kore's own tailnet for the run (embedded mode): signed out and stopped at every end.
nonisolated(unsafe) var ownTailnet: NetSidecar?

/// The run's node leaves the tailnet: signed out (an ephemeral node is deleted at once), then the
/// helper stops. Safe to call twice.
func leaveTailnet() {
    guard let own = ownTailnet else { return }
    ownTailnet = nil
    let signedOut = (try? own.tailnet.logout()) != nil
    own.stop()
    print(signedOut ? "  the run's tailnet node signed out (ephemeral: removed from the tailnet)" : "  ✘ the run's tailnet node didn't sign out: remove it in the Tailscale admin console")
}

@MainActor func finish() -> Never {
    leaveTailnet()
    try? FileManager.default.removeItem(at: scratch)
    print("numbers: " + numbers.map { "\($0.0)=\($0.1)" }.joined(separator: "; "))
    print(fails == 0 ? "korenet-e2e: all passed" : "korenet-e2e: \(fails) failed")
    exit(fails == 0 ? 0 : 1)
}

// MARK: A session, driven in place

/// One `NetSession` pumped on this thread with `poll`: the link's messages (stream 1) kept as
/// JSON objects, in order.
final class Driver {
    let session: NetSession
    var inbox: [[String: Any]] = []
    /// Messages that came while `counting` (the idle check).
    var heard = 0

    init(fd: Int32, setup: NetSession.Client) {
        session = NetSession(fd: fd, role: .client(setup))
    }

    var closed: String? {
        if case .closed(let why) = session.state { return why }
        return nil
    }

    var peer: NetPeer? {
        if case .established(let peer) = session.state { return peer }
        return nil
    }

    /// Pumps until `done` holds, the session closes, or `timeout` passes; whether `done` held.
    @discardableResult
    func pump(_ timeout: Double, until done: () -> Bool) -> Bool {
        let deadline = now() + timeout
        while true {
            take(session.pump())
            if done() { return true }
            if closed != nil { return false }
            let left = deadline - now()
            if left <= 0 { return false }
            var watch = pollfd(fd: session.descriptor, events: Int16(POLLIN | (session.wantsWrite ? POLLOUT : 0)), revents: 0)
            _ = poll(&watch, 1, Int32(min(left, 0.25) * 1000) + 1)
        }
    }

    private func take(_ messages: [NetMessage]) {
        for message in messages where message.stream == 1 {
            heard += 1
            if let object = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any] { inbox.append(object) }
        }
    }

    func send(_ object: [String: Any]) throws {
        try send(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    func send(_ data: Data) throws { try session.send(data, queue: .interactive, stream: 1) }

    /// The first message `match` takes, removed from the inbox, waiting up to `timeout`.
    func next(_ timeout: Double, _ match: ([String: Any]) -> Bool) -> [String: Any]? {
        var found: [String: Any]?
        pump(timeout) {
            if let i = inbox.firstIndex(where: match) { found = inbox.remove(at: i) }
            return found != nil
        }
        return found
    }

    func next(type: String, _ timeout: Double = 5) -> [String: Any]? { next(timeout) { $0["t"] as? String == type } }

    func result(_ id: String, _ timeout: Double = 5) -> [String: Any]? { next(timeout) { $0["t"] as? String == "result" && $0["id"] as? String == id } }

    /// Every result for `id` already in the inbox, removed.
    func results(_ id: String) -> [[String: Any]] {
        let found = inbox.filter { $0["t"] as? String == "result" && $0["id"] as? String == id }
        inbox.removeAll { $0["t"] as? String == "result" && $0["id"] as? String == id }
        return found
    }

    /// Ping round trips (the session's own `ping`/`pong`), each in seconds.
    func pings(_ count: Int) -> [Double] {
        var times: [Double] = []
        for _ in 0..<count {
            let start = now()
            guard let n = session.ping(), pump(5, until: { session.lastPong == n }) else { break }
            times.append(now() - start)
        }
        return times
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return .nan }
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

/// `ssh -o BatchMode=yes <alias> <command>`: its output and status.
@MainActor func ssh(_ command: String) -> (out: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = sshOptions + [alias, command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ("", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

// MARK: This Mac: a run's own identity and book

try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let me: SoftwareIdentity
do {
    me = try IdentityKeyFile.loadOrCreate(at: scratch.appendingPathComponent("identity.key"))
} catch {
    stop("an identity for the run", "\(error)")
}
let myDevice = UUID()
let book = DeviceBook(url: scratch.appendingPathComponent("devices.json"))
do {
    // The box's key, pinned as the SSH route vouches for it (Kore pins it from `net.node`).
    _ = try book.update {
        $0.append(DeviceRecord(
            id: boxDevice, name: alias, kind: .box, abilities: [.read, .ask, .run], identityKey: boxKey, nodeKeys: [Binding.Route.sshNodeKey],
            userId: nil, fqdn: "", added: Date()))
    }
} catch {
    stop("the box pinned in the run's book", "\(error)")
}

// MARK: This Mac's tailnet: installed Tailscale, or Kore's own

/// Installed Tailscale when it runs here (embedded mode: the node this Mac had before).
let installed: (tailnet: TailnetLocal, status: TailnetStatus)? = {
    let local = TailnetLocal()
    guard let status = try? local.status(), status.backendState == .running, status.selfNode != nil else { return nil }
    return (local, status)
}()

/// Starts Kore's own tailnet for the run and waits for its one sign-in.
@MainActor func startOwnTailnet(_ helper: String) -> NetSidecar {
    // ^C: the node signs out before the run ends.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for number in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            leaveTailnet()
            exit(130)
        }
        source.resume()
        signalSources.append(source)
    }
    var key = Data(count: 32)
    var random = SystemRandomNumberGenerator()
    for i in 0..<32 { key[i] = random.next() }
    let name = "kore-e2e-" + String(UUID().uuidString.prefix(6)).lowercased()
    let own: NetSidecar
    do {
        own = try NetSidecar.start(
            helper: URL(fileURLWithPath: helper), folder: scratch.appendingPathComponent("tn", isDirectory: true), key: key, arguments: ["-hostname", name, "-ephemeral"])
    } catch {
        stop("Kore's own tailnet (kore-tailnet) started", "\(error)")
    }
    ownTailnet = own
    check("Kore's own tailnet (kore-tailnet) started as \(name), ephemeral", true)
    let start = now()
    var shown = false
    while now() - start < signInWait {
        let status = try? own.tailnet.status()
        if status?.backendState == .running, status?.selfNode?.tailscaleIPs.isEmpty == false { break }
        if !shown, let page = status?.authURL {
            shown = true
            let rule = String(repeating: "═", count: 72)
            print("\n\(rule)\n  ONE CLICK: sign in the run's test node (\(name)) with your Tailscale account\n\n    \(page)\n\n  Ephemeral: it leaves your tailnet when this run ends. Waiting up to \(Int(signInWait / 60)) min…\n\(rule)\n")
        }
        usleep(500_000)
    }
    note("sign-in wait", String(format: "%.0f s", now() - start))
    return own
}
nonisolated(unsafe) var signalSources: [any DispatchSourceSignal] = []

let tailnet: any Tailnet
if let embeddedHelper {
    tailnet = startOwnTailnet(embeddedHelper).tailnet
} else {
    tailnet = TailnetLocal()
}
let statusStart = now()
var status: TailnetStatus
do {
    status = try tailnet.status()
} catch {
    stop("this Mac's tailnet answers", "\(error)")
}
note(embeddedHelper == nil ? "localapi status" : "kore-tailnet status", ms(now() - statusStart))
guard status.backendState == .running, let selfNode = status.selfNode else { stop("this Mac's tailnet is Running", "\(status.backendState)") }
check(embeddedHelper == nil ? "this Mac's Tailscale is Running" : "Kore's own tailnet is Running (\(selfNode.tailscaleIPs.first ?? "?"))", true)
// A node just up lists its peers offline for a moment: looked at again for up to 20 s.
var peerWait = now()
while embeddedHelper != nil, now() - peerWait < 20, status.peers.first(where: { $0.tailscaleIPs.contains(boxIP) })?.online != true {
    usleep(500_000)
    if let again = try? tailnet.status() { status = again }
}
guard let boxPeer = status.peers.first(where: { $0.tailscaleIPs.contains(boxIP) }) else { stop("the box is a peer", "no peer has \(boxIP)") }
check("the box is an online peer (\(boxPeer.hostName), \(boxPeer.relayed ? "relayed" : "direct"))", boxPeer.online)
if embeddedHelper != nil {
    check("this Mac's node is a new one (its own node key)", installed.map { $0.status.selfNode?.publicKey != selfNode.publicKey } ?? true)
    check("the same Tailscale user as the box's", boxPeer.userID != nil && boxPeer.userID == selfNode.owner)
}

// MARK: 1. Enroll over SSH (`attach --proto 2`, the grant upgrade)

var boxNodeKey: String?
do {
    let start = now()
    let (mine, theirs) = try Sockets.pair()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = sshOptions + [alias, "\(remote) attach --as \(grant) --proto 2"]
    let handle = FileHandle(fileDescriptor: theirs, closeOnDealloc: false)
    process.standardInput = handle
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    try process.run()
    Sockets.closeFD(theirs)
    var setup = NetSession.Client(
        local: NetLocal(device: myDevice, kind: .mac, nodeKey: Binding.Route.sshNodeKey, signer: me), route: .ssh, peer: .ssh, book: book,
        server: boxDevice, service: "link")
    setup.enroll = NetControl.Enroll(name: "korenet-e2e", kind: .mac, identityKey: me.publicKey)
    let ssh = Driver(fd: mine, setup: setup)
    let up = ssh.pump(20) { ssh.peer != nil }
    note("ssh enroll", ms(now() - start))
    check("enrolled over SSH (attach --proto 2)", up, ssh.closed.map { "closed: \($0)" } ?? "no welcome in 20 s")
    if let peer = ssh.peer {
        check("the box grants run", peer.abilities.effective.contains(.run), "\(peer.abilities.names)")
        let node = ssh.next(type: "net.node")
        check("the box says its node (net.node)", node != nil)
        boxNodeKey = node?["nodeKey"] as? String
        check("net.node names the pinned device", (node?["device"] as? String)?.lowercased() == boxDevice.uuidString.lowercased())
        check("net.node says this Mac enrolled", (node?["enrolled"] as? String)?.lowercased() == myDevice.uuidString.lowercased())
    }
    ssh.session.close("quit")
    process.terminate()
    process.waitUntilExit()
    guard up else { finish() }
} catch {
    stop("enrolled over SSH (attach --proto 2)", "\(error)")
}

// MARK: 2. WhoIs: the box's node key as this Mac's Tailscale sees it, and as the box says

let who: TailnetWhoIs
do {
    let start = now()
    who = try tailnet.whois(boxIP)
    note("localapi whois", ms(now() - start))
} catch {
    stop("WhoIs of the box", "\(error)")
}
check("WhoIs key is the peer's key", who.node.key == boxPeer.publicKey, "\(who.node.key) vs \(boxPeer.publicKey)")
check("WhoIs key is the key the box says (net.node)", who.node.key == boxNodeKey, "\(who.node.key) vs \(boxNodeKey ?? "none")")
check("the box is this Mac's own user, untagged", who.userId != nil && who.userId == selfNode.owner, "whois \(who.userId.map(String.init) ?? "tagged"), self \(selfNode.owner.map(String.init) ?? "tagged")")

@MainActor func tailnetSetup(device: UUID, signer: any IdentitySigner, book: DeviceBook, resume: NetControl.Resume? = nil) -> NetSession.Client {
    var setup = NetSession.Client(
        local: NetLocal(device: device, kind: .mac, nodeKey: selfNode.publicKey, signer: signer), route: .tailnet,
        peer: NetPeerFacts(nodeKey: who.node.key, userId: who.userId, tags: who.node.tags), book: book, server: boxDevice, service: "link", resume: resume)
    setup.ownUser = selfNode.owner
    return setup
}

/// Dials the box's KoreNet port and pumps the handshake: the driver and the seconds it took.
@MainActor func dial(_ setup: NetSession.Client) -> (Driver, Double)? {
    let start = now()
    guard let fd = try? tailnet.dial(boxIP, port: port) else { return nil }
    let driver = Driver(fd: fd, setup: setup)
    driver.pump(5) { driver.peer != nil }
    return (driver, now() - start)
}

// MARK: 2b. Embedded: the box first meets this Mac on its old node (installed Tailscale)

/// This Mac's node key on installed Tailscale, when the box took it before the embedded dial.
var oldKey: String?
if embeddedHelper != nil, let installed, let oldSelf = installed.status.selfNode {
    if let oldWho = try? installed.tailnet.whois(boxIP), let fd = try? installed.tailnet.dial(boxIP, port: port) {
        var setup = NetSession.Client(
            local: NetLocal(device: myDevice, kind: .mac, nodeKey: oldSelf.publicKey, signer: me), route: .tailnet,
            peer: NetPeerFacts(nodeKey: oldWho.node.key, userId: oldWho.userId, tags: oldWho.node.tags), book: book, server: boxDevice, service: "link")
        setup.ownUser = oldSelf.owner
        let old = Driver(fd: fd, setup: setup)
        old.pump(5) { old.peer != nil }
        check("welcomed first on this Mac's old node (installed Tailscale)", old.peer != nil, old.closed ?? "no welcome")
        if old.peer != nil { oldKey = oldSelf.publicKey }
        old.session.close("quit")
    } else {
        check("dialled the box on this Mac's old node (installed Tailscale)", false, "whois or connect failed")
    }
} else if embeddedHelper != nil {
    print("  (installed Tailscale isn't running here: the box meets this Mac's own node first, after SSH)")
}

// MARK: 3. Over the tailnet: both identity proofs over B

guard let dialled = dial(tailnetSetup(device: myDevice, signer: me, book: book)) else { stop("dialled the box on the tailnet", "connect to \(boxIP):\(port) failed") }
let (link, handshake) = dialled
note("tailnet handshake (connect → welcome)", ms(handshake))
guard let first = link.peer else { stop("welcomed over the tailnet", link.closed.map { "closed: \($0)" } ?? "no welcome in 5 s") }
check("welcomed over the tailnet: the box took this Mac's proof", true)
check("the box's proof holds over B with its WhoIs node key", link.session.verified?.nodeKey == who.node.key)
if oldKey == nil {
    check("the book took the box's tailnet node key (SSH-only record)", link.session.nodeKeyAppend == .appended(dropped: nil), "\(String(describing: link.session.nodeKeyAppend))")
} else {
    check("the box's node key was known already (from the old node's link)", link.session.nodeKeyAppend == nil, "\(String(describing: link.session.nodeKeyAppend))")
}
if embeddedHelper != nil, let boxState {
    // The box's own book: this Mac's record took the new node key after its proof and the box's
    // same-user WhoIs (ID2), beside the old one; no new enroll, no Allow.
    let said = ssh("cat \(boxState)/kore-host/devices/\(myDevice.uuidString.lowercased()).json")
    let keys = ((try? JSONSerialization.jsonObject(with: Data(said.out.utf8))) as? [String: Any])?["nodeKeys"] as? [String] ?? []
    check("the box kept this Mac's new node key", keys.contains(selfNode.publicKey), "\(keys)")
    if let oldKey { check("…beside its old one (rotation: kept both)", keys.contains(oldKey) && keys.count == 2, "\(keys)") }
}
check("the book now pins [WhoIs key], same user", (try? book.record(boxDevice)).flatMap { $0 }.map { $0.nodeKeys == [who.node.key] && $0.userId == who.userId } ?? false)
check("a first session isn't a resume, and carries a ticket", !first.resumed && !first.ticket.isEmpty)

let linkWelcome = link.next(type: "welcome")
check("the link's welcome follows", linkWelcome != nil)
let snapshot = link.next(type: "snapshot")
let attn = link.next(type: "attn.state")
check("snapshot and attention follow", snapshot != nil && attn != nil)
let rev = snapshot?["rev"] as? Int ?? 0
let aid = attn?["aid"] as? Int ?? 0

// MARK: 4. Round trips

let pings = link.pings(20)
check("20 pings, 20 pongs", pings.count == 20, "\(pings.count)")
note("ping rtt p50/p95/max", "\(ms(percentile(pings, 0.5)))/\(ms(percentile(pings, 0.95)))/\(ms(pings.max() ?? .nan))")

var start = now()
try? link.send(["t": "cmd", "id": "ls1", "cmd": ["type": "fs.list", "path": folder]])
let listing = link.result("ls1")
note("fs.list rtt", ms(now() - start))
let names = (listing?["entries"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
check("fs.list \(folder) lists kore-host", listing?["ok"] as? Bool == true && names.contains("kore-host"), "\(listing.map { "\($0)" } ?? "no answer")")

start = now()
try? link.send(["t": "cmd", "id": "new1", "cmd": ["type": "chat.new", "folder": folder, "provider": "claude"]])
let made = link.result("new1")
note("chat.new rtt", ms(now() - start))
guard let chatId = made?["chatId"] as? String, made?["ok"] as? Bool == true else { stop("a chat made on the box (no CLI run)", "\(made.map { "\($0)" } ?? "no answer")") }
check("a chat made on the box (no CLI run)", true)

// `setDraft` answers whether the draft changed: a second run of the same text says false, the
// first call's kept answer says true.
let draft = "korenet-e2e \(UUID().uuidString.prefix(8))"
let call1 = try JSONSerialization.data(
    withJSONObject: ["t": "chat.call", "id": "call-1", "chatId": chatId, "command": ["type": "setDraft", "text": draft]], options: [.sortedKeys])
start = now()
try? link.send(call1)
try? link.send(call1)
let firstAnswer = link.result("call-1")
note("chat.call rtt", ms(now() - start))
let secondAnswer = link.result("call-1", 2)
link.pump(0.3) { false }
var answers = [firstAnswer, secondAnswer].compactMap { $0 } + link.results("call-1")
check("chat.call sent twice at once: answered once per send", answers.count == 2, "\(answers.count) answers")
check("…both with the first run's answer (it ran once)", answers.allSatisfy { $0["ok"] as? Bool == true && ($0["value"] as? [String: Any])?["bool"] as? Bool == true }, "\(answers)")

// MARK: 5. An unknown device is refused (`bye unknown`), its proof notwithstanding

let strangerBook = DeviceBook(url: scratch.appendingPathComponent("stranger.json"))
_ = try? strangerBook.update { $0 = (try? book.read().devices) ?? [] }
if let stranger = dial(tailnetSetup(device: UUID(), signer: SoftwareIdentity(), book: strangerBook)) {
    let stranger = stranger.0
    stranger.pump(5) { stranger.closed != nil }
    check("an unknown device is refused", stranger.peer == nil && stranger.closed == "bye unknown", stranger.closed ?? "still open")
} else {
    check("an unknown device is refused", false, "connect failed")
}

// MARK: 6. Drop the TCP connection, resume with the ticket and cursors

Sockets.shutdownBoth(link.session.descriptor)
link.pump(2) { link.closed != nil }
check("the dropped connection ended", link.closed != nil)

let cursors: [String: JSONValue] = ["attn": .object(["aid": .int(Int64(aid))]), "snapshot": .object(["rev": .int(Int64(rev))])]
guard let redialled = dial(tailnetSetup(device: myDevice, signer: me, book: book, resume: .init(ticket: first.ticket, cursors: cursors))) else {
    stop("redialled the box", "connect failed")
}
let (again, resumeTime) = redialled
note("resume handshake", ms(resumeTime))
guard let second = again.peer else { stop("resumed", again.closed.map { "closed: \($0)" } ?? "no welcome") }
check("resumed with the ticket (welcome.resumed)", second.resumed)
check("a fresh ticket for the next resume", !second.ticket.isEmpty && second.ticket != first.ticket)
check("the link's welcome follows the cursors", again.next(type: "welcome") != nil)
let after = again.next(type: "snapshot")
let chat = (after?["chats"] as? [[String: Any]])?.first { $0["id"] as? String == chatId }
check("the snapshot has the chat, its draft changed once", (chat?["controls"] as? [String: Any])?["draftRev"] as? Int == 1, "\(chat.map { "\($0)" } ?? "no chat")")

// MARK: 7. chat.call dedupe across the resume

try? again.send(call1)
let replay = again.result("call-1")
again.pump(0.3) { false }
answers = [replay].compactMap { $0 } + again.results("call-1")
check("chat.call resent after the resume: one answer", answers.count == 1, "\(answers.count) answers")
check("…the kept one (true: no second run)", (replay?["value"] as? [String: Any])?["bool"] as? Bool == true, "\(replay.map { "\($0)" } ?? "none")")
let call2 = try JSONSerialization.data(
    withJSONObject: ["t": "chat.call", "id": "call-2", "chatId": chatId, "command": ["type": "setDraft", "text": draft]], options: [.sortedKeys])
try? again.send(call2)
let rerun = again.result("call-2")
check("a new id runs again (false: the draft holds it)", rerun?["ok"] as? Bool == true && (rerun?["value"] as? [String: Any])?["bool"] as? Bool == false, "\(rerun.map { "\($0)" } ?? "none")")

// MARK: 7b. Embedded: this Mac's own listener on its node (the phones' port) takes a connection

if embeddedHelper != nil {
    do {
        let sockets = try tailnet.listen(port: NetListener.port)
        defer { for socket in sockets { Sockets.closeFD(socket.fd) } }
        check("this Mac's KoreNet port \(NetListener.port) opens on its own node", sockets.count == 1)
        let macIP = selfNode.tailscaleIPs.first { $0.contains(".") } ?? selfNode.tailscaleIPs.first ?? ""
        let knock = Process()
        knock.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        knock.arguments = sshOptions + [alias, "timeout 10 bash -c 'exec 3<>/dev/tcp/\(macIP)/\(NetListener.port) && printf hi >&3 && read -r -t 5 x <&3 && echo got:$x'"]
        let out = Pipe()
        knock.standardOutput = out
        knock.standardError = FileHandle.nullDevice
        try knock.run()
        Sockets.setReadTimeout(sockets[0].fd, seconds: 15)
        let start = now()
        let (fd, remote) = try sockets[0].accept()
        defer { Sockets.closeFD(fd) }
        Sockets.setReadTimeout(fd, seconds: 5)
        let hello = String(decoding: try Sockets.read(fd, max: 2), as: UTF8.self)
        let who = try remote.map { try tailnet.whois($0) }
        try Sockets.writeAll(fd, Data("ok\n".utf8))
        let answer = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        knock.waitUntilExit()
        note("box → this Mac's own node, connect + round trip", ms(now() - start))
        check("the box reached this Mac's own node (handed over by kore-tailnet)", hello == "hi", "said \(hello)")
        check("…its WhoIs is the box's node, this Mac's own user", who?.node.key == boxPeer.publicKey && who?.userId == selfNode.owner, "\(String(describing: who?.node.key))")
        check("…and it heard this Mac back", answer.contains("got:ok"), answer)
    } catch {
        check("this Mac's own node takes a connection on \(NetListener.port)", false, "\(error)")
    }
}

// MARK: 8. Idle: the box daemon's memory and CPU, nothing on the wire

/// The daemon's CPU ticks (utime + stime), resident and peak KiB, and threads.
@MainActor func sample() -> (ticks: Int, rss: Int, hwm: Int, threads: Int)? {
    let said = ssh("cat /proc/\(daemonPid)/stat && cat /proc/\(daemonPid)/status")
    guard said.status == 0, let close = said.out.range(of: ") ") else { return nil }
    let fields = said.out[close.upperBound...].split(separator: " ")
    guard fields.count > 12, let utime = Int(fields[11]), let stime = Int(fields[12]) else { return nil }
    func kib(_ key: String) -> Int {
        let line = said.out.split(separator: "\n").first { $0.hasPrefix(key + ":") } ?? ""
        return Int(line.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init) ?? "") ?? -1
    }
    let threads = said.out.split(separator: "\n").first { $0.hasPrefix("Threads:") }.flatMap { Int($0.split(whereSeparator: \.isWhitespace).last ?? "") } ?? -1
    return (utime + stime, kib("VmRSS"), kib("VmHWM"), threads)
}

again.heard = 0
let pongsBefore = again.session.lastPong
if let before = sample() {
    let idleStart = now()
    again.pump(idle) { false }
    let slept = now() - idleStart
    if let end = sample() {
        let cpu = Double(end.ticks - before.ticks) / 100
        note("box daemon after \(Int(idle)) s idle", String(format: "RSS %.1f MB (peak %.1f MB), %d threads, CPU %.2f s (%.2f%%)", Double(end.rss) / 1024, Double(end.hwm) / 1024, end.threads, cpu, cpu / slept * 100))
        check("box daemon RSS under 15 MB idle", end.rss > 0 && end.rss < 15 * 1024, "\(end.rss) KiB")
        check("box daemon near no CPU idle (< 1%)", cpu / slept < 0.01, String(format: "%.2f s", cpu))
    } else {
        check("sampled the box daemon", false, "/proc/\(daemonPid) unreadable")
    }
} else {
    check("sampled the box daemon", false, "/proc/\(daemonPid) unreadable")
}
check("nothing on the wire while idle (no keepalive)", again.heard == 0 && again.session.lastPong == pongsBefore && again.closed == nil, "\(again.heard) messages, \(again.closed ?? "open")")
let late = again.pings(1)
check("the link answers after the idle", late.count == 1)
if let rtt = late.first { note("ping after idle", ms(rtt)) }
again.session.close("quit")
finish()
#else
print("korenet-e2e runs on a Mac")
#endif
