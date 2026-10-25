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
        if override == nil, CLILocator.known.contains(name) { return try await locateKnown(name) }
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

    // MARK: the claude and codex CLIs

    /// The places `CLILocator` looks in; a storyline host's own tree in place of the Mac's
    /// (`look(in:)`).
    package static let places = HostSetting<CLILocator.Places?>(nil)

    /// Looks in `custom` from now on (nil: the Mac's own places), forgetting what was found.
    package static func look(in custom: CLILocator.Places?) {
        places.value = custom
        winners.set([:])
        checks.set([:])
    }

    /// Each CLI's binary that answered, this run, with where it came from.
    private static let winners = Locked<[String: CLILocator.Candidate]>([:])
    /// Each path's `--version` check, run once and shared by everyone waiting on it.
    private static let checks = Locked<[String: Task<Bool, Never>]>([:])

    /// A known CLI by the fixed list, the first that answers. Before this run's shell answers,
    /// only Locate…'s pick and last run's PATH are tried, as for any other program.
    private static func locateKnown(_ name: String) async throws -> Launch {
        if let won = winners.value[name], FileManager.default.isExecutableFile(atPath: won.url.path) {
            let env: [String: String]
            if let shell = shellResult.value { env = shell } else if won.source == "chosen" || won.source == "path", let cached = cachedEnvironment {
                env = cached
            } else { env = await environment() }
            return launch(won, env)
        }
        if places.value == nil, shellResult.value == nil, let cached = cachedEnvironment {
            let early = candidates(name, env: cached).filter { $0.source == "chosen" || $0.source == "path" }
            if let won = await firstAnswering(early, env: cached) { return launch(record(name, won), cached) }
        }
        let env = await environment()
        let list = candidates(name, env: env)
        if let won = await firstAnswering(list, env: env) { return launch(record(name, won), env) }
        log.write("cli-missing", ["cli": name, "tried": String(list.count)])
        throw Failure.notFound(name: name, searched: searchPath(env, usualFolders: true))
    }

    /// The binary Kore would run for a known CLI (`claude`, `codex`), or nil when none on the list
    /// answers. Stand-ins don't count: this is the Mac's own (`--locate-cli`, after an install).
    public static func located(_ name: String) async -> URL? {
        guard CLILocator.known.contains(name) else { return nil }
        return try? await locateKnown(name).url
    }

    private static func candidates(_ name: String, env: [String: String]) -> [CLILocator.Candidate] {
        if let custom = places.value { return CLILocator.candidates(name, in: custom) }
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return CLILocator.candidates(
            name, in: CLILocator.Places(home: FileManager.default.homeDirectoryForCurrentUser, path: path, chosen: chosen(name)))
    }

    private static func firstAnswering(_ list: [CLILocator.Candidate], env: [String: String]) async -> CLILocator.Candidate? {
        for candidate in list where await answers(candidate, env: env) { return candidate }
        return nil
    }

    private static func record(_ name: String, _ won: CLILocator.Candidate) -> CLILocator.Candidate {
        winners.withLock { $0[name] = won }
        log.write("cli-found", ["cli": name, "source": won.source])
        return won
    }

    /// The launch for a candidate: a bin folder's own tools (an npm install's `node`) on PATH,
    /// after the shell's.
    private static func launch(_ won: CLILocator.Candidate, _ env: [String: String]) -> Launch {
        guard won.inBinFolder else { return Launch(url: won.url, environment: env) }
        var env = env
        let dir = won.url.deletingLastPathComponent().path
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        if !path.contains(dir) { env["PATH"] = (path + [dir]).joined(separator: ":") }
        return Launch(url: won.url, environment: env)
    }

    /// Its `--version` answers (exits 0) within 3 s. Each path is asked once a run, off the main
    /// thread; a second caller waits on the first's answer.
    private static func answers(_ candidate: CLILocator.Candidate, env: [String: String]) async -> Bool {
        let environment = launch(candidate, env).environment
        let url = candidate.url
        let check = checks.withLock { checks -> Task<Bool, Never> in
            if let running = checks[url.path] { return running }
            // On a dispatch thread: the check waits up to 3 s, not on Swift's few shared ones.
            let task = Task.detached(priority: .userInitiated) {
                await withCheckedContinuation { done in
                    DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: versionAnswers(url, environment: environment)) }
                }
            }
            checks[url.path] = task
            return task
        }
        return await check.value
    }

    private static func versionAnswers(_ url: URL, environment: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return false }
        let pid = process.processIdentifier
        ChildReaper.shared.watch(pid)
        defer { ChildReaper.shared.forget(pid) }
        guard ended.wait(timeout: .now() + 3) == .success else {
            kill(pid, SIGKILL)
            process.waitUntilExit()
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    /// The binary picked with Locate…, kept across runs.
    public static func chosen(_ name: String) -> URL? {
        UserDefaults.standard.string(forKey: chosenKey(name)).map { URL(fileURLWithPath: $0) }
    }

    /// Remembers (or, with nil, forgets) Locate…'s pick, and looks again from scratch.
    public static func choose(_ name: String, _ url: URL?) {
        if let url { UserDefaults.standard.set(url.path, forKey: chosenKey(name)) } else {
            UserDefaults.standard.removeObject(forKey: chosenKey(name))
        }
        invalidate()
    }

    private static func chosenKey(_ name: String) -> String { "cliChosen." + name }

    /// Forgets every answer: the winners, the `--version` checks and this run's shell PATH (read
    /// again in the background), so a CLI installed since is found with no restart.
    public static func invalidate() {
        winners.set([:])
        checks.set([:])
        guard places.value == nil else { return }
        shellResult.set(nil)
        loading.set(Task.detached(priority: .userInitiated) { readShell() })
    }

    private static let log = KoreLog.named("cli")

    /// `--locate-cli claude|codex`, before the app starts: prints the binary Kore would run and
    /// exits 0, or exits 1 when there is none (2: not a CLI it knows). Nil for any other launch.
    public static func headless(_ arguments: [String]) -> Int32? {
        guard let flag = arguments.firstIndex(of: "--locate-cli") else { return nil }
        let name = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        guard CLILocator.known.contains(name) else {
            FileHandle.standardError.write(Data("usage: --locate-cli claude|codex\n".utf8))
            return 2
        }
        let answer = Locked<URL?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            answer.set(await located(name))
            done.signal()
        }
        done.wait()
        guard let url = answer.value else { return 1 }
        FileHandle.standardOutput.write(Data((url.path + "\n").utf8))
        return 0
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

    /// Set when Kore itself is launched from inside the claude CLI (its VS Code extension, or a
    /// chat that opened Kore): passed on, they'd make every CLI a child of that session, with
    /// its effort, its session id and its messaging token (a credential).
    static let inheritedHostVariables = [
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT",
    ]
    /// The host session's messaging socket and token, by prefix.
    static let inheritedHostPrefix = "CLAUDE_CODE_MESSAGING_"
    /// Names a person may set themselves: stripped only when a claude CLI session set them
    /// (`CLAUDECODE` is in the environment).
    static let inheritedHostGeneric = ["GIT_EDITOR", "COREPACK_ENABLE_AUTO_PIN"]

    /// `env` without what a claude CLI session Kore was started from left in it: what a CLI or
    /// a terminal Kore starts gets, as if Kore had been opened from the Dock.
    public static func withoutHostSession(_ env: [String: String]) -> [String: String] {
        var env = env
        let hosted = env["CLAUDECODE"] != nil
        for name in env.keys
        where inheritedHostVariables.contains(name) || name.hasPrefix(inheritedHostPrefix) || (hosted && inheritedHostGeneric.contains(name)) {
            env[name] = nil
        }
        return env
    }

    /// Starts reading the login shell's PATH, once per run, then finds the claude and codex CLIs in
    /// the background, so a first chat doesn't wait on their checks. Called at app launch.
    public static func prepare() {
        let shell = loading.value
        Task.detached(priority: .utility) {
            _ = await shell.value
            for name in CLILocator.known.sorted() { _ = try? await locateKnown(name) }
        }
    }

    /// Process environment with PATH taken from the login shell. Read once; callers wait
    /// for it without holding a thread.
    public static func environment() async -> [String: String] { await loading.value.value }

    private static let loading = Locked(Task.detached(priority: .userInitiated) { readShell() })

    private static func readShell() -> [String: String] {
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
        var env = withoutHostSession(ProcessInfo.processInfo.environment)
        if let path { env["PATH"] = path }
        for name in env.keys where isForeignAuth(name) { env[name] = nil }
        // A login folder inherited from a chat Kore was started in: main means the CLI's default.
        for name in CLIProfiles.variables.values where env[name].map(CLIProfiles.isLoginFolder) == true { env[name] = nil }
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
        // nothing waits on the shell, so a slow one (a busy machine) gets longer. The shell is
        // its own process group: the whole group goes, whatever the rc files started in it,
        // and Kore ending first (a quick dev run) leaves nothing behind either.
        let pid = process.processIdentifier
        ChildReaper.shared.watch(pid)
        // Read until both markers are in, not to the end: a daemon the rc files start can keep
        // the shell's stdout open long after it has printed.
        let answer = PathAnswer(marker: marker)
        let killer = DispatchWorkItem {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            answer.finish()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + (cachedEnvironment == nil ? 5 : 10), execute: killer)

        let reading = out.fileHandleForReading
        reading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty || answer.take(data) { answer.finish() }
        }
        answer.wait()
        reading.readabilityHandler = nil
        killer.cancel()
        // Done with it: whatever it left running in its group goes now.
        kill(-pid, SIGKILL)
        process.waitUntilExit()
        ChildReaper.shared.forget(pid)
        let parts = answer.output.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }
}

/// The login shell's output as it arrives, until it holds the PATH between two markers or the
/// shell's stdout closes.
private final class PathAnswer: @unchecked Sendable {
    private let marker: String
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()
    private var finished = false

    init(marker: String) { self.marker = marker }

    var output: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

    /// Takes a chunk; true once both markers are in.
    func take(_ chunk: Data) -> Bool {
        lock.withLock {
            data.append(chunk)
            return String(decoding: data, as: UTF8.self).components(separatedBy: marker).count >= 3
        }
    }

    func finish() {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        if first { done.signal() }
    }

    func wait() { done.wait() }
}

/// A value read and written from any thread.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) { lock.withLock { stored = value } }

    /// Reads and changes it in one step.
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}
