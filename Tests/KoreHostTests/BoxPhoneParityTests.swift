#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
@testable import KoreCore
import KoreTrust
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A phone on a box gets what a phone on a Mac gets: "/" commands while the chat's CLI sleeps,
/// uploads, attachments, diffs and earlier history, Auto's cards, and the box's own words.
@Suite("kore-host, a phone's parity with a Mac", .serialized)
@MainActor
struct BoxPhoneParityTests {
    /// A box with one chat, each CLI start a new stand-in, and a grant at `control`.
    func rig(_ provider: String = "claude", control: GrantControl = .act) throws -> (HostRig, Grant, HostChat, () -> [StreamStandIn]) {
        let rig = try HostRig()
        rig.host.sessionEnv["HOME"] = rig.root.path
        try rig.host.start()
        var made: [StreamStandIn] = []
        rig.host.services.backend = { _, _ in
            let backend = StreamStandIn()
            made.append(backend)
            return backend
        }
        let grant = try GrantStore(rig.paths.grants).allow("phone", control: control, socket: rig.paths.socket)
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: provider, modelId: nil))
        return (rig, grant, hc, { made })
    }

    func result(_ client: StreamClient, _ id: String) async throws -> LinkMessage.Result {
        var found: LinkMessage.Result?
        try await until {
            found = client.frames.lazy.compactMap { data -> LinkMessage.Result? in
                guard case .result(let r)? = try? LinkMessage.decode(data), r.id == id else { return nil }
                return r
            }.first
            return found != nil
        }
        return found!
    }

    func upload(_ client: StreamClient, _ id: String, name: String, mime: String, _ data: Data) async throws -> LinkMessage.Result {
        client.socket.send(.blobPutBegin(uploadId: id, name: name, mime: mime, size: data.count, sha256: LinkUploads.hex(SHA256.hash(data: data))))
        client.socket.send(.blobPutChunk(uploadId: id, index: 0, data: data.base64EncodedString()))
        client.socket.send(.blobPutEnd(uploadId: id))
        return try await result(client, "blob.put:" + id)
    }

    func message(_ client: StreamClient, where match: (LinkMessage) -> Bool) async throws -> LinkMessage {
        var found: LinkMessage?
        try await until {
            found = client.frames.lazy.compactMap { try? LinkMessage.decode($0) }.first(where: match)
            return found != nil
        }
        return found!
    }

    // MARK: 1. "/" commands while the CLI sleeps

    @Test(arguments: ["claude", "codex"])
    func slashCommandsGoWhileTheCLISleeps(_ provider: String) async throws {
        let (rig, _, hc, made) = try rig(provider)
        defer { rig.finish() }
        // Never started: the CLI's own built-ins.
        let builtin = provider == "claude" ? "security-review" : "goal"
        #expect(HostMeta.facts(hc).commands.contains(builtin))
        #expect(HostMeta.meta(hc).commands?.contains { $0.name == builtin } == true)
        #expect(LinkPolicy.check(.send(chatId: hc.id, text: "/nope", blobs: []), HostMeta.facts(hc)) == .deny(.command, "This chat doesn't offer /nope."))
        // Started: the CLI's list ("review" from the stand-in), kept with the chat.
        #expect(rig.host.apply(.send(chatId: hc.id, text: "hi"), id: "1", control: .act) { _ in }?.ok == true)
        try await until { hc.record.commands?.map(\.name) == ["review"] && hc.idle }
        rig.host.sleep(hc)
        #expect(!hc.cliRunning)
        // And Kore's /rename besides.
        #expect(HostMeta.facts(hc).commands == ["review", "rename"])
        #expect(HostMeta.meta(hc).commands?.map(\.name) == ["review", "rename"])
        // Asleep, the command is taken, starts the CLI and reaches it.
        #expect(rig.host.apply(.send(chatId: hc.id, text: "/review now"), id: "2", control: .act) { _ in }?.ok == true)
        try await until { made().count == 2 && made()[1].calls.contains { $0.hasPrefix("send /review now") } }
        // Kept across a restart.
        rig.restart()
        let back = try #require(rig.host.chat(hc.id))
        #expect(back.record.commands?.map(\.name) == ["review"] && HostMeta.facts(back).commands == ["review", "rename"])
    }

    // MARK: 2. Uploads from a phone

    @Test func aPhoneThatActsUploadsAndSendsFiles() async throws {
        let (rig, grant, hc, made) = try rig()
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        let welcome = try await message(client) { if case .welcome = $0 { true } else { false } }
        guard case .welcome(let w) = welcome else { return }
        #expect(w.caps.contains("blob") && w.caps.contains("diff"))
        #expect(!w.caps.contains("group") && !w.caps.contains("board"), "a box has no groups or boards")
        let data = Data("notes for the box\n".utf8)
        let put = try await upload(client, "u1", name: "notes.txt", mime: "text/plain", data)
        let blob = try #require(put.blobId)
        client.socket.send(.cmd(id: "s1", .send(chatId: hc.id, text: "read this", blobs: [blob])))
        #expect(try await result(client, "s1").ok)
        try await until { made().first?.files.isEmpty == false }
        #expect(try Data(contentsOf: try #require(made().first?.files.first?.url)) == data)
        // Sent once: the same blob again, or one never uploaded, is refused in words.
        client.socket.send(.cmd(id: "s2", .send(chatId: hc.id, text: "again", blobs: [blob])))
        let again = try await result(client, "s2")
        #expect(again.code == .goneBlob && again.message == "A file wasn't uploaded, or expired. Attach it again.")
        // A message carries ten files at most, as from a Mac.
        client.socket.send(.cmd(id: "s3", .send(chatId: hc.id, text: "x", blobs: (0..<11).map { "b\($0)" })))
        #expect(try await result(client, "s3").code == .goneBlob)
        #expect(LinkPolicy.check(.send(chatId: hc.id, text: "x", blobs: (0..<11).map { "b\($0)" }), HostMeta.facts(hc)) == .deny(.invalid, "Nothing to send, or too long."))
    }

    @Test func aWatchingPhoneIsToldWhyItCantUpload() async throws {
        let (rig, grant, _, _) = try rig(control: .watch)
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        let welcome = try await message(client) { if case .welcome = $0 { true } else { false } }
        if case .welcome(let w) = welcome { #expect(!w.caps.contains("blob")) }
        let refused = try await upload(client, "u1", name: "a.txt", mime: "text/plain", Data("a".utf8))
        #expect(refused.code == .deniedControl && refused.message == LinkPolicy.watchOnly)
    }

    @Test func uploadsKeepToTheHourAndToFilesWaiting() async throws {
        // 256 MB an hour: 21 files of 12 MB fit, the 22nd waits for the hour to move on.
        var limits = HostLimits()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<21 {
            let fits = limits.uploadFits(LinkUploads.maxSize, at: start.addingTimeInterval(Double(i)))
            #expect(fits)
            limits.uploadBegan(LinkUploads.maxSize, at: start.addingTimeInterval(Double(i)))
        }
        let over = limits.uploadFits(LinkUploads.maxSize, at: start.addingTimeInterval(60))
        let later = limits.uploadFits(LinkUploads.maxSize, at: start.addingTimeInterval(3600))
        #expect(!over && later)
        // Twenty finished files waiting at most, as a Mac keeps a phone's.
        let (rig, grant, _, _) = try rig()
        defer { rig.finish() }
        // A second between uploads: the message rate isn't what's tested here.
        var clock = Date()
        rig.host.now = { clock }
        let client = try await StreamClient(rig, grant: grant)
        for i in 0..<LinkClient.heldMax {
            clock += 1
            #expect(try await upload(client, "u\(i)", name: "a.txt", mime: "text/plain", Data("a\(i)".utf8)).ok)
        }
        clock += 1
        let full = try await upload(client, "over", name: "a.txt", mime: "text/plain", Data("b".utf8))
        #expect(full.code == .busy && full.message == "Too many files waiting to be sent.")
    }

    // MARK: 3. A phone's reads: attachments, diffs, earlier history

    @Test func attachmentsDiffsAndEarlierHistoryLoadAsFromAMac() async throws {
        let (rig, grant, hc, made) = try rig()
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        let data = Data("a file for the phone\n".utf8)
        let blob = try #require(try await upload(client, "u1", name: "notes.txt", mime: "text/plain", data).blobId)
        client.socket.send(.cmd(id: "s1", .send(chatId: hc.id, text: "with a file", blobs: [blob])))
        #expect(try await result(client, "s1").ok)
        try await until { hc.entries.contains { $0.attachments?.isEmpty == false } && hc.idle }
        let ref = try #require(hc.entries.first { $0.attachments?.isEmpty == false }?.attachments?.first?.ref)
        func get(_ id: String, _ ref: String, _ variant: LinkMessage.Variant) async throws -> LinkMessage {
            client.socket.send(.blobGet(id: id, chatId: hc.id, ref: ref, variant: variant, offset: 0))
            return try await message(client) {
                switch $0 {
                case .blobChunk(let got, _, _, _, _): got == id
                case .result(let r): r.id == id
                default: false
                }
            }
        }
        guard case .blobChunk(_, let mime, _, let total, let piece) = try await get("g1", ref, .full) else { Issue.record("no chunk"); return }
        #expect(mime == "text/plain" && total == data.count && Data(base64Encoded: piece) == data)
        // A turn that changed a file: its diff, live and once the CLI has gone.
        let turn = "t-edit"
        let path = rig.folder.appendingPathComponent("a.swift").path
        let hunk = FileChange.Hunk(oldStart: 0, newStart: 1, lines: [.init(kind: .add, text: "let a = 1", old: nil, new: 1)])
        let backend = try #require(made().first)
        backend.sink.yield(.turnStarted(turn, origin: .user, at: .now))
        backend.sink.yield(.text("b-edit", .answer, "edited"))
        backend.sink.yield(.turnChanges(turn, [FileChange(path: path, kind: .add, hunks: [hunk])]))
        backend.sink.yield(.turnFinished(turn, .completed, duration: .seconds(1)))
        try await until { hc.turns[turn]?.finished == true && hc.idle }
        func diff(_ id: String) async throws -> LinkMessage {
            client.socket.send(.diffGet(id: id, chatId: hc.id, turnId: turn, path: "a.swift"))
            return try await message(client) {
                switch $0 {
                case .diffHunks(let got, _, _, _): got == id
                case .result(let r): r.id == "diff.get:" + id
                default: false
                }
            }
        }
        guard case .diffHunks(_, _, let hunks, let more) = try await diff("d1") else { Issue.record("no diff"); return }
        #expect(hunks.first?.lines == ["+let a = 1"] && !more)
        rig.host.sleep(hc)
        #expect(!hc.cliRunning)
        guard case .diffHunks(_, _, let kept, _) = try await diff("d2") else { Issue.record("no diff once asleep"); return }
        #expect(kept == hunks)
        // The attachment too, read from the log's paths; a ref the chat doesn't hold is refused.
        guard case .blobChunk(_, _, _, _, let again) = try await get("g2", ref, .full) else { Issue.record("no chunk once asleep"); return }
        #expect(Data(base64Encoded: again) == data)
        guard case .result(let refused) = try await get("g3", "nope/0", .full) else { Issue.record("no refusal"); return }
        #expect(refused.code == .deniedRef)
        // Earlier history: read from the CLI (started for it) and put first, the window grown.
        client.socket.send(.txOpen(chatId: hc.id, last: 60))
        _ = try await message(client) { if case .txPage = $0 { true } else { false } }
        client.socket.send(.txEarlier(chatId: hc.id))
        _ = try await message(client) {
            if case .txPage(_, _, let entries, _, _) = $0 { entries.first?.text == "older" } else { false }
        }
        #expect(hc.entries.first?.text == "older")
        rig.restart()
        #expect(try #require(rig.host.chat(hc.id)).entries.first?.text == "older", "the log keeps it")
    }

    @Test func aWatchingPhoneReadsAttachmentsButNotDiffsOrEarlierHistory() async throws {
        let (rig, grant, hc, _) = try rig(control: .watch)
        defer { rig.finish() }
        let client = try await StreamClient(rig, grant: grant)
        client.socket.send(.diffGet(id: "d1", chatId: hc.id, turnId: "t", path: "a"))
        let diff = try await result(client, "diff.get:d1")
        #expect(diff.code == .deniedControl && diff.message == LinkPolicy.watchOnly)
        client.socket.send(.txEarlier(chatId: hc.id))
        let earlier = try await result(client, "tx.earlier:" + hc.id)
        #expect(earlier.code == .deniedControl && earlier.message == LinkPolicy.watchOnly)
        client.socket.send(.blobGet(id: "g1", chatId: hc.id, ref: "x/0", variant: .thumb, offset: 0))
        #expect(try await result(client, "g1").code == .deniedRef)
    }

    // MARK: 4. Auto's cards

    @Test func boxCardsAnswerAutosAsksAsTheMacDoes() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        let chat = hc.live(services: rig.host.services)
        func labels(_ approval: Approval) -> [String] { HostMeta.card(approval, in: chat).actions.map(\.label) }
        var plain = Approval(id: "a", title: "Run ls", detail: nil, body: nil, canAlwaysAllow: true, questions: [])
        plain.alwaysRule = "Bash(ls:*)"
        #expect(labels(plain) == ["Allow", "Always allow", "Deny"])
        let always = HostMeta.card(plain, in: chat).actions.first { $0.id == .allowAlways }
        #expect(always?.refused == true && always?.help == plain.alwaysHelp && always?.help?.isEmpty == false)
        var asked = plain
        asked.autoStop = true
        #expect(labels(asked) == ["Run once", "Deny"], "Auto asked: run once, no Always")
        var refused = asked
        refused.allowNote = "Auto refused this: it reads outside the folder."
        #expect(labels(refused) == ["OK"], "Auto refused: OK only")
        // The same answers a Mac's card offers (`LinkSnapshot` reads the same table).
        for approval in [plain, asked, refused] { #expect(HostMeta.card(approval, in: chat).actions == LinkProjection.permissionActions(approval)) }
        // A Mac's Allow on a refused one stays refused.
        var noted = plain
        noted.allowNote = "Not in this folder."
        #expect(LinkProjection.permissionActions(noted).first?.refused == true)
    }

    // MARK: 6. The box's own words

    @Test func whatABoxDoesntDoIsSaidForPeople() {
        #expect(LinkPolicy.checkBox(.groupSet, ControlArgs(), nil, control: .full) == .deny(.invalid, "A box doesn't do that."))
        #expect(LinkPolicy.checkBox(.boardNew, ControlArgs(), nil, control: .full) == .deny(.invalid, LinkPolicy.notTaken))
    }
}
