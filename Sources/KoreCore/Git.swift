import Foundation

/// Runs git for KoreCore's readers (snapshots, status, file lists).
enum Git {
    static func run(_ args: [String], in folder: URL, env extra: [String: String] = [:]) async
        -> (status: Int32, output: String)?
    {
        guard let git = try? await CLIExecutable.resolve("git") else { return nil }
        var env = git.environment.merging(extra) { $1 }
        // Paths come back raw (not octal-escaped), and no pager or prompt can block.
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "core.quotepath"
        env["GIT_CONFIG_VALUE_0"] = "false"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        let environment = env
        return await Task.detached {
            let process = Process()
            process.executableURL = git.url
            process.arguments = args
            process.currentDirectoryURL = folder
            process.environment = environment
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            // Read before waiting, so a large diff can't fill the pipe and stall git.
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
