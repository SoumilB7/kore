import Foundation

/// Where kore-host keeps things. Linux: the XDG directories, the runtime folder falling back to
/// `/run/user/<uid>` when a shell has no `XDG_RUNTIME_DIR` (`su -`, cron, ssh without a session).
/// macOS: Application Support, unless the XDG variables are set (as tests set them).
package struct HostPaths: Sendable {
    /// `config.json`.
    package let config: URL
    /// Grants, chats and the daemon's pid.
    package let state: URL
    /// The socket's folder.
    package let runtime: URL
    /// Why the runtime folder can't be used: nil when it can.
    package let runtimeProblem: String?

    package init(environment env: [String: String] = ProcessInfo.processInfo.environment, uid: UInt32 = getuid(), runUser: String = "/run/user") {
        let home = Self.home(env)
        func xdg(_ key: String) -> URL? { env[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }
        #if os(macOS)
        let support = home.appendingPathComponent("Library/Application Support/kore-host")
        state = xdg("XDG_STATE_HOME")?.appendingPathComponent("kore-host") ?? support
        runtime = xdg("XDG_RUNTIME_DIR")?.appendingPathComponent("kore-host") ?? support
        runtimeProblem = nil
        #else
        state = (xdg("XDG_STATE_HOME") ?? home.appendingPathComponent(".local/state")).appendingPathComponent("kore-host")
        if Self.startsOnDemand(state) {
            // No service manager: the daemon and every command agree on a folder of its own,
            // whatever session (or none) each runs in.
            (runtime, runtimeProblem) = (state.appendingPathComponent("run"), nil)
        } else {
            (runtime, runtimeProblem) = Self.runtimeFolder(xdg: env["XDG_RUNTIME_DIR"], uid: uid, runUser: runUser)
        }
        #endif
        config = (xdg("XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config")).appendingPathComponent("kore-host/config.json")
    }

    private init(config: URL, state: URL, runtime: URL) {
        self.config = config
        self.state = state
        self.runtime = runtime
        runtimeProblem = nil
    }

    /// These paths as an on-demand daemon has them (its runtime folder under the state).
    package var onDemand: HostPaths {
        #if os(macOS)
        self
        #else
        HostPaths(config: config, state: state, runtime: state.appendingPathComponent("run"))
        #endif
    }

    /// How kore-host was installed here when it isn't a systemd unit: `launchd` or `on-demand`
    /// (`HostService.Kind`), in `state/service`. Nothing there for systemd.
    package var serviceKind: URL { Self.serviceKind(state) }
    static func serviceKind(_ state: URL) -> URL { state.appendingPathComponent("service") }

    /// Whether `install-service` found no service manager here, so `attach` starts the daemon.
    static func startsOnDemand(_ state: URL) -> Bool {
        (try? String(contentsOf: serviceKind(state), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "on-demand"
    }

    /// This user's home: `$HOME` first, as a shell sets it (and a test or a scratch run overrides
    /// it), else the passwd entry, which is what NSHomeDirectory() reads on Linux.
    package static func home(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = env["HOME"], !home.isEmpty { return URL(fileURLWithPath: home) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// `$XDG_RUNTIME_DIR/kore-host`, else `<runUser>/<uid>/kore-host` when that folder is there,
    /// else that path and why it can't be used.
    package static func runtimeFolder(xdg: String?, uid: UInt32, runUser: String) -> (URL, String?) {
        if let xdg, !xdg.isEmpty { return (URL(fileURLWithPath: xdg).appendingPathComponent("kore-host"), nil) }
        let fallback = runUser + "/\(uid)"
        var isDir: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: fallback, isDirectory: &isDir) && isDir.boolValue
        let folder = URL(fileURLWithPath: fallback).appendingPathComponent("kore-host")
        return there
            ? (folder, nil)
            : (folder, "XDG_RUNTIME_DIR isn't set and \(fallback) isn't there: log in over ssh, or run `loginctl enable-linger`")
    }

    /// Throws when the runtime folder can't be used, saying why.
    package func needRuntime() throws {
        if let runtimeProblem { throw HostPathsError.noRuntime(runtimeProblem) }
    }

    package var grants: URL { state.appendingPathComponent("grants") }
    package var chats: URL { state.appendingPathComponent("chats") }
    /// Each CLI's model list as it last gave it (`clis[]`), for a client that connects before
    /// any CLI runs.
    package var models: URL { state.appendingPathComponent("models.json") }
    package var socket: URL { runtime.appendingPathComponent("link.sock") }
    /// Where a box chat's `kore-host mcp` asks the daemon (link 1.6, `HostAgent`).
    package var agentSocket: URL { runtime.appendingPathComponent("agent.sock") }
    package var pid: URL { runtime.appendingPathComponent("kore-host.pid") }
    /// Held by the running daemon (`HostLock`): one per runtime folder.
    package var lock: URL { runtime.appendingPathComponent("run.lock") }

    /// A folder only this user can enter (0700), made if it isn't there.
    package static func privateFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Writes `data` as a file only this user can read (0600), whole or not at all: a temp file,
    /// synced, then renamed over the old one. A full disk is said in the journal.
    /// A log about to be appended to ends with a whole line: a torn last line (a crash or power
    /// loss mid-write) is cut off, so the next line isn't glued onto it and lost.
    package static func endOnNewline(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        var at = size
        let chunk: UInt64 = 64 * 1024
        while at > 0 {
            let from = at > chunk ? at - chunk : 0
            try? handle.seek(toOffset: from)
            guard let data = try? handle.read(upToCount: Int(at - from)) else { return }
            if at == size, data.last == 0x0A { return }
            if let newline = data.lastIndex(of: 0x0A) {
                try? handle.truncate(atOffset: from + UInt64(newline - data.startIndex) + 1)
                return
            }
            at = from
        }
        try? handle.truncate(atOffset: 0)
    }

    package static func privateFile(_ data: Data, to url: URL) throws {
        try privateFolder(url.deletingLastPathComponent())
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid())")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failed(url, errno) }
        var problem: Int32 = 0
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    problem = errno
                    return
                }
                offset += written
            }
        }
        if problem == 0, fsync(fd) != 0 { problem = errno }
        close(fd)
        if problem == 0, rename(temp.path, url.path) != 0 { problem = errno }
        guard problem == 0 else {
            unlink(temp.path)
            throw failed(url, problem)
        }
    }

    private static func failed(_ url: URL, _ code: Int32) -> Error {
        HostJournal.writeFailed(url, code)
        return CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
    }
}

