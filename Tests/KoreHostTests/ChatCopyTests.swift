import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// Link 1.11: a chat copied. The shared rewrite (the folder and the session id, nothing else), a
/// cut's trash, and the box's side: `chat.copy` naming a chat's or a past session's files and
/// putting a cut's source aside, `chat.adoptCopy` placing a copy under its new id. Scratch CLI
/// folders only; the CLI probes at the end run only with `KORE_CLI_PROBES=1`.
@Suite("kore-host, chat copies", .serialized)
@MainActor
struct ChatCopyTests {
    static let a = "/home/dev/Onfinance"
    static let b = "/home/dev/Onfinance-copy"
    static let old = "2b5ccd6e-a732-4396-88d3-b4b57acdc788"
    static let new = "9e0f1a2b-0000-4000-8000-00000000c0de"

    func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/kc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    /// Claude's rows, plus one whose text names the session's id (left as said).
    static func claude(_ folder: String, _ session: String, said: String = old) -> String {
        MoveTests.claudeRows(folder, session: session)
            + #"{"type":"user","message":{"role":"user","content":"resume \#(said) later"},"uuid":"u7","cwd":"\#(folder)","sessionId":"\#(session)"}"# + "\n"
    }

    /// A rollout as codex writes it, its thread id the session's.
    static func codex(_ folder: String, _ session: String) -> String {
        MoveTests.codexRows(folder).replacingOccurrences(of: #""id":"019a""#, with: #""id":"\#(session)""#)
    }

    @Test func aClaudeCopyIsByteIdenticalButTheFolderAndTheId() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path, "HOME": root.path]
        let from = SessionCopy.target(provider: "claude", folder: Self.a, env: env)
        try write(Self.claude(Self.a, Self.old), from.appendingPathComponent("\(Self.old).jsonl"))
        try write(MoveTests.subagentRows(Self.a, session: Self.old), from.appendingPathComponent("\(Self.old)/subagents/agent-a16.jsonl"))
        try write(#"{"agentType":"general-purpose","cwd":"\#(Self.a)"}"#, from.appendingPathComponent("\(Self.old)/subagents/agent-a16.meta.json"))
        try write("output under \(Self.a)\n", from.appendingPathComponent("\(Self.old)/tool-results/t1.txt"))
        let before = try read(from.appendingPathComponent("\(Self.old).jsonl"))

        let placed = try SessionCopy.local(provider: "claude", session: Self.old, from: Self.a, to: Self.b, as: Self.new, env: env)
        let to = SessionCopy.target(provider: "claude", folder: Self.b, env: env)
        #expect(placed.root.path == to.path)
        #expect(placed.files.sorted() == ["\(Self.new).jsonl", "\(Self.new)/subagents/agent-a16.jsonl", "\(Self.new)/subagents/agent-a16.meta.json", "\(Self.new)/tool-results/t1.txt"])
        // Each row's `cwd` (subfolders too) and `sessionId` changed; a sibling folder, text, and the id in text didn't.
        let expected = Self.claude(Self.b, Self.new, said: Self.old)
            .replacingOccurrences(of: "\(Self.b)-other", with: "\(Self.a)-other").replacingOccurrences(of: "look in \(Self.b)/src", with: "look in \(Self.a)/src")
        #expect(try read(to.appendingPathComponent("\(Self.new).jsonl")) == expected)
        #expect(try read(to.appendingPathComponent("\(Self.new)/subagents/agent-a16.jsonl")) == MoveTests.subagentRows(Self.b, session: Self.new))
        // Files that aren't rows go as they are.
        #expect(try read(to.appendingPathComponent("\(Self.new)/subagents/agent-a16.meta.json")) == #"{"agentType":"general-purpose","cwd":"\#(Self.a)"}"#)
        #expect(try read(to.appendingPathComponent("\(Self.new)/tool-results/t1.txt")) == "output under \(Self.a)\n")
        // The source is untouched, and a second copy under the same id is refused.
        #expect(try read(from.appendingPathComponent("\(Self.old).jsonl")) == before)
        #expect(throws: SessionCopy.CopyError.self) { try SessionCopy.local(provider: "claude", session: Self.old, from: Self.a, to: Self.b, as: Self.new, env: env) }
        // Same folder: a duplicate beside it.
        let twin = SessionCopy.newId()
        let dup = try SessionCopy.local(provider: "claude", session: Self.old, from: Self.a, to: Self.a, as: twin, env: env)
        #expect(dup.root.path == from.path && FileManager.default.fileExists(atPath: from.appendingPathComponent("\(twin).jsonl").path))
        #expect(try read(from.appendingPathComponent("\(twin).jsonl")) == Self.claude(Self.a, twin, said: Self.old))
    }

