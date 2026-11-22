import Foundation
@testable import HostClient
import KoreCore
import KoreHost
import LinkProtocol
import src
import Testing

/// Link 1.11 from the Mac: a chat copied and cut between this Mac's folders and stand-in boxes
/// (kore-hosts in this process), the files carried by rsync through a stand-in ssh. Every CLI
/// folder is a scratch one.
@MainActor
@Suite("chat copies", .serialized)
struct ChatCopyClientTests {
    static let session = ChatMoveTests.session

    struct Box {
        let rig: BoxRig
        let connection: HostConnection
        let moves: ChatMoves
        var folder: String { rig.folder.path }
        var real: String { SessionFiles.real(rig.folder.path) }
        var projects: URL { rig.root.appendingPathComponent("boxclaude/projects").appendingPathComponent(ClaudeHistory.projectKey(for: rig.folder)) }
        var end: CopyEnd { .box(moves, folder: folder) }
        /// Its rsync over a pipe (`box(pipe: true)`).
        var pipe: PipeRig?
        @MainActor func finish() {
            rig.finish()
            pipe?.finish()
        }
    }

    /// `pipe`: the copy's rsync over KoreNet (`kore pipe` to this kore-host's `HostPipes`), no SSH.
    func box(pipe: Bool = false) async throws -> Box {
        let rig = try BoxRig()
        rig.host.sessionEnv = ["CLAUDE_CONFIG_DIR": rig.root.appendingPathComponent("boxclaude").path, "HOME": rig.root.path]
        let connection = rig.connection()
        connection.retain()
        #expect(await until { connection.isOnline })
        #expect(connection.copiesChats)
        var piped: PipeRig?
        if pipe {
            let made = try PipeRig(home: rig.root, pipes: HostPipes(home: rig.root.path, rsync: "/usr/bin/rsync", forced: PipeRig.macForced))
            rig.host.pipes = made.pipes
            piped = made
        }
        let moves = ChatMoves(
            connection: connection, box: try piped?.syncBox() ?? fakeSSH(rig.root), staging: rig.root.appendingPathComponent("staging"), name: "MacBook",
            store: MovedChats(root: rig.root.appendingPathComponent("cache")))
        return Box(rig: rig, connection: connection, moves: moves, pipe: piped)
    }

    struct Mac {
        let root: URL
        let env: [String: String]
        let copies: ChatCopies
        func folder(_ name: String) throws -> String {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        func projects(_ folder: String) -> URL { SessionCopy.target(provider: "claude", folder: folder, env: env) }
        func finish() { try? FileManager.default.removeItem(at: root) }
    }

    func mac() throws -> Mac {
        let root = URL(fileURLWithPath: "/tmp/kcc-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let env = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("macclaude").path, "HOME": root.path]
        return Mac(root: root, env: env, copies: ChatCopies(env: env, staging: root.appendingPathComponent("staging"), trash: root.appendingPathComponent("trash")))
    }

    /// A Codex rollout in `folder` for `session`, as codex writes one.
    static func codexRows(_ folder: String, _ session: String) -> String {
        [
            #"{"timestamp":"2026-11-10T06:29:00.000Z","type":"session_meta","payload":{"id":"\#(session)","timestamp":"2026-11-10T06:29:00.000Z","cwd":"\#(folder)","originator":"codex_cli_rs","cli_version":"0.159.3","source":"vscode","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-11-10T06:29:02.000Z","type":"turn_context","payload":{"cwd":"\#(folder)","approval_policy":"on-request","model":"gpt-6-luna","effort":"low"}}"#,
        ].joined(separator: "\n")
    }

    /// The rollout under `sessions` that holds `session`'s id, read.
    func rollout(_ sessions: URL, _ session: String) -> String? {
        let walk = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix("\(session).jsonl") { return try? read(url) }
        }
        return nil
    }

