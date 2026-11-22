import Foundation
@testable import HostClient
import KoreCore
import KoreHost
import KoreTrust
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
    /// `drop`: the link this Mac dials it on, which a test ends partway.
    func box(pipe: Bool = false, drop: DropLink? = nil) async throws -> Box {
        let rig = try BoxRig()
        rig.host.sessionEnv = ["CLAUDE_CONFIG_DIR": rig.root.appendingPathComponent("boxclaude").path, "HOME": rig.root.path]
        let connection = drop.map { $0.connection(rig) } ?? rig.connection()
        connection.backoff = [.milliseconds(20)]
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
            #expect(said == ChatSettings(modelId: "m", effort: "low", mode: within ? mode.id : provider.modes[0].id, planAllow: false, modeCeiling: 1), "\(mode.id)")
        }
        #expect(ChatSettings().asked(provider: id).mode == provider.modes[0].id)
        #expect(try #require(ModeLevel(rawValue: provider.modes[0].level)) <= LinkPolicy.leavePlanMaxLevel)
        if id == "claude" { #expect(["auto", "acceptEdits"].allSatisfy { ChatSettings(mode: $0).asked(provider: id).mode == "default" }) }
        if id == "codex" { #expect(ChatSettings(mode: "approveForMe").asked(provider: id).mode == "askForApproval") }
    }

    /// A CLI's session files: written under a folder, and read back for a session.
    @MainActor
    struct Files {
        let provider: String
        func text(_ folder: String, _ session: String) -> String {
            provider == "codex" ? ChatCopyClientTests.codexRows(folder, session) : ChatCopyClientTests.rows(folder, session)
        }
        func file(_ env: [String: String], _ folder: String, _ session: String) -> URL {
            provider == "codex"
                ? SessionFiles.codexSessions(env).appendingPathComponent("2026/11/10/rollout-2026-11-10T06-29-00-\(session).jsonl")
                : SessionCopy.target(provider: "claude", folder: folder, env: env).appendingPathComponent("\(session).jsonl")
        }
        /// What's on disk for `session` (Codex keeps the rollout's day and time, whatever its folder).
        func read(_ env: [String: String], _ folder: String, _ session: String) -> String? {
            try? String(contentsOf: file(env, folder, session), encoding: .utf8)
        }
    }

    /// A phone's copy over SSH, each CLI: Mac to box, box to box, box to Mac. The rows cross whole
    /// under a new session in the new folder, each source stays, and each copy is capped.
    @Test(arguments: ["claude", "codex"])
    func aPhonesCopyToABoxIsWholeAndCappedOnEveryRoute(_ provider: String) async throws {
        let (one, two, m) = (try await box(), try await box(), try mac())
        defer { one.finish(); two.finish(); m.finish() }
        let cli = try #require(Registry.provider(provider)), files = Files(provider: provider)
        let top = try #require(cli.modes.max { $0.level < $1.level }?.id)
        let (capped, boxed) = (cli.modes[0].id, LinkPolicy.cappedMode(top, provider: provider))
        let folder = try m.folder("app"), real = SessionFiles.real(folder)
        try write(files.text(real, Self.session), files.file(m.env, folder, Self.session))
        let full = ChatSettings(mode: top, planAllow: true, arsenal: "drive")
        let source = CopySource(end: .mac(folder), id: Self.session, provider: provider, title: "Repos", settings: full)
        // The Mac's own paste carries Full access to a box that takes it; a phone's doesn't.
        let own = try await m.copies.copy(source, to: one.end).get()
        var copies = m.copies
        copies.asked = true
        let asked = try await copies.copy(source, to: one.end, line: "Copied from “Repos” · app").get()
        let kept = try #require(one.rig.host.chat(own.chatId ?? "")), low = try #require(one.rig.host.chat(asked.chatId ?? ""))
        #expect(kept.record.mode == (one.connection.takesFullAccess ? top : boxed))
        #expect(low.record.mode == capped && low.record.arsenal == nil && low.record.planAllow != true)
        // Its ceiling goes with it, before its CLI ever starts there: its history may end higher.
        #expect(ModeCeilings.at(asked.session) == 1 && ModeCeilings.at(own.session) == nil)
        let first = try #require(one.rig.host.live(low))
        #expect(first.modeCeiling == 1 && first.controls.mode == capped)
        #expect(low.record.provider == provider && low.record.session == asked.session && low.record.copied == "Copied from “Repos” · app")
        #expect(files.read(one.rig.host.sessionEnv, one.real, asked.session) == files.text(one.real, asked.session))
        #expect(files.read(m.env, folder, Self.session) == files.text(real, Self.session))
        // Box to box: the settings come from the box, and are capped on the way through.
        let crossed = try await copies.copy(CopySource(end: one.end, id: kept.id, provider: provider, title: "Repos"), to: two.end).get()
        let there = try #require(two.rig.host.chat(crossed.chatId ?? ""))
        #expect(there.record.mode == capped && there.record.arsenal == nil && there.record.planAllow != true)
        #expect(files.read(two.rig.host.sessionEnv, two.real, crossed.session) == files.text(two.real, crossed.session))
        #expect(ModeCeilings.at(crossed.session) == 1)
        // Box to Mac: what the copy lands with here.
        let back = try await copies.copy(CopySource(end: one.end, id: kept.id, provider: provider, title: "Repos"), to: .mac(folder)).get()
        #expect(back.settings.mode == capped && back.settings.arsenal == nil && back.settings.planAllow == false)
        #expect(back.settings.modeCeiling == 1 && ModeCeilings.at(back.session) == 1)
        defer { for id in [asked.session, crossed.session, back.session] { ModeCeilings.put(nil, for: id) } }
        // The Mac's own copy of a capped one is under it still.
        let next = try await m.copies.copy(CopySource(end: one.end, id: low.id, provider: provider, title: "Repos"), to: two.end).get()
        #expect(ModeCeilings.at(next.session) == 1)
        ModeCeilings.put(nil, for: next.session)
        #expect(files.read(m.env, folder, back.session) == files.text(real, back.session))
        // The box's own goes on as it was.
        #expect(kept.ownedHere && !kept.isFrozen && files.read(one.rig.host.sessionEnv, one.real, own.session) == files.text(one.real, own.session))
        #expect(Set([Self.session, own.session, asked.session, crossed.session, back.session]).count == 5)
    }

    /// A phone allowed on one box and not the other, each box deciding by its own devices, whatever
    /// the Mac may do there: refused to it, from it, and between them either way; allowed, it goes.
    @Test func aPhonesCopyNeedsEachBoxToAllowThePhone() async throws {
        let (one, two, m) = (try await box(), try await box(), try mac())
        defer { one.finish(); two.finish(); m.finish() }
        let phone = UUID()
        func allow(_ b: Box, _ change: (inout DeviceRecord) -> Void = { _ in }) throws {
            var record = DeviceRecord(
                id: phone, name: "Pixel 9", kind: .phone, abilities: [.read, .ask], identityKey: SoftwareIdentity().publicKey, nodeKeys: ["nodekey:pixel"], userId: 7,
                fqdn: "pixel.tail.ts.net.", added: Date())
            change(&record)
            try b.rig.host.devices.book.update { $0.removeAll { $0.id == phone }; $0.append(record) }
        }
        try allow(one)
        let folder = try m.folder("app"), files = Files(provider: "claude")
        try write(files.text(SessionFiles.real(folder), Self.session), files.file(m.env, folder, Self.session))
        var copies = m.copies
        copies.asked = true
        copies.phone = phone
        let here = CopySource(end: .mac(folder), id: Self.session, provider: "claude", title: "Repos")
        let made = try await copies.copy(here, to: one.end).get()
        // The second box has a chat of its own to copy from.
        let its = try await m.copies.copy(here, to: two.end).get()
        let no = MoveFailure("This phone isn't allowed on \(two.rig.host.deviceName)", .deniedControl)
        let onOne = CopySource(end: one.end, id: made.chatId ?? "", provider: "claude", title: "Repos")
        let onTwo = CopySource(end: two.end, id: its.chatId ?? "", provider: "claude", title: "Repos")
        let home = try m.folder("home")
        for standing in ["never allowed", "paused", "watch-only"] {
            if standing == "paused" { try allow(two) { $0.paused = true } }
            if standing == "watch-only" { try allow(two) { $0.abilities = [.read] } }
            for said in [await copies.copy(here, to: two.end), await copies.copy(onTwo, to: .mac(home)), await copies.copy(onOne, to: two.end), await copies.copy(onTwo, to: one.end)] {
                #expect(throws: no, "\(standing)") { try said.get() }
            }
        }
        #expect(one.rig.host.chats.count == 1 && two.rig.host.chats.count == 1)
        #expect(!FileManager.default.fileExists(atPath: m.projects(home).path))
        // Allowed there too: every way goes.
        try allow(two)
        for said in [await copies.copy(here, to: two.end), await copies.copy(onTwo, to: .mac(home)), await copies.copy(onOne, to: two.end), await copies.copy(onTwo, to: one.end)] {
            _ = try said.get()
        }
        // A box from before it could check: refused, not trusted.
        one.connection.welcomed(caps: one.connection.caps.filter { $0 != LinkPolicy.copyForCap }, control: .full)
        for said in [await copies.copy(here, to: one.end), await copies.copy(onOne, to: .mac(home)), await copies.copy(onTwo, to: one.end)] {
            #expect(throws: MoveFailure("Update kore-host on local to copy from a phone")) { try said.get() }
        }
        // The Mac's own copies ask no phone.
        _ = try await m.copies.copy(here, to: one.end).get()
    }

    /// What a copy over a link that goes must leave: the source as it was, nothing of it here or
    /// staged there, and these many chats on the box.
    func expectLeft(_ b: Box, _ m: Mac, files: Files, folder: String, chats: Int) async {
        #expect(b.rig.host.chats.count == chats)
        #expect(files.read(m.env, folder, Self.session) == files.text(SessionFiles.real(folder), Self.session))
        #expect(await until { ((try? FileManager.default.contentsOfDirectory(atPath: b.rig.host.paths.state.appendingPathComponent("staging").path)) ?? []).isEmpty })
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: m.copies.staging.path)) ?? []).isEmpty)
    }

    /// The link goes as the box makes the copy, before this Mac hears: it's asked again once the
    /// link is back, and there is one chat.
    @Test(arguments: ["claude", "codex"])
    func aLinkLostAfterTheBoxMadeTheCopyEndsInOneChat(_ provider: String) async throws {
        let drop = DropLink()
        let (b, m) = (try await box(drop: drop), try mac())
        defer { b.finish(); m.finish() }
        let folder = try m.folder("app"), files = Files(provider: provider)
        try write(files.text(SessionFiles.real(folder), Self.session), files.file(m.env, folder, Self.session))
        drop.at = .answerOf("chat.adoptCopy", phase: "commit")
        let made = try await m.copies.copy(CopySource(end: .mac(folder), id: Self.session, provider: provider, title: "Repos"), to: b.end).get()
        #expect(drop.dropped == 1 && drop.dials == 2)
        #expect(b.rig.host.chat(made.chatId ?? "")?.record.session == made.session)
        #expect(files.read(b.rig.host.sessionEnv, b.real, made.session) == files.text(b.real, made.session))
        await expectLeft(b, m, files: files, folder: folder, chats: 1)
    }

    /// It goes before the box has the last step: nothing was made, one plain line, and the same
    /// copy again makes one.
    @Test func aLinkLostBeforeTheBoxHeardChangesNothingAndSaysSo() async throws {
        let drop = DropLink()
        let (b, m) = (try await box(drop: drop), try mac())
        defer { b.finish(); m.finish() }
        let folder = try m.folder("app"), files = Files(provider: "claude")
        try write(files.text(SessionFiles.real(folder), Self.session), files.file(m.env, folder, Self.session))
        drop.at = .sending("chat.adoptCopy", phase: "commit")
        let source = CopySource(end: .mac(folder), id: Self.session, provider: "claude", title: "Repos")
        let said = await m.copies.copy(source, to: b.end)
        #expect(throws: MoveFailure("Lost local partway · nothing changed", .goneSession)) { try said.get() }
        await expectLeft(b, m, files: files, folder: folder, chats: 0)
        let made = try await m.copies.copy(source, to: b.end).get()
        #expect(b.rig.host.chats.map(\.id) == [made.chatId])
    }

    /// It goes as the box makes the copy and never comes back: the line says it may be there.
    @Test func aBoxThatNeverComesBackIsALineThatSaysToLook() async throws {
        let drop = DropLink()
        let (b, m) = (try await box(drop: drop), try mac())
        defer { b.finish(); m.finish() }
        let folder = try m.folder("app"), files = Files(provider: "claude")
        try write(files.text(SessionFiles.real(folder), Self.session), files.file(m.env, folder, Self.session))
        drop.at = .answerOf("chat.adoptCopy", phase: "commit")
        drop.stays = true
        var copies = m.copies
        copies.patience = .milliseconds(150)
        let said = await copies.copy(CopySource(end: .mac(folder), id: Self.session, provider: "claude", title: "Repos"), to: b.end)
        #expect(throws: MoveFailure("Lost local at the end · look there before copying again", .unknown)) { try said.get() }
        await expectLeft(b, m, files: files, folder: folder, chats: 1)
    }

    /// The box goes while the files cross (its link and its rsync both): the copy ends at once
    /// with one line, its clean-up not waiting for the link.
    @Test func aBoxLostWhileTheFilesCrossEndsAtOnce() async throws {
        let drop = DropLink()
        let (b, m) = (try await box(drop: drop), try mac())
        defer { b.finish(); m.finish() }
        let folder = try m.folder("app"), files = Files(provider: "claude")
        try write(files.text(SessionFiles.real(folder), Self.session), files.file(m.env, folder, Self.session))
        drop.stays = true
        let gone = b.rig.root.appendingPathComponent("gone")
        let ssh = b.rig.root.appendingPathComponent("fake-ssh")
        try Data("#!/bin/sh\ntouch '\(gone.path)'\nsleep 0.3\nexit 255\n".utf8).write(to: ssh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        let watch = Task { @MainActor in
            _ = await until { FileManager.default.fileExists(atPath: gone.path) }
            drop.end()
        }
        let said = await m.copies.copy(CopySource(end: .mac(folder), id: Self.session, provider: "claude", title: "Repos"), to: b.end)
        await watch.value
        #expect(throws: MoveFailure("Couldn't copy the session: local can't be reached over SSH right now", nil)) { try said.get() }
        #expect(!b.connection.isOnline)
        await expectLeft(b, m, files: files, folder: folder, chats: 0)
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

/// A box's link a test ends partway: as one message goes out (the box never gets it), or as its
/// answer comes (the box ran it). `stays`: every dial after that fails.
@MainActor
final class DropLink {
    enum At {
        case sending(String, phase: String)
        case answerOf(String, phase: String)
    }

    var at: At?
    var stays = false
    private(set) var dropped = 0
    private(set) var dials = 0
    fileprivate var awaited: String?
    private weak var live: DropTransport?

    func connection(_ rig: BoxRig) -> HostConnection {
        let (path, grant) = (rig.host.paths.socket.path, rig.grant)
        return HostConnection(alias: "local", cache: HostCache(alias: "local", root: rig.root.appendingPathComponent("cache"))) { [self] in
            MainActor.assumeIsolated {
                if dropped > 0, stays { return ClosedTransport("gone") }
                dials += 1
                let made = DropTransport(DaemonTransport(path: path, grant: grant), self)
                live = made
                return made
            }
        }
    }

    /// The link goes now.
    func end() {
        dropped += 1
        live?.drop()
    }

    fileprivate func sends(_ data: Data) -> Bool {
        guard let at, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let cmd = object["cmd"] as? [String: Any] else { return true }
        switch at {
        case .sending(let type, let phase) where cmd["type"] as? String == type && cmd["phase"] as? String == phase:
            self.at = nil
            end()
            return false
        case .answerOf(let type, let phase) where cmd["type"] as? String == type && cmd["phase"] as? String == phase:
            self.at = nil
            awaited = object["id"] as? String
            return true
        default: return true
        }
    }

    fileprivate func hears(_ data: Data) -> Bool {
        guard let awaited, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] as? String == awaited else { return true }
        self.awaited = nil
        end()
        return false
    }
}

final class DropTransport: HostTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let inner: DaemonTransport
    private let link: DropLink
    private var pump: Task<Void, Never>?

    init(_ inner: DaemonTransport, _ link: DropLink) {
        self.inner = inner
        self.link = link
        (events, continuation) = AsyncStream.makeStream()
    }

    func start() throws {
        try inner.start()
        pump = Task { @MainActor [inner, link, continuation] in
            for await event in inner.events {
                if case .frame(let data) = event, !link.hears(data) { return }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func send(_ payload: Data) {
        if MainActor.assumeIsolated({ link.sends(payload) }) { inner.send(payload) }
    }

    func close() { inner.close() }

    /// The link is gone: both ends hear it end.
    func drop() {
        pump?.cancel()
        inner.close()
        continuation.yield(.closed("gone"))
        continuation.finish()
    }
}
