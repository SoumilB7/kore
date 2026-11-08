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
        #expect(status(SSHTransport.ended(status: 255, line: "ssh: connect to host mybox port 22: Connection refused")) == .unreachable("Can't reach mybox"))
        #expect(status(SSHTransport.ended(status: 127, line: "bash: line 1: /home/u/.local/bin/kore-host: No such file or directory")) == .notSetUp)
        #expect(status(SSHTransport.ended(status: 126, line: "cannot execute binary file: Exec format error")) == .notSetUp)
        #expect(status(SSHTransport.ended(status: AttachExit.notRunning.rawValue, line: "kore-host isn't running")) == .stopped)
        #expect(status(SSHTransport.ended(status: AttachExit.noGrant.rawValue, line: "kore-host: no grant named mac")) == .noGrant)
        #expect(status(SSHTransport.ended(status: 0, line: nil)) == .unreachable("Can't reach mybox"))
        #expect(status(nil, .refused("mybox didn't accept this Mac's grant \"mac\"")) == .noGrant)
        #expect(status(nil, .refused("mybox runs a link this Kore can't read")) == .stale)
        // Without ssh's status (a transport that doesn't say), its words.
        #expect(status("zsh: command not found: kore-host") == .notSetUp)
        #expect(status(nil) == .unreachable("Can't reach mybox"))
        #expect(SSHTransport.exit(of: "exit 3: kore-host isn't running")?.status == 3)
        #expect(SSHTransport.exit(of: "exit 3: kore-host isn't running")?.line == "kore-host isn't running")
        #expect(SSHTransport.exit(of: "the box said quit") == nil)
    }

    @Test func eachStateHasOneLineAndAtMostOneAction() {
        var box = BoxList.Box(alias: "mybox")
        box.status = .notSetUp
        #expect(box.note == .init(line: "kore-host isn't on mybox", action: .setUp))
        box.status = .stopped
        #expect(box.note == .init(line: "kore-host is stopped on mybox", action: .start))
        box.status = .noGrant
        #expect(box.note == .init(line: "mybox doesn't know this Mac", action: .setUp))
        box.status = .ready
        box.folders = [BoxFolder(path: "/srv/app")]
        #expect(box.note == nil)
        box.older = true
        #expect(box.note == .init(line: "mybox runs an older kore-host", action: .update))
        box.status = .working("Copying kore-host…")
        #expect(box.note == .init(line: "Copying kore-host…", action: nil))
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

    /// A folder standing in for the box's home, and ssh/scp stand-ins that log each call and act
    /// on it: `uname` says Linux x86_64, scp copies into the home, and `ssh` exits `status`.
    private struct FakeSSH {
        let root: URL
        var box: URL { root.appendingPathComponent("box") }
        var log: URL { root.appendingPathComponent("calls") }
        var shell: BoxShell { BoxShell(ssh: root.appendingPathComponent("ssh").path, scp: root.appendingPathComponent("scp").path) }

        init(status: Int32 = 0, said: String = "", uname: String = "Linux x86_64") throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boxops-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("box"), withIntermediateDirectories: true)
            let ssh = """
                #!/bin/sh
                [ "$1 $2 $3 $4" = "-T -o BatchMode=yes --" ] || exit 99
                echo "ssh $5 $6" >> '\(root.path)/calls'
                [ \(status) = 0 ] || { echo '\(said)' >&2; exit \(status); }
                case "$6" in
                  "uname -sm") echo '\(uname)' ;;
                  *install-service) echo installed ;;
                esac
                exit 0
                """
            let scp = """
                #!/bin/sh
                [ "$1 $2 $3 $4" = "-q -o BatchMode=yes --" ] || exit 99
                echo "scp $6" >> '\(root.path)/calls'
                cp "$5" '\(root.path)/box/copied'
                """
            for (name, text) in [("ssh", ssh), ("scp", scp)] {
                FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o755])
            }
        }

        var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func finish() { try? FileManager.default.removeItem(at: root) }
    }

    private static func binary(_ root: URL) -> @Sendable (String) throws -> (url: URL, temporary: Bool) {
        { arch in
            let file = root.appendingPathComponent("kore-host-\(arch)")
            try Data("binary for \(arch)".utf8).write(to: file)
            return (file, true)
        }
    }

    @Test func setUpCopiesInstallsAndGrantsOverSSH() async throws {
        let fake = try FakeSSH()
        defer { fake.finish() }
        let setup = BoxSetup(alias: "mybox", grant: "Soumils-Mac", shell: fake.shell, binary: Self.binary(fake.root))
        let steps = Steps()
        try await setup.run(allow: true) { steps.add($0) }
        #expect(fake.calls == [
            "ssh mybox uname -sm", "ssh mybox mkdir -p .local/bin", "scp mybox:.local/bin/kore-host.new",
            "ssh mybox chmod 755 .local/bin/kore-host.new && mv -f .local/bin/kore-host.new .local/bin/kore-host",
            "ssh mybox .local/bin/kore-host install-service", "ssh mybox .local/bin/kore-host allow 'Soumils-Mac' --control full",
        ])
        #expect(try String(contentsOf: fake.box.appendingPathComponent("copied"), encoding: .utf8) == "binary for x86_64")
        #expect(steps.all == ["Checking mybox…", "Copying kore-host…", "Starting…"])
        // The unpacked binary was a temp file: gone.
        #expect(!FileManager.default.fileExists(atPath: fake.root.appendingPathComponent("kore-host-x86_64").path))
    }

    @Test func updateGrantsNothingAndAnArmBoxGetsItsOwnBinary() async throws {
        let fake = try FakeSSH(uname: "Linux aarch64")
        defer { fake.finish() }
        let setup = BoxSetup(alias: "pi", grant: "mac", shell: fake.shell, binary: Self.binary(fake.root))
        try await setup.run(allow: false) { _ in }
        #expect(!fake.calls.contains { $0.contains(" allow ") })
        #expect(try String(contentsOf: fake.box.appendingPathComponent("copied"), encoding: .utf8) == "binary for aarch64")
    }

    @Test func aFailedStepSaysWhyAndStops() async throws {
        let down = try FakeSSH(status: 255, said: "ssh: Could not resolve hostname nobox")
        defer { down.finish() }
        await #expect(throws: BoxSetup.Failure(message: "Can't reach nobox")) {
            try await BoxSetup(alias: "nobox", grant: "mac", shell: down.shell, binary: Self.binary(down.root)).run(allow: true) { _ in }
        }
        let mac = try FakeSSH(uname: "Darwin arm64")
        defer { mac.finish() }
        await #expect(throws: BoxSetup.Failure.self) {
            try await BoxSetup(alias: "mac2", grant: "mac", shell: mac.shell, binary: Self.binary(mac.root)).run(allow: true) { _ in }
        }
        #expect(mac.calls == ["ssh mac2 uname -sm"])
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
        }) { alias, grant in BoxSetup(alias: alias, grant: grant, shell: fake.shell, binary: Self.binary(fake.root)) }
        list.add("mybox")
        await list.act(.setUp, on: "mybox")
        #expect(list.box("mybox")?.status == .ready)
        #expect(list.box("mybox")?.note?.line == "Ready")
        #expect(BoxSetup.grant(for: "mybox", defaults: defaults) == BoxSetup.macGrantName())
        #expect(grants.last == BoxSetup.macGrantName())
        #expect(BoxSetup.macGrantName() != "laptop")
        #expect(fake.calls.contains("ssh mybox .local/bin/kore-host allow '\(BoxSetup.macGrantName())' --control full"))
    }

    @Test func theBinaryComesUnpackedForTheBoxsCPU() async throws {
        #expect(BoxBinary.arch(uname: "Linux x86_64") == "x86_64")
        #expect(BoxBinary.arch(uname: "Linux aarch64") == "aarch64")
        #expect(BoxBinary.arch(uname: "Darwin arm64") == nil)
        #expect(BoxBinary.arch(uname: "Linux riscv64") == nil)
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
        #expect(try await probe("kore-ops-no-such-host.invalid", command) == .unreachable("Can't reach kore-ops-no-such-host.invalid"))
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
