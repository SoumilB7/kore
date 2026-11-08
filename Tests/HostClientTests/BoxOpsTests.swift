import Foundation
import HostClient
import LinkProtocol
import Testing

/// The Boxes view's side of running a box: why a link failed, setting a box up over (stand-in)
/// ssh, the version check, and removing a box.
@MainActor
@Suite(.serialized)
struct BoxOpsTests {
    private func defaults() throws -> UserDefaults { try #require(UserDefaults(suiteName: "boxops-\(UUID().uuidString)")) }

    // MARK: Why a box didn't link

    @Test func eachEndOfALinkNamesItsCause() {
        func status(_ reason: String?, _ phase: HostConnection.Phase = .offline) -> BoxList.Status {
            BoxList.status("mybox", phase: phase, reason: reason)
        }
        #expect(status(SSHTransport.ended(status: 255, line: "ssh: connect to host mybox port 22: Connection refused")) == .unreachable("mybox refused SSH", .tryAgain))
        #expect(status(SSHTransport.ended(status: 255, line: "me@mybox: Permission denied (publickey,password).")) == .unreachable("mybox needs a key · ssh-copy-id mybox", .copy("ssh-copy-id mybox")))
        #expect(status(SSHTransport.ended(status: 255, line: "Host key verification failed.")) == .unreachable("mybox's host key is new · ssh mybox once in Terminal", .copy("ssh mybox")))
        #expect(status(SSHTransport.ended(status: 127, line: "bash: line 1: /home/u/.local/bin/kore-host: No such file or directory")) == .notSetUp)
        #expect(status(SSHTransport.ended(status: 126, line: "cannot execute binary file: Exec format error")) == .notSetUp)
        #expect(status(SSHTransport.ended(status: AttachExit.notRunning.rawValue, line: "kore-host isn't running")) == .stopped)
        #expect(status(SSHTransport.ended(status: AttachExit.noGrant.rawValue, line: "kore-host: no grant named mac")) == .noGrant)
        #expect(status(SSHTransport.ended(status: 0, line: nil)) == .unreachable("Can't reach mybox", .tryAgain))
        #expect(status(nil, .refused(.auth)) == .noGrant)
        #expect(status(nil, .refused(.version)) == .stale)
        #expect(status(nil, .refused(.replaced)) == .unreachable("Another Kore here holds mybox", nil))
        // Without ssh's status (a transport that doesn't say), its words.
        #expect(status("zsh: command not found: kore-host") == .notSetUp)
        #expect(status(nil) == .unreachable("Can't reach mybox", .tryAgain))
        #expect(SSHTransport.exit(of: "exit 3: kore-host isn't running")?.status == 3)
        #expect(SSHTransport.exit(of: "exit 3: kore-host isn't running")?.line == "kore-host isn't running")
        #expect(SSHTransport.exit(of: "the box said quit") == nil)
    }

    @Test func eachStateHasOneLineAndAtMostOneAction() {
        var box = BoxList.Box(alias: "mybox")
        box.status = .notSetUp
        #expect(box.note == .init(line: "Not set up on mybox", action: .setUp))
        box.status = .stopped
        #expect(box.note == .init(line: "Stopped on mybox", action: .start))
        box.status = .noGrant
        #expect(box.note == .init(line: "mybox doesn't know this Mac", action: .setUp))
        box.status = .ready
        box.folders = [BoxFolder(path: "/srv/app")]
        #expect(box.note == nil)
        box.older = true
        #expect(box.note == .init(line: "mybox needs an update", action: .update))
        box.status = .working("Copying kore-host to mybox…")
        #expect(box.note == .init(line: "Copying kore-host to mybox…", action: nil))
    }

    @Test func anOlderBoxIsOneWithALowerLinkOrVersion() {
        func welcome(_ minor: Int, _ version: String) -> LinkMessage.Welcome {
            .init(
                proto: LinkVersion(major: 1, minor: minor), epoch: "e", host: .init(name: "mybox", koreVersion: version, kind: "box"), providers: [],
                policy: .init(sendMaxLevel: .danger), caps: [])
        }
        let now = HostWire.proto.minor
        #expect(!HostWire.older(welcome(now, "0.2.3"), mine: "0.2.3"))
        #expect(HostWire.older(welcome(now - 1, "0.2.3"), mine: "0.2.3"))
        #expect(HostWire.older(welcome(now, "0.2.2"), mine: "0.2.3"))
        #expect(HostWire.older(welcome(now, "0.1"), mine: "0.2.3"))
        #expect(!HostWire.older(welcome(now, "0.3.0"), mine: "0.2.3"))
        // A dev build has no version: the link alone.
        #expect(!HostWire.older(welcome(now, "0.0.1"), mine: nil))
    }

    // MARK: Setting a box up

    @Test func setUpChecksCopiesProvesInstallsAndGrantsOverSSH() async throws {
        let fake = try FakeSSH()
        defer { fake.finish() }
        let setup = BoxSetup(alias: "mybox", grant: "Soumils-Mac", shell: fake.shell, binary: fake.binary())
        let steps = Steps()
        let done = try await setup.run(allow: true) { steps.add($0) }
        #expect(fake.calls == [
            "ssh mybox sh -s: # kore: detect", "ssh mybox mkdir -p .local/bin", "scp mybox:.local/bin/kore-host.new",
            "ssh mybox chmod 755 .local/bin/kore-host.new && .local/bin/kore-host.new --version",
            "ssh mybox mv -f .local/bin/kore-host.new .local/bin/kore-host",
            "ssh mybox .local/bin/kore-host install-service", "ssh mybox .local/bin/kore-host allow 'Soumils-Mac' --control full",
        ])
        #expect(try String(contentsOf: fake.box.appendingPathComponent("copied"), encoding: .utf8) == "binary for linux-x86_64")
        #expect(steps.all == [
            "Checking mybox…", "Getting kore-host for Linux · x86_64 · Debian GNU/Linux 13 (trixie)…", "Copying kore-host to mybox…",
            "Starting kore-host (systemd)…", "Letting this Mac in…",
        ])
        #expect(done.machine.koreHost == "kore-host 0.2.3 (link 1.4)")
        #expect(done.warning == nil)
        // The unpacked binary was a temp file: gone.
        #expect(!FileManager.default.fileExists(atPath: fake.root.appendingPathComponent("kore-host-linux-x86_64").path))
    }

    @Test func eachKindOfMachineGetsItsOwnBinaryAndService() async throws {
        for (kind, platform, service) in [
            (FakeSSH.Kind.aarch64, "linux-aarch64", "systemd"), (.linuxNoSystemd, "linux-x86_64", "on demand"), (.macOS, "macos-arm64", "launchd"),
        ] {
            let fake = try FakeSSH(kind)
            defer { fake.finish() }
            let steps = Steps()
            try await BoxSetup(alias: "b", grant: "mac", shell: fake.shell, binary: fake.binary()).run(allow: false) { steps.add($0) }
            #expect(try String(contentsOf: fake.box.appendingPathComponent("copied"), encoding: .utf8) == "binary for \(platform)")
            #expect(steps.all.contains("Starting kore-host (\(service))…"))
            // Update grants nothing.
            #expect(!fake.calls.contains { $0.contains(" allow ") })
        }
    }

    @Test func aMachineKoreCantRunOnOrWithoutRoomStopsAtTheCheck() async throws {
        let old = try FakeSSH(.oldMac)
        defer { old.finish() }
        await #expect(throws: BoxSetup.Failure(message: "mini runs macOS 13.6 · Kore needs macOS 15 or later")) {
            try await BoxSetup(alias: "mini", grant: "mac", shell: old.shell, binary: old.binary()).run(allow: true) { _ in }
        }
        #expect(old.calls == ["ssh mini sh -s: # kore: detect"])
    }

    @Test func aBinaryThatDoesntRunThereIsRemovedAndTheOldOneKept() async throws {
        let fake = try FakeSSH()
        defer { fake.finish() }
        // The copied binary's check prints nothing (an exec format error says so on stderr).
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake.root.appendingPathComponent("noop"))
        let shell = BoxShell(ssh: fake.shell.ssh, scp: fake.shell.scp)
        let setup = BoxSetup(alias: "mybox", grant: "mac", shell: shell) { _ in
            let file = fake.root.appendingPathComponent("bin")
            try Data("x".utf8).write(to: file)
            return (file, false)
        }
        // A check that answers but isn't kore-host.
        let script = try String(contentsOf: fake.root.appendingPathComponent("ssh"), encoding: .utf8)
            .replacingOccurrences(of: "echo 'kore-host 0.2.3 (link 1.4)'", with: "echo 'cannot execute binary file: Exec format error'")
        try Data(script.utf8).write(to: fake.root.appendingPathComponent("ssh"))
        await #expect(throws: BoxSetup.Failure(message: "That kore-host doesn't run on mybox: cannot execute binary file: Exec format error")) {
            try await setup.run(allow: true) { _ in }
        }
        #expect(fake.calls.last == "ssh mybox rm -f .local/bin/kore-host.new")
        #expect(!fake.calls.contains { $0.contains("mv -f") })
    }

    @Test func sshFailuresSayWhatFixesThem() async throws {
        let down = try FakeSSH(status: 255, said: "ssh: connect to host nobox port 22: Operation timed out")
        defer { down.finish() }
        await #expect(throws: BoxSetup.Failure(message: "Can't reach nobox", fix: .tryAgain)) {
            try await BoxSetup(alias: "nobox", grant: "mac", shell: down.shell, binary: down.binary()).run(allow: true) { _ in }
        }
        let key = try FakeSSH(status: 255, said: "me@10.0.0.5: Permission denied (publickey,password).")
        defer { key.finish() }
        await #expect(throws: BoxSetup.Failure(message: "me@10.0.0.5:2222 needs a key · ssh-copy-id -p 2222 me@10.0.0.5", fix: .copy("ssh-copy-id -p 2222 me@10.0.0.5"))) {
            try await BoxSetup(alias: "me@10.0.0.5:2222", grant: "mac", shell: key.shell, binary: key.binary()).detect()
        }
        // A typed destination: the user and port as options, the host one word after `--`.
        #expect(key.calls == ["ssh -o User=me -o Port=2222 10.0.0.5 sh -s: # kore: detect"])
        let changed = BoxSetup.sshFailure("mybox", "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.")
        #expect(changed == BoxSetup.Failure(message: "mybox's host key changed · check it, then ssh-keygen -R mybox", fix: .copy("ssh-keygen -R mybox")))
        #expect(BoxSetup.sshFailure("x", "ssh: Could not resolve hostname x: nodename nor servname provided").message == "Can't find x · check the name")
    }

    @Test func setUpFromTheListReachesTheBoxWithThisMacsGrant() async throws {
        let fake = try FakeSSH()
        defer { fake.finish() }
        let defaults = try defaults()
        var grants: [String] = []
        let list = BoxList(defaults: defaults, hosts: { [] }, cacheRoot: fake.root.appendingPathComponent("cache"), connection: { alias in
            grants.append(BoxSetup.grant(for: alias, defaults: defaults))
            let connection = HostConnection(alias: alias, cache: HostCache(alias: alias, root: fake.root.appendingPathComponent("conn"))) {
                let (client, host) = FakeHost.pair()
                Task { @MainActor in
                    _ = await host.handshake(windows: [], chats: [])
                    let ask = await host.next("cmd")
                    host.send(json: ["t": "result", "ok": true, "id": ask?["id"] ?? "", "folders": [["windowId": "w_1", "path": "/home/me/app"]]])
                }
                return client
            }
            return connection
        }) { alias, grant in BoxSetup(alias: alias, grant: grant, shell: fake.shell, binary: fake.binary()) }
        list.findMac = { nil }
        list.add("mybox")
        await list.act(.setUp, on: "mybox")
        #expect(list.box("mybox")?.status == .ready)
        #expect(list.box("mybox")?.note?.line == "Ready")
        #expect(list.box("mybox")?.kind == "Linux · x86_64 · Debian GNU/Linux 13 (trixie)")
        #expect(BoxSetup.grant(for: "mybox", defaults: defaults) == BoxSetup.macGrantName())
        #expect(grants.last == BoxSetup.macGrantName())
        #expect(BoxSetup.macGrantName() != "laptop")
        #expect(fake.calls.contains("ssh mybox .local/bin/kore-host allow '\(BoxSetup.macGrantName())' --control full"))
        // The machine is kept for the next run.
        #expect(BoxMachine.cached("mybox", root: fake.root.appendingPathComponent("cache"))?.platform == "linux-x86_64")
        #expect(BoxList(defaults: defaults, hosts: { [] }, cacheRoot: fake.root.appendingPathComponent("cache")).box("mybox")?.machine?.system == .linux)
    }

    @Test func theBinaryComesUnpackedForTheBoxsCPU() async throws {
        #expect(BoxBinary.arch(uname: "Linux x86_64") == "x86_64")
        #expect(BoxBinary.arch(uname: "Linux aarch64") == "aarch64")
        #expect(BoxBinary.arch(uname: "Darwin arm64") == nil)
        #expect(BoxBinary.arch(uname: "Linux riscv64") == nil)
        #expect(BoxBinary.here.hasPrefix("macos-"))
        // `xz` made this; Kore reads it without the xz command.
        let packed = try #require(Data(base64Encoded: "/Td6WFoAAATm1rRGBMATDyEBFgAAAAAAAAAAAG75/+kBAA5rb3JlLWhvc3QgdGVzdAoAAD0k29I+59IvAAEvD9eQJaIftvN9AQAAAAAEWVo="))
        #expect(String(decoding: try BoxBinary.unxz(packed), as: UTF8.self) == "kore-host test\n")
        // A development build named by the default.
        let defaults = try defaults()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boxbin-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try packed.write(to: dir.appendingPathComponent("kore-host.xz"))
        defaults.set(dir.appendingPathComponent("kore-host.xz").path, forKey: BoxBinary.overrideKey)
        let local = try await BoxBinary.local(arch: "x86_64", override: defaults.string(forKey: BoxBinary.overrideKey))
        defer { try? FileManager.default.removeItem(at: local.url) }
        #expect(local.temporary)
        #expect(try String(contentsOf: local.url, encoding: .utf8) == "kore-host test\n")
    }

    // MARK: A real box, on purpose only

    /// `KORE_BOX_PROBE=<alias>` (and `KORE_BOX_COMMAND=<kore-host's path there>`): what each failure
    /// reads as against a real box, through real ssh. Grants and installs nothing there.
    nonisolated static let realBox = ProcessInfo.processInfo.environment["KORE_BOX_PROBE"]

    @Test(.enabled(if: realBox != nil)) func aRealBoxsFailuresAreToldApart() async throws {
        let box = try #require(Self.realBox)
        let command = ProcessInfo.processInfo.environment["KORE_BOX_COMMAND"] ?? SSHTransport.defaultCommand
        let root = Fixture.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        func probe(_ alias: String, _ command: String) async throws -> BoxList.Status? {
            let list = BoxList(defaults: try defaults(), hosts: { [] }, cacheRoot: root) { alias in
                HostConnection(alias: alias, grant: "kore-ops-no-grant", command: command, cache: HostCache(alias: alias, root: root))
            }
            list.add(alias)
            await list.probe(alias)
            return list.box(alias)?.status
        }
        #expect(try await probe(box, "~/.local/bin/kore-host-not-here") == .notSetUp)
        #expect(try await probe(box, command) == .noGrant)
        #expect(try await probe("kore-ops-no-such-host.invalid", command) == .unreachable("Can't find kore-ops-no-such-host.invalid · check the name", .tryAgain))
    }

    // MARK: The list

    @Test func removingABoxForgetsItHereOnly() throws {
        let defaults = try defaults()
        let root = Fixture.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // Boxes listed before this Mac named its grant keep the one they were set up with.
        defaults.set(["mybox"], forKey: "boxHosts")
        let list = BoxList(defaults: defaults, hosts: { [] }, cacheRoot: root)
        #expect(BoxSetup.grant(for: "mybox", defaults: defaults) == "laptop")
        list.add("other")
        #expect(BoxSetup.grant(for: "other", defaults: defaults) == BoxSetup.macGrantName())
        list.add("-oProxyCommand=x")
        #expect(list.boxes.map(\.alias) == ["mybox", "other"])
        let cache = HostCache(alias: "mybox", root: root)
        try FileManager.default.createDirectory(at: cache.folder, withIntermediateDirectories: true)
        defaults.set("/opt/kh", forKey: "boxKoreHost.mybox")
        list.remove("mybox")
        #expect(list.boxes.map(\.alias) == ["other"])
        #expect(defaults.stringArray(forKey: "boxHosts") == ["other"])
        #expect(defaults.string(forKey: "boxGrant.mybox") == nil)
        #expect(defaults.string(forKey: "boxKoreHost.mybox") == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.folder.path))
        #expect(BoxList(defaults: defaults, hosts: { [] }, cacheRoot: root).boxes.map(\.alias) == ["other"])
    }
}

/// Lines gathered as they're said.
@MainActor
final class Steps {
    private(set) var all: [String] = []
    func add(_ line: String) { all.append(line) }
}
