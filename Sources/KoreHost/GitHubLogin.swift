import Foundation

/// `gh` on the box: whether it's signed in to github.com, and its device-code sign-in, run
/// without a terminal. Each runs only when asked (a connect, `auth.gh`): nothing polls.
package enum GitHubLogin {
    /// `gh auth status` for github.com succeeds; false without `gh`. `environment`: the box's
    /// (its `PATH` finds `gh`).
    package static func signedIn(environment: [String: String]) async -> Bool {
        await run(["gh", "auth", "status", "--hostname", "github.com"], environment: environment) == 0
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
        environment: [String: String], started: @escaping @Sendable ((url: String, code: String)?, String) -> Void,
        ended: @escaping @Sendable (Bool) -> Void
    ) -> Process? {
        let process = Process()
        process.environment = environment
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
            let ok = process.terminationStatus == 0
            Task {
                let set = ok ? await run(["gh", "auth", "setup-git"], environment: environment) == 0 : false
                ended(set)
            }
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

    static func run(_ arguments: [String], environment: [String: String]? = nil) async -> Int32? {
        let process = Process()
        if let environment { process.environment = environment }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Its end comes by its termination handler: a wait would hold one of the few threads
        // all of the box's async work shares, for as long as `gh` takes.
        return await withCheckedContinuation { ended in
            process.terminationHandler = { ended.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                ended.resume(returning: nil)
            }
        }
    }
}
