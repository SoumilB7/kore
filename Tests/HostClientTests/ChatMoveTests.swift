import Foundation
import HostClient
import KoreCore
import KoreHost
import LinkProtocol
import src
import Testing

/// Link 1.10 from the Mac: a box chat brought here and sent back, against a kore-host in this
/// process, the session files moved by rsync through a stand-in ssh. Each side's CLI folders are
/// scratch ones (never the real `~/.claude`).
@MainActor
@Suite("chat moves", .serialized)
struct ChatMoveTests {
    static let session = "7d1e3c40-0000-4000-8000-00000000abcd"

    static func rows(_ folder: String, count: Int, from: Int = 0) -> String {
        (from..<(from + count)).map { i in
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"step \#(i) \#(String(repeating: "lorem ipsum ", count: 40))"},"uuid":"u\#(i)","timestamp":"2026-11-10T06:29:00.000Z","userType":"external","cwd":"\#(folder)","sessionId":"\#(session)","version":"2.1.318","gitBranch":"main"}"#
                + "\n"
        }.joined()
    }

    struct Sides {
        let rig: BoxRig
        let mac: URL
        let macEnv: [String: String]
        let pair: SyncPair
        let moves: ChatMoves
        let connection: HostConnection
        var boxProjects: URL { rig.root.appendingPathComponent("boxclaude/projects").appendingPathComponent(ClaudeHistory.projectKey(for: rig.folder)) }
        var macProjects: URL { rig.root.appendingPathComponent("macclaude/projects").appendingPathComponent(ClaudeHistory.projectKey(for: mac)) }
    }

    func sides() async throws -> Sides {
        let rig = try BoxRig()
        rig.host.sessionEnv = ["CLAUDE_CONFIG_DIR": rig.root.appendingPathComponent("boxclaude").path, "HOME": rig.root.path]
        let mac = rig.root.appendingPathComponent("mac")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let connection = rig.connection()
        connection.retain()
        #expect(await until { connection.isOnline })
        #expect(connection.moves)
        let store = MovedChats(root: rig.root.appendingPathComponent("cache"))
        var moves = ChatMoves(connection: connection, box: try fakeSSH(rig.root), staging: rig.root.appendingPathComponent("staging"), name: "MacBook", store: store)
        let macEnv = ["CLAUDE_CONFIG_DIR": rig.root.appendingPathComponent("macclaude").path, "HOME": rig.root.path]
        moves.env = macEnv
        return Sides(rig: rig, mac: mac, macEnv: macEnv, pair: SyncPair(mac: mac.path, alias: "local", box: rig.folder.path), moves: moves, connection: connection)
    }

    func write(_ text: String, _ url: URL, append: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    @Test func aChatGoesToTheMacAndBackLosingNothing() async throws {
        let s = try await sides()
        defer { s.rig.finish() }
        let boxFolder = SessionFiles.real(s.rig.folder.path), macFolder = SessionFiles.real(s.mac.path)
        let hc = try #require(s.rig.host.newChat(folder: s.rig.folder.path, provider: "claude", modelId: "haiku", title: "Repos", session: Self.session))
        let boxFile = s.boxProjects.appendingPathComponent("\(Self.session).jsonl")
        try write(Self.rows(boxFolder, count: 400), boxFile)
        try write(Self.rows(boxFolder, count: 3), s.boxProjects.appendingPathComponent("\(Self.session)/subagents/agent-a1.jsonl"))

        // The folder's sync has nothing to wait for (no watch on this link): settled.
        let flushed = await s.connection.move(.syncFlush, ControlArgs(folder: s.rig.folder.path))
        #expect(flushed.settled == true && flushed.watching == false)

        // Bring it here.
        let brought = try await s.moves.bring(chatId: hc.id, gen: 0, boxFolder: s.rig.folder.path, pair: s.pair).get()
        #expect(brought.moved.gen == 1 && brought.title == "Repos" && brought.moved.macFolder == s.mac.path)
        let macFile = s.macProjects.appendingPathComponent("\(Self.session).jsonl")
        #expect(try String(contentsOf: macFile, encoding: .utf8) == Self.rows(macFolder, count: 400))
        #expect(try String(contentsOf: s.macProjects.appendingPathComponent("\(Self.session)/subagents/agent-a1.jsonl"), encoding: .utf8) == Self.rows(macFolder, count: 3))
        #expect(hc.isReplica && hc.record.owner?.name == "MacBook" && s.moves.store.session(Self.session)?.boxChat == hc.id)
        // A replica takes nothing.
        #expect(await s.connection.call(hc.id, .send(text: "hi", files: [], queued: nil, id: "x")).code == .elsewhere)
        let size = (try FileManager.default.attributesOfItem(atPath: boxFile.path)[.size] as? Int) ?? 0
        print("move here: session \(size) B, rsync received \(brought.cost.rsyncReceived) B, sent \(brought.cost.rsyncSent) B, link \(brought.cost.linkBytes) B")

        // Two turns here, mirrored to the box's replica.
        let mirrored = await s.connection.move(
            .chatMirror,
            ControlArgs(chatId: hc.id, gen: 1, seq: 0, events: MirrorItems([StreamItem(s: 0, e: .userMessage(text: "on the Mac", attachments: [], id: "m1"))])))
        #expect(mirrored.mirrored == 1)
        try write(Self.rows(macFolder, count: 2, from: 400), macFile, append: true)

        // Send it back: only the new tail travels.
        let back = try await s.moves.sendBack(s.moves.store.session(Self.session)!, title: "Repos", settings: ChatSettings(modelId: "haiku"), mirrored: 1).get()
        #expect(back.chatId == hc.id && hc.ownedHere && hc.gen == 2)
        #expect(try String(contentsOf: boxFile, encoding: .utf8) == Self.rows(boxFolder, count: 402))
        #expect(s.moves.store.session(Self.session) == nil)
        print("move back: rsync sent \(back.cost.rsyncSent) B, received \(back.cost.rsyncReceived) B, link \(back.cost.linkBytes) B")
        #expect(back.cost.rsyncSent < size / 4)

        // And here again: the Mac's last copy seeds it, so only the box's new rows come.
        try write(Self.rows(boxFolder, count: 1, from: 402), boxFile, append: true)
        let again = try await s.moves.bring(chatId: hc.id, gen: 2, boxFolder: s.rig.folder.path, pair: s.pair).get()
        #expect(again.moved.gen == 3)
        #expect(try String(contentsOf: macFile, encoding: .utf8) == Self.rows(macFolder, count: 403))
        print("move here again: rsync received \(again.cost.rsyncReceived) B, sent \(again.cost.rsyncSent) B")
        #expect(again.cost.rsyncReceived < size / 4)
    }

    /// A rollback here, on a chat held from the box: the replica's events can't say it, so the
    /// return says no count and the box's log starts again (its next start reads the session),
    /// with no rolled-back turn. Without one, the replica's log is kept.
    @Test(arguments: [false, true]) func aRollbackHereGoesBackWhole(_ rolledBack: Bool) async throws {
        let s = try await sides()
        defer { s.rig.finish() }
        let hc = try #require(s.rig.host.newChat(folder: s.rig.folder.path, provider: "claude", modelId: "haiku", title: "Repos", session: Self.session))
        try write(Self.rows(SessionFiles.real(s.rig.folder.path), count: 3), s.boxProjects.appendingPathComponent("\(Self.session).jsonl"))
        let brought = try await s.moves.bring(chatId: hc.id, gen: 0, boxFolder: s.rig.folder.path, pair: s.pair).get()
        let mirrors = ChatMirrors()
        mirrors.store = s.moves.store
        mirrors.connection = { _ in s.connection }
        mirrors.every = 0.02
        let mirror = mirrors.mirror(brought.moved)
        s.connection.post(StreamWire.encode(ChatFollow(chatId: hc.id, after: nil, log: nil)))
        for (text, id) in [("kept", "k1"), ("gone", "g1")] {
            mirrors.event(session: Self.session, .userMessage(text: text, attachments: [], id: id))
            mirrors.event(session: Self.session, .turnFinished("t-\(id)", .completed, duration: .seconds(1)))
        }
        mirror.write()
        #expect(await until(30) { mirror.count == 4 && mirror.acked == 4 })
        func said(_ text: String) async -> Bool {
            await hc.stream.since(nil, log: nil).items.contains { if case .userMessage(text, _, _)? = $0.e { true } else { false } }
        }
        #expect(await said("gone"))

        // Back to “gone” here: its history replaced (never mirrored), and the mirror told.
        if rolledBack {
            mirrors.event(session: Self.session, .historyReplaced([.userMessage(text: "kept", attachments: [], id: "k1")]))
            mirrors.rolledBack(session: Self.session)
        }
        let moved = try #require(s.moves.store.session(Self.session))
        let count = mirrors.count(moved)
        #expect(count == (rolledBack ? nil : 4))
        let back = try await s.moves.sendBack(moved, title: "Repos", settings: ChatSettings(modelId: "haiku"), mirrored: count).get()
        #expect(back.chatId == hc.id && hc.ownedHere)
        #expect(await said("gone") == !rolledBack)
        #expect(await said("kept") == !rolledBack)
    }

    /// A Claude rollback with nothing written since lives outside the session file (the CLI
    /// resumes at the point, `--resume-session-at`): the point goes with the session both ways,
    /// and only a message's uuid is taken (anything else, the session resumes at its end).
    @Test func aRollbackPointGoesWithTheSession() async throws {
        let s = try await sides()
        defer {
            s.rig.finish()
            RollbackPoints.forget(Self.session)
        }
        let hc = try #require(s.rig.host.newChat(folder: s.rig.folder.path, provider: "claude", modelId: "haiku", title: "Repos", session: Self.session))
        try write(Self.rows(SessionFiles.real(s.rig.folder.path), count: 3), s.boxProjects.appendingPathComponent("\(Self.session).jsonl"))
        let onBox = "0a1b2c3d-0000-4000-8000-000000000001", onMac = "0a1b2c3d-0000-4000-8000-000000000002"
        var moves = s.moves
        var kept: [(String?, String)] = []
        moves.keepRollbackPoint = { kept.append(($0, $1)) }

        // Cut back on the box (a phone's rollback): the Mac's CLI resumes there too.
        RollbackPoints.set(onBox, for: Self.session)
        _ = try await moves.bring(chatId: hc.id, gen: 0, boxFolder: s.rig.folder.path, pair: s.pair).get()
        #expect(kept.count == 1 && kept.first?.0 == onBox && kept.first?.1 == Self.session)

        // Cut back here: the box's CLI resumes at this Mac's point.
        RollbackPoints.forget(Self.session)
        moves.rollbackPoint = { $0 == Self.session ? onMac : nil }
        _ = try await moves.sendBack(try #require(moves.store.session(Self.session)), title: "Repos", settings: ChatSettings(modelId: "haiku"), mirrored: nil).get()
        #expect(RollbackPoints.at(Self.session) == onMac)

        // A point that isn't a message's uuid never reaches a CLI's arguments: the box forgets its own.
        _ = try await moves.bring(chatId: hc.id, gen: 2, boxFolder: s.rig.folder.path, pair: s.pair).get()
        #expect(kept.last?.0 == onMac)
        moves.rollbackPoint = { _ in "--dangerously-skip-permissions" }
        _ = try await moves.sendBack(try #require(moves.store.session(Self.session)), title: "Repos", settings: ChatSettings(modelId: "haiku"), mirrored: nil).get()
        #expect(RollbackPoints.at(Self.session) == nil)
        #expect(LinkMoves.rollbackPoint("--resume-session-at") == nil && LinkMoves.rollbackPoint(onBox.uppercased()) == onBox.uppercased())
    }

    /// Catching up is waited for as long as a busy machine needs (30 s at most): what this guards is
    /// that every row is acked in few small frames, not how fast.
    @Test func anHourOfAChattyChatMirrorsInFewSmallFrames() async throws {
        let s = try await sides()
        defer { s.rig.finish() }
        let hc = try #require(s.rig.host.newChat(folder: s.rig.folder.path, provider: "claude", modelId: "haiku", title: "Repos", session: Self.session))
        try write(Self.rows(SessionFiles.real(s.rig.folder.path), count: 10), s.boxProjects.appendingPathComponent("\(Self.session).jsonl"))
        let brought = try await s.moves.bring(chatId: hc.id, gen: 0, boxFolder: s.rig.folder.path, pair: s.pair).get()
        let mirrors = ChatMirrors()
        mirrors.store = s.moves.store
        mirrors.connection = { _ in s.connection }
        mirrors.every = 0.02
        let mirror = mirrors.mirror(brought.moved)
        func peak() -> Int {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Int(usage.ru_maxrss)
        }
        // An hour's worth: 60 turns, each a message, 400 streamed pieces, three tools with output.
        func turn(_ t: Int) {
            mirrors.event(session: Self.session, .userMessage(text: "turn \(t)", attachments: [], id: "m\(t)"))
            mirrors.event(session: Self.session, .turnStarted("t\(t)", origin: .user, at: Date()))
            for p in 0..<400 { mirrors.event(session: Self.session, .text("a\(t)", .answer, "word\(p) ", agent: .main)) }
            for k in 0..<3 {
                for _ in 0..<50 { mirrors.event(session: Self.session, .toolOutput(id: "x\(t).\(k)", String(repeating: "o", count: 80) + "\n", agent: .main)) }
            }
            mirrors.event(session: Self.session, .turnFinished("t\(t)", .completed, duration: .seconds(3)))
        }
        // No client follows the replica: nothing goes, it waits on disk.
        let before = peak()
        for t in 0..<30 { turn(t) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(mirror.frames == 0 && mirror.count > 0)
        // The box window follows it: what waited goes, then each turn as it comes.
        s.connection.post(StreamWire.encode(ChatFollow(chatId: hc.id, after: nil, log: nil)))
        #expect(await until(30) { mirror.acked == mirror.count })
        for t in 30..<60 {
            turn(t)
            try await Task.sleep(for: .milliseconds(30))
        }
        mirror.write()
        #expect(await until(30) { mirror.acked == mirror.count })
        #expect(hc.record.owner?.mirrored == mirror.count)
        let held = await hc.stream.since(nil, log: nil).items.compactMap(\.e)
        let text = held.compactMap { if case .text(_, _, let t, _) = $0 { t } else { nil } }.joined()
        #expect(text.contains("word0 word1 ") && text.contains("word399 "))
        print("mirror, an hour: \(mirror.count) events in \(mirror.frames) frames, \(mirror.sentBytes) B on the link, resident +\((peak() - before) / 1024) KiB")
        #expect(mirror.frames < 200)
    }

    @Test func aStaleReturnStaysHereAndAFailedCopyUnfreezes() async throws {
        let s = try await sides()
        defer { s.rig.finish() }
        let hc = try #require(s.rig.host.newChat(folder: s.rig.folder.path, provider: "claude", modelId: "haiku", title: "Repos", session: Self.session))
        // No session file on the box: the move is refused, the chat stays the box's.
        let none = await s.moves.bring(chatId: hc.id, gen: 0, boxFolder: s.rig.folder.path, pair: s.pair)
        #expect(throws: MoveFailure.self) { try none.get() }
        #expect(hc.ownedHere)
        // A folder outside the pair: no move.
        let outside = await s.moves.bring(chatId: hc.id, gen: 0, boxFolder: "/elsewhere", pair: s.pair)
        #expect((try? outside.get()) == nil && hc.ownedHere)
    }
}

/// "The box" on this Mac through a stand-in ssh: everything after `--` and the alias runs under `sh -c`.
@MainActor
func fakeSSH(_ root: URL) throws -> SyncBox {
    let ssh = root.appendingPathComponent("fake-ssh")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("""
        #!/bin/sh
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        exec /bin/sh -c "$*"
        """.utf8).write(to: ssh)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
    return SyncBox.via(ssh.path, alias: "local", base: root.path)
}
