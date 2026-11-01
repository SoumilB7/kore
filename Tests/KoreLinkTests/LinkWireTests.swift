import CryptoKit
import Foundation
import Testing

@testable import KoreLink

/// The protocol's fixtures (`Tests/Fixtures/link/v1`): every message decodes and encodes back to
/// the same bytes, the manifest covers every type, and the card digest follows its canonical rule.
@Suite("link protocol fixtures")
struct LinkFixtureTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/link/v1")

    struct Manifest: Decodable {
        struct Fixture: Decodable {
            struct File: Decodable { let file: String }
            let file: String
            let type: String
        }
        let proto: LinkVersion
        let fixtures: [Fixture]
        let cardDigest: Fixture.File
        let ringProof: Fixture.File

        /// The message fixtures' names, without ".json".
        var messages: [String] { fixtures.map { String($0.file.dropLast(5)) } }
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    static func bytes(_ name: String) throws -> Data {
        var data = try Data(contentsOf: folder.appendingPathComponent(name + ".json"))
        while data.last == 0x0A { data.removeLast() }
        return data
    }

    @Test func manifestIsThisVersion() throws {
        #expect(try Self.manifest().proto == LinkProto.version)
    }

    @Test(arguments: try LinkFixtureTests.manifest().messages)
    func roundTrips(_ name: String) throws {
        let data = try Self.bytes(name)
        let message = try LinkMessage.decode(data)
        if case .unknown(let t) = message { Issue.record("\(name) decoded as unknown type \(t)") }
        let again = try message.encoded()
        #expect(String(decoding: again, as: UTF8.self) == String(decoding: data, as: UTF8.self))
    }

    @Test func everyTypeHasAFixture() throws {
        let manifest = try Self.manifest()
        let types = try Set(manifest.messages.map { try LinkMessage.decode(Self.bytes($0)).type })
        #expect(types == LinkMessage.types)
        // Each entry's `type` is its message's.
        for fixture in manifest.fixtures {
            #expect(try LinkMessage.decode(Self.bytes(String(fixture.file.dropLast(5)))).type == fixture.type)
        }
    }

    @Test func cardDigestFollowsTheCanonicalRule() throws {
        struct Fixture: Decodable {
            struct Input: Decodable {
                let actions: [CardAction]
                let body: String?
                let detail: String?
                let kind: LinkCard.Kind
                let plan: String?
                let questions: [LinkQuestion]?
                let title: String
            }
            let input: Input
            let canonical: String
            let digest: String
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Self.bytes("card-digest"))
        let i = fixture.input
        let digest = LinkCardDigest(kind: i.kind, title: i.title, detail: i.detail, body: i.body, plan: i.plan, questions: i.questions, actions: i.actions)
        #expect(String(decoding: digest.canonical, as: UTF8.self) == fixture.canonical)
        #expect(digest.digest == fixture.digest)
        // The snapshot's card carries the same digest.
        guard case .snapshot(_, _, let chats, _) = try LinkMessage.decode(Self.bytes("snapshot")) else {
            Issue.record("not a snapshot")
            return
        }
        #expect(chats.first?.cards.first?.digest == fixture.digest)
    }

    @Test func ringProofFollowsItsRule() throws {
        struct Fixture: Decodable {
            let runSecret: String
            let epoch: String
            let ts: Int
            let message: String
            let ringProof: String
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Self.bytes(String(try Self.manifest().ringProof.file.dropLast(5))))
        let secret = try #require(Data(base64Encoded: fixture.runSecret))
        #expect(fixture.message == "kore-ring/1|\(fixture.epoch)|\(fixture.ts)")
        #expect(LinkProof.ringProof(runSecret: secret, epoch: fixture.epoch, ts: fixture.ts) == fixture.ringProof)
        #expect(LinkProof.checkRing(fixture.ringProof, runSecret: secret, epoch: fixture.epoch, ts: fixture.ts))
        #expect(!LinkProof.checkRing(fixture.ringProof, runSecret: secret, epoch: fixture.epoch, ts: fixture.ts + 1))
    }

    @Test func helloCarriesTheCompanionsCommands() throws {
        guard case .hello(_, _, _, let commands) = try LinkMessage.decode(Self.bytes("hello.commands")) else {
            Issue.record("not a hello")
            return
        }
        #expect(commands?.map(\.id) == ["qr", "activity"])
        guard case .hello(_, _, _, let none) = try LinkMessage.decode(Self.bytes("hello")) else { return }
        #expect(none == nil)
        #expect(try LinkMessage.decode(Self.bytes("command")) == .command(id: "qr"))
    }

    @Test func unknownTypesAndCommandsAreKeptAsUnknown() throws {
        #expect(try LinkMessage.decode(Data(#"{"t":"files.list","path":"a"}"#.utf8)) == .unknown("files.list"))
        let cmd = try LinkMessage.decode(Data(#"{"t":"cmd","id":"x","cmd":{"type":"files.read","path":"/etc"}}"#.utf8))
        #expect(cmd == .cmd(id: "x", .unknown("files.read")))
        #expect(LinkPolicy.check(.unknown("files.read"), nil) == .deny(.invalid, "Kore doesn't know that command."))
    }

    @Test func unknownEnumValuesReadAsUnknown() throws {
        let bye = try LinkMessage.decode(Data(#"{"t":"bye","reason":"sleepy"}"#.utf8))
        #expect(bye == .bye(.unknown))
    }
}

@Suite("link frames and proof")
struct LinkFrameTests {
    @Test func framesSplitAndJoin() throws {
        var buffer = LinkFrame.frame(Data("one".utf8)) + LinkFrame.frame(Data("two".utf8))
        let half = buffer.count - 2
        var first = Data(buffer.prefix(half))
        let some = try LinkFrame.take(&first, max: 100)
        #expect(some == [Data("one".utf8)])
        #expect(first.count == half - 7)
        let all = try LinkFrame.take(&buffer, max: 100)
        #expect(all == [Data("one".utf8), Data("two".utf8)])
        #expect(buffer.isEmpty)
    }

    @Test func anOversizedFrameIsRefused() {
        let buffer = LinkFrame.frame(Data(repeating: 1, count: 300))
        #expect(throws: LinkFrameError.tooLarge(300)) {
            var copy = buffer
            _ = try LinkFrame.take(&copy, max: 256)
        }
    }

    @Test func proofChecksOnlyWithTheSecretAndNonce() {
        let secret = Data(repeating: 7, count: 32)
        let proof = LinkProof.proof(secret: secret, nonce: "abc")
        #expect(LinkProof.check(proof, secret: secret, nonce: "abc"))
        #expect(!LinkProof.check(proof, secret: secret, nonce: "abd"))
        #expect(!LinkProof.check(proof, secret: Data(repeating: 8, count: 32), nonce: "abc"))
        #expect(!LinkProof.check("not base64!", secret: secret, nonce: "abc"))
    }
}

@Suite("link policy")
struct LinkPolicyTests {
    static let card = LinkPolicy.ChatFacts.Card(kind: .permission, digest: "D")
    static let manual = LinkPolicy.ChatFacts(
        level: .manual, modes: ["default": .manual, "plan": .plan, "acceptEdits": .edits, "auto": .auto], cards: ["c": card])

    @Test func sendsInEveryMode() {
        for level in ModeLevel.allCases {
            var chat = Self.manual
            chat.level = level
            #expect(LinkPolicy.check(.send(chatId: "x", text: "hi"), chat) == .allow)
        }
    }

    @Test func raisingStaysRefusedWhereSendingIsAllowed() {
        var auto = Self.manual
        auto.level = .auto
        auto.modes["danger"] = .danger
        #expect(LinkPolicy.check(.send(chatId: "x", text: "hi"), auto) == .allow)
        if case .deny(let code, _) = LinkPolicy.check(.setMode(chatId: "x", modeId: "danger"), auto) { #expect(code == .raiseMode) } else { Issue.record() }
        auto.planOn = true
        if case .deny(let code, _) = LinkPolicy.check(.setPlan(chatId: "x", on: false), auto) { #expect(code == .raiseMode) } else { Issue.record() }
    }

    @Test func refusesCommandsShellAndEmpty() {
        #expect(LinkPolicy.check(.send(chatId: "x", text: "/compact"), Self.manual) == .allow)
        if case .deny(let code, _) = LinkPolicy.check(.send(chatId: "x", text: "/login"), Self.manual) { #expect(code == .command) } else { Issue.record() }
        if case .deny(let code, _) = LinkPolicy.check(.send(chatId: "x", text: "!rm -rf ~"), Self.manual) { #expect(code == .command) } else { Issue.record() }
        if case .deny(let code, _) = LinkPolicy.check(.send(chatId: "x", text: "  "), Self.manual) { #expect(code == .invalid) } else { Issue.record() }
        let long = String(repeating: "a", count: LinkPolicy.maxText + 1)
        if case .deny(let code, _) = LinkPolicy.check(.send(chatId: "x", text: long), Self.manual) { #expect(code == .invalid) } else { Issue.record() }
    }

    @Test func neverRaisesTheMode() {
        #expect(LinkPolicy.check(.setMode(chatId: "x", modeId: "plan"), Self.manual) == .allow)
        #expect(LinkPolicy.check(.setMode(chatId: "x", modeId: "acceptEdits"), Self.manual) == .deny(.raiseMode, "The link can only lower a chat's mode."))
        #expect(LinkPolicy.check(.setMode(chatId: "x", modeId: "auto"), Self.manual) == .deny(.raiseMode, "The link can only lower a chat's mode."))
        var autoPlan = Self.manual
        autoPlan.level = .auto
        autoPlan.planOn = true
        if case .deny(let code, _) = LinkPolicy.check(.setPlan(chatId: "x", on: false), autoPlan) { #expect(code == .raiseMode) } else { Issue.record() }
        #expect(LinkPolicy.check(.setPlan(chatId: "x", on: true), autoPlan) == .allow)
        #expect(LinkPolicy.allowedModes(Self.manual) == ["default", "plan"])
    }

    @Test func answersOnlyWhatTheCardTakesWithItsDigest() {
        #expect(LinkPolicy.check(.answer(chatId: "x", cardId: "c", action: .allow, digest: "D", answers: nil), Self.manual) == .allow)
        #expect(
            LinkPolicy.check(.answer(chatId: "x", cardId: "c", action: .allow, digest: "old", answers: nil), Self.manual)
                == .deny(.staleCard, "The card changed; look again."))
        if case .deny(let code, _) = LinkPolicy.check(.answer(chatId: "x", cardId: "c", action: .allowAlways, digest: "D", answers: nil), Self.manual) {
            #expect(code == .alwaysAllow)
        } else { Issue.record() }
        if case .deny(let code, _) = LinkPolicy.check(.answer(chatId: "x", cardId: "c", action: .approvePlan, digest: "D", answers: nil), Self.manual) {
            #expect(code == .action)
        } else { Issue.record() }
        if case .deny(let code, _) = LinkPolicy.check(.answer(chatId: "x", cardId: "gone", action: .allow, digest: "D", answers: nil), Self.manual) {
            #expect(code == .goneCard)
        } else { Issue.record() }
        var plan = Self.manual
        plan.cards = ["p": .init(kind: .plan, digest: "P"), "s": .init(kind: .signIn, digest: "S")]
        if case .deny(let code, _) = LinkPolicy.check(.answer(chatId: "x", cardId: "p", action: .approvePlanAcceptEdits, digest: "P", answers: nil), plan) {
            #expect(code == .raiseMode)
        } else { Issue.record() }
        #expect(LinkPolicy.check(.answer(chatId: "x", cardId: "p", action: .approvePlan, digest: "P", answers: nil), plan) == .allow)
        if case .deny(let code, _) = LinkPolicy.check(.answer(chatId: "x", cardId: "s", action: .allow, digest: "S", answers: nil), plan) {
            #expect(code == .signIn)
        } else { Issue.record() }
    }

    @Test func aGoneChatIsGone() {
        if case .deny(let code, _) = LinkPolicy.check(.stop(chatId: "x"), nil) { #expect(code == .goneChat) } else { Issue.record() }
        #expect(LinkPolicy.check(.new(windowId: "w", provider: "claude"), nil) == .allow)
    }

    @Test func limitersCount() {
        var limiter = RateLimiter(limit: 2, per: 60)
        let now = Date()
        let taken = [limiter.take(at: now), limiter.take(at: now), limiter.take(at: now), limiter.take(at: now.addingTimeInterval(61))]
        #expect(taken == [true, true, false, true])
        var bucket = MessageBucket(rate: 20, burst: 40)
        var verdicts: [MessageBucket.Verdict] = []
        for _ in 0..<200 { verdicts.append(bucket.take(at: now)) }
        #expect(verdicts.prefix(40).allSatisfy { $0 == .ok })
        #expect(verdicts[40] == .over)
        #expect(verdicts.last == .far)
    }
}

/// Link 1.1's "/" commands: any the chat offers, never Kore's own, never "!".
@Suite("link commands")
struct LinkCommandPolicyTests {
    static let chat = LinkPolicy.ChatFacts(
        level: .manual, modes: ["default": .manual], commands: ["review", "init"], koreEntries: ["usage", "account", "remote-control"])

    @Test func sendsTheChatsCommands() {
        #expect(LinkPolicy.check(.send(chatId: "x", text: "/review 12"), Self.chat) == .allow)
        #expect(LinkPolicy.check(.send(chatId: "x", text: "/compact"), Self.chat) == .allow)
    }

    @Test func refusesKoreEntriesUnknownCommandsAndShell() {
        for text in ["/usage", "/account", "/remote-control", "/login", "/logout", "/nope", "!ls"] {
            if case .deny(let code, _) = LinkPolicy.check(.send(chatId: "x", text: text), Self.chat) { #expect(code == .command) } else {
                Issue.record("\(text) was allowed")
            }
        }
    }

    @Test func filesAloneMaySend() {
        #expect(LinkPolicy.check(.send(chatId: "x", text: "", blobs: ["b"]), Self.chat) == .allow)
        let many = (0...LinkPolicy.maxBlobs).map { "b\($0)" }
        if case .deny(let code, _) = LinkPolicy.check(.send(chatId: "x", text: "hi", blobs: many), Self.chat) { #expect(code == .invalid) } else { Issue.record() }
    }
}

/// Link 1.1's uploads: checked whole, bounded, and dropped when unfinished.
@Suite("link uploads")
struct LinkUploadTests {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    static func sha(_ data: Data) -> String { LinkUploads.hex(SHA256.hash(data: data)) }

    @Test func anImageRoundTrips() throws {
        var uploads = LinkUploads()
        #expect(uploads.begin("u", name: "a.png", mime: "image/png", size: Self.png.count, sha256: Self.sha(Self.png)) == nil)
        #expect(uploads.chunk("u", index: 0, base64: Self.png.base64EncodedString()) == nil)
        let file = try uploads.end("u").get()
        #expect(file.sniffed == .image && file.data == Self.png)
        #expect(uploads.count == 0)
    }

    @Test func refusesBadHashTypeSizeAndOrder() {
        var uploads = LinkUploads()
        _ = uploads.begin("h", name: "a.png", mime: "image/png", size: Self.png.count, sha256: String(repeating: "0", count: 64))
        _ = uploads.chunk("h", index: 0, base64: Self.png.base64EncodedString())
        #expect(uploads.end("h") == .failure(.init(.badHash, "The file's SHA-256 doesn't match.")))
        let text = Data("not a picture".utf8)
        _ = uploads.begin("t", name: "a.png", mime: "image/png", size: text.count, sha256: Self.sha(text))
        _ = uploads.chunk("t", index: 0, base64: text.base64EncodedString())
        if case .failure(let f) = uploads.end("t") { #expect(f.code == .badType) } else { Issue.record() }
        #expect(uploads.begin("big", name: "b", mime: "application/octet-stream", size: LinkUploads.maxSize + 1, sha256: Self.sha(text))?.code == .tooLarge)
        _ = uploads.begin("o", name: "a.txt", mime: "text/plain", size: 2, sha256: Self.sha(Data("ab".utf8)))
        #expect(uploads.chunk("o", index: 1, base64: Data("b".utf8).base64EncodedString())?.code == .invalid)
        #expect(uploads.count == 0)
    }

    @Test func dropsUnfinishedUploadsAfterTwoMinutes() {
        var uploads = LinkUploads()
        let start = Date()
        _ = uploads.begin("u", name: "a.png", mime: "image/png", size: Self.png.count, sha256: Self.sha(Self.png), at: start)
        #expect(uploads.chunk("u", index: 0, base64: Self.png.base64EncodedString(), at: start.addingTimeInterval(121))?.code == .goneBlob)
    }

    @Test func boundsUploadsAtOnce() {
        var uploads = LinkUploads()
        for i in 0..<LinkUploads.maxUploads { #expect(uploads.begin("u\(i)", name: "f", mime: "text/plain", size: 1, sha256: String(repeating: "a", count: 64)) == nil) }
        #expect(uploads.begin("more", name: "f", mime: "text/plain", size: 1, sha256: String(repeating: "a", count: 64))?.code == .busy)
    }

    @Test func savesUnderASafeName() {
        #expect(LinkUploads.safeName("../../etc/passwd") == "passwd")
        #expect(LinkUploads.safeName("..hidden") == "hidden")
        #expect(LinkUploads.safeName("a\u{0}b:c.txt") == "abc.txt")
        #expect(LinkUploads.safeName("") == "file")
    }
}

/// Link 1.2: every new command needs full control granted on the Mac this run, and the grant
/// never lets a `!` line through.
@Suite("link full control")
struct LinkControlTests {
    static let chat = LinkPolicy.ChatFacts(level: .manual, modes: ["default": .manual])

    @Test(arguments: ControlKind.allCases)
    func refusedWithoutTheGrant(_ kind: ControlKind) {
        let args = ControlArgs(chatId: "x", windowId: "w", title: "A name", text: "hi")
        #expect(LinkPolicy.check(.control(kind, args), Self.chat, control: .standard) == .deny(.deniedControl, "Full control isn't granted in Kore for this run."))
    }

    @Test(arguments: ControlKind.allCases)
    func allowedWithTheGrant(_ kind: ControlKind) {
        let args = ControlArgs(chatId: "x", windowId: "w", title: "A name", text: "hi")
        #expect(LinkPolicy.check(.control(kind, args), Self.chat, control: .full) == .allow)
    }

    @Test func shellLinesStayRefusedWithTheGrant() {
        #expect(LinkPolicy.check(.send(chatId: "x", text: "!ls"), Self.chat, control: .full) != .allow)
        let atReset = LinkPolicy.check(.control(.chatSendAtReset, ControlArgs(chatId: "x", text: "!rm -rf ~")), Self.chat, control: .full)
        #expect(atReset != .allow)
    }

    @Test func titlesAreOneShortLine() {
        let full = LinkPolicy.check(.control(.chatRename, ControlArgs(chatId: "x", title: "two\nlines")), Self.chat, control: .full)
        #expect(full != .allow)
    }
}
