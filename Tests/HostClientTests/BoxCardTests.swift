import Foundation
import HostClient
import LinkProtocol
import Testing

/// The box card as re-adding a box shows it: the first add goes straight through, an install
/// ends with a fresh look (or its one-line failure, a hang included), a newer CLI there isn't
/// something to fix, and the count is what Fix does.
@MainActor
@Suite(.serialized)
struct BoxCardTests {
    private func defaults() throws -> UserDefaults { try #require(UserDefaults(suiteName: "boxcard-\(UUID().uuidString)")) }
    private func machine(_ kind: FakeSSH.Kind) throws -> BoxMachine { try #require(BoxMachine.parse(kind.detection)) }

    /// This Mac as the owner's was: codex 0.170, gh 2.92, git 2.54, node 25.8, its own skills,
    /// MCP servers and default models.
    private func mac() throws -> BoxMachine {
        var mac = try machine(.macOS)
        mac.versions = [
            "claude": "2.1.322 (Claude Code)", "codex": "codex-cli 0.170.0", "gh": "gh version 2.92.0 (2026-04-01)", "git": "git version 2.54.0",
            "node": "v25.8.0",
        ]
        for tool in ["codex", "gh", "node"] { mac.tools[tool] = "/opt/homebrew/bin/" + tool }
        mac.gitName = "Me"
        mac.gitEmail = "me@example.com"
        var facts = AgentFacts()
        facts.claudeSkills = ["autoreview", "logging-best-practices", "pstack-claude-in-your-own-words"]
        facts.codexMCP = ["computer-use", "cua_repl", "node_repl"]
        facts.claudeModel = "opus[1m]"
        facts.codexModel = "gpt-6.1-sol"
        mac.facts = facts
        return mac
    }

    /// mybox as it was: codex 0.167 (older), gh 2.103 (newer), git 2.47, node 20.19.
    private func box(codex: String = "0.167.0") throws -> BoxMachine {
        var box = try machine(.linuxSystemd)
        box.versions = [
            "claude": "2.1.322 (Claude Code)", "codex": "codex-cli \(codex)", "gh": "gh version 2.103.0 (2026-10-01)", "git": "git version 2.47.3",
            "node": "v20.19.2",
        ]
        for tool in ["claude", "codex", "gh", "node", "npm"] { box.tools[tool] = "/home/me/.npm-global/bin/" + tool }
        box.facts = AgentFacts()
        return box
    }

    /// A detection script's answer for `box`, as the fake ssh prints it.
    private func detection(_ box: BoxMachine) -> String {
        FakeSSH.Kind.linuxSystemd.detection + "\n" + box.tools.map { "has.\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
            + box.versions.map { "v.\($0.key)=\($0.value)" }.joined(separator: "\n") + "\nfacts={}\n"
    }

    // MARK: 1 · The first add

    /// The first link comes up and is turned away before its welcome (as a first add's tailnet
    /// try is, the box still holding this Mac's old key), and the link dials SSH again at once.
    /// The probe waits for that dial: the box is Ready, never "Can't reach mybox · Try again".
    @Test func theFirstAddGoesThroughWithNoRetry() async throws {
        let root = Fixture.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        @MainActor final class Dials {
            var count = 0
            weak var connection: HostConnection?
        }
        let dials = Dials()
        let fake = try FakeSSH()
        defer { fake.finish() }
        let list = BoxList(defaults: try defaults(), hosts: { [] }, cacheRoot: root.appendingPathComponent("cache"), connection: { alias in
            if let live = dials.connection { return live }
            let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: root.appendingPathComponent("conn"))) {
                let (client, host) = FakeHost.pair()
                dials.count += 1
                let first = dials.count == 1
                Task { @MainActor in
                    if first {
                        // Turned away before the welcome, as the switch's own newer link: dialled again at once.
                        host.send(.challenge(nonce: "bm9uY2U="))
                        _ = await host.next("hello")
                        dials.connection?.ownRouteCameUp()
                        host.send(.bye(.replaced))
                        return
                    }
                    // The SSH dial after it: up a moment later, past the probe's next look.
                    try? await Task.sleep(for: .milliseconds(300))
                    _ = await host.handshake(windows: [], chats: [])
                    let ask = await host.next("cmd")
                    host.send(json: ["t": "result", "ok": true, "id": ask?["id"] ?? "", "folders": [["windowId": "w_1", "path": "/home/me/app"]]])
                }
                return client
            }
            dials.connection = connection
            return connection
        }) { alias, grant in BoxSetup(alias: alias, grant: grant, shell: fake.shell, binary: fake.binary()) }
        list.findMac = { nil }
        list.add("mybox")
        var known = try machine(.linuxSystemd)
        known.versions = [:]
        known.keep("mybox", root: root.appendingPathComponent("cache"))
        list.reload()
        await list.probe("mybox")
        #expect(dials.count == 2)
        #expect(list.box("mybox")?.status == .ready)
        #expect(list.box("mybox")?.note?.line != "Can't reach mybox")
        #expect(list.box("mybox")?.folders.map(\.path) == ["/home/me/app"])
    }

    // MARK: 2 · After an install

    @Test func theCardLooksAgainAfterAnInstall() async throws {
        let fake = try FakeSSH()
        defer { fake.finish() }
        let mac = try mac()
        let list = BoxList(defaults: try defaults(), hosts: { [] }, cacheRoot: fake.root, setup: { alias, grant in
            BoxSetup(alias: alias, grant: grant, shell: fake.shell, binary: fake.binary())
        })
        list.findMac = { mac }
        list.add("mybox")
        let detectionFile = fake.root.appendingPathComponent("detection")
        try Data(detection(try box()).utf8).write(to: detectionFile)
        await list.detect("mybox")
        // The logins as the card read them: claude on another account there.
        await list.compare("mybox", macLogins: ["claude": BoxLogin(signedIn: true, who: "a@b.c")], boxLogins: ["claude": BoxLogin(signedIn: true, who: "x@y.z")])
        #expect(list.box("mybox")?.parity?.differences.map(\.id) == ["version.codex", "login.claude"])

        // The update lands (codex 0.171 there now): the look after it shows it, and the logins stay.
        try Data(detection(try box(codex: "0.171.0")).utf8).write(to: detectionFile)
        #expect(await list.install(.codex, on: "mybox") == nil)
        #expect(list.box("mybox")?.machine?.versions["codex"] == "codex-cli 0.171.0")
        #expect(list.box("mybox")?.parity?.differences.map(\.id) == ["login.claude"])
        #expect(list.box("mybox")?.parity?.notes.contains { $0.line == "codex 0.171 on mybox, 0.170 here" && $0.fix == nil } == true)
        #expect(fake.calls.filter { $0.hasSuffix("# kore: detect") }.count == 2)

        // An install that ran but changed nothing says so, never "Installing…" or the old line alone.
        try Data(detection(try box()).utf8).write(to: detectionFile)
        await list.detect("mybox")
        #expect(await list.install(.codex, on: "mybox") == BoxSetup.Failure(message: "codex is still 0.167 on mybox", fix: nil))
    }

    // MARK: 3 · A newer box

    @Test func aNewerOrEqualBoxVersionIsNotADifference() throws {
        let mac = try mac()
        var box = try box()
        box.versions["codex"] = "codex-cli 0.170.2"
        let parity = BoxParity.compare(mac: mac, box: box, name: "mybox")
        #expect(!parity.differences.contains { $0.id == "version.gh" || $0.id == "version.codex" })
        // gh newer there: said, with nothing to press; codex the same: not said at all.
        #expect(parity.notes.first { $0.id == "version.gh" } == .init(id: "version.gh", line: "gh 2.103 on mybox, 2.92 here", fix: nil))
        #expect(!parity.notes.contains { $0.id == "version.codex" })
        #expect(BoxMachine.older("gh version 2.92.0", than: "gh version 2.103.0"))
        #expect(!BoxMachine.older("gh version 2.103.0", than: "gh version 2.92.0"))
        #expect(!BoxMachine.older("codex-cli 0.170.0", than: "codex-cli 0.170.0"))
        #expect(!BoxMachine.older("unknown", than: "codex-cli 0.170.0"))
    }

    // MARK: 4 · A download that hangs

    /// The script's own bound: curl's timeout comes back as one line the card shows.
    @Test func anInstallDownloadTimesOutWithOneLine() async throws {
        let root = Fixture.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // A curl that times out (its exit 28), and the arguments it was given.
        let curl = bin.appendingPathComponent("curl")
        try "#!/bin/sh\necho \"$@\" >> '\(root.path)/curl.args'\nexit 28\n".write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        var debian = try machine(.linuxSystemd)
        debian.tools["unzip"] = "/usr/bin/unzip"
        for agent in [BoxAgent.gh, .claude] {
            let script = try agent.install(on: debian, name: "mybox").get()
            let ran = await BoxShell.local("HOME='\(root.path)'; PATH='\(bin.path)':$PATH; export HOME PATH\n" + script)
            #expect(!ran.ok)
            let site = agent == .gh ? "api.github.com" : "claude.ai"
            #expect(ran.lastLine == "the download from \(site) timed out after \(BoxAgent.small) s")
        }
        let args = try String(contentsOf: root.appendingPathComponent("curl.args"), encoding: .utf8)
        #expect(args.split(separator: "\n").allSatisfy { $0.contains("--connect-timeout 20 --max-time \(BoxAgent.small)") })
        // Every download in every script is bounded.
        for agent in BoxAgent.allCases {
            for kind in [FakeSSH.Kind.linuxSystemd, .macOS] {
                var machine = try machine(kind)
                machine.tools["bash"] = "/bin/bash"
                machine.tools["tar"] = "/usr/bin/tar"
                guard case .success(let script) = agent.install(on: machine, name: "box") else { continue }
                #expect(!script.contains("curl -fsSL https"), "\(agent) on \(kind)")
                #expect(!script.contains("| tar"), "\(agent) on \(kind)")
            }
        }
    }

    /// Kore's own bound on the whole install: a run that hangs past it is stopped and said.
    @Test func anInstallThatHangsIsStoppedAndSaid() async throws {
        let fake = try FakeSSH()
        defer { fake.finish() }
        try Data(detection(try box()).utf8).write(to: fake.root.appendingPathComponent("detection"))
        // ssh that answers the detect, and hangs on anything else.
        let ssh = """
            #!/bin/sh
            script=$(cat)
            case "$script" in *"# kore: detect"*) cat '\(fake.root.path)/detection'; exit 0 ;; esac
            exec sleep 30
            """
        try ssh.write(to: fake.root.appendingPathComponent("ssh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.root.appendingPathComponent("ssh").path)
        let list = BoxList(defaults: try defaults(), hosts: { [] }, cacheRoot: fake.root, setup: { alias, grant in
            BoxSetup(alias: alias, grant: grant, shell: fake.shell, binary: fake.binary())
        })
        let mac = try mac()
        list.findMac = { mac }
        list.installLimit = .seconds(1)
        list.add("mybox")
        await list.detect("mybox")
        let started = ContinuousClock.now
        let why = await list.install(.codex, on: "mybox")
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(why == BoxSetup.Failure(message: "codex didn't install: it took longer than 1 s, so Kore stopped it", fix: nil))
        // And the look after it ran: the card shows what's there.
        #expect(list.box("mybox")?.machine?.versions["codex"] == "codex-cli 0.167.0")
    }

    /// SSH that connects and never answers, its output held open by a child (a ProxyCommand) that
    /// ignores the end: each action the person starts ends at its bound, with one plain line.
    @Test func deadSSHEndsEveryActionFastAndSaysSo() async throws {
        // Its own name: another test's live link to "mybox" would word it as connected.
        let alias = "dead-ssh-box"
        let fake = try FakeSSH()
        defer { fake.finish() }
        try Data(detection(try box()).utf8).write(to: fake.root.appendingPathComponent("detection"))
        let path = fake.root.appendingPathComponent("ssh")
        func ssh(_ body: String) throws {
            try ("#!/bin/sh\n" + body).write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        var shell = fake.shell
        shell.quick = .milliseconds(500)
        shell.reach = .milliseconds(500)
        let bounded = shell
        let list = BoxList(defaults: try defaults(), hosts: { [] }, cacheRoot: fake.root, setup: { alias, grant in
            BoxSetup(alias: alias, grant: grant, shell: bounded, binary: fake.binary())
        })
        let mac = try mac()
        list.findMac = { mac }
        list.add(alias)
        try ssh("cat > /dev/null; cat '\(fake.root.path)/detection'\n")
        _ = try await list.look(alias).get()
        try ssh("(trap '' TERM HUP; sleep 20) &\ntrap '' TERM\nsleep 20\n")
        let dead = BoxSetup.Failure(message: "Can't reach \(alias)", fix: .tryAgain)
        func timed(_ what: String, _ action: () async -> BoxSetup.Failure?) async {
            let started = ContinuousClock.now
            let why = await action()
            let took = ContinuousClock.now - started
            #expect(why == dead, "\(what): \(String(describing: why))")
            #expect(took < .seconds(6), "\(what) took \(took)")
        }
        await timed("Check again") { if case .failure(let why) = await list.look(alias) { why } else { nil } }
        await timed("agent install") { await list.install(.codex, on: alias) }
        await timed("git identity") { await list.setGitIdentity(name: "a", email: "b@c", on: alias) }
        let started = ContinuousClock.now
        let scanned = await BoxHostKey.scan(alias, shell: bounded)
        #expect(scanned == nil)
        #expect(ContinuousClock.now - started < .seconds(6))
    }

    // MARK: 6 · The count

    /// The owner's card: 9 lines counted; only the older codex is Fix's to change.
    @Test func theDifferenceCountIsWhatFixDoes() throws {
        let parity = BoxParity.compare(mac: try mac(), box: try box(), name: "mybox")
        #expect(parity.differences.map(\.line) == ["codex 0.167 on mybox, 0.170 here"])
        #expect(parity.differences.allSatisfy { BoxParity.counts($0.fix) })
        #expect(parity.notes.map(\.line) == [
            "gh 2.103 on mybox, 2.92 here", "git 2.47 on mybox, 2.54 here", "node 20.19 on mybox, 25.8 here",
            "claude skills not on mybox: autoreview, logging-best-practices, pstack-claude-in-your-own-words",
            "codex MCP not on mybox: computer-use, cua_repl, node_repl",
            "claude's default model is its own on mybox, opus[1m] here", "codex's default model is its own on mybox, gpt-6.1-sol here",
        ])
        #expect(parity.notes.allSatisfy { !BoxParity.counts($0.fix) })
        var row = BoxList.Box(alias: "mybox")
        row.status = .ready
        row.folders = [BoxFolder(path: "/srv")]
        row.machine = try box()
        row.parity = parity
        #expect(row.note == .init(line: "1 difference from this Mac", action: .differences(1)))
        // Nothing for Fix to do: no Fix at all, the notes stay in the card.
        row.parity = BoxParity.compare(mac: try mac(), box: try box(codex: "0.171.0"), name: "mybox")
        #expect(row.parity?.differences.isEmpty == true)
        #expect(row.note == nil)
        // A tool that needs sudo is a Copy for the user: said, not counted.
        #expect(!BoxParity.counts(.copy("sudo apt-get install rsync")))
        #expect(BoxParity.counts(.tool("rsync")) && BoxParity.counts(.signIn(.codex)) && BoxParity.counts(.install(.gh)))
    }
}
