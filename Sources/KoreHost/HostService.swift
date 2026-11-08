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

/// The systemd user unit: writing, enabling and removing it, linger, and telling systemd the
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
