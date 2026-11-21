import Foundation
import HostClient
import KoreCore
@testable import KoreHost
import LinkProtocol
import src
import Testing

/// A chat's own settings (`ChatSettings`) on every copy, cut and move between this Mac and
/// stand-in boxes: model, effort, mode, fast, plan, Plan's allow switch, the auto-compact point,
/// the login where the target has it, the Arsenal tier; the draft on a move and a cut, never on a
/// copy; on a send back the newer settings win. Every CLI folder is a scratch one.
@MainActor
@Suite("chat settings carried", .serialized)
struct ChatSettingsCarryTests {
    let base = ChatCopyClientTests()
    static let session = ChatMoveTests.session

    /// A box whose Claude has an added login named `logins` (a folder each, in its scratch home).
    func box(logins: [String] = []) async throws -> ChatCopyClientTests.Box {
        let made = try await base.box()
        for login in logins {
            try FileManager.default.createDirectory(
                at: made.rig.root.appendingPathComponent(".config/claude-accounts/\(login)"), withIntermediateDirectories: true)
        }
        return made
    }

    /// A box chat with every setting of its own, its session on the box.
    func settled(_ b: ChatCopyClientTests.Box, login: String? = "work") throws -> HostChat {
        let hc = try #require(b.rig.host.newChat(folder: b.folder, provider: "claude", modelId: "haiku", title: "Repos", mode: "acceptEdits", effort: "low", session: Self.session))
        hc.setAccount(login)
        hc.setAutoCompact(70)
        hc.setDraft("half done")
        hc.carry(ChatSettings(fast: true, planAllow: true))
        b.rig.host.arsenalSaid("own", hc)
        try base.write(ChatCopyClientTests.rows(b.real), b.projects.appendingPathComponent("\(Self.session).jsonl"))
        return hc
    }

    func expectAll(_ s: ChatSettings, draft: String?) {
        #expect(s.modelId == "haiku" && s.effort == "low" && s.mode == "acceptEdits")
        #expect(s.fast == true && s.planAllow == true && s.autoCompact == 70 && s.arsenal == "own" && s.login == "work")
        #expect(s.draft == draft)
    }

    @Test func aBoxChatCopiedHereCarriesItsSettingsAndACutItsDraftToo() async throws {
        let (b, m) = (try await box(logins: ["work"]), try base.mac())
        defer { b.rig.finish(); m.finish() }
        let hc = try settled(b)
        let folder = try m.folder("here")
        let source = CopySource(end: b.end, id: hc.id, provider: "claude", title: "Repos")
        let copied = try await m.copies.copy(source, to: .mac(folder)).get()
        expectAll(copied.settings, draft: nil)
        #expect(copied.settings.at == nil)
        let cut = try await m.copies.cut(source, to: .mac(try m.folder("there"))).copy.get()
        expectAll(cut.settings, draft: "half done")
    }

    @Test func boxToBoxCarriesTheLoginWhereItIsAndFallsBackWhereItIsnt() async throws {
        let (one, two, three, m) = (try await box(logins: ["work"]), try await box(logins: ["work"]), try await box(), try base.mac())
        defer { one.rig.finish(); two.rig.finish(); three.rig.finish(); m.finish() }
        let hc = try settled(one)
        let source = CopySource(end: one.end, id: hc.id, provider: "claude", title: "Repos")

        let there = try await m.copies.copy(source, to: two.end).get()
        let made = try #require(two.rig.host.chat(there.chatId ?? ""))
        #expect(made.record.account == "work" && made.record.autoCompact == 70 && made.record.fast == true && made.record.planAllow == true)
        #expect(made.record.mode == "acceptEdits" && made.record.effort == "low" && made.arsenal == "own" && there.notes.isEmpty)
        // A copy leaves the draft with its original.
        #expect(made.record.draft == nil && hc.record.draft == "half done")

        // Not signed in on the third: its folder's login, said once.
        let elsewhere = try await m.copies.copy(source, to: three.end).get()
        let other = try #require(three.rig.host.chat(elsewhere.chatId ?? ""))
        #expect(other.record.account == nil && other.record.autoCompact == 70 && other.arsenal == "own")
        #expect(elsewhere.notes == ["work isn't signed in here · on main"])
    }

    @Test func aMacChatCopiedToABoxCarriesItsSettingsWithoutTheLoginItHasNot() async throws {
        let (b, m) = (try await box(), try base.mac())
        defer { b.rig.finish(); m.finish() }
        let folder = try m.folder("app")
        try base.write(ChatCopyClientTests.rows(SessionFiles.real(folder)), m.projects(folder).appendingPathComponent("\(Self.session).jsonl"))
        let settings = ChatSettings(
            modelId: "haiku", effort: "high", mode: "acceptEdits", fast: true, planAllow: true, autoCompact: 0, arsenal: "device", draft: "mine", at: 5)
        let source = CopySource(end: .mac(folder), id: Self.session, provider: "claude", title: "Repos", settings: settings)
        let copied = try await m.copies.copy(source, to: b.end).get()
        let made = try #require(b.rig.host.chat(copied.chatId ?? ""))
        // Off is a point of its own; Act device is this box's (it says so in its welcome).
        #expect(made.record.autoCompact == 0 && made.record.fast == true && made.record.planAllow == true && made.arsenal == "device")
        #expect(made.record.modelId == "haiku" && made.record.effort == "high" && made.record.mode == "acceptEdits")
        #expect(made.record.draft == nil && made.record.account == nil && copied.notes.isEmpty)
    }

