import Foundation

/// Installs the claude or codex CLI for a person who clicked Install: the CLI's official installer
/// by default, or Homebrew or npm when the Mac has them. It runs as a child process with the
/// login shell's PATH, off the main thread, and stops when its task is cancelled. Only its
/// stages and a parsed reason come out: its own output stays inside. `kore setup` runs the same
/// commands (`command(_:for:)`).
public enum CLIInstaller {
    public enum Method: String, CaseIterable, Sendable {
        case official, homebrew, npm

        /// Its name in a list of ways to install.
        public var title: String {
            switch self {
            case .official: "Official installer"
            case .homebrew: "Homebrew"
            case .npm: "npm"
            }
        }

        /// The program the Mac must have for it; nil: nothing beyond curl and a shell.
        public var needs: String? {
            switch self {
            case .official: nil
            case .homebrew: "brew"
            case .npm: "npm"
            }
        }
    }

    /// The command for `cli` (`claude`, `codex`) by `method`; nil for a CLI it doesn't know.
    public static func command(_ method: Method, for cli: String) -> String? {
        switch (cli, method) {
        case ("claude", .official): "curl -fsSL https://claude.ai/install.sh | bash"
        case ("codex", .official): "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        case ("claude", .homebrew): "brew install --cask claude-code"
        case ("codex", .homebrew): "brew install --cask codex"
        case ("claude", .npm): "npm i -g @anthropic-ai/claude-code"
        case ("codex", .npm): "npm i -g @openai/codex"
        default: nil
        }
    }

    /// The ways this Mac can install: the official installer always, then those whose program
    /// `has` finds.
    public static func methods(has: (String) -> Bool) -> [Method] {
        Method.allCases.filter { $0.needs.map(has) ?? true }
    }

