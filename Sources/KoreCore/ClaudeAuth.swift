import Foundation

/// Auth is owned by the CLI: we never handle credentials, we only ask the CLI who it is
/// logged in as. To sign in or switch accounts, run `claude auth login` in a terminal.
public enum ClaudeAuth {
    public struct Status: Sendable {
        public let loggedIn: Bool
        /// e.g. "claude.ai" (subscription) or "console" (API billing)
        public let authMethod: String?
        public let email: String?
        public let orgName: String?
        /// e.g. "max", "pro"
        public let subscriptionType: String?
        public let raw: JSONValue

        init(_ json: JSONValue) {
            loggedIn = json["loggedIn"]?.bool ?? false
            authMethod = json["authMethod"]?.string
            email = json["email"]?.string
            orgName = json["orgName"]?.string
            subscriptionType = json["subscriptionType"]?.string
            raw = json
        }
    }

    /// Runs `claude auth status --json` with the same binary and environment sessions use.
    public static func status(executable: URL? = nil) async throws -> Status {
        let data = try await Task.detached {
            // Resolving may spawn the login shell once; keep that off the caller's actor.
            let launch = try CLIExecutable.resolve("claude", override: executable)
            let process = Process()
            process.executableURL = launch.url
            process.arguments = ["auth", "status", "--json"]
            process.environment = launch.environment
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        // Logged-out still prints JSON (loggedIn: false), so parse regardless of exit status.
        return Status(try JSONValue.parse(data))
    }
}
