import Foundation
import KorePhone
import KoreRemote
import KoreUI

// The phone remote's secure path on Kore Phone (phase 13 R1): Phone on opens the Mac's mailbox
// on the (in-process) relay, a phone pairs with the code typed on the Mac and links through the
// relay end to end encrypted, alerts only until it unlocks, signed answers, and pairings that
// end with Phone off or Remove. Kore listens on nothing throughout.

/// "/" → Phone opens its popup; Phone on opens a mailbox and listens on nothing; a phone pairs with
/// the code typed on the Mac, links with alerts only (no chats, no actions), unlocks to see and
/// act, answers a card with its signature, can't raise the mode, and locks back to alerts. While
/// it's connected, Stay awake holds for it.
final class PhonePairsAndUnlocks: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals, .gate] }
    override class var script: CLIScript {
        let approval = Approval(id: "first", title: "Run rm -rf build?", detail: "Bash", body: "rm -rf build", canAlwaysAllow: true, questions: [])
        return CLIScript(turns: [[
            .startTurn,
            .approval(approval, allow: [.tool(name: "Bash", detail: "rm -rf build", output: "removed")], deny: Beat.answer("Okay.")),
            .finishTurn(.completed),
        ]])
    }

    override func steps() -> [any Step] {
        let popup = Locator.id(StoryID(.composer, "phone"))
        // A mode above Manual: Accept edits (Claude), Approve for me (Codex).
        let higher = variant == .codex ? "approveForMe" : "acceptEdits"
        return super.steps() + [
            InstallKorePhone(),
            WaitForFocus(.id(StoryID.Composer.field)),
            Press(.id(StoryID.Composer.slash)),
            Press(.id(StoryID.Composer.command("phone"))),
            WaitForElement(popup),
            PhoneOn(),
            Expect("Kore listening on nothing", found: { _ in Listening.ports().joined(separator: ", ") }) { _ in Listening.ports().isEmpty },
            SecurePhonePairs(),
            Expect("the phone paired, not yet connected") { _ in RemoteHost.shared.phone.rows.count == 1 },
            SecurePhoneLinks(),
            Expect("alerts only: no chats sent") { story in try story.phoneClient().rev == 0 },
            Expect("Stay awake holding for the phone", found: { _ in AwakeInputs.line }) { _ in AwakeInputs.holding != nil },
            PhoneCommand(what: "send while locked", command: { .send(chatId: $0, text: "Clean the build") }, refused: .access),
            SecurePhoneUnlocks(),
            Expect("the window and its chat on the phone") { story in
                let client = try story.phoneClient()
                return client.chats[try story.activeChatID()] != nil
            },
            PhoneCommand(what: "send “Clean the build”") { .send(chatId: $0, text: "Clean the build") },
            PhoneAnswer(card: "first", action: .allowAlways, refused: .alwaysAllow),
            PhoneAnswer(card: "first", action: .allow),
            TurnFinished(1),
            Expect("the tool ran") { story in try story.scriptedBackend().log.contains { "\($0)".contains("allow") } },
            PhoneCommand(what: "raise the mode to \(higher)", command: { .setMode(chatId: $0, modeId: higher) }, refused: .raiseMode),
            SecurePhoneLocks(),
            PhoneCommand(what: "send after locking", command: { .send(chatId: $0, text: "More") }, refused: .access),
        ]
    }
}

/// A signature over another card, or with another key, is refused; an answer whose card changed
/// since the phone saw it is refused as stale.
final class PhoneAnswersMustBeSigned: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals] }
    override class var script: CLIScript { PhonePairsAndUnlocks.script }

    override func steps() -> [any Step] {
        super.steps() + [
            PhoneOn(), SecurePhonePairs(), SecurePhoneLinks(), SecurePhoneUnlocks(),
            PhoneCommand(what: "send “Clean the build”") { .send(chatId: $0, text: "Clean the build") },
            PhoneSignedWrongly(),
            PhoneAnswer(card: "first", action: .deny),
            TurnFinished(1),
        ]
    }
}

/// Phone off ends the pairing: the link closes, the mailbox goes, and after Phone on again the
/// old pairing can't connect (a new key, a new mailbox).
final class PhoneOffEndsThePairing: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .gate] }

    override func steps() -> [any Step] {
        super.steps() + [
            PhoneOn(), SecurePhonePairs(), SecurePhoneLinks(),
            PhoneOff(),
            Expect("the phone's link closed") { story in story.phone.secure?.isClosed == true },
            RelayKeepsNothing(),
            Expect("Stay awake let go") { _ in AwakeInputs.holding == nil },
            PhoneOn(),
            SecurePhoneLinks(refused: true),
        ]
    }
}

/// Three wrong codes refuse a pairing; a removed phone's link closes and can't come back.
final class PhoneRemovedAndWrongCode: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    override func steps() -> [any Step] {
        super.steps() + [
            PhoneOn(),
            SecurePhonePairs(wrongCode: true),
            Expect("no phone paired") { _ in RemoteHost.shared.phone.rows.isEmpty },
            SecurePhonePairs(), SecurePhoneLinks(),
            RemovePhone(),
            Expect("the phone's link closed") { story in story.phone.secure?.isClosed == true },
            SecurePhoneLinks(refused: true),
        ]
    }
}

/// Remove, as the popup's row does it.
private struct RemovePhone: Step {
    var label: String { "Remove the phone" }

    func run(_ story: StoryContext) async throws {
        let host = RemoteHost.shared
        guard let id = host.phone.rows.first?.id else { throw StoryFailure.modelMissing("a paired phone") }
        host.service.remove(id)
        try await story.until("the phone gone") { host.phone.rows.isEmpty }
    }
}

/// Answers signed for another card, with another key, and over a digest the card doesn't have.
private struct PhoneSignedWrongly: Step {
    var label: String { "Answers signed wrongly are refused" }

    func run(_ story: StoryContext) async throws {
        let client = try story.phoneClient()
        let chat = try story.activeChatID()
        guard let link = story.phone.secure else { throw StoryFailure.modelMissing("a linked phone") }
        let card = try await story.wait("the card on the phone") { client.chats[chat]?.cards.first { $0.id == "first" } }
        let digest = card.digest ?? ""
        let identity = story.phone.identity
        let attempts: [(String, AnswerProof, ResultCode)] = [
            ("for another card", AnswerProof(digest: digest, sig: PhoneSide.approve(link, identity: identity, cardId: "other", digest: digest, action: "allow")), .signature),
            ("with another key", AnswerProof(digest: digest, sig: PhoneSide.approve(link, identity: PhoneIdentity(), cardId: "first", digest: digest, action: "allow")), .signature),
            ("over another digest", AnswerProof(digest: String(repeating: "0", count: 64), sig: ""), .staleCard),
            ("unsigned", AnswerProof(digest: digest, sig: ""), .signature),
        ]
        for (what, proof, code) in attempts {
            let id = client.command(.answer(chatId: chat, cardId: "first", action: .allow, answers: nil, proof: proof))
            let result = try await story.wait("the result of answering \(what)") { client.results[id] }
            guard !result.ok, result.code == code else {
                throw StoryFailure.expectation("an answer signed \(what) refused with \(code.rawValue) (got \(result.code?.rawValue ?? "ok"))")
            }
        }
    }
}

/// Phone off closed the mailbox: the relay holds nothing of it.
private struct RelayKeepsNothing: Step {
    var label: String { "The relay keeps nothing" }

    func run(_ story: StoryContext) async throws {
        for _ in 0..<100 {
            if await story.storyRelay.count == 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw StoryFailure.expectation("no mailbox left (\(await story.storyRelay.count))")
    }
}
