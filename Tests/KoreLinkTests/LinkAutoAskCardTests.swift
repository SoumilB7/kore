import Foundation
import Testing

@testable import KoreLink
@testable import KoreUI
import LinkProtocol
@testable import src

/// K: a "Claude stopped" card on the phone (approvals.pending, as every card, so it notifies as
/// they do): Run once and Dismiss, no Always allow (that's the Mac's, once a person sees what it
/// keeps); a critical removal's card has Dismiss only.
@MainActor
@Suite("Auto stops over the link")
struct LinkAutoAskCardTests {
    @Test func runOnceAndDismissNoAlwaysAllowAndDismissOnlyForACriticalRemoval() {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp/kore-auto-link"))
        let ask = ClaudeAutoStops.Card(
            id: "autostop-t1", command: "sudo apt install ffmpeg", cwd: "/tmp/kore-auto-link", critical: false, rule: "sudo apt install *"
        ).approval
        #expect(ask.canAlwaysAllow, "the Mac's card offers it")
        let card = LinkSnapshot.card(ask, in: chat)
        #expect(card.kind == .permission && card.title == "Claude stopped: it needs `sudo apt install ffmpeg`")
        #expect(card.actions.map(\.id) == [.allow, .deny] && card.actions.map(\.label) == ["Run once", "Dismiss"])
        #expect(card.actions.allSatisfy { $0.refused == nil })
        let stop = ClaudeAutoStops.Card(id: "autostop-t2", command: "rm -rf ~/Code", cwd: "/Users/me/Code/app", critical: true, rule: nil).approval
        let refused = LinkSnapshot.card(stop, in: chat)
        #expect(refused.actions.map(\.id) == [.deny] && refused.actions.first?.label == "Dismiss")
    }
}