    @Test func aCodexCopyRenamesTheRolloutAndItsThreadId() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["CODEX_HOME": root.appendingPathComponent("codex").path, "HOME": root.path]
        let sessions = SessionFiles.codexSessions(env)
        let name = "2026/11/10/rollout-2026-11-10T06-29-00-\(Self.old).jsonl"
        try write(Self.codex(Self.a, Self.old), sessions.appendingPathComponent(name))
        let placed = try SessionCopy.local(provider: "codex", session: Self.old, from: Self.a, to: Self.b, as: Self.new, env: env)
        #expect(placed.files == ["2026/11/10/rollout-2026-11-10T06-29-00-\(Self.new).jsonl"])
        let copy = try read(sessions.appendingPathComponent(placed.files[0]))
        // The thread id and each `cwd` changed; the folder in text didn't; no newline was added.
        #expect(copy == Self.codex(Self.b, Self.new).replacingOccurrences(of: "<cwd>\(Self.b)</cwd>", with: "<cwd>\(Self.a)</cwd>"))
        #expect(try read(sessions.appendingPathComponent(name)) == Self.codex(Self.a, Self.old))
        #expect(SessionFiles.codex(Self.new, env: env).files == placed.files)
    }

    @Test func aWorkingChatsTornLastRowIsLeftOutAndACutGoesToTheTrash() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path, "HOME": root.path]
        let from = SessionCopy.target(provider: "claude", folder: Self.a, env: env)
        let rows = Self.claude(Self.a, Self.old)
        try write(rows + #"{"type":"assistant","message":{"id":"m3","#, from.appendingPathComponent("\(Self.old).jsonl"))
        try write(MoveTests.subagentRows(Self.a, session: Self.old), from.appendingPathComponent("\(Self.old)/subagents/agent-a1.jsonl"))
        let copy = try SessionCopy.local(provider: "claude", session: Self.old, from: Self.a, to: Self.b, as: Self.new, env: env)
        #expect(try read(copy.root.appendingPathComponent("\(Self.new).jsonl")).hasSuffix(#""sessionId":"\#(Self.new)"}"# + "\n"))
        #expect(SessionCopy.rows(copy.root.appendingPathComponent("\(Self.new).jsonl")) == SessionCopy.rows(from.appendingPathComponent("\(Self.old).jsonl")) - 1)
        // A cut checks every row came: the torn one makes it not whole, and nothing of it stays.
        let other = SessionCopy.newId()
        #expect(throws: SessionCopy.CopyError.self) { try SessionCopy.local(provider: "claude", session: Self.old, from: Self.a, to: Self.b, as: other, whole: true, env: env) }
        #expect(!FileManager.default.fileExists(atPath: copy.root.appendingPathComponent("\(other).jsonl").path))

        // The cut's source, once its copy is verified: into the trash, paths kept, nothing deleted.
        let found = SessionCopy.files(provider: "claude", session: Self.old, folder: Self.a, env: env)
        let trash = root.appendingPathComponent("trash")
        let put = try SessionCopy.trash(found, session: Self.old, into: trash)
        #expect(!FileManager.default.fileExists(atPath: from.appendingPathComponent("\(Self.old).jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: from.appendingPathComponent(Self.old).path))
        #expect(try read(put.appendingPathComponent("\(Self.old)/subagents/agent-a1.jsonl")) == MoveTests.subagentRows(Self.a, session: Self.old))
        #expect(try read(put.appendingPathComponent("\(Self.old).jsonl")).hasPrefix(rows))
    }

    @Test func linkRulesTakeOnlyFullGrantsAndPlainIds() {
        let full = LinkControlLevel.full
        #expect(LinkPolicy.checkBox(.chatCopy, ControlArgs(sourceId: Self.old, phase: "prepare"), nil, control: full) == .allow)
        #expect(LinkPolicy.checkBox(.chatCopy, ControlArgs(sourceId: Self.old, phase: "prepare"), nil, control: .standard) != .allow)
        #expect(LinkPolicy.checkBox(.chatCopy, ControlArgs(sourceId: "../x", phase: "prepare"), nil, control: full) != .allow)
        #expect(LinkPolicy.checkBox(.chatCopy, ControlArgs(sourceId: Self.old, folder: "rel", phase: "prepare"), nil, control: full) != .allow)
        let move = UUID().uuidString.lowercased()
        #expect(LinkPolicy.checkBox(.chatAdoptCopy, ControlArgs(phase: "prepare", moveId: move), nil, control: full) == .allow)
        let commit = ControlArgs(sourceId: Self.old, provider: "claude", sessionId: Self.new, folder: Self.b, phase: "commit", moveId: move)
        #expect(LinkPolicy.checkBox(.chatAdoptCopy, commit, nil, control: full) == .allow)
        var torn = commit
        torn.copiedFrom = "two\nlines"
        #expect(LinkPolicy.checkBox(.chatAdoptCopy, torn, nil, control: full) != .allow)
        var bad = commit
        bad.sessionId = "a/b"
        #expect(LinkPolicy.checkBox(.chatAdoptCopy, bad, nil, control: full) != .allow)
    }

    // MARK: The box's side

    func command(_ client: StreamClient, _ kind: ControlKind, _ args: ControlArgs) async throws -> MoveResult {
        let id = UUID().uuidString
        client.socket.send(.cmd(id: id, .control(kind, args)))
        var found: MoveResult?
        try await until {
            found = client.frames.lazy.compactMap { try? JSONDecoder().decode(MoveResult.self, from: $0) }.first { $0.id == id }
            return found != nil
        }
        return found!
    }

    @Test func theBoxNamesACopysFilesAdoptsOneUnderItsNewIdAndPutsACutAside() async throws {
        let rig = try MoveTests.Rig()
        defer { rig.host.finish() }
        let folder = SessionFiles.real(rig.host.folder.path)
        try write(MoveTests.claudeRows(folder, session: rig.session), rig.projects.appendingPathComponent("\(rig.session).jsonl"))
        try write(MoveTests.subagentRows(folder, session: rig.session), rig.projects.appendingPathComponent("\(rig.session)/subagents/agent-a1.jsonl"))
        let client = try await StreamClient(rig.host, grant: rig.grant)

        // chat.copy prepare: the files as they are; the chat isn't frozen, nothing changes.
        let said = try await command(client, .chatCopy, ControlArgs(sourceId: rig.hc.id, phase: "prepare"))
        let info = try #require(said.move)
        #expect(info.files == ["\(rig.session).jsonl", "\(rig.session)/subagents/agent-a1.jsonl"] && info.root == rig.projects.path)
        #expect(info.sessionId == rig.session && info.title == "Repos" && info.folders.contains(folder) && rig.hc.ownedHere && !rig.hc.isFrozen)
        // An unknown one is gone.
        #expect(try await command(client, .chatCopy, ControlArgs(sourceId: "nope", provider: "claude", folder: rig.host.folder.path, phase: "prepare")).code == .goneSession)

        // chat.adoptCopy: staging, the Mac's rsync (here: a copy of the box's own files, in a Mac folder's words), commit.
        let mac = "/Users/dev/Code/Onfinance"
        let fresh = SessionCopy.newId()
        let moveId = UUID().uuidString.lowercased()
        let staged = try #require(try await command(client, .chatAdoptCopy, ControlArgs(provider: "claude", sessionId: fresh, phase: "prepare", moveId: moveId)).move)
        let stage = URL(fileURLWithPath: staged.root)
        try write(MoveTests.claudeRows(mac, session: rig.session), stage.appendingPathComponent("\(rig.session).jsonl"))
        try write(MoveTests.subagentRows(mac, session: rig.session), stage.appendingPathComponent("\(rig.session)/subagents/agent-a1.jsonl"))
        let commit = ControlArgs(
            title: "Repos", modelId: "haiku", sourceId: rig.session, provider: "claude", sessionId: fresh, folder: rig.host.folder.path, folders: [mac],
            phase: "commit", moveId: moveId, copiedFrom: "Copied from “Repos” · Onfinance")
        let adopted = try await command(client, .chatAdoptCopy, commit)
        let made = try #require(rig.host.host.chat(adopted.chatId ?? ""))
        #expect(made.record.session == fresh && made.record.copied == "Copied from “Repos” · Onfinance" && made.title == "Repos" && made.ownedHere)
        let placed = rig.projects.appendingPathComponent("\(fresh).jsonl")
        #expect(try read(placed) == MoveTests.claudeRows(folder, session: fresh).replacingOccurrences(of: "\(folder)-other", with: "\(mac)-other").replacingOccurrences(of: "look in \(folder)", with: "look in \(mac)"))
        #expect(try read(rig.projects.appendingPathComponent("\(fresh)/subagents/agent-a1.jsonl")) == MoveTests.subagentRows(folder, session: fresh))
        #expect(made.record.transcript == placed.path && !FileManager.default.fileExists(atPath: staged.root))
        // The source chat is as it was.
        #expect(try read(rig.projects.appendingPathComponent("\(rig.session).jsonl")) == MoveTests.claudeRows(folder, session: rig.session))
        // The same id again is refused: never another chat's history.
        let again = UUID().uuidString.lowercased()
        let second = try #require(try await command(client, .chatAdoptCopy, ControlArgs(provider: "claude", sessionId: fresh, phase: "prepare", moveId: again)).move)
        try write(MoveTests.claudeRows(mac, session: rig.session), URL(fileURLWithPath: second.root).appendingPathComponent("\(rig.session).jsonl"))
        var twice = commit
        twice.moveId = again
        #expect(try await command(client, .chatAdoptCopy, twice).code == .staleGen)
        // A folder the box doesn't serve.
        var elsewhere = commit
        elsewhere.moveId = UUID().uuidString.lowercased()
        elsewhere.sessionId = SessionCopy.newId()
        elsewhere.folder = "/etc"
        #expect(try await command(client, .chatAdoptCopy, elsewhere).code == .goneFolder)

        // A cut's source, once its copy is placed elsewhere: out of the box's chats, its files in kore-host's trash.
        let source = rig.hc.id
        #expect(try await command(client, .chatCopy, ControlArgs(sourceId: source, phase: "commit")).ok)
        #expect(rig.host.host.chat(source) == nil && rig.host.host.boxChat(source) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.projects.appendingPathComponent("\(rig.session).jsonl").path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: rig.host.host.chatTrash.path)
        #expect(trashed.count == 1 && trashed[0].hasSuffix(rig.session))
        #expect(FileManager.default.fileExists(atPath: rig.host.host.chatTrash.appendingPathComponent("\(trashed[0])/\(rig.session)/subagents/agent-a1.jsonl").path))
        // The copy is untouched.
        #expect(FileManager.default.fileExists(atPath: placed.path) && rig.host.host.chat(made.id) != nil)
    }

    // MARK: The CLIs resume a copy (KORE_CLI_PROBES=1: no account, scratch homes)

    nonisolated static let probes = ProcessInfo.processInfo.environment["KORE_CLI_PROBES"] == "1"

    func run(_ tool: String, _ args: [String], in folder: URL, env: [String: String], input: String = "", wait: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + args
        process.currentDirectoryURL = folder
        process.environment = env
        let out = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = inp
        try process.run()
        inp.fileHandleForWriting.write(Data(input.utf8))
        if input.isEmpty { try? inp.fileHandleForWriting.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { if process.isRunning { process.terminate() } }
        if !input.isEmpty {
            // The app-server answers, then its stdin closes.
            Thread.sleep(forTimeInterval: min(8, wait))
            try? inp.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func probeEnv(_ root: URL) -> [String: String] {
        var env = ["HOME": root.appendingPathComponent("home").path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        env["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("home/.claude").path
        env["CODEX_HOME"] = root.appendingPathComponent("home/.codex").path
        // No account: a key that's refused, so nothing is spent.
        env["ANTHROPIC_API_KEY"] = "sk-ant-kore-probe-invalid"
        return env
    }

    @Test(.enabled(if: probes)) func claudeResumesAPastedCopyByItsNewId() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = probeEnv(root)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let realA = SessionFiles.real(a.path)
        let rows = [
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"say hi"},"uuid":"00000000-0000-4000-8000-000000000001","timestamp":"2026-11-10T06:29:00.000Z","userType":"external","cwd":"\#(realA)","sessionId":"\#(Self.old)","version":"2.1.318","gitBranch":"main"}"#,
            #"{"parentUuid":"00000000-0000-4000-8000-000000000001","isSidechain":false,"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}},"uuid":"00000000-0000-4000-8000-000000000002","timestamp":"2026-11-10T06:29:01.000Z","userType":"external","cwd":"\#(realA)","sessionId":"\#(Self.old)","version":"2.1.318","gitBranch":"main"}"#,
        ].joined(separator: "\n") + "\n"
        try write(rows, SessionCopy.target(provider: "claude", folder: a.path, env: env).appendingPathComponent("\(Self.old).jsonl"))
        _ = try SessionCopy.local(provider: "claude", session: Self.old, from: a.path, to: b.path, as: Self.new, env: env)
        // Cut: the original goes to the trash (claude finds a session in any folder's key, so only
        // its absence shows the copy is found where it was placed).
        let original = SessionCopy.files(provider: "claude", session: Self.old, folder: a.path, env: env)
        try SessionCopy.trash(original, session: Self.old, into: root.appendingPathComponent("trash"))
        let found = try run("claude", ["--resume", Self.new, "-p", "hi", "--model", "haiku"], in: b, env: env)
        let missing = try run("claude", ["--resume", Self.old, "-p", "hi", "--model", "haiku"], in: b, env: env)
        print("claude --resume <new> in b: \(found.prefix(200))\nclaude --resume <old> in b: \(missing.prefix(200))")
        #expect(!found.contains("No conversation found") && !found.isEmpty)
        #expect(missing.contains("No conversation found"))
    }

    @Test(.enabled(if: probes)) func codexResumesAPastedCopyByItsNewId() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = probeEnv(root)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let old = "019a7c2e-1111-7222-8333-444455556666", new = "019a7c2e-2222-7222-8333-444455556666"
        let realA = SessionFiles.real(a.path), realB = SessionFiles.real(b.path)
        let rollout = [
            #"{"timestamp":"2026-11-10T06:29:00.000Z","type":"session_meta","payload":{"id":"\#(old)","timestamp":"2026-11-10T06:29:00.000Z","cwd":"\#(realA)","originator":"codex_cli_rs","cli_version":"0.159.3","instructions":null,"source":"vscode","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-11-10T06:29:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"say hi"}]}}"#,
            #"{"timestamp":"2026-11-10T06:29:01.500Z","type":"event_msg","payload":{"type":"user_message","message":"say hi","images":[]}}"#,
            #"{"timestamp":"2026-11-10T06:29:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try write(rollout, SessionFiles.codexSessions(env).appendingPathComponent("2026/11/10/rollout-2026-11-10T06-29-00-\(old).jsonl"))
        _ = try SessionCopy.local(provider: "codex", session: old, from: a.path, to: b.path, as: new, env: env)
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"kore-probe","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"thread/resume","params":{"threadId":"\#(new)"}}"#,
        ].joined(separator: "\n") + "\n"
        let said = try run("codex", ["app-server"], in: b, env: env, input: input, wait: 20)
        let answer = said.split(separator: "\n").first { $0.contains(#""id":2"#) }.map(String.init) ?? ""
        print("codex thread/resume <new>: \(answer.prefix(300))")
        #expect(answer.contains(#""result""#) && answer.contains(#""id":"\#(new)""#) && answer.contains(#""cwd":"\#(realB)""#))
    }
}
