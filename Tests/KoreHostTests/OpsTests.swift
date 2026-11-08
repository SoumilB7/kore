import Foundation
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// Running the box: paths, config, the unit, journal lines, `status`, and `attach`'s exit codes.
@Suite("kore-host ops", .serialized)
struct OpsTests {
    private static func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/kho-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: Paths

    @Test func theRuntimeFolderFallsBackToRunUserAndSaysWhyWhenItCant() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let runUser = root.appendingPathComponent("run/user").path
        let (set, setProblem) = HostPaths.runtimeFolder(xdg: "/x/run", uid: 1000, runUser: runUser)
        #expect(set.path == "/x/run/kore-host")
        #expect(setProblem == nil)
        let (missing, problem) = HostPaths.runtimeFolder(xdg: nil, uid: 1000, runUser: runUser)
        #expect(missing.path == runUser + "/1000/kore-host")
        #expect(problem?.contains("XDG_RUNTIME_DIR isn't set") == true)
        try FileManager.default.createDirectory(atPath: runUser + "/1000", withIntermediateDirectories: true)
        let (fallback, none) = HostPaths.runtimeFolder(xdg: "", uid: 1000, runUser: runUser)
        #expect(fallback.path == runUser + "/1000/kore-host")
        #expect(none == nil)
    }

    @Test func homeIsHomeFirstSoAnOverrideIsHonoured() throws {
        #expect(HostPaths.home(["HOME": "/tmp/fake-home"]).path == "/tmp/fake-home")
        #expect(HostPaths.home(["HOME": ""]).path == NSHomeDirectory())
        #expect(HostPaths.home([:]).path == NSHomeDirectory())
        let paths = HostPaths(environment: ["HOME": "/tmp/fake-home"])
        #expect(paths.config.path == "/tmp/fake-home/.config/kore-host/config.json")
        #expect(HostService.unitFile(home: HostPaths.home(["HOME": "/tmp/fake-home"])).path == "/tmp/fake-home/.config/systemd/user/kore-host.service")
    }

    @Test(.enabled(if: binary != nil)) func installAndUninstallTouchOnlyTheOverriddenHome() throws {
        // The real binary, a fake home, and systemctl/loginctl stand-ins first on PATH: nothing
        // outside the scratch folder is written, and no real service manager is asked.
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let calls = root.appendingPathComponent("calls").path
        for tool in ["systemctl", "loginctl"] {
            let script = "#!/bin/sh\necho \"\(tool) $*\" >> \(calls)\n[ \"$1\" = show-user ] && echo yes\nexit 0\n"
            FileManager.default.createFile(atPath: bin.path + "/" + tool, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        }
        let home = root.appendingPathComponent("home")
        let env = [
            "HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin", "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ]
        let unit = HostService.unitFile(home: home)
        let realUnit = HostService.unitFile(home: URL(fileURLWithPath: NSHomeDirectory()))
        let realBefore = FileManager.default.fileExists(atPath: realUnit.path)
        #expect(try Self.run(["install-service"], env: env).0 == 0)
        #expect(FileManager.default.fileExists(atPath: unit.path))
        #expect(try String(contentsOf: unit, encoding: .utf8).contains(#"ExecStart="\#(try #require(Self.binary).resolvingSymlinksInPath().path)" run"#))
        #expect(try Self.run(["uninstall", "--purge"], env: env).0 == 0)
        #expect(!FileManager.default.fileExists(atPath: unit.path))
        #expect(FileManager.default.fileExists(atPath: realUnit.path) == realBefore)
        let said = try String(contentsOfFile: calls, encoding: .utf8)
        #expect(said.contains("systemctl --user restart kore-host.service"))
        #expect(said.contains("systemctl --user disable --now kore-host.service"))
    }

    @Test func privateFilesAreWholeAndOnlyTheUsers() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a/b/meta.json")
        try HostPaths.privateFile(Data("one".utf8), to: file)
        try HostPaths.privateFile(Data("two".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        // No temp file is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["meta.json"])
    }

    // MARK: Config

    @Test func configPathsAreNormalisedAndRelativeOnesSkipped() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        try Data(#"{"folders": ["~/Code", "/srv/app/", "/srv/x/../app", "relative/dir", "~"]}"#.utf8).write(to: file)
        let config = HostConfig.load(file, home: "/home/u")
        #expect(config.unreadable == nil)
        #expect(config.folders == ["/home/u/Code", "/srv/app", "/home/u"])
        #expect(HostConfig.normalised(" ~/a/./b ", home: "/home/u") == "/home/u/a/b")
        #expect(HostConfig.normalised("a/b", home: "/home/u") == nil)
        #expect(HostConfig.normalised("~user/x", home: "/home/u") == nil)
    }

    @Test func anUnreadableConfigIsLoggedKeptAndNeverSavedOver() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = Lines()
        HostJournal.listen { lines.add($0) }
        defer { HostJournal.listen(nil) }
        let file = root.appendingPathComponent("config.json")
        #expect(HostConfig.load(file).unreadable == nil)
        try Data(#"{"folders": ["/srv/app""#.utf8).write(to: file)
        #expect(HostConfig.load(file).unreadable != nil)
        let typo = Data(#"{"folders": "~/Code"}"#.utf8)
        try typo.write(to: file)
        var config = HostConfig.load(file)
        #expect(config.unreadable != nil)
        #expect(config.folders.isEmpty)
        #expect(lines.all.contains { $0.hasPrefix("config unreadable path=") })
        config.folders.append("/srv/other")
        #expect(throws: HostConfigError.self) { try config.save(file) }
        #expect(try Data(contentsOf: file) == typo)
        // A good one is written 0600.
        try HostConfig(folders: ["/srv/app"]).save(file)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        #expect(HostConfig.load(file).folders == ["/srv/app"])
    }

    @Test @MainActor func addFolderExpandsTildeOnTheBoxAndAMissingFolderStaysListed() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let home = NSHomeDirectory()
        // `~` is this box's home: a folder there that exists is served by its absolute path.
        let added = rig.host.addFolder("~")
        #expect(added == URL(fileURLWithPath: home).standardizedFileURL.path)
        #expect(rig.host.addFolder("~/no-such-folder-\(UUID().uuidString)") == nil)
        #expect(rig.host.addFolder("relative") == nil)
        // A served folder that goes away stays, said missing.
        try FileManager.default.removeItem(at: rig.folder)
        let listed = rig.host.folders.first { $0.path == rig.folder.path }
        #expect(listed?.missing == true)
        #expect(rig.host.folders.first { $0.path == added }?.missing == nil)
        #expect(rig.host.windows.count == 2)
    }

    // MARK: The unit

    @Test func theUnitRunsTheRealPathQuotedWithTheCLIsOnPath() throws {
        let unit = try HostService.unit(executable: "/home/a b/50%$x/kore-host")
        #expect(unit.contains(#"ExecStart="/home/a b/50%%$$x/kore-host" run"#))
        #expect(unit.contains("Environment=PATH=%h/.local/bin:%h/.npm-global/bin:%h/.bun/bin:/usr/local/bin:/usr/bin"))
        #expect(unit.contains("SyslogIdentifier=kore-host"))
        #expect(!unit.contains("After="))
        #expect(throws: HostServiceError.self) { try HostService.unit(executable: "kore-host") }
        #expect(throws: HostServiceError.self) { try HostService.unit(executable: "/a\nExecStartPre=/bin/x") }
    }

    @Test func installWritesEnablesRestartsAndTurnsLingerOn() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let ran = Lines()
        let lines = try HostService.install(executable: "/opt/kore-host", home: home, user: "u") { args in
            ran.add(args.joined(separator: " "))
            if args.starts(with: ["loginctl", "show-user"]) { return HostRan(status: 0, output: "no\n") }
            return HostRan(status: 0)
        }
        #expect(ran.all == [
            "systemctl --version", "loginctl show-user u --property=Linger --value", "loginctl enable-linger u",
            "systemctl --user daemon-reload", "systemctl --user enable kore-host.service", "systemctl --user restart kore-host.service",
        ])
        #expect(lines.contains { $0.hasPrefix("linger is on") })
        let unit = try String(contentsOf: HostService.unitFile(home: home), encoding: .utf8)
        #expect(unit.contains(#"ExecStart="/opt/kore-host" run"#))
    }

    @Test func lingerAlreadyOnIsLeftAloneAndARefusalSaysHow() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let ran = Lines()
        _ = try HostService.install(executable: "/opt/kore-host", home: home, user: "u") { args in
            ran.add(args.joined(separator: " "))
            return HostRan(status: 0, output: args.starts(with: ["loginctl", "show-user"]) ? "yes\n" : "")
        }
        #expect(!ran.all.contains { $0.hasPrefix("loginctl enable-linger") })
        let lines = try HostService.install(executable: "/opt/kore-host", home: home, user: "u") { args in
            HostRan(status: args.first == "loginctl" ? 1 : 0)
        }
        #expect(lines.contains("linger is off, so kore-host stops when you log out: run `sudo loginctl enable-linger u`"))
    }

    @Test func installSaysWhenThereIsNoSystemdOrAStepFails() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: HostServiceError.self) {
            try HostService.install(executable: "/opt/kore-host", home: home, user: "u") { _ in HostRan(status: 127) }
        }
        do {
            _ = try HostService.install(executable: "/opt/kore-host", home: home, user: "u") { args in
                args.last == "kore-host.service" && args.contains("restart") ? HostRan(status: 1, output: "Job failed.\nunit failed to start\n") : HostRan(status: 0, output: "yes")
            }
            Issue.record("expected the restart to fail")
        } catch {
            #expect("\(error)".contains("systemctl --user restart kore-host.service failed: unit failed to start"))
        }
    }

    @Test func uninstallStopsDisablesAndRemovesAndPurgeTakesTheState() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = HostService.unitFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[Unit]".utf8).write(to: file)
        let ran = Lines()
        let lines = HostService.uninstall(home: home) { args in
            ran.add(args.joined(separator: " "))
            return HostRan(status: 0)
        }
        #expect(ran.all == ["systemctl --user disable --now kore-host.service", "systemctl --user daemon-reload"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(lines.count == 2)
        let paths = HostPaths(environment: [
            "HOME": home.path, "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": home.appendingPathComponent("run").path, "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
        ])
        try GrantStore(paths.grants).allow("laptop", control: .full, socket: paths.socket)
        try HostConfig(folders: ["/srv"]).save(paths.config)
        let purged = HostService.purge(paths)
        #expect(purged.count == 2)
        #expect(!FileManager.default.fileExists(atPath: paths.state.path))
        #expect(!FileManager.default.fileExists(atPath: paths.config.path))
    }

    // MARK: Journal and status

    @Test @MainActor func theJournalSaysStartConnectRefusalAndStopWithoutSecrets() async throws {
        let lines = Lines()
        HostJournal.listen { lines.add($0) }
        defer { HostJournal.listen(nil) }
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        let grant = try GrantStore(rig.paths.grants).allow("laptop", control: .full, socket: rig.paths.socket)
        let client = try Client(rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: grant)
        try await until { client.got.count >= 3 }
        let wrong = try Client(rig.paths.socket)
        try await until { !wrong.got.isEmpty }
        wrong.hello(grant: grant, secret: LinkProof.random(32))
        try await until { wrong.ended }
        client.socket.close()
        try await until { lines.all.contains { $0.hasPrefix("disconnect") } }
        rig.host.stop()
        let said = lines.all
        #expect(said.contains { $0.hasPrefix("start version=\(HostVersion.string) link=\(HostVersion.link) pid=") })
        #expect(said.contains("connect grant=laptop control=full"))
        #expect(said.contains("refused grant=laptop reason=auth"))
        #expect(said.contains("disconnect grant=laptop"))
        #expect(said.contains("stop"))
        #expect(!said.joined().contains(grant.secret))
    }

    @Test func statusSaysTheVersionGrantsFoldersAndCLIs() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        try GrantStore(paths.grants).allow("mac", control: .full, socket: paths.socket)
        try HostConfig(folders: [root.path, root.path + "/gone"]).save(paths.config)
        let bin = root.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.path + "/claude", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let lines = HostStatus.lines(paths: paths, home: root.path, environment: [:]) { _ in HostRan(status: 127) }
        #expect(lines.first == "kore-host \(HostVersion.string) (link \(HostVersion.link))")
        #expect(lines.contains("daemon   not running"))
        #expect(lines.contains("grants   mac (full)"))
        #expect(lines.contains("         \(root.path)/gone (missing)"))
        #expect(lines.contains("claude   \(bin.path)/claude"))
        #expect(HostVersion.string.first?.isNumber == true)
    }

    // MARK: attach

    /// `kore-host`, built beside the test bundle (a test dependency).
    private static let binary: URL? = {
        let url = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("kore-host")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()
    private final class Marker {}

    private static func run(_ arguments: [String], env: [String: String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = try #require(binary)
        process.arguments = arguments
        process.environment = env
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let said = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: said, as: UTF8.self))
    }

    @Test(.enabled(if: binary != nil)) func attachExitsWithADistinctCodeForEachCause() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ]
        let noGrant = try Self.run(["attach", "--as", "mac"], env: env)
        #expect(noGrant.0 == AttachExit.noGrant.rawValue)
        #expect(noGrant.1.contains("no grant named mac"))
        #expect(try Self.run(["allow", "mac", "--control", "full"], env: env).0 == 0)
        let stopped = try Self.run(["attach", "--as", "mac"], env: env)
        #expect(stopped.0 == AttachExit.notRunning.rawValue)
        #expect(stopped.1.contains("kore-host isn't running"))
        #expect(try Self.run(["attach"], env: env).0 == AttachExit.usage.rawValue)
        let version = try Self.run(["--version"], env: env)
        #expect(version.0 == 0)
    }
}

/// Lines gathered from any thread.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
