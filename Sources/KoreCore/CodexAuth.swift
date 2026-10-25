import Foundation

/// Auth is owned by the Codex CLI: Kore never handles credentials. It asks who Codex is logged
/// in as (`account/read`), asks it to sign in in the browser (`account/login/start`) and to
/// sign out (`account/logout`), each on a short-lived app-server of its own. Never asked for:
/// `getAuthStatus` with its token, and the token login types. An API key the user types goes
/// to Codex once (`signIn(apiKey:)`).
public enum CodexAuth {
    public struct Status: Sendable, Equatable {
        public let loggedIn: Bool
        /// "chatgpt", "apiKey", "amazonBedrock"
        public let type: String?
        public let email: String?
        /// ChatGPT plan, e.g. "free", "plus", "pro"
        public let planType: String?
        /// Codex needs an OpenAI login for its provider; false when the provider signs in some
        /// other way (set in its config).
        public let requiresOpenaiAuth: Bool

        public init(_ json: JSONValue) {
            let account = json["account"]
            loggedIn = account != nil && account != .null
            type = account?["type"]?.string
            email = account?["email"]?.string
            planType = account?["planType"]?.string
            requiresOpenaiAuth = json["requiresOpenaiAuth"]?.bool ?? true
        }
    }

    /// Starts a short-lived app-server and asks it `account/read`.
    public static func status(executable: URL? = nil) async throws -> Status {
        Status(try await statusReply(executable: executable))
    }

    /// `account/read`'s answer, on a short-lived app-server.
    public static func statusReply(executable: URL? = nil) async throws -> JSONValue {
        let server = try await CodexAppServer.start(
            cwd: FileManager.default.homeDirectoryForCurrentUser, executable: executable)
        defer { Task { await server.close() } }
        return try await server.request("account/read")
    }

    /// The file Codex keeps its login in: `auth.json` in `CODEX_HOME`, else in `~/.codex`. Kore
    /// only watches it for changes and never reads it: it holds the tokens.
    public static func authFile(environment: [String: String] = CLIProfiles.environment) -> URL {
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    /// `account/logout`: global, Terminal and VS Code included.
    public static func logout(executable: URL? = nil) async throws {
        let server = try await CodexAppServer.start(cwd: FileManager.default.homeDirectoryForCurrentUser, executable: executable)
        defer { Task { await server.close() } }
        _ = try await server.request("account/logout")
    }

    /// Signs in with an API key the user typed: `account/login/start {type: "apiKey", apiKey}` on
    /// a short-lived app-server (Codex stores the key itself), then the account it now reads.
    /// The key is in the request only, and the caller forgets it.
    public static func signIn(apiKey: String, executable: URL? = nil) async throws -> JSONValue {
        let server = try await CodexAppServer.start(cwd: FileManager.default.homeDirectoryForCurrentUser, executable: executable)
        defer { Task { await server.close() } }
        _ = try await server.request("account/login/start", ["type": "apiKey", "apiKey": .string(apiKey)])
        return try await server.request("account/read")
    }

    /// The config files that may set `forced_login_method`, the managed one first.
    public static func configFiles(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return [URL(fileURLWithPath: "/etc/codex/managed_config.toml"), home.appendingPathComponent("config.toml")]
    }

    /// The one login Codex allows ("chatgpt" or "api"), from the first file that says; nil when
    /// any is.
    public static func forcedLoginMethod(files: [URL]) -> String? {
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let method = forcedLoginMethod(toml: text) { return method }
        }
        return nil
    }

