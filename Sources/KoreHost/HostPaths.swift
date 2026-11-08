import Foundation

/// Where kore-host keeps things. Linux: the XDG directories. macOS: Application Support, unless
/// the XDG variables are set (as tests set them).
package struct HostPaths: Sendable {
    /// `config.json`.
    package let config: URL
    /// Grants, chats and the daemon's pid.
    package let state: URL
    /// The socket's folder.
    package let runtime: URL

    package init(environment env: [String: String] = ProcessInfo.processInfo.environment) {
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
        func xdg(_ key: String) -> URL? { env[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }
        #if os(macOS)
        let support = home.appendingPathComponent("Library/Application Support/kore-host")
        state = xdg("XDG_STATE_HOME")?.appendingPathComponent("kore-host") ?? support
        runtime = xdg("XDG_RUNTIME_DIR")?.appendingPathComponent("kore-host") ?? support
        #else
        state = (xdg("XDG_STATE_HOME") ?? home.appendingPathComponent(".local/state")).appendingPathComponent("kore-host")
        runtime = xdg("XDG_RUNTIME_DIR")?.appendingPathComponent("kore-host") ?? state
        #endif
        config = (xdg("XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config")).appendingPathComponent("kore-host/config.json")
    }

    package var grants: URL { state.appendingPathComponent("grants") }
    package var chats: URL { state.appendingPathComponent("chats") }
    package var socket: URL { runtime.appendingPathComponent("link.sock") }
    package var pid: URL { runtime.appendingPathComponent("kore-host.pid") }

    /// A folder only this user can enter (0700), made if it isn't there.
    package static func privateFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Writes `data` as a file only this user can read (0600), whole or not at all.
    package static func privateFile(_ data: Data, to url: URL) throws {
        try privateFolder(url.deletingLastPathComponent())
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid())")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temp.path, url.path) != 0 { throw CocoaError(.fileWriteUnknown) }
    }
}

/// `config.json`: the folders the host serves.
package struct HostConfig: Codable, Sendable, Equatable {
    package var folders: [String]

    package init(folders: [String] = []) { self.folders = folders }

    package static func load(_ url: URL) -> HostConfig {
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(HostConfig.self, from: data) else { return HostConfig() }
        return config
    }

    package func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
