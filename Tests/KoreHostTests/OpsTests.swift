import Foundation
import KoreCore
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
            "KORE_HOST_SERVICE": "systemd",
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

    @Test func theServicesFoldersStayOnTheCLIsPathAfterTheLoginShells() {
        // A login profile that resets PATH keeps the unit's folders after its own.
        let service = HostService.searchPath.replacingOccurrences(of: "%h", with: "/home/u")
        let path = CLIExecutable.joined("/usr/local/bin:/usr/bin:/bin:/usr/games", service)
        #expect(path == "/usr/local/bin:/usr/bin:/bin:/usr/games:/home/u/.local/bin:/home/u/.npm-global/bin:/home/u/.bun/bin")
        #expect(CLIExecutable.joined("/a::/b", nil) == "/a:/b")
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

    // MARK: launchd and on demand

    private static func paths(_ root: URL) -> HostPaths {
        HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
    }

    @Test func theKindIsForcedByTheEnvironmentElseTheMachines() {
        #expect(HostService.kind(environment: ["KORE_HOST_SERVICE": "on-demand"]) { _ in HostRan(status: 0) } == .onDemand)
        #expect(HostService.kind(environment: ["KORE_HOST_SERVICE": "systemd"]) { _ in HostRan(status: 1) } == .systemd)
        #if os(macOS)
        #expect(HostService.kind(environment: [:]) { _ in HostRan(status: 127) } == .launchd)
        #else
        #expect(HostService.kind(environment: [:]) { _ in HostRan(status: 0) } == .systemd)
        // systemctl there, but no user manager answers (a container): on demand.
        #expect(HostService.kind(environment: [:]) { _ in HostRan(status: 1, output: "Failed to connect to bus") } == .onDemand)
        #endif
    }

    @Test func aMacGetsALaunchAgentLoadedInItsSessionAndRemovedAgain() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Self.paths(home)
        let ran = Lines()
        let lines = try HostService.install(.launchd, executable: "/Users/u/.local/bin/kore-host", home: home, user: "u", paths: paths) { args in
            ran.add(args.joined(separator: " "))
            // No desktop session (an ssh login): the user's own domain.
            return HostRan(status: args.starts(with: ["launchctl", "print"]) ? 113 : 0)
        }
        let uid = getuid()
        let file = HostService.agentFile(home: home)
        #expect(ran.all == ["launchctl print gui/\(uid)", "launchctl bootout user/\(uid)/dev.kore.kore-host", "launchctl bootstrap user/\(uid) \(file.path)"])
        #expect(lines == ["installed \(file.path)", "kore-host is running (/Users/u/.local/bin/kore-host)"])
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/u/.local/bin/kore-host", "run"])
        #expect((plist["EnvironmentVariables"] as? [String: String])?["PATH"]?.hasPrefix(home.path + "/.local/bin:") == true)
        #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect(HostService.installed(paths) == .launchd)
        let gone = Lines()
        let removed = HostService.uninstall(home: home, paths: paths) { args in
            gone.add(args.joined(separator: " "))
            return HostRan(status: 0)
        }
        #expect(gone.all.contains("launchctl bootout gui/\(uid)/dev.kore.kore-host"))
        #expect(removed.contains("removed \(file.path)"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(HostService.installed(paths) == nil)
        #expect(throws: HostServiceError.self) { try HostService.agent(executable: "kore-host", home: home, log: home) }
    }

    @Test func launchdRefusingFallsBackToStartingOnDemand() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Self.paths(home)
        let ran = Lines()
        let lines = try HostService.install(.launchd, executable: "/opt/kore-host", home: home, user: "u", paths: paths) { args in
            ran.add(args.joined(separator: " "))
            return HostRan(status: args.starts(with: ["launchctl", "bootstrap"]) ? 5 : 0, output: "Bootstrap failed: 5: Input/output error")
        }
        #expect(lines.first?.hasPrefix("launchd refused kore-host") == true)
        #expect(lines.contains("no service manager here: kore-host starts when Kore connects"))
        #expect(HostService.installed(paths) == .onDemand)
        // Started now, detached, its lines in the state folder.
        let spawned = try #require(ran.all.last)
        #expect(spawned.hasPrefix("sh -c "))
        #expect(spawned.contains("nohup \"$0\" run"))
        #expect(spawned.hasSuffix(" /opt/kore-host \(paths.state.path)/kore-host.log"))
    }

    @Test func noServiceManagerStartsOnDemandAndStartSaysHowEachKindStarts() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Self.paths(home)
        let ran = Lines()
        let record: HostRunner = { args in
            ran.add(args.prefix(2).joined(separator: " "))
            return HostRan(status: 0)
        }
        let lines = try HostService.install(.onDemand, executable: "/opt/kore-host", home: home, user: "u", paths: paths, run: record)
        #expect(lines == ["no service manager here: kore-host starts when Kore connects", "kore-host is running (/opt/kore-host)"])
        #expect(ran.all == ["sh -c"])
        #expect(HostService.start(.onDemand, executable: "/opt/kore-host", home: home, paths: paths, run: record))
        #expect(HostService.start(nil, executable: "/opt/kore-host", home: home, paths: paths, run: record))
        #expect(ran.all == ["sh -c", "sh -c", "systemctl --user"])
        // A systemd install over it forgets the on-demand kind.
        _ = try HostService.install(.systemd, executable: "/opt/kore-host", home: home, user: "u", paths: paths) { _ in HostRan(status: 0, output: "yes") }
        #expect(HostService.installed(paths) == nil)
    }

    @Test(.enabled(if: binary != nil)) func onDemandTheFirstAttachStartsTheDaemonAndUninstallStopsIt() throws {
        let root = try Self.scratch()
        let env = [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "KORE_HOST_SERVICE": "on-demand", "PATH": "/usr/bin:/bin",
        ]
        let paths = HostPaths(environment: env)
        defer {
            _ = try? Self.run(["uninstall", "--purge"], env: env)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(try Self.run(["install-service"], env: env).0 == 0)
        #expect(HostService.waitForDaemon(paths))
        // Stopped by hand: the next attach starts it again.
        let pid = try #require(Int32(String(contentsOf: paths.pid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(pid, SIGTERM)
        for _ in 0..<50 where HostLock.held(paths.lock) { usleep(100_000) }
        #expect(!HostLock.held(paths.lock))
        #expect(try Self.run(["allow", "mac", "--control", "full"], env: env).0 == 0)
        let attached = try Self.run(["attach", "--as", "mac"], env: env)
        #expect(attached.0 == AttachExit.ended.rawValue)
        #expect(HostLock.held(paths.lock))
        #expect(try Self.run(["uninstall"], env: env).0 == 0)
        #expect(!HostLock.held(paths.lock))
    }

    @Test func factsAreNamesOnlyFromEachCLIsOwnFiles() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ path: String, _ text: String) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write(".claude.json", #"{"mcpServers": {"linear": {"env": {"TOKEN": "s3cret"}}, "files": {}}, "projects": {}}"#)
        try write(".claude/settings.json", #"{"model": "opus", "enabledPlugins": {"a@m": true, "b@m": false}}"#)
        try write(".claude/skills/review/SKILL.md", "x")
        try write(".claude/skills/empty/notes.txt", "x")
        try write(".claude/agents/planner.md", "x")
        try write(".codex/config.toml", "model = \"gpt-6\"\n[mcp_servers.linear]\ncommand = \"x\"\n[mcp_servers.linear.env]\nTOKEN = \"s3cret\"\n[mcp_servers.\"a.b\"]\n[profiles.x]\nmodel = \"other\"\n")
        let facts = AgentFacts.read(home: home, environment: [:])
        #expect(facts.claudeMCP == ["files", "linear"])
        #expect(facts.claudePlugins == ["a@m"])
        #expect(facts.claudeModel == "opus")
        #expect(facts.claudeSkills == ["review"])
        #expect(facts.claudeAgents == ["planner"])
        #expect(facts.codexMCP == ["a.b", "linear"])
        #expect(facts.codexModel == "gpt-6")
        #expect(!String(decoding: facts.json(), as: UTF8.self).contains("s3cret"))
        #expect(AgentFacts.read(home: home.appendingPathComponent("none"), environment: [:]) == AgentFacts())
    }

    @Test func theCLIsAreToldWhatKindOfMachineThisIs() {
        #expect(HostServices.instructions(host: "mini", machine: "a Mac").hasPrefix("This chat runs on mini, a Mac, through kore-host."))
        #if os(macOS)
        #expect(HostServices.machine == "a Mac")
        #else
        #expect(HostServices.machine == "a Linux machine")
        #endif
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
