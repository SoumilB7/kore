import Foundation

/// `gh` on the box: whether it's signed in to github.com, and its device-code sign-in, run
/// without a terminal. Each runs only when asked (a connect, `auth.gh`): nothing polls.
package enum GitHubLogin {
    /// `gh auth status` for github.com succeeds; false without `gh`.
    package static func signedIn() -> Bool {
        (try? run(["gh", "auth", "status", "--hostname", "github.com"])) == 0
    }

    /// The page and the one-time code, once `gh` has printed both.
    package static func parse(_ output: String) -> (url: String, code: String)? {
        guard let code = output.firstMatch(of: /one-time code: ([A-Z0-9]{4}-[A-Z0-9]{4})/)?.1,
            let url = output.firstMatch(of: /(https:\/\/github\.com\/login\/device)/)?.1
        else { return nil }
        return (String(url), String(code))
    }

    /// Starts `gh auth login --web`: `started` gets the page and code (or nil, when `gh` ended
    /// without them); `ended` whether the sign-in finished, after `gh auth setup-git`.
    @discardableResult
    package static func start(
        started: @escaping @Sendable ((url: String, code: String)?, String) -> Void, ended: @escaping @Sendable (Bool) -> Void
    ) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let state = Collected()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let found = state.add(data) { started(found, "") }
        }
        process.terminationHandler = { process in
            pipe.fileHandleForReading.readabilityHandler = nil
            if !state.told { started(nil, state.text) }
            let ok = process.terminationStatus == 0 && (try? run(["gh", "auth", "setup-git"])) == 0
            ended(ok)
        }
        do {
            try process.run()
            return process
        } catch {
            started(nil, "gh isn't installed on the box.")
            return nil
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var told = false
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

        func add(_ more: Data) -> (url: String, code: String)? {
            lock.withLock {
                data.append(more)
                guard !told, let found = GitHubLogin.parse(String(decoding: data, as: UTF8.self)) else { return nil }
                told = true
                return found
            }
        }
    }

    private static func run(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
