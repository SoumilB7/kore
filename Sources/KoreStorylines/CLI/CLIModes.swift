import Foundation
import KoreCore
import KoreUI

/// How a storyline run's chats reach a CLI (plan §5), and what keeps the run off the owner's
/// files: Kore's turn-change logs, Codex's home and Claude's store all live in the run's scratch
/// folder. The one exception is live Claude, which can only run logged in with the real
/// `~/.claude`: what its sessions write there is removed after each storyline.
@MainActor
package final class CLIModes {
    package enum Mode: Sendable, Equatable {
        /// `ScriptedBackend`: no CLI at all.
        case scripted
        /// `kore-fake-cli` playing each storyline's cassette.
        case process
        /// The real CLIs on a cheap model (`haiku`, `gpt-6-luna`).
        case live(model: String)
    }

    package let mode: Mode
    /// The run's scratch folder: `$TMPDIR/kore-storylines/<run>/`.
    package let run: URL
    /// Where cassettes are read (process mode) and written (`record`).
    package let cassettes: URL
    /// `kore-fake-cli`, for process mode.
    package let fakeCLI: URL?
    /// Live mode only: record each storyline's CLI sessions as cassettes.
    package let record: Bool

    package var codexHome: URL { run.appendingPathComponent("codex-home") }
    package var claudeStore: URL { run.appendingPathComponent("claude-store") }

    /// The storyline running and its folder, between `begin` and `end`.
    private var current: (name: String, folder: URL)?

    package init(mode: Mode, run: URL, cassettes: URL, fakeCLI: URL? = nil, record: Bool = false) {
        self.mode = mode
        self.run = run
        self.cassettes = cassettes
        self.fakeCLI = fakeCLI
        self.record = record
    }

    /// Once, before any chat starts.
    package func installRun() throws {
        let files = FileManager.default
        try files.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try files.createDirectory(at: claudeStore, withIntermediateDirectories: true)
        TurnChangeLog.root.value = run.appendingPathComponent("turn-changes")
        // Usage attribution reads and keeps the run's files only.
        UsagePaths.host.value = UsagePaths(
            support: run.appendingPathComponent("usage"), caches: run.appendingPathComponent("usage-index"),
            claudeProjects: claudeStore.appendingPathComponent("projects"), codexSessions: codexHome.appendingPathComponent("sessions"))
        HandoffRecords.root.value = run.appendingPathComponent("handoffs")
        switch mode {
        case .scripted:
            ScriptedWorld.shared.install()
            ScriptedAccounts.shared.install()
        case .process:
            guard fakeCLI != nil else { throw CLIModeError.noFakeCLI }
        case .live:
            // Codex runs in the scratch home, logged in through the owner's auth: a link, not a
            // copy, so a token refresh lands in the real file and doesn't strand it.
            let auth = codexHome.appendingPathComponent("auth.json")
            let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
            if !files.fileExists(atPath: auth.path) { try files.createSymbolicLink(at: auth, withDestinationURL: real) }
            CLIExecutable.standIns.value = ["codex": .init(environment: ["CODEX_HOME": codexHome.path])]
        }
        // The cloud files a platform form reads (AWS profiles, gcloud's project) are the run's
        // own, empty until a storyline writes one: never the owner's.
        let cloud = run.appendingPathComponent("cloud", isDirectory: true)
        try files.createDirectory(at: cloud, withIntermediateDirectories: true)
        setenv("AWS_CONFIG_FILE", cloud.appendingPathComponent("aws-config").path, 1)
        setenv("AWS_SHARED_CREDENTIALS_FILE", cloud.appendingPathComponent("aws-credentials").path, 1)
        setenv("CLOUDSDK_CONFIG", cloud.appendingPathComponent("gcloud").path, 1)
        // Kore reads Claude's store from here (recorded sessions); live Claude needs the real one.
        if case .live = mode {} else { setenv("CLAUDE_CONFIG_DIR", claudeStore.path, 1) }
    }

    /// Before a storyline: its cassette (process mode), or recording (live with `record`).
    /// `provider`: the variant it runs as ("claude", "codex").
    package func begin(storyline name: String, provider: String, folder: URL) throws {
        current = (name, folder)
        let cassette = cassettes.appendingPathComponent("\(name).\(provider).jsonl")
        switch mode {
        case .scripted:
            ScriptedWorld.shared.reset()
            ScriptedAccounts.shared.reset()
        case .process:
            guard let fakeCLI else { throw CLIModeError.noFakeCLI }
            guard FileManager.default.fileExists(atPath: cassette.path) else { throw CLIModeError.noCassette(cassette.path) }
            let claims = run.appendingPathComponent("claims-\(name)-\(provider)")
            try? FileManager.default.removeItem(at: claims)
            let environment = [
                "KORE_FAKE_CASSETTE": cassette.path, "KORE_FAKE_CLAIMS": claims.path, "CODEX_HOME": codexHome.path,
            ]
            CLIExecutable.standIns.value = [
                "claude": .init(executable: fakeCLI, environment: environment.merging(["KORE_FAKE_AS": "claude"]) { $1 }),
                "codex": .init(executable: fakeCLI, environment: environment.merging(["KORE_FAKE_AS": "codex"]) { $1 }),
            ]
        case .live(let model):
            // Live Claude writes its transcripts for the folder into the real ~/.claude, and
            // `end()` removes them: only a folder of this run may be one.
            guard ClaudeTraces.isInside(folder, run: run) else { throw CLIModeError.outsideRun(folder.path, run.path) }
            if record {
                StdioProcess.recorder.value = try CassetteRecorder(url: cassette, work: folder, codexHome: codexHome, model: model)
            }
        }
    }

    /// After a storyline (also when it failed): recording stops, and live Claude's traces of
    /// its folder are removed.
    @discardableResult
    package func end() -> [URL] {
        StdioProcess.recorder.value = nil
        defer { current = nil }
        guard case .live = mode, let folder = current?.folder else { return [] }
        return ClaudeTraces.remove(for: [folder], within: run)
    }

    /// After the run.
    package func finishRun() {
        StdioProcess.recorder.value = nil
        CLIExecutable.standIns.value = [:]
        if CLIExecutable.places.value != nil { CLIExecutable.look(in: nil) }
        CLIInstaller.standIn.value = nil
        TurnChangeLog.root.value = nil
        UsagePaths.host.value = nil
        HandoffRecords.root.value = nil
        HandoffWriters.standIns.value = [:]
    }
}

