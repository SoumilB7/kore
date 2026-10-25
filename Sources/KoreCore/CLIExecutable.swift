import Foundation

/// Finds an agent CLI (`claude`, `codex`) and the environment to run it with.
///
/// Apps launched from Finder/Dock get a bare PATH (/usr/bin:/bin:...), so we ask the
/// user's login shell for its PATH once per run. That picks up nvm, Homebrew, ~/.local/bin,
/// etc. An interactive login shell takes a second or two, so it starts at app launch
/// (`prepare()`), off the main thread. Until it answers, a CLI starts with the PATH the last
/// run's shell gave, when the CLI is still found there; otherwise it waits for this run's.
public enum CLIExecutable {
    public struct Launch: Sendable {
        public let url: URL
        public let environment: [String: String]
    }

    public enum Failure: Error, CustomStringConvertible {
        case notFound(name: String, searched: [String])

        public var description: String {
            switch self {
            case .notFound(let name, let dirs):
                "\(name) CLI not found. Install it or set an explicit path. Searched: \(dirs.joined(separator: ":"))"
            }
        }
    }

    /// What a storyline host (phase 12) runs in place of a CLI, by name (`claude`, `codex`).
    package struct StandIn: Sendable {
        /// Run this instead (`kore-fake-cli`); nil runs the real CLI.
        package var executable: URL?
        /// Added to the CLI's environment: the cassette to play, or live mode's scratch `CODEX_HOME`.
        package var environment: [String: String]

        package init(executable: URL? = nil, environment: [String: String] = [:]) {
            self.executable = executable
            self.environment = environment
        }
    }

    /// Empty in Kore. An explicit `override` (kore-cli's) wins over a stand-in.
    package static let standIns = HostSetting<[String: StandIn]>([:])

    public static func resolve(_ name: String, override: URL? = nil) async throws -> Launch {
        let standIn = override == nil ? standIns.value[name] : nil
        let launch = try await locate(name, override: override ?? standIn?.executable)
        // The active login's folder (`CLIProfiles`); a storyline host's stand-in sets its own.
        guard let standIn else {
            // Explicit executable overrides are isolated tools/tests with their own environment.
            if override == nil { try CLIProfiles.repairForLaunch(name) }
            return Launch(url: launch.url, environment: launch.environment.merging(CLIProfiles.overrides(name)) { $1 })
        }
        return Launch(url: launch.url, environment: launch.environment.merging(standIn.environment) { $1 })
    }

    private static func locate(_ name: String, override: URL?) async throws -> Launch {
        // Last run's PATH counts only if the CLI is in it, not just in the usual folders below:
        // a CLI found there with a stale PATH would run its own tools without theirs.
        if shellResult.value == nil, let cached = cachedEnvironment,
            let launch = find(name, override, in: cached, usualFolders: false)
        {
            return launch
        }
        let env = await environment()
        if let override { return Launch(url: override, environment: env) }
        if let launch = find(name, nil, in: env, usualFolders: true) { return launch }
        throw Failure.notFound(name: name, searched: searchPath(env, usualFolders: true))
    }

    private static func find(_ name: String, _ override: URL?, in env: [String: String], usualFolders: Bool) -> Launch? {
        if let override {
            return FileManager.default.isExecutableFile(atPath: override.path) ? Launch(url: override, environment: env) : nil
        }
        for dir in searchPath(env, usualFolders: usualFolders) {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return Launch(url: URL(fileURLWithPath: path), environment: env)
            }
        }
        return nil
    }

    private static func searchPath(_ env: [String: String], usualFolders: Bool) -> [String] {
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        guard usualFolders else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path + ["\(home)/.claude/local", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// Variables a launch shell may carry that would make a CLI sign in some other way than its
    /// login (`claude auth login` / `codex login`) or its settings: a key or token, a base URL, a
    /// platform switch (every `CLAUDE_CODE_USE_*`, by prefix) and the platforms' own keys. They
    /// are stripped together, so a platform never runs half on (its switch gone, its key kept).
    /// A platform set up in Claude's settings keeps working: the CLI applies its settings' `env`
    /// over its environment after it starts, whatever Kore stripped. The variables that only
    /// say where things are (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `AWS_PROFILE`, `AWS_REGION`, the
    /// AWS and Google credential files) stay, so "credentials already in my environment" work.
    static let foreignAuthVariables = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_FOUNDRY_AUTH_TOKEN", "ANTHROPIC_AWS_API_KEY",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
    ]
    /// Every variable with this prefix is a Claude platform switch, stripped with the list above.
    static let foreignAuthPrefix = "CLAUDE_CODE_USE_"

    /// Whether a launch variable is stripped.
    static func isForeignAuth(_ name: String) -> Bool {
        name.hasPrefix(foreignAuthPrefix) || foreignAuthVariables.contains(name)
    }

    /// Set when Kore itself is launched from inside Claude Code (e.g. its VS Code extension);
    /// passed on, they'd record Kore's sessions as that host's.
    static let inheritedHostVariables = ["CLAUDE_CODE_ENTRYPOINT", "CLAUDECODE"]

    /// Starts reading the login shell's PATH, once per run. Called at app launch.
    public static func prepare() { _ = loading }

    /// Process environment with PATH taken from the login shell. Read once; callers wait
    /// for it without holding a thread.
    public static func environment() async -> [String: String] { await loading.value }

    private static let loading = Task.detached(priority: .userInitiated) { () -> [String: String] in
        let env: [String: String]
        if let path = loginShellPATH() {
            env = cleaned(path: path)
            UserDefaults.standard.set(path, forKey: cacheKey)
        } else {
            // Timed out or failed: last run's PATH stands in for this run's, and stays cached.
            env = cachedEnvironment ?? cleaned(path: nil)
        }
        shellResult.set(env)
        return env
    }

    /// The process environment with a CLI-ready PATH and without the variables above.
    private static func cleaned(path: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let path { env["PATH"] = path }
        for name in env.keys where isForeignAuth(name) || inheritedHostVariables.contains(name) { env[name] = nil }
        return env
    }

    /// This run's shell answer, once it's in: from then on every start uses it.
    private static let shellResult = Locked<[String: String]?>(nil)

    /// Last run's login-shell PATH. Only PATH is kept: the shell's environment can hold keys
    /// and tokens, and defaults are a plain plist. Dev builds share the app's defaults domain
    /// but keep their own key, so a terminal's PATH never becomes the app's.
    private static let cacheKey = Bundle.main.bundleURL.pathExtension == "app" ? "cliSearchPath" : "cliSearchPath.dev"
    private static let cachedEnvironment: [String: String]? = UserDefaults.standard.string(forKey: cacheKey)
        .map { cleaned(path: $0) }

    private static func loginShellPATH() -> String? {
        let marker = "__KORE_PATH__"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i as well as -l: nvm and friends are usually set up in .zshrc, not .zprofile.
        process.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // A broken rc file shouldn't hang app launch. With last run's PATH to start CLIs with,
        // nothing waits on the shell, so a slow one (a busy machine) gets longer.
        let pid = process.processIdentifier
        let killer = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + (cachedEnvironment == nil ? 5 : 10), execute: killer)

        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        killer.cancel()
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }
}

/// A value read and written from any thread.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) { lock.withLock { stored = value } }
}
