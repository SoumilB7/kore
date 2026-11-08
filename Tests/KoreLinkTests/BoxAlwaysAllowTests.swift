import Foundation
import Testing

@testable import LinkProtocol
@testable import src

/// Always allow on a box chat's card (owner, 2026-11-21): a full grant's, on a permission card
/// that offers it, never on a critical removal; phones and act grants are refused as before.
@Suite("box always allow")
struct BoxAlwaysAllowTests {
    func chat(_ card: LinkPolicy.ChatFacts.Card) -> LinkPolicy.ChatFacts {
        LinkPolicy.ChatFacts(level: .manual, modes: ["default": .manual], cards: ["c1": card])
    }
    func always(_ card: LinkPolicy.ChatFacts.Card, _ control: LinkControlLevel = .full) -> LinkPolicy.Verdict {
        LinkPolicy.check(ChatCommand.respond(approval: "c1", decision: .allowAlways), chat(card), control: control)
    }

    @Test func aFullGrantMayAlwaysAllowAPermissionCard() {
        #expect(always(.init(kind: .permission, digest: "d", canAlwaysAllow: true)) == .allow)
        #expect(always(.init(kind: .permission, digest: "d", canAlwaysAllow: true, command: "sudo apt install jq", cwd: "/work")) == .allow)
    }

    @Test func aCriticalRemovalOrACardWithoutItIsRefused() {
        let critical = LinkPolicy.ChatFacts.Card(kind: .permission, digest: "d", canAlwaysAllow: true, command: "rm -rf /work", cwd: "/work/app")
        #expect(always(critical) == .deny(.alwaysAllow, LinkPolicy.boxCriticalAlwaysLine))
        #expect(always(.init(kind: .permission, digest: "d", canAlwaysAllow: false)) == .deny(.alwaysAllow, LinkPolicy.boxNoAlwaysLine))
        #expect(always(.init(kind: .plan, digest: "d", canAlwaysAllow: true)) == .deny(.alwaysAllow, LinkPolicy.boxNoAlwaysLine))
        // A card that's gone.
        #expect(
            LinkPolicy.check(ChatCommand.respond(approval: "nope", decision: .allowAlways), chat(.init(kind: .permission, digest: "d")), control: .full)
                == .deny(.alwaysAllow, LinkPolicy.boxNoAlwaysLine))
    }

    @Test func phonesAndActGrantsStayRefused() {
        let card = LinkPolicy.ChatFacts.Card(kind: .permission, digest: "d", canAlwaysAllow: true)
        // An act grant (standard control) doesn't drive the chat at all.
        #expect(always(card, .standard) == .deny(.deniedControl, "Driving a chat needs a grant with full control."))
        // A phone's card answer, whatever its control.
        for control in [LinkControlLevel.standard, .full] {
            #expect(
                LinkPolicy.check(.answer(chatId: "x", cardId: "c1", action: .allowAlways, digest: "d", answers: nil), chat(card), control: control)
                    == .deny(.alwaysAllow, "Always allow can only be set in Kore."))
        }
    }
}
