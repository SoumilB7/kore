import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// Link 1.10: a chat moving between the box and a Mac. The session files' folder rewrite (the
/// shared helper both sides use), and the box's side: release, abort, the replica's refusals,
/// a return that fast-forwards and one that comes in as a new chat.
@Suite("kore-host, chat moves", .serialized)
@MainActor
struct MoveTests {
    static let box = "/home/dev/Onfinance"
    static let mac = "/Users/dev/Code/Onfinance"

    /// Rows shaped as the claude CLI (2.1) writes them: the folder, a subfolder, a sibling
    /// sharing its start, a nested `cwd`, and a folder only said in text.
    static func claudeRows(_ folder: String, session: String) -> String {
        [
            #"{"type":"custom-title","customTitle":"Repos","sessionId":"\#(session)"}"#,
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"look in \#(folder)/src"},"uuid":"u1","timestamp":"2026-11-10T06:29:00.000Z","userType":"external","entrypoint":"sdk-cli","cwd":"\#(folder)","sessionId":"\#(session)","version":"2.1.318","gitBranch":"main"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]},"uuid":"a1","timestamp":"2026-11-10T06:29:01.000Z","userType":"external","cwd":"\#(folder)/src","sessionId":"\#(session)","version":"2.1.318","gitBranch":"main"}"#,
            #"{"parentUuid":"a1","type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"ok"}]},"toolUseResult":{"stdout":"ok","cwd":"\#(folder)/src"},"uuid":"r1","cwd":"\#(folder)-other","sessionId":"\#(session)","version":"2.1.318"}"#,
            #"{"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Done é \"quoted\""}]},"uuid":"a2","cwd":"\#(folder)","sessionId":"\#(session)"}"#,
        ].joined(separator: "\n") + "\n"
    }

    static func subagentRows(_ folder: String, session: String) -> String {
        #"{"parentUuid":null,"isSidechain":true,"agentId":"a16ac5647bc88cb7d","type":"user","message":{"role":"user","content":"review"},"uuid":"s1","userType":"external","entrypoint":"sdk-cli","cwd":"\#(folder)","sessionId":"\#(session)","version":"2.1.318","gitBranch":"main"}"#
            + "\n"
    }

    /// Rows shaped as codex (0.159) writes a rollout: the session's meta, a turn's context, and
    /// a message whose text names the folder (left as said).
    static func codexRows(_ folder: String) -> String {
        [
            #"{"timestamp":"2026-11-10T06:29:00.000Z","type":"session_meta","payload":{"id":"019a","timestamp":"2026-11-10T06:29:00.000Z","cwd":"\#(folder)","originator":"codex_cli_rs","cli_version":"0.159.3","source":"vscode","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-11-10T06:29:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>\#(folder)</cwd>\n</environment_context>"}]}}"#,
            #"{"timestamp":"2026-11-10T06:29:02.000Z","type":"turn_context","payload":{"cwd":"\#(folder)/web","approval_policy":"on-request","model":"gpt-6-luna","effort":"low"}}"#,
        ].joined(separator: "\n")  // no newline after the last row
    }

    func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/km-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func aRoundTripIsByteIdenticalApartFromTheFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "2b5ccd6e-a732-4396-88d3-b4b57acdc788"
        let boxSide = root.appendingPathComponent("box"), macSide = root.appendingPathComponent("mac"), back = root.appendingPathComponent("back")
        let files = ["\(session).jsonl", "\(session)/subagents/agent-a16.jsonl", "\(session)/subagents/agent-a16.meta.json", "\(session)/tool-results/t1.txt", "r/rollout-2026-11-10T06-29-00-019a.jsonl"]
        try write(Self.claudeRows(Self.box, session: session), boxSide.appendingPathComponent(files[0]))
        try write(Self.subagentRows(Self.box, session: session), boxSide.appendingPathComponent(files[1]))
        try write(#"{"agentType":"general-purpose","description":"review","cwd":"\#(Self.box)"}"#, boxSide.appendingPathComponent(files[2]))
        try write("output under \(Self.box)\n", boxSide.appendingPathComponent(files[3]))
        try write(Self.codexRows(Self.box), boxSide.appendingPathComponent(files[4]))

        try FolderRewrite(from: [Self.box], to: Self.mac).files(files, from: boxSide, to: macSide)
        try FolderRewrite(from: [Self.mac], to: Self.box).files(files, from: macSide, to: back)

        func read(_ base: URL, _ path: String) throws -> String { String(decoding: try Data(contentsOf: base.appendingPathComponent(path)), as: UTF8.self) }
        // Box → Mac: every row's `cwd` (subfolders too) moved; a sibling, text and non-rows not.
        #expect(try read(macSide, files[0]) == Self.claudeRows(Self.mac, session: session).replacingOccurrences(of: "\(Self.mac)-other", with: "\(Self.box)-other")
            .replacingOccurrences(of: "look in \(Self.mac)/src", with: "look in \(Self.box)/src"))
        #expect(try read(macSide, files[1]) == Self.subagentRows(Self.mac, session: session))
        #expect(try read(macSide, files[2]).contains(Self.box) && read(macSide, files[3]).contains(Self.box))
        let rollout = try read(macSide, files[4])
        #expect(rollout.contains(#""cwd":"\#(Self.mac)""#) && rollout.contains(#""cwd":"\#(Self.mac)/web""#) && rollout.contains("<cwd>\(Self.box)</cwd>"))
        #expect(!rollout.hasSuffix("\n"))
        // Mac → box: the same bytes as before.
        for path in files { #expect(try Data(contentsOf: back.appendingPathComponent(path)) == Data(contentsOf: boxSide.appendingPathComponent(path))) }
        // A folder JSON escapes is matched as written.
        let odd = FolderRewrite(from: [#"/home/dev/a "b""#], to: "/x")
        #expect(odd.line(Data(#"{"cwd":"/home/dev/a \"b\"/c"}"#.utf8)) == Data(#"{"cwd":"/x/c"}"#.utf8))
    }

    @Test func aBigRolloutIsStreamedNotLoadedWhole() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("big.jsonl")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        let row = Data((#"{"type":"turn_context","payload":{"cwd":"\#(Self.box)","pad":""# + String(repeating: "x", count: 2000) + "\"}}\n").utf8)
        for _ in 0..<20_000 { try handle.write(contentsOf: row) }
        try handle.close()
        func peak() -> Int {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Int(usage.ru_maxrss)
        }
        let before = peak()
        let written = try FolderRewrite(from: [Self.box], to: Self.mac).file(source, to: root.appendingPathComponent("out.jsonl"))
        let grew = peak() - before
        #expect(written == 20_000 * (row.count + Self.mac.utf8.count - Self.box.utf8.count))
        print("rewrote \(written / 1_000_000) MB, resident grew \(grew / 1024) KiB")
        #expect(grew < 16 << 20)
    }

    // MARK: The box's side

    @MainActor
    final class Rig {
        let host: HostRig
        let claude: URL
        let grant: Grant
        let session = "5f0c8a51-0000-4000-8000-000000000001"
        var hc: HostChat

        init() throws {
            host = try HostRig()
            claude = host.root.appendingPathComponent("claude")
            host.host.sessionEnv = ["CLAUDE_CONFIG_DIR": claude.path, "CODEX_HOME": host.root.appendingPathComponent("codex").path, "HOME": host.root.path]
            try host.host.start()
            grant = try GrantStore(host.paths.grants).allow("laptop", control: .full, socket: host.paths.socket)
            hc = try #require(host.host.newChat(folder: host.folder.path, provider: "claude", modelId: "haiku", title: "Repos", session: session))
        }

        var projects: URL { claude.appendingPathComponent("projects").appendingPathComponent(ClaudeHistory.projectKey(for: host.folder)) }
    }

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

    @Test func releaseFreezesNamesTheFilesAndAnAbortUnfreezes() async throws {
        let rig = try Rig()
        defer { rig.host.finish() }
        let folder = SessionFiles.real(rig.host.folder.path)
        try write(Self.claudeRows(folder, session: rig.session), rig.projects.appendingPathComponent("\(rig.session).jsonl"))
        try write(Self.subagentRows(folder, session: rig.session), rig.projects.appendingPathComponent("\(rig.session)/subagents/agent-a1.jsonl"))
        let client = try await StreamClient(rig.host, grant: rig.grant)

        // A stale gen, and a watch grant, are refused.
        #expect(try await command(client, .chatRelease, ControlArgs(chatId: rig.hc.id, phase: "prepare", gen: 3)).code == .staleGen)
        let prepared = try await command(client, .chatRelease, ControlArgs(chatId: rig.hc.id, phase: "prepare", gen: 0))
        let move = try #require(prepared.move)
        #expect(move.files == ["\(rig.session).jsonl", "\(rig.session)/subagents/agent-a1.jsonl"] && move.root == rig.projects.path)
        #expect(move.sessionId == rig.session && move.title == "Repos" && move.gen == 0)
        #expect(rig.hc.isFrozen && rig.hc.record.transcript == rig.projects.appendingPathComponent("\(rig.session).jsonl").path)
        // Frozen: it takes nothing, and a second move is refused.
        #expect(rig.host.host.apply(.send(chatId: rig.hc.id, text: "hi"), id: "s", control: .full) { _ in }?.code == .moving)
        #expect(try await client.call(rig.hc.id, .send(text: "hi", files: [], queued: nil, id: "m")).code == .moving)
        #expect(try await command(client, .chatRelease, ControlArgs(chatId: rig.hc.id, phase: "prepare", gen: 0)).code == .moving)
        #expect(HostMeta.meta(rig.hc).moving == true && HostMeta.meta(rig.hc).can.send == false)

        #expect(try await command(client, .chatRelease, ControlArgs(chatId: rig.hc.id, phase: "abort", gen: 0, moveId: move.moveId)).ok)
        #expect(rig.hc.ownedHere && rig.hc.gen == 0 && HostMeta.meta(rig.hc).moving == nil)

        // A link lost mid-move aborts it too.
        let again = try #require(try await command(client, .chatRelease, ControlArgs(chatId: rig.hc.id, phase: "prepare", gen: 0)).move)
        #expect(rig.hc.isFrozen && !again.moveId.isEmpty)
        client.close()
        try await until { !rig.hc.isFrozen }
    }

    @Test func aReplicaRefusesAndAReturnFastForwardsOrComesInNew() async throws {
        let rig = try Rig()
        defer { rig.host.finish() }
        let boxFolder = SessionFiles.real(rig.host.folder.path)
        let file = rig.projects.appendingPathComponent("\(rig.session).jsonl")
        try write(Self.claudeRows(boxFolder, session: rig.session), file)
        let client = try await StreamClient(rig.host, grant: rig.grant)
        let move = try #require(try await command(client, .chatRelease, ControlArgs(chatId: rig.hc.id, phase: "prepare", gen: 0)).move)
        let committed = try await command(client, .chatRelease, ControlArgs(chatId: rig.hc.id, phase: "commit", gen: 0, moveId: move.moveId, host: "MacBook"))
        #expect(committed.owner?.host == "laptop" && committed.owner?.gen == 1 && rig.hc.isReplica)

        // A replica: no message, no call, no CLI; its meta says where it lives.
        #expect(rig.host.host.apply(.send(chatId: rig.hc.id, text: "hi"), id: "s", control: .full) { _ in }?.code == .elsewhere)
        #expect(try await client.call(rig.hc.id, .send(text: "hi", files: [], queued: nil, id: "m")).code == .elsewhere)
        #expect(rig.host.host.live(rig.hc) == nil)
        #expect(HostMeta.meta(rig.hc).owner?.name == "MacBook" && HostMeta.meta(rig.hc).can.send == false)

        // The Mac mirrors two events; a repeat is skipped, a gap answers where to send from.
        let events = MirrorItems([StreamItem(s: 0, e: .userMessage(text: "on the Mac", attachments: [], id: "x1")), StreamItem(s: 1, e: .text("e1", .answer, "ok", agent: .main))])
        #expect(try await command(client, .chatMirror, ControlArgs(chatId: rig.hc.id, gen: 1, seq: 0, events: events)).mirrored == 2)
        #expect(try await command(client, .chatMirror, ControlArgs(chatId: rig.hc.id, gen: 1, seq: 1, events: MirrorItems(Array(events.items.suffix(1))))).mirrored == 2)
        #expect(try await command(client, .chatMirror, ControlArgs(chatId: rig.hc.id, gen: 1, seq: 5, events: events)).mirrored == 2)
        #expect(try await command(client, .chatMirror, ControlArgs(chatId: rig.hc.id, gen: 0, seq: 2, events: events)).code == .staleGen)

        // The Mac sends it back: the box seeds staging with its own copy in the Mac's words, so
        // only the new tail travels.
        let macFolder = "/Users/dev/Code/Onfinance"
        let backId = UUID().uuidString.lowercased()
        let back = ControlArgs(chatId: rig.hc.id, provider: "claude", sessionId: rig.session, gen: 1, moveId: backId, host: "MacBook")
        var prepare = back
        prepare.phase = "prepare"
        prepare.from = macFolder
        let staged = try #require(try await command(client, .chatAdopt, prepare).move)
        #expect(staged.fastForward == true && staged.files == ["\(rig.session).jsonl"])
        let seeded = URL(fileURLWithPath: staged.root).appendingPathComponent("\(rig.session).jsonl")
        #expect(try String(contentsOf: seeded, encoding: .utf8) == Self.claudeRows(macFolder, session: rig.session).replacingOccurrences(of: "\(macFolder)-other", with: "\(boxFolder)-other").replacingOccurrences(of: "look in \(macFolder)", with: "look in \(boxFolder)"))
        // What the Mac's rsync leaves: the seed plus a new row.
        let handle = try FileHandle(forWritingTo: seeded)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"user","uuid":"u9","cwd":"\#(macFolder)","sessionId":"\#(rig.session)"}"# + "\n").utf8))
        try handle.close()
        var commit = back
        commit.phase = "commit"
        commit.folder = rig.host.folder.path
        commit.folders = [macFolder]
        commit.seq = 2
        let adopted = try await command(client, .chatAdopt, commit)
        #expect(adopted.chatId == rig.hc.id && adopted.owner?.onBox == true && adopted.owner?.gen == 2 && rig.hc.ownedHere)
        let now = try String(contentsOf: file, encoding: .utf8)
        #expect(now == Self.claudeRows(boxFolder, session: rig.session) + #"{"type":"user","uuid":"u9","cwd":"\#(boxFolder)","sessionId":"\#(rig.session)"}"# + "\n")
        #expect(!FileManager.default.fileExists(atPath: staged.root))

        // A return at a gen the box didn't give, while the box keeps the session for its own
        // chat: refused, the copy stays on the Mac. One the box no longer has: a new chat.
        func stale(_ session: String) async throws -> MoveResult {
            var args = ControlArgs(chatId: rig.hc.id, provider: "claude", sessionId: session, phase: "prepare", gen: 1, moveId: UUID().uuidString.lowercased(), host: "MacBook")
            let staged = try #require(try await command(client, .chatAdopt, args).move)
            #expect(staged.fastForward == false && staged.files.isEmpty)
            try write(#"{"type":"user","uuid":"u1","cwd":"\#(macFolder)"}"# + "\n", URL(fileURLWithPath: staged.root).appendingPathComponent("\(session).jsonl"))
            args.phase = "commit"
            args.folder = rig.host.folder.path
            args.folders = [macFolder]
            return try await command(client, .chatAdopt, args)
        }
        #expect(try await stale(rig.session).code == .staleGen)
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix(Self.claudeRows(boxFolder, session: rig.session)))
        let other = "5f0c8a51-0000-4000-8000-000000000002"
        let fresh = try await stale(other)
        #expect(fresh.ok && fresh.chatId != rig.hc.id)
        let made = try #require(rig.host.host.chat(fresh.chatId ?? ""))
        #expect(made.record.from == "MacBook" && made.record.session == other && made.ownedHere && rig.hc.gen == 2)
        #expect(try String(contentsOf: rig.projects.appendingPathComponent("\(other).jsonl"), encoding: .utf8).contains(boxFolder))
    }
}
