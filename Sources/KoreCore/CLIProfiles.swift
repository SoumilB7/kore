import Foundation
import SQLite3

/// A CLI's extra logins. Each one is a config folder of its own (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`)
/// under Kore's, where the CLI keeps that login (Claude in a Keychain item named for the folder,
/// Codex in its `auth.json`) and links everything else to the main folder: chats, settings,
/// skills and instructions stay one. The active one's folder goes into every CLI Kore starts;
/// main is the folder the CLI uses by itself. Kore never reads a login, only picks the folder.
public enum CLIProfiles {
    public struct Profile: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        /// Who it's signed in as, the last time Kore read it.
        public var email: String?
        /// The organisation (or Codex's plan) it works in, with the email telling two logins
        /// apart: "" for none, nil when not read yet.
        public var workspace: String?
    }

    struct Saved: Codable {
        var active: [String: String] = [:]
        var added: [String: [Profile]] = [:]
        var mainEmail: [String: String] = [:]
        /// Optional, so a list saved before it reads.
        var mainWorkspace: [String: String]?
    }

    static let variables = ["claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"]
    /// The main folder's entries that stay each login's own.
    static let own: [String: Set<String>] = [
        "claude": [".claude.json", ".claude.json.lock", ".credentials.json", "backups", "config.json", "mcp-needs-auth-cache.json", "statsig"],
        "codex": ["auth.json", "installation_id", "ipc", "log", "models_cache.json", "sqlite", "tmp", ".tmp"],
    ]

    /// Kore's folder for them, and the CLIs' main folders by name; a test's own.
    package static let root = HostSetting<URL?>(nil)
    package static let mains = HostSetting<[String: URL]>([:])

    /// Reads the list again (after `root` changes).
    package static func reload() { state.set(nil) }

    static var directory: URL {
        if let root = root.value { return root }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Kore/accounts")
    }

    private static let state = Locked<Saved?>(nil)

    private static var saved: Saved {
        if let saved = state.value { return saved }
        let read = (try? Data(contentsOf: directory.appendingPathComponent("accounts.json")))
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        state.set(read)
        return read
    }

    private static func change(_ edit: (inout Saved) -> Void) {
        var value = saved
        edit(&value)
        state.set(value)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: directory.appendingPathComponent("accounts.json"), options: .atomic)
        }
    }

    public static func supports(_ cli: String) -> Bool { variables[cli] != nil }

    /// The added logins, oldest first.
    public static func added(_ cli: String) -> [Profile] { saved.added[cli] ?? [] }
    /// The active login: nil is main.
    public static func active(_ cli: String) -> String? { saved.active[cli] }
    public static func mainEmail(_ cli: String) -> String? { saved.mainEmail[cli] }
    public static func mainWorkspace(_ cli: String) -> String? { saved.mainWorkspace?[cli] }

    /// The CLI's main folder: its variable as Kore was started with it, else its default.
    public static func mainFolder(_ cli: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let main = mains.value[cli] { return main }
        if let name = variables[cli], let dir = environment[name], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(cli == "codex" ? ".codex" : ".claude", isDirectory: true)
    }

    public static func folder(_ cli: String, _ id: String) -> URL {
        directory.appendingPathComponent(cli).appendingPathComponent(id, isDirectory: true)
    }

    public struct Pin: Sendable {
        public let cli: String
        /// nil: main.
        public let id: String?
        public init(cli: String, id: String?) { (self.cli, self.id) = (cli, id) }
    }

    /// A login's folder for the CLIs one task starts: an added login's sign-in, before it's
    /// active, or a sign-in, read or sign-out of one that isn't.
    @TaskLocal public static var pinned: Pin?

    /// What a CLI starts with for the active (or pinned) login: nothing for main.
    public static func overrides(_ cli: String) -> [String: String] {
        guard let name = variables[cli] else { return [:] }
        if let pin = pinned, pin.cli == cli { return pin.id.map { [name: folder(cli, $0).path] } ?? [:] }
        guard let id = saved.active[cli] else { return [:] }
        return [name: folder(cli, id).path]
    }

    enum LaunchFailure: Error, CustomStringConvertible {
        case sharedFilesUnavailable
        var description: String {
            "Claude's shared chat history or settings aren't available for this login. Try switching accounts again."
        }
    }

    /// Fixes older/partially created logins before a resumed process reads its history.
    /// Healthy launches only check paths; directory enumeration happens only on repair.
    /// The sign-in task's pin takes precedence over the active login, including a pinned main.
    static func repairForLaunch(_ cli: String) throws {
        guard cli == "claude" else { return }
        let id: String?
        if let pin = pinned, pin.cli == cli { id = pin.id } else { id = saved.active[cli] }
        guard let id else { return }
        let files = FileManager.default
        let main = mainFolder(cli)
        let dir = folder(cli, id)
        let required = ["projects", "settings.json"].filter { name in
            !files.fileExists(atPath: dir.appendingPathComponent(name).path)
                && files.fileExists(atPath: main.appendingPathComponent(name).path)
        }
        guard !required.isEmpty else { return }
        // `link` never replaces an existing file/directory, nor any login's auth files.
        link(cli, id)
        guard required.allSatisfy({ files.fileExists(atPath: dir.appendingPathComponent($0).path) }) else {
            throw LaunchFailure.sharedFilesUnavailable
        }
    }

    /// Kore's environment with `id`'s folder (nil: main's) for `cli`, for reading that login's
    /// files whichever is active.
    public static func environment(_ cli: String, login id: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let id, let name = variables[cli] { env[name] = folder(cli, id).path }
        return env
    }

    /// Kore's environment as the active logins change it, for reading their files.
    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for cli in variables.keys { env.merge(overrides(cli)) { $1 } }
        return env
    }

    /// A new login's folder, linked to main, signed out: not listed until `adopt`.
    public static func prepare(_ cli: String) throws -> String {
        let id = UUID().uuidString.lowercased().prefix(8).description
        let dir = folder(cli, id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if cli == "claude" { seedClaudeConfig(in: dir) }
        if cli == "codex" { seedCodexState(in: dir) }
        link(cli, id)
        return id
    }

    /// A prepared login, signed in: listed, and active from now on.
    public static func adopt(_ cli: String, _ id: String, email: String?, workspace: String? = nil) {
        // A browser/Terminal login can replace its fresh config folder while signing in.
        // Re-establish missing shared entries after it finishes, before chats resume there.
        link(cli, id)
        change {
            $0.added[cli, default: []].append(Profile(id: id, email: email, workspace: workspace))
            $0.active[cli] = id
        }
    }

    /// Makes `id` (nil: main) the login every CLI from now on starts with, its links brought up
    /// to date with main's folder.
    public static func activate(_ cli: String, _ id: String?) {
        if let id { link(cli, id) }
        change { $0.active[cli] = id }
    }

    /// Forgets a login and deletes its folder (the caller signs it out first); main comes back if
    /// it was active.
    public static func remove(_ cli: String, _ id: String) {
        try? FileManager.default.removeItem(at: folder(cli, id))
        change {
            $0.added[cli]?.removeAll { $0.id == id }
            if $0.active[cli] == id { $0.active[cli] = nil }
        }
    }

    /// Records who the active login is; whether that changed the list.
    @discardableResult
    public static func note(_ cli: String, email: String?, workspace: String? = nil) -> Bool {
        note(cli, login: saved.active[cli], email: email, workspace: workspace)
    }

    /// Records who `id`'s login (nil: main) is; a nil workspace keeps the one known for the same
    /// email. Whether that changed the list.
    @discardableResult
    public static func note(_ cli: String, login id: String?, email: String?, workspace: String?) -> Bool {
        guard let email, !email.isEmpty else { return false }
        if let id {
            guard let index = saved.added[cli]?.firstIndex(where: { $0.id == id }), let profile = saved.added[cli]?[index] else { return false }
            let kept = workspace ?? (profile.email == email ? profile.workspace : nil)
            guard profile.email != email || profile.workspace != kept else { return false }
            change { $0.added[cli]?[index] = Profile(id: id, email: email, workspace: kept) }
        } else {
            let known = saved.mainWorkspace?[cli]
            let kept = workspace ?? (saved.mainEmail[cli] == email ? known : nil)
            guard saved.mainEmail[cli] != email || known != kept else { return false }
            change {
                $0.mainEmail[cli] = email
                var workspaces = $0.mainWorkspace ?? [:]
                workspaces[cli] = kept
                $0.mainWorkspace = workspaces
            }
        }
        return true
    }

    /// Links each entry of main's folder the login doesn't keep for itself, where it has none:
    /// what main gained since, too. A link the CLI replaced with a file of its own stays.
    static func link(_ cli: String, _ id: String) {
        let files = FileManager.default
        let main = mainFolder(cli)
        let dir = folder(cli, id)
        let skip = own[cli] ?? []
        guard let names = try? files.contentsOfDirectory(atPath: main.path) else { return }
        for name in skip where (try? files.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(name).path)) != nil {
            // Linked by an older Kore: the login's own from now on.
            try? files.removeItem(at: dir.appendingPathComponent(name))
        }
        for name in names where !skip.contains(name) && !name.hasSuffix(".sqlite") && !name.contains(".sqlite-") && !name.hasPrefix("logs_") {
            let target = dir.appendingPathComponent(name)
            guard (try? files.destinationOfSymbolicLink(atPath: target.path)) == nil, !files.fileExists(atPath: target.path) else { continue }
            try? files.createSymbolicLink(at: target, withDestinationURL: main.appendingPathComponent(name))
        }
    }

    /// Deletes the folders of logins no longer listed (a sign-in Kore quit during, or a CLI that
    /// wrote on after its folder went). At launch, before any sign-in.
    public static func sweep() {
        let files = FileManager.default
        // Only against a list read whole: never on a file that didn't parse.
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("accounts.json")),
            let read = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        for cli in variables.keys {
            let listed = Set((read.added[cli] ?? []).map(\.id))
            let base = directory.appendingPathComponent(cli)
            for name in (try? files.contentsOfDirectory(atPath: base.path)) ?? [] where !listed.contains(name) {
                try? files.removeItem(at: base.appendingPathComponent(name))
            }
        }
    }

    /// Codex lists its threads from a database it builds from every rollout the first time it
    /// runs in a folder (20 s and more): a new login starts with a copy of main's, by SQLite's
    /// own backup, so a sign-in starts at once and the threads are there.
    private static func seedCodexState(in dir: URL) {
        let main = mainFolder("codex")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: main.path)) ?? []
        for name in names where name.hasPrefix("state_") && name.hasSuffix(".sqlite") {
            var source: OpaquePointer?
            var target: OpaquePointer?
            defer {
                sqlite3_close(source)
                sqlite3_close(target)
            }
            guard sqlite3_open_v2(main.appendingPathComponent(name).path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                sqlite3_open(dir.appendingPathComponent(name).path, &target) == SQLITE_OK,
                let backup = sqlite3_backup_init(target, "main", source, "main")
            else { continue }
            sqlite3_backup_step(backup, -1)
            sqlite3_backup_finish(backup)
        }
    }

    /// Claude's MCP servers and other user-wide choices live in `.claude.json` beside the login:
    /// a new login starts with main's, without its account.
    private static func seedClaudeConfig(in dir: URL) {
        let main = mainFolder("claude")
        let file = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { _ in main.appendingPathComponent(".claude.json") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let kept = object.filter { ["mcpServers", "hasCompletedOnboarding", "theme", "projects"].contains($0.key) }
        guard let out = try? JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted]) else { return }
        try? out.write(to: dir.appendingPathComponent(".claude.json"), options: .atomic)
    }
}
