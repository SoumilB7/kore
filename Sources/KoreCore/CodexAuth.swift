import Foundation

/// Auth is owned by the Codex CLI (`codex login`); we only ask who it is logged in as.
public enum CodexAuth {
    public struct Status: Sendable {
        public let loggedIn: Bool
        /// "chatgpt", "apiKey", "amazonBedrock"
        public let type: String?
        public let email: String?
        /// ChatGPT plan, e.g. "free", "plus", "pro"
        public let planType: String?
        public let raw: JSONValue

        init(_ json: JSONValue) {
            let account = json["account"]
            loggedIn = account != nil && account != .null
            type = account?["type"]?.string
            email = account?["email"]?.string
            planType = account?["planType"]?.string
            raw = json
        }
    }

    /// Starts a short-lived app-server and asks it `account/read`.
    public static func status(executable: URL? = nil) async throws -> Status {
        let server = try await CodexAppServer.start(
            cwd: FileManager.default.homeDirectoryForCurrentUser, executable: executable)
        defer { Task { await server.close() } }
        return Status(try await server.request("account/read"))
    }
}