    @Test func aMovedChatCarriesItsSettingsAndTheNewerWinOnTheWayBack() async throws {
        let s = try await ChatMoveTests().sides()
        defer { s.rig.finish() }
        try FileManager.default.createDirectory(at: s.rig.root.appendingPathComponent(".config/claude-accounts/work"), withIntermediateDirectories: true)
        let hc = try #require(s.rig.host.newChat(folder: s.rig.folder.path, provider: "claude", modelId: "haiku", title: "Repos", session: Self.session))
        hc.setAccount("work")
        hc.setAutoCompact(70)
        hc.setDraft("half done")
        s.rig.host.arsenalSaid("drive", hc)
        let boxFile = s.boxProjects.appendingPathComponent("\(Self.session).jsonl")
        try ChatMoveTests().write(ChatMoveTests.rows(SessionFiles.real(s.rig.folder.path), count: 3), boxFile)

        // Here: everything, the draft too.
        let brought = try await s.moves.bring(chatId: hc.id, gen: 0, boxFolder: s.rig.folder.path, pair: s.pair).get()
        #expect(brought.settings.autoCompact == 70 && brought.settings.draft == "half done" && brought.settings.login == "work")
        #expect(brought.settings.arsenal == "drive" && brought.settings.at == nil)

        // Changed here after: the Mac's point, draft and tier go back (the box's were older).
        var mine = brought.settings
        (mine.autoCompact, mine.draft, mine.arsenal, mine.at, mine.changed) = (90, "next step", "own", ChatSettings.ms(Date()), true)
        let moved = try #require(s.moves.store.session(Self.session))
        let back = try await s.moves.sendBack(moved, title: "Repos", settings: mine, mirrored: nil).get()
        #expect(back.chatId == hc.id && hc.ownedHere)
        #expect(hc.record.autoCompact == 90 && hc.record.draft == "next step" && hc.arsenal == "own" && hc.record.account == "work")

        // Here again, then changed on the box's replica and not on this Mac: the box's stay.
        let again = try await s.moves.bring(chatId: hc.id, gen: 2, boxFolder: s.rig.folder.path, pair: s.pair).get()
        var stale = again.settings
        stale.changed = false
        stale.autoCompact = 50
        hc.setAutoCompact(60)
        stale.draft = "typed on the Mac"
        let moved2 = try #require(s.moves.store.session(Self.session))
        let back2 = try await s.moves.sendBack(moved2, title: "Repos", settings: stale, mirrored: nil).get()
        // The box says what stood, for this Mac's tab; the draft is the Mac's whichever won.
        #expect(hc.record.autoCompact == 60 && back2.settings.autoCompact == 60 && back2.settings.arsenal == "own")
        #expect(hc.record.draft == "typed on the Mac" && back2.settings.draft == nil)

        // Nothing changed on either side since the move: the Mac's (the box's as they came) stand.
        let third = try await s.moves.bring(chatId: hc.id, gen: 4, boxFolder: s.rig.folder.path, pair: s.pair).get()
        var unchanged = third.settings
        unchanged.draft = ""
        let moved3 = try #require(s.moves.store.session(Self.session))
        _ = try await s.moves.sendBack(moved3, title: "Repos", settings: unchanged, mirrored: nil).get()
        #expect(hc.record.autoCompact == 60 && hc.record.draft == nil)

        // Changed on a Mac whose clock is ten minutes behind, nothing on the box: the Mac's. A login
        // the box no longer has gives way to the one the chat had there, said.
        let fourth = try await s.moves.bring(chatId: hc.id, gen: 6, boxFolder: s.rig.folder.path, pair: s.pair).get()
        var behind = fourth.settings
        (behind.autoCompact, behind.login, behind.at, behind.changed) = (80, "gone", ChatSettings.ms(Date()) - 600_000, true)
        let moved4 = try #require(s.moves.store.session(Self.session))
        let back4 = try await s.moves.sendBack(moved4, title: "Repos", settings: behind, mirrored: nil).get()
        #expect(hc.record.autoCompact == 80 && hc.record.account == "work")
        #expect(back4.notes == ["gone isn't signed in here · on work"] && back4.settings.login == "work")

        // Changed on both, whichever clock is ahead: the Mac's, which held it. A Mac that doesn't
        // say whether it changed them (one from before): the Mac's too.
        for (gen, said) in [(8, true), (10, nil)] as [(Int, Bool?)] {
            let here = try await s.moves.bring(chatId: hc.id, gen: gen, boxFolder: s.rig.folder.path, pair: s.pair).get()
            hc.setAutoCompact(90)
            var both = here.settings
            (both.autoCompact, both.at, both.changed) = (50, ChatSettings.ms(Date()) - 600_000, said)
            let moved = try #require(s.moves.store.session(Self.session))
            _ = try await s.moves.sendBack(moved, title: "Repos", settings: both, mirrored: nil).get()
            #expect(hc.record.autoCompact == 50, "\(String(describing: said))")
        }
    }

    @Test func aMacChatCutToABoxCarriesItsDraftAndSaysTheLoginItFellBackFrom() async throws {
        let (b, m) = (try await box(), try base.mac())
        defer { b.rig.finish(); m.finish() }
        var moves = b.moves
        moves.env = m.env
        let folder = try m.folder("app")
        try base.write(ChatCopyClientTests.rows(SessionFiles.real(folder)), m.projects(folder).appendingPathComponent("\(Self.session).jsonl"))
        let settings = ChatSettings(modelId: "haiku", autoCompact: 80, login: "work", arsenal: "watch", draft: "carry me")
        let sent = try await moves.send(session: Self.session, provider: "claude", from: folder, to: b.folder, title: "Repos", settings: settings).get()
        let there = try #require(b.rig.host.chat(sent.chatId))
        #expect(there.record.autoCompact == 80 && there.record.draft == "carry me" && there.arsenal == "watch" && there.record.account == nil)
        #expect(sent.notes == ["work isn't signed in here · on main"])
    }
}
