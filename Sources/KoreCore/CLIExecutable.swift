import Foundation

/// Finds an agent CLI (`claude`, `codex`) and the environment to run it with.
///
/// Apps launched from Finder/Dock get a bare PATH (/usr/bin:/bin:...), so we ask the
/// user's login shell for its PATH once per run. That picks up nvm, Homebrew, ~/.local/bin,
/// etc. An interactive login shell takes a second or two, so it starts at app launch
/// (`prepare()`), off the main thread, and only the first CLI start waits for what's left.
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

    public static func resolve(_ name: String, override: URL? = nil) async throws -> Launch {
        let env = await environment()
        if let override { return Launch(url: override, environment: env) }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + [
            "\(home)/.claude/local", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
        ]
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return Launch(url: URL(fileURLWithPath: path), environment: env)
            }
        }
        throw Failure.notFound(name: name, searched: dirs)
    }

    /// Variables that would make a CLI authenticate some other way than its own login
    /// (`claude auth login` / `codex login`). Stripped so we always use that login.
    static let foreignAuthVariables = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY",
    ]

    /// Set when Kore itself is launched from inside Claude Code (e.g. its VS Code extension);
    /// passed on, they'd record Kore's sessions as that host's.
    static let inheritedHostVariables = ["CLAUDE_CODE_ENTRYPOINT", "CLAUDECODE"]

    /// Starts reading the login shell's PATH, once per run. Called at app launch.
    public static func prepare() { _ = loading }

    /// Process environment with PATH taken from the login shell. Read once; callers wait
    /// for it without holding a thread.
    public static func environment() async -> [String: String] { await loading.value }

    private static let loading = Task.detached(priority: .userInitiated) { () -> [String: String] in
        var env = ProcessInfo.processInfo.environment
        if let path = loginShellPATH() { env["PATH"] = path }
        for name in foreignAuthVariables + inheritedHostVariables { env[name] = nil }
        return env
    }

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

        // A broken rc file shouldn't hang app launch.
        let pid = process.processIdentifier
        let killer = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)

        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        killer.cancel()
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }
}