    /// Over a pipe (link on KoreNet, no SSH): a Claude chat and a Codex chat each copied to the
    /// box and back, as over SSH.
    @Test(arguments: ["claude", "codex"])
    func chatsCopyBothWaysOverAPipe(_ provider: String) async throws {
        let (b, m) = (try await box(pipe: true), try mac())
        defer { b.finish(); m.finish() }
        let folder = try m.folder("app"), real = SessionFiles.real(folder)
        let sessions = { (env: [String: String]) in SessionFiles.codexSessions(env) }
        let boxEnv = b.rig.host.sessionEnv
        if provider == "claude" {
            try write(Self.rows(real), m.projects(folder).appendingPathComponent("\(Self.session).jsonl"))
        } else {
            try write(Self.codexRows(real, Self.session), sessions(m.env).appendingPathComponent("2026/11/10/rollout-2026-11-10T06-29-00-\(Self.session).jsonl"))
        }
        let there = SessionCopy.newId()
        let made = try await m.copies.copy(CopySource(end: .mac(folder), id: Self.session, provider: provider, title: "Repos"), to: b.end, as: there).get()
        let chat = try #require(b.rig.host.chat(made.chatId ?? ""))
        #expect(chat.record.session == there)
        if provider == "claude" {
            #expect(try read(b.projects.appendingPathComponent("\(there).jsonl")) == Self.rows(b.real, there))
        } else {
            #expect(rollout(sessions(boxEnv), there) == Self.codexRows(b.real, there))
        }
        // And back, from the box's chat to another folder here.
        let back = try m.folder("back"), backReal = SessionFiles.real(back)
        let home = SessionCopy.newId()
        let returned = try await m.copies.copy(CopySource(end: b.end, id: chat.id, provider: provider, title: "Repos"), to: .mac(back), as: home).get()
        #expect(returned.session == home)
        if provider == "claude" {
            #expect(try read(m.projects(back).appendingPathComponent("\(home).jsonl")) == Self.rows(backReal, home))
        } else {
            #expect(rollout(sessions(m.env), home) == Self.codexRows(backReal, home))
        }
        // Every rsync went over the pipe: the box was asked for each.
        #expect((b.pipe?.asked.withLock { $0.count } ?? 0) >= 2)
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    /// Claude rows in `folder` for `session`.
    static func rows(_ folder: String, _ session: String = session, count: Int = 30) -> String {
        ChatMoveTests.rows(folder, count: count).replacingOccurrences(of: Self.session, with: session)
    }

    @Test func aMacChatCopiedToABoxIsANewChatThereAndTheMacsIsUntouched() async throws {
        let (b, m) = (try await box(), try mac())
        defer { b.rig.finish(); m.finish() }
        let folder = try m.folder("app"), real = SessionFiles.real(folder)
        let file = m.projects(folder).appendingPathComponent("\(Self.session).jsonl")
        try write(Self.rows(real), file)
        try write(Self.rows(real, count: 2), m.projects(folder).appendingPathComponent("\(Self.session)/subagents/agent-a1.jsonl"))
        let new = SessionCopy.newId()
        let source = CopySource(end: .mac(folder), id: Self.session, provider: "claude", title: "Repos")
        let made = try await m.copies.copy(source, to: b.end, as: new, line: "Copied from “Repos” · app").get()
        let chat = try #require(b.rig.host.chat(made.chatId ?? ""))
        #expect(chat.record.session == new && chat.record.copied == "Copied from “Repos” · app" && chat.title == "Repos")
        #expect(try read(b.projects.appendingPathComponent("\(new).jsonl")) == Self.rows(b.real, new))
        #expect(try read(b.projects.appendingPathComponent("\(new)/subagents/agent-a1.jsonl")) == Self.rows(b.real, new, count: 2))
        #expect(try read(file) == Self.rows(real))
        // Its history, once its CLI starts there, has the copy's line at the top.
        let live = try #require(b.rig.host.live(chat))
        await live.start()
        #expect(await until { !b.rig.made.isEmpty })
        b.rig.cli.sink.yield(.replayed([.userMessage(text: "step 0", attachments: [], id: "u0"), .text("a0", .answer, "ok")]))
        #expect(await until { live.transcriptView.entries.count >= 3 })
        #expect(live.transcriptView.entries.first?.kind == .divider && live.transcriptView.entries.first?.text == "Copied from “Repos” · app")
        #expect(live.transcriptView.entries.dropFirst().first?.kind == .user)
        print("mac → box copy: rsync sent \(made.cost.rsyncSent) B, link \(made.cost.linkBytes) B")
    }

    /// A copy a phone asked for (`chat.copyVia`) starts as a phone's new chat does, whatever its
    /// source runs in: Manual at most (Auto and Edit automatically too come down), no Arsenal, no
    /// commands in Plan; a mode that asks for as much or more stays.
    @Test(arguments: ["claude", "codex"])
    func aPhonesCopysSettingsAreCapped(_ id: String) throws {
        let provider = try #require(Registry.provider(id))
        for mode in provider.modes {
            let said = ChatSettings(modelId: "m", effort: "low", mode: mode.id, planAllow: true, arsenal: "drive").asked(provider: id)
            let within = try #require(ModeLevel(rawValue: mode.level)) <= LinkPolicy.leavePlanMaxLevel
            #expect(said == ChatSettings(modelId: "m", effort: "low", mode: within ? mode.id : provider.modes[0].id, planAllow: false), "\(mode.id)")
        }
        #expect(ChatSettings().asked(provider: id).mode == provider.modes[0].id)
        #expect(try #require(ModeLevel(rawValue: provider.modes[0].level)) <= LinkPolicy.leavePlanMaxLevel)
        if id == "claude" { #expect(["auto", "acceptEdits"].allSatisfy { ChatSettings(mode: $0).asked(provider: id).mode == "default" }) }
        if id == "codex" { #expect(ChatSettings(mode: "approveForMe").asked(provider: id).mode == "askForApproval") }
    }

    @Test func aPhonesCopyToABoxIsCappedOnEveryRoute() async throws {
        let (one, two, m) = (try await box(), try await box(), try mac())
        defer { one.rig.finish(); two.rig.finish(); m.finish() }
        let top = try #require(ProviderDescriptor.claude.modes.max { $0.level < $1.level }?.id)
        let (capped, boxed) = ("default", LinkPolicy.cappedMode(top, provider: "claude"))
        let folder = try m.folder("app")
        try write(Self.rows(SessionFiles.real(folder)), m.projects(folder).appendingPathComponent("\(Self.session).jsonl"))
        let full = ChatSettings(mode: top, planAllow: true, arsenal: "drive")
        let source = CopySource(end: .mac(folder), id: Self.session, provider: "claude", title: "Repos", settings: full)
        // The Mac's own paste carries Full access to a box that takes it; a phone's doesn't.
        let own = try await m.copies.copy(source, to: one.end).get()
        var copies = m.copies
        copies.asked = true
        let asked = try await copies.copy(source, to: one.end).get()
        let kept = try #require(one.rig.host.chat(own.chatId ?? "")), low = try #require(one.rig.host.chat(asked.chatId ?? ""))
        #expect(kept.record.mode == (one.connection.takesFullAccess ? top : boxed))
        #expect(low.record.mode == capped && low.record.arsenal == nil && low.record.planAllow != true)
        // Box to box: the settings come from the box, and are capped on the way through.
        let file = one.projects.appendingPathComponent("\(own.session).jsonl")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let crossed = try await copies.copy(CopySource(end: one.end, id: kept.id, provider: "claude", title: "Repos"), to: two.end).get()
        let there = try #require(two.rig.host.chat(crossed.chatId ?? ""))
        #expect(there.record.mode == capped && there.record.arsenal == nil && there.record.planAllow != true)
        // Box to Mac: what the copy lands with here.
        let back = try await copies.copy(CopySource(end: one.end, id: kept.id, provider: "claude", title: "Repos"), to: .mac(folder)).get()
        #expect(back.settings.mode == capped && back.settings.arsenal == nil && back.settings.planAllow == false)
    }

    /// A chat copied to a box has its wheel in the box window here: its CLI resumes the copy and
    /// never says the session, so the box's log says it, and the fill and window follow.
    @Test func aChatCopiedToABoxShowsItsWheelHere() async throws {
        let (b, m) = (try await box(), try mac())
        defer { b.rig.finish(); m.finish() }
        b.rig.silentResume = true
        let folder = try m.folder("app"), real = SessionFiles.real(folder)
        try write(Self.rows(real), m.projects(folder).appendingPathComponent("\(Self.session).jsonl"))
        let new = SessionCopy.newId()
        let source = CopySource(end: .mac(folder), id: Self.session, provider: "claude", title: "Repos")
        let made = try await m.copies.copy(source, to: b.end, as: new, line: "Copied from “Repos” · app").get()
        let chatId = try #require(made.chatId)
        let (chat, _) = b.rig.chat(b.connection, id: chatId)
        await chat.startOnce()
        #expect(await until { chat.status.sessionId == new && chat.context.usage?.window == 200_000 && chat.context.fraction == 0.15 })
        #expect(chat.canCompact)
        chat.close()
    }

    @Test func aBoxChatCopiedHereLandsUnderANewIdAndTheBoxKeepsRunningIt() async throws {
        let (b, m) = (try await box(), try mac())
        defer { b.rig.finish(); m.finish() }
        let hc = try #require(b.rig.host.newChat(folder: b.folder, provider: "claude", modelId: "haiku", title: "Repos", session: Self.session))
        try write(Self.rows(b.real), b.projects.appendingPathComponent("\(Self.session).jsonl"))
        let folder = try m.folder("elsewhere")
        let new = SessionCopy.newId()
        let made = try await m.copies.copy(CopySource(end: b.end, id: hc.id, provider: "claude", title: "Repos"), to: .mac(folder), as: new).get()
        #expect(made.session == new && made.chatId == nil && made.modelId == "haiku")
        #expect(try read(m.projects(folder).appendingPathComponent("\(new).jsonl")) == Self.rows(SessionFiles.real(folder), new))
        // The box's chat goes on as it was: never frozen, its file the same.
        #expect(hc.ownedHere && !hc.isFrozen && b.rig.host.chat(hc.id) != nil)
        #expect(try read(b.projects.appendingPathComponent("\(Self.session).jsonl")) == Self.rows(b.real))
        // Nothing is left in this Mac's staging.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: m.copies.staging.path)) ?? []).isEmpty)
    }

    /// A copy of a Claude chat cut back by a rollback it hasn't written past resumes where its
    /// source does: the point goes with it to its new id, from a box and to one.
    @Test func aCopyKeepsItsSourcesRollbackPoint() async throws {
        let (b, m) = (try await box(), try mac())
        let (here, there) = (SessionCopy.newId(), SessionCopy.newId())
        defer {
            b.rig.finish()
            m.finish()
            for id in [Self.session, here, there] { RollbackPoints.forget(id) }
        }
        let cut = "0a1b2c3d-0000-4000-8000-000000000003"
        let hc = try #require(b.rig.host.newChat(folder: b.folder, provider: "claude", modelId: "haiku", title: "Repos", session: Self.session))
        try write(Self.rows(b.real), b.projects.appendingPathComponent("\(Self.session).jsonl"))
        RollbackPoints.set(cut, for: Self.session)
        // Box to this Mac: the point is the box's, kept here under the copy's id.
        let folder = try m.folder("elsewhere")
        _ = try await m.copies.copy(CopySource(end: b.end, id: hc.id, provider: "claude", title: "Repos"), to: .mac(folder), as: here).get()
        #expect(RollbackPoints.at(here) == cut)
        // This Mac to the box: the box keeps it under its copy's id.
        let source = CopySource(end: .mac(folder), id: here, provider: "claude", title: "Repos")
        _ = try await m.copies.copy(source, to: b.end, as: there).get()
        #expect(RollbackPoints.at(there) == cut)
    }

    @Test func boxToBoxCopiesAndACutKeepsTheSourceUntilTheCopyIsPlaced() async throws {
        let (one, two, m) = (try await box(), try await box(), try mac())
        defer { one.rig.finish(); two.rig.finish(); m.finish() }
        let hc = try #require(one.rig.host.newChat(folder: one.folder, provider: "claude", modelId: nil, title: "Repos", session: Self.session))
        let file = one.projects.appendingPathComponent("\(Self.session).jsonl")
        try write(Self.rows(one.real), file)
        let source = CopySource(end: one.end, id: hc.id, provider: "claude", title: "Repos")

        // Metered: both legs on one bar (box to Mac, then Mac to box), ending at all of it.
        var copies = m.copies
        var heard: [(Int64, Int64)] = []
        copies.progress = { heard.append(($0, $1)) }
        let copied = try await copies.copy(source, to: two.end, line: "Copied from “Repos” · work on one").get()
        let size = Int64(Self.rows(one.real).utf8.count)
        #expect(heard.first.map { $0 == (0, size * 2) } == true)
        #expect(heard.last.map { $0 == (size * 2, size * 2) } == true)
        #expect(zip(heard, heard.dropFirst()).allSatisfy { $0.0 <= $1.0 })
        #expect(try read(two.projects.appendingPathComponent("\(copied.session).jsonl")) == Self.rows(two.real, copied.session))
        #expect(two.rig.host.chat(copied.chatId ?? "")?.record.copied == "Copied from “Repos” · work on one")

        // A cut to a folder the second box doesn't serve: the copy fails, the source stays as it was.
        let nowhere = CopyEnd.box(two.moves, folder: "/nowhere")
        let (failed, _) = await m.copies.cut(source, to: nowhere)
        // A cancelled one (the bar's Cancel) changes nothing either.
        var stopped = m.copies
        stopped.stopper = Spawn()
        stopped.stopper?.stop()
        let (cancelled, _) = await stopped.cut(source, to: two.end)
        #expect(throws: MoveFailure.self) { try cancelled.get() }
        #expect(one.rig.host.chat(hc.id) != nil && FileManager.default.fileExists(atPath: file.path))
        #expect(throws: MoveFailure.self) { try failed.get() }
        #expect(one.rig.host.chat(hc.id) != nil && FileManager.default.fileExists(atPath: file.path))

        // A cut that lands: the copy is placed and verified, then the source goes to kore-host's trash.
        let (moved, kept) = await m.copies.cut(source, to: two.end)
        let made = try moved.get()
        #expect(kept == nil && two.rig.host.chat(made.chatId ?? "") != nil)
        #expect(try read(two.projects.appendingPathComponent("\(made.session).jsonl")) == Self.rows(two.real, made.session))
        #expect(one.rig.host.chat(hc.id) == nil && !one.rig.host.closedChats.contains { $0.id == hc.id } && !FileManager.default.fileExists(atPath: file.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: one.rig.host.chatTrash.path)) ?? []).count == 1)
    }

    @Test func aMacFolderToFolderCutPutsTheOriginalInKoresTrash() async throws {
        let m = try mac()
        defer { m.finish() }
        let a = try m.folder("a"), b = try m.folder("b")
        let file = m.projects(a).appendingPathComponent("\(Self.session).jsonl")
        try write(Self.rows(SessionFiles.real(a)), file)
        let source = CopySource(end: .mac(a), id: Self.session, provider: "claude", title: "Repos")
        let (result, kept) = await m.copies.cut(source, to: .mac(b))
        let made = try result.get()
        #expect(kept == nil && made.session != Self.session)
        #expect(try read(m.projects(b).appendingPathComponent("\(made.session).jsonl")) == Self.rows(SessionFiles.real(b), made.session))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: m.copies.trash.path)
        #expect(trashed.count == 1)
        #expect(try read(m.copies.trash.appendingPathComponent("\(trashed[0])/\(Self.session).jsonl")) == Self.rows(SessionFiles.real(a)))
        // One with no session here: nothing changes.
        let gone = CopySource(end: .mac(a), id: SessionCopy.newId(), provider: "claude", title: "Gone")
        let none = await m.copies.cut(gone, to: .mac(b))
        #expect(throws: MoveFailure.self) { try none.copy.get() }
    }

    @Test func aMacChatCutToABoxGoesThroughChatAdoptAndABoxChatCutHereThroughRelease() async throws {
        let (b, m) = (try await box(), try mac())
        defer { b.rig.finish(); m.finish() }
        var moves = b.moves
        moves.env = m.env
        // Mac → box: 1.10's adopt as a new chat, same session; the Mac's original then to the trash.
        let folder = try m.folder("app")
        try write(Self.rows(SessionFiles.real(folder)), m.projects(folder).appendingPathComponent("\(Self.session).jsonl"))
        let sent = try await moves.send(session: Self.session, provider: "claude", from: folder, to: b.folder, title: "Repos", settings: ChatSettings()).get()
        let there = try #require(b.rig.host.chat(sent.chatId))
        #expect(there.record.session == Self.session && there.record.from == "MacBook" && there.ownedHere)
        #expect(try read(b.projects.appendingPathComponent("\(Self.session).jsonl")) == Self.rows(b.real))
        try await m.copies.removeSource(CopySource(end: .mac(folder), id: Self.session, provider: "claude", title: "Repos")).get()
        #expect(!FileManager.default.fileExists(atPath: m.projects(folder).appendingPathComponent("\(Self.session).jsonl").path))

        // Box → any Mac folder (no pair): 1.10's release, owner and gen; the box keeps a replica.
        let other = try m.folder("other")
        let brought = try await moves.bring(chatId: there.id, gen: 0, boxFolder: b.folder, macFolder: other).get()
        #expect(brought.moved.macFolder == other && brought.moved.gen == 1 && there.isReplica)
        #expect(try read(m.projects(other).appendingPathComponent("\(Self.session).jsonl")) == Self.rows(SessionFiles.real(other)))
    }
}