package enum HostPathsError: Error, CustomStringConvertible {
    case noRuntime(String)
    package var description: String {
        switch self {
        case .noRuntime(let why): "kore-host: \(why)"
        }
    }
}

/// `config.json`: the folders the host serves, as absolute paths. A file that can't be read is
/// kept as it is: the journal says why, the box serves nothing from it, and nothing saves over it.
package struct HostConfig: Codable, Sendable, Equatable {
    package var folders: [String]
    /// Why `config.json` couldn't be read; nil when it could (or isn't there).
    package var unreadable: String?

    private enum CodingKeys: String, CodingKey { case folders }

    package init(folders: [String] = [], unreadable: String? = nil) {
        self.folders = folders
        self.unreadable = unreadable
    }

    package static func load(_ url: URL, home: String = HostPaths.home().path) -> HostConfig {
        guard let data = try? Data(contentsOf: url) else { return HostConfig() }
        let config: HostConfig
        do {
            config = try JSONDecoder().decode(HostConfig.self, from: data)
        } catch {
            let why = Self.reason(error)
            HostJournal.note("config unreadable", ["path": url.path, "reason": why])
            return HostConfig(unreadable: why)
        }
        var folders: [String] = []
        for folder in config.folders {
            guard let path = normalised(folder, home: home) else {
                HostJournal.note("config folder skipped", ["path": folder, "reason": "not an absolute path"])
                continue
            }
            if !folders.contains(path) { folders.append(path) }
        }
        return HostConfig(folders: folders)
    }

    /// An absolute path as the box keeps it: `~` is this user's home, `.` and `..` are resolved,
    /// no trailing slash. Nil for a relative path.
    package static func normalised(_ path: String, home: String = HostPaths.home().path) -> String? {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst()
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Whether a served folder isn't there (moved or deleted): its window stays, said missing.
    package static func missing(_ folder: String) -> Bool {
        var isDir: ObjCBool = false
        return !(FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue)
    }

    /// Writes it (0600, atomic); refused while the file on disk couldn't be read.
    package func save(_ url: URL) throws {
        if let unreadable { throw HostConfigError.unreadable(url.path, unreadable) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try HostPaths.privateFile(encoder.encode(self), to: url)
    }

    private static func reason(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case .dataCorrupted(let context): return (context.underlyingError as NSError?)?.localizedDescription ?? context.debugDescription
        case .keyNotFound(let key, _): return "no \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            let at = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\"\(at)\" is the wrong type"
        @unknown default: return "\(error)"
        }
    }
}

package enum HostConfigError: Error, CustomStringConvertible {
    case unreadable(String, String)
    package var description: String {
        switch self {
        case .unreadable(let path, let why): "\(path) couldn't be read (\(why)): fix it, then restart kore-host"
        }
    }
}
