import Foundation
import Testing

@testable import KoreLink
@testable import KoreUI
import LinkProtocol
@testable import src

/// The held-messages card on the phone (approvals.pending, as every card): a permission card, so a
/// phone of any version shows it with Allow and Deny; on a hold no flag can lift, Allow is refused.
@MainActor
@Suite("Held messages card over the link")
struct LinkHeldCardTests {
    @Test func aPermissionCardWithAllowRefusedWhenOnlyDenyWorks() {
        let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp/kore-held-link"))
        var approval = Approval(id: "peer-hold", title: "A message from “Kore-main” is held: it bypasses permissions and this chat doesn't", detail: nil, body: nil, canAlwaysAllow: false, questions: [])
        approval.held = [.init(from: "uds:/tmp/cc-socks/1.sock", name: "Kore-main")]
        let open = LinkSnapshot.card(approval, in: chat)
        #expect(open.kind == .permission && open.title == approval.title)
        #expect(open.actions.map(\.id) == [.allow, .deny] && open.actions.allSatisfy { $0.refused == nil })
        approval.allowNote = "A setting Kore can't change holds it: only Deny works here."
        let denyOnly = LinkSnapshot.card(approval, in: chat)
        #expect(denyOnly.actions.first { $0.id == .allow }?.refused == true)
        #expect(denyOnly.actions.first { $0.id == .deny }?.refused == nil)
    }
}