    /// The ways this Mac can install, looking for brew and npm on the login shell's PATH and in
    /// Homebrew's folders.
    public static func methods() async -> [Method] {
        let env = await CLIExecutable.environment()
        let folders = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return methods { program in folders.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + program) } }
    }

    // MARK: Progress

    public enum Stage: String, Sendable, CaseIterable {
        case starting = "Starting"
        case downloading = "Downloading"
        case verifying = "Verifying"
        case installing = "Installing"
        case finishing = "Finishing"
    }

    public struct Progress: Equatable, Sendable {
        public var stage: Stage = .starting
        /// Megabytes downloaded and in all, when the installer says.
        public var megabytes: (done: Double, total: Double)?
        /// Done, 0 to 1, when the installer gives a percentage.
        public var percent: Double?

        public init(stage: Stage = .starting, megabytes: (done: Double, total: Double)? = nil, percent: Double? = nil) {
            self.stage = stage
            self.megabytes = megabytes
            self.percent = percent
        }

        public static func == (a: Progress, b: Progress) -> Bool {
            a.stage == b.stage && a.megabytes?.done == b.megabytes?.done && a.megabytes?.total == b.megabytes?.total
                && a.percent == b.percent
        }

        /// The stage line: "Downloading · 18 of 29 MB" when the size is known, else the stage.
        public var text: String {
            guard stage == .downloading, let mb = megabytes else { return stage.rawValue }
            return "\(stage.rawValue) · \(Self.number(mb.done)) of \(Self.number(mb.total)) MB"
        }

        /// How far along, 0 to 1: the bytes or percentage when known, else the stage's place.
        public var fraction: Double {
            if stage == .downloading, let mb = megabytes, mb.total > 0 { return 0.1 + 0.6 * min(1, mb.done / mb.total) }
            if stage == .downloading, let percent { return 0.1 + 0.6 * percent }
            switch stage {
            case .starting: return 0.06
            case .downloading: return 0.3
            case .verifying: return 0.72
            case .installing: return 0.82
            case .finishing: return 0.94
            }
        }

        private static func number(_ value: Double) -> String {
            value >= 10 || value == value.rounded() ? String(Int(value.rounded())) : String(format: "%.1f", value)
        }
    }

    /// The progress after one line of the installer's output: a stage word moves it on (never
    /// back), and a size ("18 of 29 MB", "18.2MB/29.0MB") or a percentage fills it in.
    public static func progress(after line: String, _ progress: Progress) -> Progress {
        var next = progress
        let lower = line.lowercased()
        let words: [(Stage, [String])] = [
            (.downloading, ["download", "fetching", "fetch "]),
            (.verifying, ["verif", "checksum", "sha256"]),
            (.installing, ["install", "extract", "unpack", "added ", "linking", "moving"]),
            (.finishing, ["success", "complete", "done", "installed"]),
        ]
        for (stage, keys) in words.reversed() where keys.contains(where: lower.contains) {
            if Stage.allCases.firstIndex(of: stage)! > Stage.allCases.firstIndex(of: next.stage)! { next.stage = stage }
            break
        }
        if let mb = megabytes(in: lower) {
            next.megabytes = mb
            if next.stage == .starting { next.stage = .downloading }
        } else if let percent = percent(in: lower), next.stage == .downloading || next.stage == .starting {
            next.percent = percent
            next.stage = .downloading
        }
        return next
    }

    private static func megabytes(in line: String) -> (done: Double, total: Double)? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(?:mb|mib|m)?\s*(?:of|/)\s*(\d+(?:\.\d+)?)\s*(?:mb|mib|m)\b"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        let numbers = line[match].split { !($0.isNumber || $0 == ".") }.compactMap { Double($0) }
        guard numbers.count >= 2, numbers[1] > 0, numbers[0] <= numbers[1] else { return nil }
        return (numbers[0], numbers[1])
    }

    private static func percent(in line: String) -> Double? {
        guard let match = line.range(of: #"(\d{1,3}(?:\.\d+)?)\s*%"#, options: .regularExpression),
            let value = Double(line[match].dropLast().trimmingCharacters(in: .whitespaces)), value <= 100
        else { return nil }
        return value / 100
    }

    // MARK: Failure

    /// Why an install failed, as one plain reason: never the installer's words.
    public enum Reason: String, Error, Sendable {
        case offline, permission, other

        public var text: String {
            switch self {
            case .offline: "No internet connection."
            case .permission: "No permission to write where it installs."
            case .other: "The installer stopped with an error."
            }
        }
    }

    /// The reason in the installer's output (kept private) and exit status.
    public static func reason(output: String, status: Int32) -> Reason {
        let text = output.lowercased()
        let offline = [
            "could not resolve host", "couldn't resolve host", "failed to connect", "network is unreachable", "no route to host",
            "connection timed out", "operation timed out", "connection refused", "curl: (6)", "curl: (7)", "curl: (28)",
            "enotfound", "eai_again", "getaddrinfo", "econnrefused", "etimedout", "offline", "internet connection",
        ]
        if offline.contains(where: text.contains) { return .offline }
        let permission = [
            "permission denied", "eacces", "eperm", "operation not permitted", "read-only file system", "not writable",
            "must be run as root", "sudo",
        ]
        if permission.contains(where: text.contains) || status == 126 { return .permission }
        return .other
    }

    // MARK: Running

    /// What a test or storyline runs in place of the real command: a script given the CLI's name
    /// as `$1`, in an environment of its own (a temp HOME). `KORE_CLI_INSTALLER=<script>` sets
    /// it for a whole run of the app. Nil in Kore: the real installers run.
    package struct StandIn: Sendable {
        package var script: URL
        package var environment: [String: String]

        package init(script: URL, environment: [String: String] = [:]) {
            self.script = script
            self.environment = environment
        }
    }

    package static let standIn = HostSetting<StandIn?>(
        ProcessInfo.processInfo.environment["KORE_CLI_INSTALLER"].map { StandIn(script: URL(fileURLWithPath: $0)) })

    /// Runs the install, telling `progress` (on any thread) as it moves. Throws a `Reason` when
    /// it fails, and `CancellationError` when cancelled, after the installer and everything it
    /// started have ended.
    public static func install(
        _ cli: String, method: Method, progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        guard let command = command(method, for: cli) else { throw Reason.other }
        var env = await CLIExecutable.environment()
        let arguments: [String]
        if let fake = standIn.value {
            env.merge(fake.environment) { $1 }
            arguments = [fake.script.path, cli]
        } else {
            arguments = ["-o", "pipefail", "-c", command]
        }
        let run = InstallRun(arguments: arguments, environment: env, progress: progress)
        let log = KoreLog.named("cli")
        log.write("install-start", ["cli": cli, "method": method.rawValue])
        let outcome: Result<Void, any Error> = await withTaskCancellationHandler {
            await run.wait()
        } onCancel: {
            run.cancel()
        }
        switch outcome {
        case .success:
            log.write("install-done", ["cli": cli, "method": method.rawValue])
        case .failure(let error):
            let reason = (error as? Reason)?.rawValue ?? "cancelled"
            log.write("install-failed", ["cli": cli, "method": method.rawValue, "reason": reason])
            throw error
        }
    }
}

