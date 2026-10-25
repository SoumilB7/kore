import Foundation

/// The AWS profiles a Bedrock form offers: their names and regions from the AWS config and
/// credentials files (`AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE`, else `~/.aws`). Nothing
/// else in them is kept: no key, no token.
package struct AWSProfiles: Equatable, Sendable {
    /// In the files' order, `default` where it falls.
    package var names: [String] = []
    package var regions: [String: String] = [:]

    package init(names: [String] = [], regions: [String: String] = [:]) {
        self.names = names
        self.regions = regions
    }

    package static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> AWSProfiles {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = environment["AWS_CONFIG_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".aws/config")
        let credentials = environment["AWS_SHARED_CREDENTIALS_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".aws/credentials")
        let text = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return parse(config: text(config), credentials: text(credentials))
    }

    /// `[default]` and `[profile name]` in the config file, `[name]` in the credentials file;
    /// `region =` under each.
    package static func parse(config: String, credentials: String) -> AWSProfiles {
        var profiles = AWSProfiles()
        for (text, isConfig) in [(config, true), (credentials, false)] {
            var current: String?
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
                if line.hasPrefix("["), line.hasSuffix("]") {
                    let section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                    current = nil
                    if section == "default" {
                        current = "default"
                    } else if isConfig, section.hasPrefix("profile ") {
                        current = section.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
                    } else if !isConfig {
                        current = section
                    }
                    if let name = current, !name.isEmpty, !profiles.names.contains(name) { profiles.names.append(name) }
                    continue
                }
                guard let name = current, let equals = line.firstIndex(of: "=") else { continue }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if key == "region", !value.isEmpty, profiles.regions[name] == nil { profiles.regions[name] = value }
            }
        }
        return profiles
    }
}

/// A Vertex key file's `project_id` (the file itself is the secret, and stays where it is).
package func vertexProject(keyFile: URL) -> String? {
    guard let data = try? Data(contentsOf: keyFile), data.count < 1_000_000, let json = try? JSONValue.parse(data) else { return nil }
    return json["project_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
}

/// gcloud's active project, from its default configuration.
package func gcloudProject(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    let root = environment["CLOUDSDK_CONFIG"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gcloud")
    guard let text = try? String(contentsOf: root.appendingPathComponent("configurations/config_default"), encoding: .utf8) else { return nil }
    var inCore = false
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { inCore = line == "[core]"; continue }
        guard inCore, let equals = line.firstIndex(of: "=") else { continue }
        if line[..<equals].trimmingCharacters(in: .whitespaces) == "project" {
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }
    return nil
}

/// A settings command (Claude's `awsAuthRefresh`) run as the CLI runs it: in the user's login
/// shell, in a folder. Cancelling ends it.
package final class ShellRun: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var err = ""
    private var ended: Int32?
    private var waiting: CheckedContinuation<Int32, Never>?

    package init(_ command: String, in folder: URL) throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.said(data) }
        }
        process.terminationHandler = { [weak self] process in self?.exited(process.terminationStatus) }
        try process.run()
        ChildReaper.shared.watch(process.processIdentifier)
    }

    private func said(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            err += text
            // Only the end is ever shown.
            if err.count > 8_000 { err = String(err.suffix(4_000)) }
        }
    }

    private func exited(_ status: Int32) {
        ChildReaper.shared.forget(process.processIdentifier)
        let waiter: CheckedContinuation<Int32, Never>? = lock.withLock {
            ended = status
            defer { waiting = nil }
            return waiting
        }
        waiter?.resume(returning: status)
    }

    /// Waits for it to end; throws its last line on stderr when it failed.
    package func wait() async throws {
        let status: Int32 = await withCheckedContinuation { continuation in
            let done: Int32? = lock.withLock {
                if let ended { return ended }
                waiting = continuation
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
        guard status != 0 else { return }
        let last = lock.withLock { err.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } }
        throw ClaudeAuth.Failure.said(last ?? "it exited \(status)")
    }

    package func cancel() {
        if process.isRunning { process.terminate() }
    }
}

/// Claude's interactive `/login`, handed to Terminal: a `.command` file that runs the CLI in the
/// chat's folder and removes itself. Terminal opens it through Launch Services, with no
/// AppleScript and so no automation prompt.
package enum TerminalLogin {
    /// The file's text. `claude` is the CLI's full path; `arguments` follow it.
    package static func script(claude: String, arguments: [String], folder: URL) -> String {
        let words = ([claude] + arguments).map(quoted).joined(separator: " ")
        // The active login's folder (`CLIProfiles`), so the sign-in lands in it.
        let env = CLIProfiles.overrides("claude").map { "export \($0.key)=\(quoted($0.value))\n" }.joined()
        return "#!/bin/zsh -l\nrm -f -- \"$0\"\ncd -- \(quoted(folder.path)) 2>/dev/null\n\(env)exec \(words)\n"
    }

    /// Writes it, executable, in a folder of Kore's own; its location.
    package static func write(claude: String, arguments: [String], folder: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kore-login", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("Claude Code login \(UUID().uuidString.prefix(8)).command")
        guard FileManager.default.createFile(
            atPath: file.path, contents: Data(script(claude: claude, arguments: arguments, folder: folder).utf8),
            attributes: [.posixPermissions: 0o700])
        else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    /// Single-quoted for the shell.
    static func quoted(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A hand-off's end: its login file names an account other than the one it named at the
    /// start (an added login's starts with none). Looked at once a second and read only when
    /// written, so the end is seen whichever login's folder it signs in. `stop` ends the wait.
    package final class Landing: Sendable {
        private let file: URL
        private let start: String?
        private let stopped = Locked(false)

        package init(file: URL) {
            self.file = file
            start = (try? Data(contentsOf: file)).flatMap(ClaudeAuth.accountStamp)
        }

        package func stop() { stopped.set(true) }

        package func wait() async throws {
            var written = Self.written(file)
            while !stopped.value, !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                let now = Self.written(file)
                guard now != written else { continue }
                written = now
                if let stamp = (try? Data(contentsOf: file)).flatMap(ClaudeAuth.accountStamp), !stamp.isEmpty, stamp != start { return }
            }
            throw CancellationError()
        }

        private static func written(_ file: URL) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        }
    }
}
