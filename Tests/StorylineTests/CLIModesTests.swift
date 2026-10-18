import Foundation
import Testing

@testable import KoreCore
@testable import KoreStorylines

@MainActor
@Suite("CLI modes and what they keep off the owner's files", .serialized)
struct CLIModesTests {
    private let files = FileManager.default

    private func scratch() throws -> URL {
        let url = files.temporaryDirectory.appendingPathComponent("cli-modes-\(UUID().uuidString)")
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: ClaudeTraces.realPath(url.path))
    }

    private func make(_ url: URL, file: Bool = false) throws {
        if file {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        } else {
            try files.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    @Test func removesOnlyTheScratchFoldersClaudeTraces() throws {
        let root = try scratch()
        defer { try? files.removeItem(at: root) }
        let home = root.appendingPathComponent("claude-home")
        let folder = root.appendingPathComponent("folders/story")
        try make(folder)
        let session = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        let project = home.appendingPathComponent("projects/" + CassettePaths.encoded(folder.path))
        try make(project.appendingPathComponent("\(session).jsonl"), file: true)
        try make(home.appendingPathComponent("session-env/\(session)"))
        try make(home.appendingPathComponent("file-history/\(session)"))
        // Someone else's: a neighbouring project and another session's traces.
        let neighbour = home.appendingPathComponent("projects/" + CassettePaths.encoded(folder.path) + "-2")
        try make(neighbour.appendingPathComponent("\(other).jsonl"), file: true)
        try make(home.appendingPathComponent("session-env/\(other)"))

        let removed = ClaudeTraces.remove(for: [folder], within: root.appendingPathComponent("folders"), claudeHome: home)
        #expect(removed.count == 3)
        #expect(!files.fileExists(atPath: project.path))
        #expect(!files.fileExists(atPath: home.appendingPathComponent("session-env/\(session)").path))
        #expect(!files.fileExists(atPath: home.appendingPathComponent("file-history/\(session)").path))
        #expect(files.fileExists(atPath: neighbour.path))
        #expect(files.fileExists(atPath: home.appendingPathComponent("session-env/\(other)").path))
        #expect(files.fileExists(atPath: folder.path))
    }

    @Test func aLinkedProjectDirIsUnlinkedNotFollowed() throws {
        let root = try scratch()
        defer { try? files.removeItem(at: root) }
        let home = root.appendingPathComponent("claude-home")
        let folder = root.appendingPathComponent("story")
        let precious = root.appendingPathComponent("precious")
        try make(precious.appendingPathComponent("keep.txt"), file: true)
        try make(home.appendingPathComponent("projects"))
        let project = home.appendingPathComponent("projects/" + CassettePaths.encoded(folder.path))
        try files.createSymbolicLink(at: project, withDestinationURL: precious)
        try make(folder)
        _ = ClaudeTraces.remove(for: [folder], within: root, claudeHome: home)
        #expect(files.fileExists(atPath: precious.appendingPathComponent("keep.txt").path))
    }

    /// A Claude home holding a project dir with one session for `folder`; returns the project dir.
    private func traces(for folder: URL, in home: URL) throws -> URL {
        let project = home.appendingPathComponent("projects/" + CassettePaths.encoded(ClaudeTraces.realPath(folder.path)))
        try make(project.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl"), file: true)
        return project
    }

    @Test func leavesTracesOfAFolderOutsideTheRunAlone() throws {
        let root = try scratch()
        defer { try? files.removeItem(at: root) }
        let run = root.appendingPathComponent("run")
        let real = root.appendingPathComponent("real-project")
        try make(run)
        try make(real)
        let home = root.appendingPathComponent("claude-home")
        let project = try traces(for: real, in: home)
        #expect(ClaudeTraces.remove(for: [real], within: run, claudeHome: home).isEmpty)
        #expect(files.fileExists(atPath: project.path))
        // The run itself isn't a folder of the run, and a folder that doesn't exist isn't either.
        let runProject = try traces(for: run, in: home)
        #expect(ClaudeTraces.remove(for: [run, run.appendingPathComponent("missing")], within: run, claudeHome: home).isEmpty)
        #expect(files.fileExists(atPath: runProject.path))
    }

    @Test func leavesTracesAloneForALinkInTheRunToAFolderOutside() throws {
        let root = try scratch()
        defer { try? files.removeItem(at: root) }
        let run = root.appendingPathComponent("run")
        let real = root.appendingPathComponent("real-project")
        try make(run)
        try make(real)
        let link = run.appendingPathComponent("folders/story")
        try make(link.deletingLastPathComponent())
        try files.createSymbolicLink(at: link, withDestinationURL: real)
        let home = root.appendingPathComponent("claude-home")
        let project = try traces(for: real, in: home)
        #expect(ClaudeTraces.remove(for: [link], within: run, claudeHome: home).isEmpty)
        #expect(files.fileExists(atPath: project.path))
    }

    @Test func aLiveStorylineRunsOnlyInAFolderOfItsRun() throws {
        let root = try scratch()
        defer { try? files.removeItem(at: root) }
        let run = root.appendingPathComponent("run")
        let real = root.appendingPathComponent("real-project")
        try make(real)
        let inside = run.appendingPathComponent("folders/story")
        try make(inside)
        let link = run.appendingPathComponent("folders/linked")
        try files.createSymbolicLink(at: link, withDestinationURL: real)
        let modes = CLIModes(mode: .live(model: "haiku"), run: run, cassettes: run)
        defer { modes.finishRun() }
        #expect(throws: CLIModeError.self) { try modes.begin(storyline: "S", provider: "claude", folder: real) }
        #expect(throws: CLIModeError.self) { try modes.begin(storyline: "S", provider: "claude", folder: link) }
        #expect(throws: CLIModeError.self) { try modes.begin(storyline: "S", provider: "claude", folder: run) }
        try modes.begin(storyline: "S", provider: "claude", folder: inside)
        #expect(modes.end().isEmpty)
    }

    @Test func installsARecordedClaudeSessionForTheRunsFolder() throws {
        let root = try scratch()
        defer { try? files.removeItem(at: root) }
        let fixture = root.appendingPathComponent("abc.jsonl")
        try #"{"cwd":"/WORK","file":"/WORK/a.swift","memory":"/HOME/.claude/projects/-WORK/memory"}"#
            .write(to: fixture, atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("folders/demo")
        try make(folder)
        let store = root.appendingPathComponent("claude-store")
        let id = try SessionFixtures.installClaude(fixture, folder: folder, store: store)
        #expect(id == "abc")
        let installed = store.appendingPathComponent("projects/" + CassettePaths.encoded(folder.path) + "/abc.jsonl")
        let text = try String(contentsOf: installed, encoding: .utf8)
        #expect(text.contains(#""cwd":"\#(folder.path)""#) && text.contains(folder.path + "/a.swift"))
        #expect(text.contains("/projects/" + CassettePaths.encoded(folder.path) + "/memory"))
        // And a fixture made from it scrubs back to the same text.
        #expect(try SessionFixtures.scrub(installed, folder: folder) == (try String(contentsOf: fixture, encoding: .utf8)))
    }

    @Test func processModeStandsInForBothCLIsWithTheStorylinesCassette() throws {
        let root = try scratch()
        defer { try? files.removeItem(at: root) }
        let cassettes = root.appendingPathComponent("cassettes")
        try make(cassettes.appendingPathComponent("SendAndStream.codex.jsonl"), file: true)
        let modes = CLIModes(mode: .process, run: root, cassettes: cassettes, fakeCLI: URL(fileURLWithPath: "/bin/echo"))
        defer { modes.finishRun() }
        try modes.begin(storyline: "SendAndStream", provider: "codex", folder: root)
        let codex = try #require(CLIExecutable.standIns.value["codex"])
        #expect(codex.executable?.path == "/bin/echo")
        #expect(codex.environment["KORE_FAKE_AS"] == "codex")
        #expect(codex.environment["KORE_FAKE_CASSETTE"]?.hasSuffix("SendAndStream.codex.jsonl") == true)
        #expect(CLIExecutable.standIns.value["claude"]?.environment["KORE_FAKE_AS"] == "claude")
        #expect(throws: CLIModeError.self) { try modes.begin(storyline: "Missing", provider: "codex", folder: root) }
    }

    @Test func liveModeRunsCodexInTheScratchHomeAndUndoesItAfter() throws {
        let root = try scratch()
        defer { try? files.removeItem(at: root) }
        let modes = CLIModes(mode: .live(model: "gpt-6-luna"), run: root, cassettes: root)
        try modes.installRun()
        let auth = modes.codexHome.appendingPathComponent("auth.json")
        #expect((try? files.destinationOfSymbolicLink(atPath: auth.path))?.hasSuffix("/.codex/auth.json") == true)
        #expect(CLIExecutable.standIns.value["codex"]?.environment["CODEX_HOME"] == modes.codexHome.path)
        #expect(CLIExecutable.standIns.value["codex"]?.executable == nil)
        #expect(TurnChangeLog.root.value?.path.hasPrefix(root.path) == true)
        modes.finishRun()
        #expect(CLIExecutable.standIns.value.isEmpty && TurnChangeLog.root.value == nil)
    }
}
