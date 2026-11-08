import Foundation
import Testing

@testable import KoreHost
@testable import KoreLink
@testable import KoreUI
import LinkProtocol
@testable import src

/// The same answer reads the same on the Mac's card, a phone's (the Mac's link) and a box's
/// (kore-host's): the plan card, "Implement this plan?" and a question's Submit and Skip.
@MainActor
@Suite("Card words, Mac and link")
struct CardWordsTests {
    let chat = Chat(provider: .claude, folder: URL(fileURLWithPath: "/tmp/kore-card-words"))

    @Test func thePlanCardReadsAsTheMacs() {
        let plan = Approval(id: "p", title: "Plan", detail: nil, body: nil, canAlwaysAllow: false, questions: [], plan: "Do it.")
        let mac = [CardLabels.Plan.approve, CardLabels.Plan.autoAccept, CardLabels.Plan.keepPlanning]
        #expect(mac == ["Yes, manually approve edits", "Yes, auto-accept edits", "No, keep planning"])
        #expect(LinkSnapshot.card(plan, in: chat).actions.map(\.label) == mac)
        #expect(HostMeta.card(plan, in: chat).actions.map(\.label) == mac)
    }

    @Test func implementThisPlanReadsAsTheMacs() {
        let mac = [CardLabels.Implement.implement, CardLabels.Implement.stay]
        #expect(mac == ["Yes, implement this plan", "No, stay in Plan mode"])
        chat.approvals.offerImplementPlan = true
        let card = LinkSnapshot.cards(chat).first { $0.kind == .planReady }
        #expect(card?.title == CardLabels.Implement.title && card?.actions.map(\.label) == mac)
        #expect(HostMeta.implementActions.map(\.label) == mac)
        #expect(HostMeta.implementActions.map(\.id) == card?.actions.map(\.id))
    }

    @Test func aQuestionsSkipIsItsDeny() {
        let ask = Approval(id: "q", title: "Q", detail: nil, body: nil, canAlwaysAllow: false, questions: [.init(id: "c", text: "Colour?", options: [.init(label: "Red", description: "")])])
        for card in [LinkSnapshot.card(ask, in: chat), HostMeta.card(ask, in: chat)] {
            #expect(card.actions.map(\.label) == [CardLabels.Question.submit, CardLabels.Question.skip])
            #expect(card.actions.last?.id == .deny)
        }
    }
}
