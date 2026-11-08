import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A command's run: its exit status and what it printed (stdout and stderr together).
package struct HostRan: Sendable, Equatable {
    package var status: Int32
    package var output: String

    package init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }

    package var ok: Bool { status == 0 }
    /// The last line it printed: what an error says.
    package var lastLine: String {
        output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// Runs a command found on PATH; tests stand one in.
package typealias HostRunner = @Sendable ([String]) -> HostRan

/// Keeping kore-host running: a systemd user unit (with linger), a LaunchAgent on a Mac, or, with
/// no service manager, started on demand by `attach`; removing each, and telling systemd the
/// socket is up (`Type=notify`).
package enum HostService {
    package static let unitName = "kore-host.service"

    /// Where the service looks for the CLIs, before the login shell's PATH is read: their usual
    /// installs (claude's native installer, npm and bun user prefixes, system packages).
    package static let searchPath = "%h/.local/bin:%h/.npm-global/bin:%h/.bun/bin:/usr/local/bin:/usr/bin:/bin"

    package static func unitFile(home: URL) -> URL { home.appendingPathComponent(".config/systemd/user/" + unitName) }

    package static func unit(executable: String) throws -> String {
        guard !executable.contains(where: \.isNewline), executable.hasPrefix("/") else { throw HostServiceError.badPath(executable) }
        return """
            [Unit]
            Description=kore-host: Kore's chats on this machine, for the Mac over SSH

            [Service]
            Type=notify
            ExecStart=\(quoted(executable)) run
            Environment=PATH=\(searchPath)
            # The allocator hands freed pages back at once, so an idle box stays small.
            Environment=MIMALLOC_PURGE_DELAY=0
            SyslogIdentifier=kore-host
            # libdispatch can't raise a thread's priority without CAP_SYS_NICE, and says so each time.
            LogFilterPatterns=~Failed to set thread priority
            Restart=on-failure
            RestartSec=2

            [Install]
            WantedBy=default.target

            """
    }

    /// A path as one word of a unit's command line: quoted, with systemd's specifiers (`%`) and
    /// variables (`$`) taken literally.
    package static func quoted(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "$", with: "$$")
        return "\"" + escaped + "\""
    }

    /// How kore-host stays running on this machine.
    package enum Kind: String, Sendable, CaseIterable {
        /// A systemd user unit (Linux with a user manager).
        case systemd
        /// A LaunchAgent (macOS).
        case launchd
        /// No service manager (a container, WSL, a VPS without user sessions): `attach` starts
        /// `kore-host run` under nohup when no daemon answers, and it stays up after.
        case onDemand = "on-demand"
    }

    /// What this machine has: `KORE_HOST_SERVICE` when set, else launchd on macOS, systemd where a
    /// user manager answers, otherwise on demand.
    package static func kind(environment: [String: String] = ProcessInfo.processInfo.environment, run: HostRunner = system) -> Kind {
        if let forced = environment["KORE_HOST_SERVICE"].flatMap(Kind.init(rawValue:)) { return forced }
        #if os(macOS)
        return .launchd
        #else
        return run(["systemctl", "--user", "show-environment"]).ok ? .systemd : .onDemand
        #endif
    }

    /// The kind `install-service` chose here last (nil: never installed, or systemd).
    package static func installed(_ paths: HostPaths) -> Kind? {
        (try? String(contentsOf: paths.serviceKind, encoding: .utf8)).flatMap { Kind(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Installs kore-host as `kind` and (re)starts it, which takes a new binary. A service manager
    /// that refuses falls back to starting on demand. The lines to print.
    package static func install(
        _ kind: Kind, executable: String, home: URL, user: String, paths: HostPaths, run: HostRunner = system
    ) throws -> [String] {
        switch kind {
        case .systemd:
            let lines = try install(executable: executable, home: home, user: user, run: run)
            try? FileManager.default.removeItem(at: paths.serviceKind)
            return lines
        case .launchd:
            do {
                let lines = try installAgent(executable: executable, home: home, paths: paths, run: run)
                try mark(.launchd, paths)
                return lines
            } catch {
                return ["launchd refused kore-host (\(error)): it starts when Kore connects instead"] + (try onDemand(executable: executable, paths: paths, run: run))
            }
        case .onDemand:
            return try onDemand(executable: executable, paths: paths, run: run)
        }
    }

    private static func mark(_ kind: Kind, _ paths: HostPaths) throws {
        try HostPaths.privateFile(Data((kind.rawValue + "\n").utf8), to: paths.serviceKind)
    }

    // MARK: systemd

    /// Writes the unit, turns linger on (so the service outlives the last login), enables it and
    /// (re)starts it, which takes a new binary. The lines to print.
    package static func install(executable: String, home: URL, user: String, run: HostRunner = system) throws -> [String] {
        guard run(["systemctl", "--version"]).status != 127 else { throw HostServiceError.noSystemd }
        let file = unitFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(unit(executable: executable).utf8).write(to: file, options: .atomic)
        var lines = ["installed \(file.path)"]
        if let note = linger(user: user, run: run) { lines.append(note) }
        for step in [["daemon-reload"], ["enable", unitName], ["restart", unitName]] {
            let ran = run(["systemctl", "--user"] + step)
            guard ran.ok else { throw HostServiceError.failed("systemctl --user " + step.joined(separator: " "), ran.lastLine) }
        }
        lines.append("kore-host is running (\(executable))")
        return lines
    }

    /// Linger on, so the user's services run without a login: nothing when it's on already, one
    /// line saying how when it can't be turned on.
    static func linger(user: String, run: HostRunner) -> String? {
        let now = run(["loginctl", "show-user", user, "--property=Linger", "--value"])
        if now.ok, now.output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" { return nil }
        if run(["loginctl", "enable-linger", user]).ok { return "linger is on: kore-host keeps running after you log out" }
        return "linger is off, so kore-host stops when you log out: run `sudo loginctl enable-linger \(user)`"
    }

    // MARK: launchd

    package static let agentLabel = "dev.kore.kore-host"

    package static func agentFile(home: URL) -> URL { home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist") }

    /// The CLIs' usual folders on a Mac, Homebrew's included.
    static func agentPath(home: String) -> String {
        ["\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
    }

    /// The LaunchAgent: `kore-host run` at load, again if it fails, with the CLIs on PATH.
    package static func agent(executable: String, home: URL, log: URL) throws -> Data {
        guard executable.hasPrefix("/"), !executable.contains(where: \.isNewline) else { throw HostServiceError.badPath(executable) }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            // An ssh login without a desktop session runs it too.
            "LimitLoadToSessionType": ["Aqua", "Background"],
            "EnvironmentVariables": ["PATH": agentPath(home: home.path), "MIMALLOC_PURGE_DELAY": "0"],
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// The launchd domain to use: the desktop session's when there is one, else the user's own
    /// (an ssh login without one).
    static func domain(run: HostRunner) -> String {
        let uid = getuid()
        return run(["launchctl", "print", "gui/\(uid)"]).ok ? "gui/\(uid)" : "user/\(uid)"
    }

    /// Writes the agent and loads it afresh (unloading the old one first), which starts it.
    static func installAgent(executable: String, home: URL, paths: HostPaths, run: HostRunner) throws -> [String] {
        let file = agentFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HostPaths.privateFolder(paths.state)
        try agent(executable: executable, home: home, log: paths.state.appendingPathComponent("kore-host.log")).write(to: file, options: .atomic)
        let domain = domain(run: run)
        _ = run(["launchctl", "bootout", "\(domain)/\(agentLabel)"])
        // bootout finishes in the background: a bootstrap right after can find it still there.
        var loaded = run(["launchctl", "bootstrap", domain, file.path])
        for _ in 0..<10 where !loaded.ok {
            usleep(200_000)
            loaded = run(["launchctl", "bootstrap", domain, file.path])
        }
        guard loaded.ok else { throw HostServiceError.failed("launchctl bootstrap \(domain)", loaded.lastLine) }
        return ["installed \(file.path)", "kore-host is running (\(executable))"]
    }

    // MARK: On demand

    /// No service manager: remembered, and the daemon started now under nohup.
    static func onDemand(executable: String, paths: HostPaths, run: HostRunner) throws -> [String] {
        try mark(.onDemand, paths)
        // The marker moves the runtime folder: paths made before it are stale.
        let now = paths.onDemand
        stopOnDemand(now)
        spawn(executable: executable, paths: now, run: run)
        return ["no service manager here: kore-host starts when Kore connects", "kore-host is running (\(executable))"]
    }

    /// `kore-host run` in its own session, detached from this one, its lines in `state/kore-host.log`.
    package static func spawn(executable: String, paths: HostPaths, run: HostRunner = system) {
        try? HostPaths.privateFolder(paths.state)
        let log = paths.state.appendingPathComponent("kore-host.log")
        // Kept small: started again, a long log starts over.
        if let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int), size > 1 << 20 {
            try? FileManager.default.removeItem(at: log)
        }
        let script = #"if command -v setsid >/dev/null 2>&1; then setsid nohup "$0" run; else nohup "$0" run; fi >>"$1" 2>&1 </dev/null &"#
        _ = run(["sh", "-c", script, executable, log.path])
    }

    /// Stops the on-demand daemon, when one holds its lock, and waits for it to let go.
    static func stopOnDemand(_ paths: HostPaths) {
        guard HostLock.held(paths.lock), let text = try? String(contentsOf: paths.pid, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 1
        else { return }
        kill(pid, SIGTERM)
        for _ in 0..<50 where HostLock.held(paths.lock) { usleep(100_000) }
    }

    /// Starts the daemon as it was installed here: `kore-host start`, and `attach` when nothing
    /// answers on a machine without systemd. False when it can't be started from here.
    @discardableResult
    package static func start(_ kind: Kind?, executable: String, home: URL, paths: HostPaths, run: HostRunner = system) -> Bool {
        switch kind {
        case nil, .systemd?:
            return run(["systemctl", "--user", "start", unitName]).ok
        case .launchd?:
            let domain = domain(run: run)
            let file = agentFile(home: home)
            // After a restart without a desktop login, nothing loaded it.
            if run(["launchctl", "print", "\(domain)/\(agentLabel)"]).ok == false, FileManager.default.fileExists(atPath: file.path) {
                _ = run(["launchctl", "bootstrap", domain, file.path])
            }
            if run(["launchctl", "kickstart", "\(domain)/\(agentLabel)"]).ok { return true }
            spawn(executable: executable, paths: paths, run: run)
            return true
        case .onDemand?:
            spawn(executable: executable, paths: paths, run: run)
            return true
        }
    }

    /// Waits up to `seconds` for the daemon to hold its lock and its socket to be there.
    package static func waitForDaemon(_ paths: HostPaths, seconds: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if HostLock.held(paths.lock), FileManager.default.fileExists(atPath: paths.socket.path) { return true }
            usleep(50_000)
        }
        return false
    }

    // MARK: Removing

    /// Stops and removes whatever kind was installed. The lines to print.
    package static func uninstall(home: URL, paths: HostPaths, run: HostRunner = system) -> [String] {
        var lines: [String] = []
        let agent = agentFile(home: home)
        if FileManager.default.fileExists(atPath: agent.path) {
            let domain = domain(run: run)
            _ = run(["launchctl", "bootout", "\(domain)/\(agentLabel)"])
            if (try? FileManager.default.removeItem(at: agent)) != nil { lines.append("removed \(agent.path)") }
        }
        if installed(paths) == .onDemand {
            stopOnDemand(paths)
            lines.append("stopped kore-host")
        }
        try? FileManager.default.removeItem(at: paths.serviceKind)
        if FileManager.default.fileExists(atPath: unitFile(home: home).path) || lines.isEmpty {
            lines += uninstall(home: home, run: run)
        }
        return lines
    }

    /// Stops and disables the unit and removes it. The lines to print.
    package static func uninstall(home: URL, run: HostRunner = system) -> [String] {
        let file = unitFile(home: home)
        var lines: [String] = []
        if run(["systemctl", "--user", "disable", "--now", unitName]).ok { lines.append("stopped and disabled kore-host") }
        if (try? FileManager.default.removeItem(at: file)) != nil { lines.append("removed \(file.path)") }
        _ = run(["systemctl", "--user", "daemon-reload"])
        return lines.isEmpty ? ["kore-host wasn't installed as a service"] : lines
    }

    /// `--purge`: the state (chats, grants), the config and the runtime folder.
    package static func purge(_ paths: HostPaths) -> [String] {
        [paths.state, paths.config.deletingLastPathComponent(), paths.runtime].compactMap { folder in
            (try? FileManager.default.removeItem(at: folder)) != nil ? "removed \(folder.path)" : nil
        }
    }

    /// This process's own file, whatever it was started as (`kore-host` from PATH, a relative path).
    package static func executable() -> String {
        #if os(Linux)
        if let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
            return path.hasSuffix(" (deleted)") ? String(path.dropLast(" (deleted)".count)) : path
        }
        #endif
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The user's login name.
    package static func user() -> String {
        if let entry = getpwuid(getuid()), let name = entry.pointee.pw_name { return String(cString: name) }
        return ProcessInfo.processInfo.environment["USER"] ?? "\(getuid())"
    }

    /// Runs `arguments` through `env`: 127 when the command isn't there.
    package static let system: HostRunner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return HostRan(status: 127, output: "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return HostRan(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// `READY=1` to `$NOTIFY_SOCKET`, when systemd set one: the socket is listening by then.
    package static func notifyReady(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard var path = environment["NOTIFY_SOCKET"], !path.isEmpty else { return }
        let abstract = path.hasPrefix("@")
        if abstract { path.removeFirst() }
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        #endif
        guard fd >= 0 else { return }
        defer { _ = Glue4.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count + 1 < MemoryLayout.size(ofValue: address.sun_path) else { return }
        let start = abstract ? 1 : 0
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.storeBytes(of: 0, toByteOffset: 0, as: UInt8.self)
            for (i, b) in bytes.enumerated() { raw[start + i] = b }
            raw[start + bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + start + bytes.count + (abstract ? 0 : 1))
        let message = Array("READY=1".utf8)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, message, message.count, 0, $0, length) }
        }
    }
}

package enum HostServiceError: Error, CustomStringConvertible {
    case noSystemd
    case badPath(String)
    case failed(String, String)
    package var description: String {
        switch self {
        case .noSystemd: "no systemd here: start `kore-host run` from your init system instead"
        case .badPath(let path): "kore-host can't be a service from \(path)"
        case .failed(let command, let said): "\(command) failed" + (said.isEmpty ? "" : ": \(said)") + " (see `journalctl --user -u kore-host`)"
        }
    }
}

private enum Glue4 {
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Glibc)
        Glibc.close(fd)
        #else
        Musl.close(fd)
        #endif
    }
}
