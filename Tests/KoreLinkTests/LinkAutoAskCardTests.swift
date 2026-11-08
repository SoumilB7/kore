import Foundation
import Testing

@testable import KoreLink
@testable import KoreUI
import LinkProtocol
@testable import src

/// An Auto ask on the phone (approvals.pending, as every card, so it notifies as they do): a
/// permission card whose Allow reads Run once, with no Always allow (that's the Mac's, once a
/// person sees what it keeps); a call Auto refused outright has OK only.
@MainActor
@Suite("Auto asks over the link")
struct LinkAutoAskCardTests {
    @Test func runOnceAndDenyNoAlwaysAllowAndRefusedWhenAutoAlreadySaidNo() {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp/kore-auto-link"))
        var ask = Approval(id: "r-hook", title: "Auto asks: sudo reboot (Kore asks you first: sudo.)", detail: nil, body: "sudo reboot", canAlwaysAllow: true, questions: [])
        ask.autoStop = true
        ask.alwaysRule = "sudo reboot *"
        let card = LinkSnapshot.card(ask, in: chat)
        #expect(card.kind == .permission && card.title == ask.title)
        #expect(card.actions.map(\.id) == [.allow, .deny] && card.actions.first?.label == "Run once" && card.actions.allSatisfy { $0.refused == nil })
        var stop = Approval(id: "autostop-t1", title: "Auto stopped: rm -rf ~ (a removal Auto never runs)", detail: ClaudeAutoStops.safetyLine, body: nil, canAlwaysAllow: false, questions: [])
        stop.autoStop = true
        stop.allowNote = ClaudeAutoStops.safetyLine
        // Refused outright: OK only, no Run once at all.
        let refused = LinkSnapshot.card(stop, in: chat)
        #expect(refused.actions.map(\.id) == [.deny] && refused.actions.first?.label == "OK")
    }
}
