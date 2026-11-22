import Foundation
import LinkProtocol
import Testing

@testable import HostClient

/// A box set up through an SSH alias (owner's G1 run, 2026-11-24): it's called by its own name,
/// its row says the route its link is on, a new host key shows its fingerprint and Trust adds
/// exactly what ssh's accept-new would, a changed key is never trusted, and a step done in
/// Terminal has Check again on its line.
@MainActor
@Suite("box identity and routes", .serialized)
struct BoxIdentityTests {
    static let key1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC6tEGZ1hP1Opy4qSpRaxJpBrqWYD5M+5BpkSs8dCZ0f"
    static let print1 = "ED25519 SHA256:CpT7pkFHVJ1A1tN1JCwrndgczZS6lmg7a5Ye8OO/7BI"
    static let key2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILjiy+aotD/fKBtNfR1wqlWv9CxZ2WCIohDkmCgyJZcj"

    private func directory() throws -> (NodeDirectory, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "box-identity-\(UUID().uuidString)"))
        return (NodeDirectory(defaults: defaults), defaults)
    }

    // MARK: Names

    @Test func aBoxIsCalledByItsOwnNameNeverItsAlias() throws {
        let (directory, defaults) = try directory()
        // Found over SSH only: the host name its setup found.
        #expect(directory.name(forKey: "mybox-cf") == "mybox-cf")
        directory.noteFound("mybox.example.internal", alias: "mybox-cf")
        #expect(directory.name(forKey: "mybox-cf") == "mybox")
        // On KoreNet: the name it says, by its id and by its alias, rekeyed or not.
        let device = UUID()
        directory.upsert(.init(device: device, name: "mybox", ssh: "mybox-cf", nodeKey: nil, identityKey: Data([1]), enrolled: true, rekeyed: true))
        #expect(directory.name(forKey: device.uuidString.lowercased()) == "mybox")
        #expect(directory.name(forKey: "mybox-cf") == "mybox")
        // Rename still wins, and clearing it goes back to its own name.
        directory.rename("mybox-cf", to: "build box")
        #expect(directory.name(forKey: device.uuidString.lowercased()) == "build box")
        directory.rename("mybox-cf", to: "")
        #expect(directory.name(forKey: "mybox-cf") == "mybox")
        // A plain alias nothing is known of is its own name; a host name that says nothing isn't kept.
        #expect(directory.name(forKey: "other") == "other")
        directory.noteFound("localhost", alias: "other")
        directory.noteFound("  ", alias: "other")
        #expect(directory.name(forKey: "other") == "other")
        #expect(NodeDirectory.deviceName("my box!.lan") == "mybox" && NodeDirectory.deviceName("") == nil)
        // Forgotten: the found name goes too.
        directory.forgetNames(["mybox-cf"])
        #expect(NodeDirectory(defaults: defaults).found("mybox-cf") == nil)
    }

    @Test func namesThatWereOnlyTheAliasAreMigratedAway() throws {
        let (_, defaults) = try directory()
        let device = UUID()
        let id = device.uuidString.lowercased()
        let entry = NodeDirectory.Entry(device: device, name: "mybox", ssh: "mybox-cf", nodeKey: nil, identityKey: Data([1]), enrolled: true, rekeyed: true)
        defaults.set(try JSONEncoder().encode([id: entry]), forKey: NodeDirectory.defaultsKey)
        // 0.3.9 kept these: the alias under its id, the alias under itself, and a real rename.
        defaults.set([id: "mybox-cf", "pi-cf": "pi-cf", "gpu": "GPU box"], forKey: NodeDirectory.namesKey)
        let directory = NodeDirectory(defaults: defaults)
        #expect(directory.name(forKey: id) == "mybox")
        #expect(directory.name(forKey: "pi-cf") == "pi-cf")
        #expect(directory.name(forKey: "gpu") == "GPU box")
        #expect(defaults.dictionary(forKey: NodeDirectory.namesKey) as? [String: String] == ["gpu": "GPU box"])
    }

    @Test func theMachineSaysItsHostName() {
        let machine = BoxMachine.parse("uname=Linux x86_64\nhostname=mybox\n")
        #expect(machine?.hostname == "mybox")
        #expect(BoxMachine.script().contains("hostname=$(uname -n)"))
    }

    /// Forgetting the SSH route (asked for in ⋯): only for a box keyed by its id; the box stays listed.
    @Test func forgettingTheSSHRouteKeepsTheBox() throws {
        let (directory, defaults) = try directory()
        let device = UUID()
        let id = device.uuidString.lowercased()
        directory.upsert(.init(device: device, name: "mybox", ssh: "mybox-cf", nodeKey: "nodekey:box", identityKey: Data([1]), enrolled: true, rekeyed: false))
        #expect(directory.forgetSSH("mybox-cf") == nil)
        directory.update { $0[id]?.rekeyed = true }
        #expect(directory.forgetSSH(id) == "mybox-cf")
        #expect(directory.all[id]?.ssh == nil && directory.name(forKey: id) == "mybox")
        defaults.set([id], forKey: "boxHosts")
        let list = BoxList(defaults: defaults, hosts: { [] }, cacheRoot: FileManager.default.temporaryDirectory)
        list.directory = { directory }
        list.reload()
        #expect(list.boxes.map(\.alias) == [id])
    }

    // MARK: Routes

    static func facts(route: HostRoute?, entry: Bool = true) -> BoxFacts {
        var facts = BoxFacts(key: "mybox-cf", name: "mybox")
        facts.listed = .ready
        facts.online = route != nil
        facts.route = route
        if entry { facts.entry = NodeDirectory.Entry(device: UUID(), name: "mybox", ssh: "mybox-cf", nodeKey: "nodekey:box", identityKey: Data([1]), enrolled: true) }
        return facts
    }

    static func row(_ facts: BoxFacts, state: NetState = .sidecar, peers: [String]? = nil) -> DeviceRow {
        let status = DevicesPictureTests.status(peers: peers ?? [DevicesPictureTests.peer("nodekey:box", name: "mybox-kore")])
        return DevicesPicture.make(
            net: NetFacts(on: true, state: state, status: status), macName: "MacBook", boxes: [facts], phones: [], addUntil: nil, refusals: [], signingIn: false,
            nudge: false, now: DevicesPictureTests.now
        ).devices[0]
    }

    @Test func theRowSaysTheActiveRouteAndFollowsIt() {
        let now = DevicesPictureTests.now
        let net = Self.row(Self.facts(route: .net))
        #expect(net.name == "mybox" && DevicesWords.detail(net, now: now) == "Kore's tailnet")
        #expect(DevicesWords.help(net) == "node mybox-kore 100.64.0.9\nSSH (mybox-cf) · not needed now; Kore's tailnet carries mybox")
        // Over installed Tailscale.
        let tailscale = Self.row(Self.facts(route: .net), state: .installed)
        #expect(DevicesWords.detail(tailscale, now: now) == "Tailscale")
        #expect(DevicesWords.sshNotNeeded(tailscale) == "SSH (mybox-cf) · not needed now; Tailscale carries mybox")
        // The link fell back to SSH: the route says so, and no hint.
        let ssh = Self.row(Self.facts(route: .ssh(alias: "mybox-cf", grant: "mac")))
        #expect(DevicesWords.detail(ssh, now: now) == "SSH (mybox-cf)" && DevicesWords.sshNotNeeded(ssh) == nil && DevicesWords.help(ssh) == nil)
        // Relayed on the tailnet.
        let relayed = Self.row(Self.facts(route: .net), peers: [DevicesPictureTests.peer("nodekey:box", name: "mybox-kore", relay: true)])
        #expect(DevicesWords.detail(relayed, now: now) == "Kore's tailnet · relayed")
        // A box only ever reached over SSH (no KoreNet entry): its alias is its SSH route.
        let plain = Self.row(Self.facts(route: .ssh(alias: "mybox-cf", grant: "mac"), entry: false))
        #expect(DevicesWords.detail(plain, now: now) == "SSH (mybox-cf)")
        // Its SSH route forgotten: the tailnet carries it, no hint.
        var forgotten = Self.facts(route: .net)
        forgotten.entry?.ssh = nil
        #expect(DevicesWords.sshNotNeeded(Self.row(forgotten)) == nil)
    }

    // MARK: Lines

    @Test func aStepDoneInTerminalHasCheckAgainOnItsLine() {
        var box = BoxList.Box(alias: "mybox-cf")
        box.status = .unreachable("mybox-cf needs a key · ssh-copy-id mybox-cf", .copy("ssh-copy-id mybox-cf"))
        #expect(box.note?.more == [.checkAgain] && BoxFix.checkAgain.title == "Check again")
        let offer = BoxHostKey.Offer(ssh: "mybox-cf", fingerprints: [Self.print1], lines: ["mybox-cf " + Self.key1], command: "ssh mybox-cf")
        box.status = .failed(offer.line, .trust(offer))
        #expect(box.note?.line == "mybox-cf's host key is new · " + Self.print1)
        #expect(box.note.map { [$0.action?.title] + $0.more.map(\.title) } == ["Trust", "Copy", "Check again"])
        // A box seen before over the alias: it points somewhere new, not a scary new key.
        var moved = offer
        moved.moved = true
        #expect(moved.line == "mybox-cf now points at a new address · " + Self.print1)
        box.status = .notSetUp
        #expect(box.note?.more == [])
    }

    @Test func aChangedKeyIsNeverOfferedTrust() {
        let changed = BoxSetup.sshFailure("mybox-cf", "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@")
        #expect(changed.message.contains("could be an attack") && changed.fix == .copy("ssh-keygen -R mybox-cf"))
        let new = BoxSetup.sshFailure("mybox-cf", "Host key verification failed.")
        #expect(BoxSetup.isNewKey(new.message) && !BoxSetup.isNewKey(changed.message))
    }

    // MARK: The key itself

    /// A stand-in ssh: on a key scan it writes `key` for the host into the scratch known_hosts
    /// it's given, as accept-new does.
    private func fakeSSH(_ folder: URL, key: String) throws -> String {
        let path = folder.appendingPathComponent("ssh-\(UUID().uuidString.prefix(6))").path
        let script = """
            #!/bin/sh
            for a in "$@"; do case "$a" in UserKnownHostsFile=*) f="${a#UserKnownHostsFile=}" ;; esac; done
            [ -n "$f" ] && echo "mybox-cf \(key)" >> "$f"
            echo "Permission denied (none)." >&2
            exit 255
            """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func trustAddsExactlyWhatSSHWroteAndOnlyThatKey() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("box-identity-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = BoxShell(ssh: try fakeSSH(folder, key: Self.key1), scp: "/usr/bin/false")
        let found = try #require(await BoxHostKey.scan("mybox-cf", shell: shell))
        #expect(found.fingerprints == [Self.print1] && found.lines == ["mybox-cf " + Self.key1])
        let offer = BoxHostKey.Offer(ssh: "mybox-cf", fingerprints: found.fingerprints, lines: found.lines, command: "ssh mybox-cf")
        // The box shows another key at Trust: nothing is written.
        let file = folder.appendingPathComponent("ssh/known_hosts").path
        let other = BoxShell(ssh: try fakeSSH(folder, key: Self.key2), scp: "/usr/bin/false")
        #expect(await BoxHostKey.trust(offer, shell: other, file: file) == .changed)
        #expect(!FileManager.default.fileExists(atPath: file))
        // The same key: its line, in a new 0600 file; a second Trust adds nothing.
        #expect(await BoxHostKey.trust(offer, shell: shell, file: file) == nil)
        #expect(await BoxHostKey.trust(offer, shell: shell, file: file) == nil)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "mybox-cf \(Self.key1)\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // ssh's own words for the file it writes.
        #expect(BoxHostKey.knownHostsFile(config: "user me\nuserknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2\n", home: "/Users/me") == "/Users/me/.ssh/known_hosts")
        #expect(BoxHostKey.knownHostsFile(config: "userknownhostsfile /etc/kh\n", home: "/h") == "/etc/kh")
        #expect(BoxHostKey.knownHostsFile(config: "", home: "/h") == "/h/.ssh/known_hosts")
        #expect(BoxHostKey.fingerprints("256 SHA256:abc mybox-cf (ED25519)\n3072 SHA256:def mybox-cf (RSA)\n") == ["ED25519 SHA256:abc", "RSA SHA256:def"])
    }

    /// The box list: a new key's line becomes its fingerprint and Trust; Trust writes the key and
    /// Set up goes on (it stopped Set up), never for a changed key.
    @Test func theListOffersTrustAndGoesOn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("box-identity-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (directory, defaults) = try directory()
        let ssh = try fakeSSH(folder, key: Self.key1)
        let list = BoxList(
            defaults: defaults, hosts: { [] }, cacheRoot: folder,
            setup: { alias, grant in BoxSetup(alias: alias, grant: grant, shell: BoxShell(ssh: ssh, scp: "/usr/bin/false")) })
        list.directory = { directory }
        list.scanKey = { @Sendable alias, shell, keygen in await BoxHostKey.scan(alias, shell: shell, keygen: keygen) }
        list.knownHosts = folder.appendingPathComponent("known_hosts").path
        list.add("mybox-cf")
        // Set up meets the key (the stand-in ssh fails as a new key does... and as a changed one).
        await list.act(.setUpAnyway, on: "mybox-cf")
        guard case .failed(let line, .copy?)? = list.box("mybox-cf")?.status else {
            Issue.record("not a key line: \(String(describing: list.box("mybox-cf")?.status))")
            return
        }
        // The stand-in says "Permission denied": a key is needed, nothing to trust.
        #expect(line == "mybox-cf needs a key · ssh-copy-id mybox-cf")
        // A new key's line: the fingerprint and Trust come.
        list.injectStatus("mybox-cf", .unreachable(BoxSetup.newKeyLine("mybox-cf", "ssh mybox-cf"), .copy("ssh mybox-cf")))
        try await waitUntil { if case .failed(_, .trust?)? = list.box("mybox-cf")?.status { return true }; return false }
        guard case .failed(let shown, .trust(let offer))? = list.box("mybox-cf")?.status else { return }
        #expect(shown == "mybox-cf's host key is new · " + Self.print1 && offer.lines == ["mybox-cf " + Self.key1] && !offer.moved)
        await list.act(.trust(offer), on: "mybox-cf")
        #expect(try String(contentsOfFile: folder.appendingPathComponent("known_hosts").path, encoding: .utf8) == "mybox-cf \(Self.key1)\n")
        // A changed key's line stays as it is: no Trust ever.
        list.injectStatus("mybox-cf", .unreachable(BoxSetup.sshFailure("mybox-cf", "REMOTE HOST IDENTIFICATION HAS CHANGED").message, .copy("ssh-keygen -R mybox-cf")))
        try await Task.sleep(for: .milliseconds(300))
        if case .failed(_, .trust?)? = list.box("mybox-cf")?.status { Issue.record("a changed key offered Trust") }
    }

    private func waitUntil(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(done())
    }
}
