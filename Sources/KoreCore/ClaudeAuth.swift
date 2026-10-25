import Foundation

/// Auth is owned by the CLI: Kore never handles credentials. It asks the CLI who it is logged
/// in as, asks it to sign in (the CLI's own OAuth, in the browser) and to sign out.
public enum ClaudeAuth {
    public struct Status: Sendable, Equatable {
        public let loggedIn: Bool
        /// "claude.ai" (subscription), "api_key" (a Console login's key, or one from the env),
        /// "oauth_token" (a token from the env), "api_key_helper", "third_party", "none".
        public let authMethod: String?
        /// Where an API key comes from: "/login managed key" (a Console login),
        /// "ANTHROPIC_API_KEY", "apiKeyHelper".
        public let apiKeySource: String?
        /// "firstParty", "bedrock", "vertex", "foundry", …
        public let apiProvider: String?
        /// The one login managed settings allow ("claudeai", "console"); nil when any is.
        public let forcedLoginMethod: String?
        public let email: String?
        public let orgName: String?
        /// e.g. "max", "pro"
        public let subscriptionType: String?

        public init(_ json: JSONValue) {
            loggedIn = json["loggedIn"]?.bool ?? false
            authMethod = json["authMethod"]?.string
            apiKeySource = json["apiKeySource"]?.string
            apiProvider = json["apiProvider"]?.string
            forcedLoginMethod = json["forcedLoginMethod"]?.string
            email = json["email"]?.string
            orgName = json["orgName"]?.string
            subscriptionType = json["subscriptionType"]?.string
        }
    }

    /// Runs `claude auth status --json` with the same binary and environment sessions use.
    public static func status(executable: URL? = nil) async throws -> Status {
        Status(try await statusReply(executable: executable))
    }

    /// `claude auth status --json`'s answer, as it printed it.
    public static func statusReply(executable: URL? = nil) async throws -> JSONValue {
        let run = try await run(["auth", "status", "--json"], executable: executable)
        // Logged-out still prints JSON (loggedIn: false), so parse regardless of exit status.
        return try JSONValue.parse(run.out)
    }