package enum CLIModeError: LocalizedError {
    case noFakeCLI
    case noCassette(String)
    case outsideRun(String, String)

    package var errorDescription: String? {
        switch self {
        case .noFakeCLI: "process mode needs kore-fake-cli built (swift build --product kore-fake-cli)"
        case .noCassette(let path): "no cassette at \(path); record one with --live haiku --record"
        case .outsideRun(let folder, let run):
            "a live storyline runs only in a folder of its run (\(run)), not \(folder): its Claude transcripts are removed afterwards"
        }
    }
}

/// What a live Claude session leaves in `~/.claude` for a scratch folder: its project dir
/// (`projects/<the folder's real path, encoded>`), and per session `session-env/<id>` and
/// `file-history/<id>`. Nothing else there is touched.
package enum ClaudeTraces {
    /// Removes those for `folders`, each only after its real path proves to be one of them, and
    /// only for folders inside the run's scratch folder `run`: a real project's transcripts are
    /// never touched. Returns what it removed.
    package static func remove(for folders: [URL], within run: URL, claudeHome: URL = defaultHome) -> [URL] {
        let files = FileManager.default
        let home = URL(fileURLWithPath: realPath(claudeHome.path))
        var removed: [URL] = []
        for folder in folders {
            guard isInside(folder, run: run) else {
                FileHandle.standardError.write(Data(
                    "kore-storylines: left Claude's traces for \(folder.path) alone: it isn't inside the run \(run.path)\n".utf8))
                continue
            }
            let project = home.appendingPathComponent("projects").appendingPathComponent(CassettePaths.encoded(realPath(folder.path)))
            guard Self.inside(project, home.appendingPathComponent("projects")), files.fileExists(atPath: project.path) else { continue }
            // The sessions that ran there, by their transcripts' names.
            let sessions = ((try? files.contentsOfDirectory(atPath: project.path)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }.filter(Self.isSessionId)
            for id in sessions {
                for area in ["session-env", "file-history"] {
                    let trace = home.appendingPathComponent(area).appendingPathComponent(id)
                    if Self.inside(trace, home.appendingPathComponent(area)), (try? files.removeItem(at: trace)) != nil { removed.append(trace) }
                }
            }
            if (try? files.removeItem(at: project)) != nil { removed.append(project) }
        }
        return removed
    }

    /// `folder` exists and its real path (links resolved) is strictly inside `run`'s.
    package static func isInside(_ folder: URL, run: URL) -> Bool {
        guard let folder = resolved(folder.path), let run = resolved(run.path) else { return false }
        return folder.hasPrefix(run.hasSuffix("/") ? run : run + "/") && folder != run
    }

    /// The real path, or nil when it doesn't resolve (the path doesn't exist).
    private static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    package static var defaultHome: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// `path` sits directly in `parent`, after resolving links: never `parent` itself, never
    /// outside it.
    static func inside(_ path: URL, _ parent: URL) -> Bool {
        let resolved = realPath(path.deletingLastPathComponent().path)
        return resolved == realPath(parent.path) && !path.lastPathComponent.isEmpty
            && path.lastPathComponent != "." && path.lastPathComponent != ".."
    }

    static func isSessionId(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    static func realPath(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }
}

/// Recorded sessions as fixtures (plan §5): stored with their folder, home and Codex home
/// scrubbed (`CassettePaths`), installed into a run with this run's paths put back.
package enum SessionFixtures {
    /// A Claude transcript into `store/projects/<folder>/<id>.jsonl`, where Kore (reading
    /// `CLAUDE_CONFIG_DIR`) finds it for `folder`. Returns the session id.
    @discardableResult
    package static func installClaude(_ fixture: URL, folder: URL, store: URL) throws -> String {
        let id = fixture.deletingPathExtension().lastPathComponent
        let paths = CassettePaths(work: folder)
        let project = store.appendingPathComponent("projects").appendingPathComponent(CassettePaths.encoded(ClaudeTraces.realPath(folder.path)))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let text = try String(contentsOf: fixture, encoding: .utf8)
        try paths.restore(text).write(to: project.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        return id
    }

    /// A Codex rollout into `codexHome/sessions/…`, under its own name. Codex builds its turn
    /// index from it the first time the thread is read.
    package static func installCodex(_ fixture: URL, folder: URL, codexHome: URL) throws {
        let paths = CassettePaths(work: folder, codexHome: codexHome)
        let day = codexHome.appendingPathComponent("sessions/2026/01/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let text = try String(contentsOf: fixture, encoding: .utf8)
        try paths.restore(text).write(to: day.appendingPathComponent(fixture.lastPathComponent), atomically: true, encoding: .utf8)
    }

    /// A session file as a fixture: `folder` and the home folders as placeholders.
    package static func scrub(_ session: URL, folder: URL, codexHome: URL? = nil) throws -> String {
        CassettePaths(work: folder, codexHome: codexHome).scrub(try String(contentsOf: session, encoding: .utf8))
    }
}
