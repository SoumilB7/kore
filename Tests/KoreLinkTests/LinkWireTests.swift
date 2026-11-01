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
        guard case .snapshot(_, _, let chats) = try LinkMessage.decode(Self.bytes("snapshot")) else {
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
        #expect(try LinkMessage.decode(Data(#"{"t":"blob.put.begin","size":3}"#.utf8)) == .unknown("blob.put.begin"))
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