/// One installer process: `/bin/bash` as the leader of its own process group (so Cancel ends
/// the curl and the shell it pipes into too), its output read line by line into stages and
/// kept, last 64 KB, for the reason.
private final class InstallRun: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var progress = CLIInstaller.Progress()
    private var cancelled = false
    private var pid: pid_t = 0
    private let tell: @Sendable (CLIInstaller.Progress) -> Void
    private let arguments: [String]
    private let environment: [String: String]

    init(arguments: [String], environment: [String: String], progress: @escaping @Sendable (CLIInstaller.Progress) -> Void) {
        self.arguments = arguments
        self.environment = environment
        tell = progress
    }

    func wait() async -> Result<Void, any Error> {
        await withCheckedContinuation { (done: CheckedContinuation<Result<Void, any Error>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: self.run()) }
        }
    }

    func cancel() {
        let pid: pid_t = lock.withLock {
            cancelled = true
            return pid
        }
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        // One that ignores the ask goes anyway.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(-pid, SIGKILL) }
    }

    private func run() -> Result<Void, any Error> {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return .failure(CLIInstaller.Reason.other) }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Signals as a fresh process has them, whatever this thread blocks or ignores.
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        let argv = (["/bin/bash"] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var child: pid_t = 0
        let spawned: Int32 = lock.withLock {
            guard !cancelled else { return ECANCELED }
            let result = posix_spawn(&child, "/bin/bash", &actions, &attributes, argv, envp)
            if result == 0 { pid = child }
            return result
        }
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            return .failure(spawned == ECANCELED ? CancellationError() : CLIInstaller.Reason.other)
        }
        ChildReaper.shared.watch(child)
        defer { ChildReaper.shared.forget(child) }
        var splitter = LineSplitter()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        while true {
            let count = read(readEnd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            // curl's meter rewrites one line with \r: each rewrite counts as a line.
            let chunk = Data(buffer[0..<count].map { $0 == 13 ? 10 : $0 })
            for line in splitter.feed(chunk) { take(line) }
        }
        close(readEnd)
        if let rest = splitter.finish() { take(rest) }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        // Whatever it left running in its group goes with it.
        kill(-child, SIGKILL)
        let (wasCancelled, said) = lock.withLock { (cancelled, String(decoding: output, as: UTF8.self)) }
        if wasCancelled { return .failure(CancellationError()) }
        let exited = status & 0x7f == 0
        let code = (status >> 8) & 0xff
        guard exited, code == 0 else { return .failure(CLIInstaller.reason(output: said, status: exited ? code : -1)) }
        return .success(())
    }

    private func take(_ line: Data) {
        let text = String(decoding: line, as: UTF8.self)
        let changed: CLIInstaller.Progress? = lock.withLock {
            output.append(line)
            output.append(10)
            if output.count > 64 << 10 { output = output.suffix(64 << 10) }
            let next = CLIInstaller.progress(after: text, progress)
            guard next != progress else { return nil }
            progress = next
            return next
        }
        if let changed { tell(changed) }
    }
}