    /// `forced_login_method = "…"` at the top level of a config.toml (before any table).
    public static func forcedLoginMethod(toml: String) -> String? {
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix("forced_login_method"), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "forced_login_method" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") { value = value[..<hash].trimmingCharacters(in: .whitespaces) }
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return ["chatgpt", "api"].contains(unquoted) ? unquoted : nil
        }
        return nil
    }

    /// What `account/login/start` answers: the page to open, and for a device code, the code.
    public struct Prompt: Sendable, Equatable {
        public let loginId: String
        public let url: URL
        public let userCode: String?

        /// From `{loginId, authUrl}` or `{loginId, verificationUrl, userCode}`; nil without a
        /// login id or a web address.
        public init?(_ reply: JSONValue) {
            guard let id = reply["loginId"]?.string, !id.isEmpty,
                let text = reply["authUrl"]?.string ?? reply["verificationUrl"]?.string, let url = URL(string: text),
                let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
            else { return nil }
            loginId = id
            self.url = url
            userCode = reply["userCode"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// How a sign-in ended, from `account/login/completed`.
    public enum Completion: Sendable, Equatable {
        case succeeded
        /// Codex's reason, if it gave one ("Login cancelled", when another login took the port).
        case failed(String?)

        /// The notification's outcome when it's for `loginId`; nil for another login's.
        public init?(_ params: JSONValue, loginId: String) {
            guard params["loginId"]?.string == loginId else { return nil }
            if params["success"]?.bool == true {
                self = .succeeded
            } else {
                self = .failed(params["error"]?.string.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }

    /// One sign-in on an app-server held for it: `account/login/start`, then the matching
    /// `account/login/completed`, then `account/read`. `cancel` sends `account/login/cancel`.
    public actor Login {
        private let server: CodexAppServer
        private var prompt: Prompt?
        private var ended: Completion?
        private var waiting: CheckedContinuation<Completion, Never>?
        private var listening: Task<Void, Never>?

        public static func start(executable: URL? = nil) async throws -> Login {
            let login = Login(
                server: try await CodexAppServer.start(cwd: FileManager.default.homeDirectoryForCurrentUser, executable: executable))
            await login.listen()
            return login
        }

        private init(server: CodexAppServer) { self.server = server }

        private func listen() {
            let incoming = server.incoming
            listening = Task { [weak self] in
                for await message in incoming {
                    switch message {
                    case .notification(method: "account/login/completed", let params): await self?.completed(params)
                    case .exited: await self?.end(.failed(nil))
                    default: break
                    }
                }
            }
        }

        private func completed(_ params: JSONValue) {
            guard let id = prompt?.loginId, let completion = Completion(params, loginId: id) else { return }
            end(completion)
        }

        private func end(_ completion: Completion) {
            guard ended == nil else { return }
            ended = completion
            waiting?.resume(returning: completion)
            waiting = nil
        }

        /// `params`: the method's, `{type: "chatgpt"}` or `{type: "chatgptDeviceCode"}`.
        public func begin(_ params: JSONValue) async throws -> Prompt {
            let reply = try await server.request("account/login/start", params)
            guard let prompt = Prompt(reply) else { throw CodexAppServer.Failure.rpc(code: 0, message: "Codex sent no sign-in page.") }
            self.prompt = prompt
            return prompt
        }

        /// Waits for `account/login/completed`; then the account it signed in to (`account/read`).
        public func wait() async throws -> JSONValue {
            let completion: Completion =
                if let ended { ended } else { await withCheckedContinuation { waiting = $0 } }
            switch completion {
            case .succeeded: return try await server.request("account/read")
            case .failed(let reason): throw CodexAppServer.Failure.rpc(code: 0, message: reason ?? "")
            }
        }

        /// Sends a pasted callback only to this sign-in's own loopback listener.
        public func submit(_ input: String) async throws {
            guard let prompt, prompt.userCode == nil, ended == nil else { throw LoginCallback.Failure.unavailable }
            try await LoginCallback.finishLocalhost(input, authorizationURL: prompt.url)
        }

        /// Stops the sign-in (`account/login/cancel`), then the app-server.
        public func cancel() async {
            if let id = prompt?.loginId { _ = try? await server.request("account/login/cancel", ["loginId": .string(id)]) }
            await close()
        }

        public func close() async {
            listening?.cancel()
            await server.close()
            end(.failed(nil))
        }
    }
}