    /// The file the CLI keeps its account in: `.claude.json` in `CLAUDE_CONFIG_DIR`, else in the
    /// home folder.
    public static func configFile(environment: [String: String] = CLIProfiles.environment) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// Who that file says is signed in: its `oauthAccount`, as canonical text, and nothing else
    /// of it; "" when it has none, nil when it isn't JSON. The CLI writes the file often, so a
    /// change to it only counts when this changes.
    public static func accountStamp(_ config: Data) -> String? {
        guard let json = try? JSONValue.parse(config) else { return nil }
        guard let account = json["oauthAccount"], account != .null else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(account)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// `claude auth logout`: global, it signs Terminal and VS Code out too and revokes the
    /// tokens. Throws the CLI's reason ("Logout failed: …") when it fails.
    public static func logout(executable: URL? = nil) async throws {
        let run = try await run(["auth", "logout"], executable: executable)
        guard run.status != 0 else { return }
        throw Failure.said(logoutReason(String(decoding: run.err, as: UTF8.self)) ?? "claude exited \(run.status)")
    }

    /// The reason in `claude auth logout`'s stderr: the text after "Logout failed:", else its
    /// first line; nil when it said nothing.
    static func logoutReason(_ stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let failed = lines.first(where: { $0.hasPrefix("Logout failed:") }) {
            let reason = failed.dropFirst("Logout failed:".count).trimmingCharacters(in: .whitespaces)
            return reason.isEmpty ? nil : reason
        }
        return lines.first
    }

    public enum Failure: LocalizedError {
        /// The CLI's own words.
        case said(String)

        public var errorDescription: String? {
            switch self {
            case .said(let words): words
            }
        }
    }

    /// The installed CLI's version ("2.1.293"), as its own transcripts record it.
    public static func version(executable: URL? = nil) async throws -> String {
        let run = try await run(["--version"], executable: executable)
        let text = String(decoding: run.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard run.status == 0, let version = text.split(separator: " ").first, version.first?.isNumber == true else {
            throw Failure.said(String(decoding: run.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(version)
    }

    private static func run(_ arguments: [String], executable: URL?) async throws -> (out: Data, err: Data, status: Int32) {
        let launch = try await CLIExecutable.resolve("claude", override: executable)
        return try await Task.detached {
            let process = Process()
            process.executableURL = launch.url
            process.arguments = arguments
            process.environment = launch.environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // Both pipes drained at once, so a full stderr can't stall the CLI.
            let errors = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let said = await errors.value
            process.waitUntilExit()
            return (output, said, process.terminationStatus)
        }.value
    }

    /// One sign-in, on a message-less `claude -p` held for it: `claude_authenticate`, then
    /// `claude_oauth_wait_for_completion`. Cancelling ends the process (the CLI has no request
    /// for it). The pasted-code path (`claude_oauth_callback`) isn't used: it would pass an
    /// authorization code through Kore.
    public actor Login {
        private let session: ClaudeSession

        /// Starts the CLI for the sign-in; nothing is asked of it yet.
        public static func start(executable: URL? = nil) async throws -> Login {
            Login(
                session: try await ClaudeSession.start(
                    .init(cwd: FileManager.default.homeDirectoryForCurrentUser, thinkingSummaries: false, executable: executable)))
        }

        private init(session: ClaudeSession) { self.session = session }

        /// The page to open: the CLI's `automaticUrl` (its localhost callback finishes the
        /// sign-in by itself). `fields` are the method's (`loginWithClaudeAi`, …).
        public func begin(_ fields: [String: JSONValue]) async throws -> URL {
            let reply = try await session.authenticate(fields)
            guard let url = ClaudeAuth.automaticURL(reply) else { throw Failure.said("Claude Code sent no sign-in page.") }
            return url
        }

        /// Waits for the browser; the account it signed in to.
        public func wait() async throws -> JSONValue {
            try await session.waitForSignIn()["account"] ?? .null
        }

        public func cancel() async { await session.close() }
    }

    /// `claude auth login --sso` over pipes: the CLI opens the browser itself and prints the page
    /// as "If the browser didn't open, visit: <url>" (plain, with `FORCE_HYPERLINK=0`). It ends
    /// with exit 0 once signed in, or "Login failed: <reason>" on stderr. Nothing is ever written
    /// to its input: the pasted-code path stays unused. Cancelling ends the process.
    public final class SSOLogin: @unchecked Sendable {
        private let process = Process()
        private let lock = NSLock()
        private var out = ""
        private var err = ""
        private var page: CheckedContinuation<URL, any Error>?
        private var found: URL?
        private var ended: Int32?
        private var waiting: CheckedContinuation<Int32, Never>?
        /// Held open and never written: a closed input would read as an empty pasted code.
        private let input = Pipe()

        /// Starts it; the page it prints, once printed.
        public static func start(executable: URL? = nil) async throws -> (SSOLogin, URL) {
            let launch = try await CLIExecutable.resolve("claude", override: executable)
            let login = SSOLogin()
            let url = try await login.run(launch)
            return (login, url)
        }

        private func run(_ launch: CLIExecutable.Launch) async throws -> URL {
            process.executableURL = launch.url
            process.arguments = ["auth", "login", "--sso"]
            process.environment = launch.environment.merging(["FORCE_HYPERLINK": "0"]) { $1 }
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = input
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { self?.said(data, error: false) }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { self?.said(data, error: true) }
            }
            process.terminationHandler = { [weak self] process in self?.exited(process.terminationStatus) }
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { page = continuation }
                do {
                    try process.run()
                    ChildReaper.shared.watch(process.processIdentifier)
                } catch {
                    lock.withLock { page = nil }
                    continuation.resume(throwing: error)
                }
            }
        }

        private func said(_ data: Data, error: Bool) {
            let text = String(decoding: data, as: UTF8.self)
            let resume: (CheckedContinuation<URL, any Error>, URL)? = lock.withLock {
                if error {
                    err += text
                    return nil
                }
                out += text
                guard found == nil, let url = ClaudeAuth.visitURL(out), let page else { return nil }
                found = url
                self.page = nil
                return (page, url)
            }
            if let (page, url) = resume { page.resume(returning: url) }
        }

        private func exited(_ status: Int32) {
            ChildReaper.shared.forget(process.processIdentifier)
            let (page, waiter, reason): (CheckedContinuation<URL, any Error>?, CheckedContinuation<Int32, Never>?, String?) = lock.withLock {
                ended = status
                defer { (self.page, waiting) = (nil, nil) }
                return (self.page, waiting, ClaudeAuth.loginReason(err))
            }
            page?.resume(throwing: Failure.said(reason ?? "Claude Code exited \(status)."))
            waiter?.resume(returning: status)
        }

        /// Waits for the CLI to finish; throws its reason when it didn't sign in.
        public func wait() async throws {
            let status: Int32 = await withCheckedContinuation { continuation in
                let done: Int32? = lock.withLock {
                    if let ended { return ended }
                    waiting = continuation
                    return nil
                }
                if let done { continuation.resume(returning: done) }
            }
            guard status != 0 else { return }
            let reason = lock.withLock { ClaudeAuth.loginReason(err) }
            throw Failure.said(reason ?? "Claude Code exited \(status).")
        }

        public func cancel() {
            if process.isRunning { process.terminate() }
        }
    }

    /// The page in `auth login`'s output: the address after "visit:", any terminal hyperlink
    /// around it taken off; nil until the line is whole, or when it isn't a web address.
    public static func visitURL(_ output: String) -> URL? {
        // Whole lines only: the last piece may still be arriving.
        for line in output.components(separatedBy: "\n").dropLast() {
            guard let range = line.range(of: "visit:") else { continue }
            let rest = String(line[range.upperBound...])
            // OSC 8 hyperlinks: ESC ] 8 ; ; <url> BEL|ESC\ <text> ESC ] 8 ; ; BEL|ESC\
            let plain = rest.replacingOccurrences(of: "\u{1B}\\]8;[^;]*;[^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: " ", options: .regularExpression)
            for word in plain.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }) {
                guard let url = URL(string: String(word)), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                    url.host() != nil
                else { continue }
                return url
            }
        }
        return nil
    }

    /// The reason in `auth login`'s stderr: the text after "Login failed:", else its first line.
    public static func loginReason(_ stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let failed = lines.first(where: { $0.hasPrefix("Login failed:") }) {
            let reason = failed.dropFirst("Login failed:".count).trimmingCharacters(in: .whitespaces)
            return reason.isEmpty ? nil : reason
        }
        return lines.first
    }

    /// `claude_authenticate`'s `automaticUrl`, when it's a web address.
    public static func automaticURL(_ reply: JSONValue) -> URL? {
        guard let text = reply["automaticUrl"]?.string, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}
