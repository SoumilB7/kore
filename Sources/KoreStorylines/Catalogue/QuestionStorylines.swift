import AppKit
import KoreUI

// The question card (question-card.html, B "Steps"): one question at a time under tabs from the
// CLI's headers, Submit an outline until every question is answered, and the keys while it has them.

/// A question card's turn: the questions, then "Got it." once they're answered.
@MainActor private func questionScript(_ questions: [Approval.Question]) -> CLIScript {
    let approval = Approval(id: "q1", title: "", detail: nil, body: nil, canAlwaysAllow: false, questions: questions)
    return CLIScript(turns: [[.startTurn, .approval(approval, allow: Beat.answer("Got it."), deny: []), .finishTurn(.completed)]])
}

@MainActor private func shown(_ id: StoryID) -> Bool { StoryRegistry.ids.contains(id.raw) }

@MainActor private func answers(_ story: StoryContext) throws -> [String: [String]]? { try story.scriptedBackend().answers["q1"] }

private let card = StoryID.Approval.card("q1")
private func tab(_ index: Int) -> StoryID { StoryID.Approval.tab("q1", index) }

/// Three questions, the last without a header: a tab each, ticked once answered; the card keeps
/// its height from tab to tab; Submit is an outline until the last answer, and the answers go
/// back as they always have.
final class QuestionCardSteps: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals] }
    static let layout = "How should the settings page be organised?"
    static let sync = "Which settings should sync across Macs?"
    static let reset = "Keep a Reset button on each section?"
    override class var script: CLIScript {
        questionScript([
            Approval.Question(
                id: layout, text: layout, header: "Layout",
                options: [
                    .init(label: "Tabs", description: "One pane per area; nothing scrolls far"),
                    .init(label: "One long page", description: "Every setting in one scroll, with section headers"),
                    .init(label: "Sidebar", description: "Sections on the left, the chosen one on the right"),
                ]),
            Approval.Question(
                id: sync, text: sync, header: "Sync",
                options: [
                    .init(label: "Appearance", description: "Theme, zoom and font sizes"),
                    .init(label: "Shortcuts", description: "Your rebound keys"),
                    .init(label: "Accounts", description: "Which logins exist, never their tokens"),
                ], multiple: true),
            Approval.Question(
                id: reset, text: reset,
                options: [.init(label: "Yes", description: "Under each section's last setting"), .init(label: "No", description: "One Reset all at the bottom")]),
        ])
    }

    /// Where Submit sits: it moves only if the card changes height.
    private var submitAt: CGRect?
    @MainActor private static func submitFrame() -> CGRect? { StoryElement(card.part(.submit))?.frame }

    private func option(_ question: String, _ label: String) -> Press { Press(.id(StoryID.Approval.option(question, label))) }
    private func ticked(_ question: String, _ label: String) -> Bool { shown(StoryID.Approval.option(question, label).part(.ticks)) }

    private func steady(_ what: String) -> Expect {
        Expect("the card as tall as before (\(what))", found: { _ in "\(String(describing: Self.submitFrame())) vs \(String(describing: self.submitAt))" }) { _ in
            guard let now = Self.submitFrame(), let before = self.submitAt else { return false }
            return abs(now.minY - before.minY) < 0.5 && abs(now.maxY - before.maxY) < 0.5
        }
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Ask me"),
            WaitForElement(.id(tab(2))),
            Expect("three tabs, the first shown, none ticked, Submit an outline") { _ in
                shown(tab(0)) && shown(tab(1)) && shown(tab(2)) && shown(tab(0).part(.lit))
                    && !(0..<3).contains { shown(tab($0).part(.done)) } && !shown(card.part(.done))
            },
            WaitIdle(),
            Do("note where Submit is") { _ in self.submitAt = Self.submitFrame() },
            MarksDrawn(),
            Snapshot("steps-none"),
            option(Self.layout, "Sidebar"),
            Expect("Sidebar picked, Layout ticked") { _ in self.ticked(Self.layout, "Sidebar") && shown(tab(0).part(.done)) },
            Snapshot("steps-oneof-picked"),
            Press(.id(tab(1))),
            Expect("Sync shown") { _ in shown(tab(1).part(.lit)) && shown(StoryID.Approval.option(Self.sync, "Accounts")) },
            steady("Sync"),
            option(Self.sync, "Appearance"),
            option(Self.sync, "Shortcuts"),
            Expect("two ticked: any of them") { _ in
                self.ticked(Self.sync, "Appearance") && self.ticked(Self.sync, "Shortcuts") && shown(tab(1).part(.done))
            },
            Snapshot("steps-anyof"),
            Press(.id(card.part(.submit))),
            Expect("nothing sent with Reset unanswered, Submit still an outline") { story in
                try !story.scriptedBackend().log.contains { if case .respond = $0 { true } else { false } }
                    && !shown(card.part(.done)) && !shown(tab(2).part(.done))
            },
            Press(.id(tab(2))),
            steady("Reset"),
            option(Self.reset, "No"),
            Expect("every tab ticked, Submit ready") { _ in (0..<3).allSatisfy { shown(tab($0).part(.done)) } && shown(card.part(.done)) },
            Snapshot("steps-ready"),
            Press(.id(card.part(.submit))),
            TurnFinished(1),
            Expect("the answers, as the CLIs always got them") { story in
                try answers(story) == [Self.layout: ["Sidebar"], Self.sync: ["Appearance", "Shortcuts"], Self.reset: ["No"]]
            },
        ]
    }
}

/// The card has the keys as it arrives over an empty composer: ↓ and ↩ pick and go on to the
/// next question, a digit picks, Space toggles, the number after the options opens Other, Esc
/// leaves its field and then gives the keys back; a click takes them again, ⇥ ⇧⇥ go between
/// questions and ⌘↩ submits.
final class QuestionCardKeys: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals] }
    static let layout = "Which settings layout?"
    static let sync = "Which settings should sync?"
    override class var script: CLIScript {
        questionScript([
            Approval.Question(
                id: layout, text: layout, header: "Layout",
                options: [.init(label: "Tabs", description: ""), .init(label: "One long page", description: ""), .init(label: "Sidebar", description: "")]),
            Approval.Question(
                id: sync, text: sync, header: "Sync",
                options: [.init(label: "Appearance", description: ""), .init(label: "Shortcuts", description: ""), .init(label: "Accounts", description: "")],
                multiple: true),
        ])
    }

    private func lit(_ question: String, _ label: String) -> Bool { shown(StoryID.Approval.option(question, label).part(.lit)) }
    private func ticked(_ question: String, _ label: String) -> Bool { shown(StoryID.Approval.option(question, label).part(.ticks)) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Ask me"),
            WaitForElement(.id(card.part(.focus))),
            MarksDrawn(),
            Snapshot("keys-arrive"),
            Key(.down), Key(.down),
            Expect("the second row current") { _ in self.lit(Self.layout, "One long page") },
            Snapshot("keys-current"),
            Key(.returnKey),
            Expect("↩ picked it and went on to Sync, its first row current") { _ in
                shown(tab(0).part(.done)) && shown(tab(1).part(.lit)) && self.lit(Self.sync, "Appearance")
            },
            Key(.key("2")),
            Key(.up),
            Key(KeyChord(.space)),
            Expect("2 and Space ticked two") { _ in self.ticked(Self.sync, "Shortcuts") && self.ticked(Self.sync, "Appearance") },
            Key(.key("4")),
            WaitForElement(.id(StoryID.Approval.other(Self.sync).part(.field))),
            TypeText("Window size"),
            Snapshot("keys-other"),
            Key(.escape),
            Expect("Esc left the field, the card keeps the keys") { story in
                shown(card.part(.focus)) && !(story.window?.firstResponder is NSText)
            },
            Key(KeyChord(.tab, .shift)),
            Expect("⇧⇥ back to Layout") { _ in shown(tab(0).part(.lit)) },
            Key(.tab),
            Expect("⇥ on to Sync") { _ in shown(tab(1).part(.lit)) },
            Key(.escape),
            Expect("a second Esc gave the keys to the composer") { _ in !shown(card.part(.focus)) },
            Click(.id(tab(0))),
            Expect("a click on the card took them back") { _ in shown(card.part(.focus)) && shown(tab(0).part(.lit)) },
            Key(KeyChord(.returnKey, .command)),
            TurnFinished(1),
            Expect("⌘↩ sent the answers") { story in
                try answers(story) == [Self.layout: ["One long page"], Self.sync: ["Appearance", "Shortcuts", "Window size"]]
            },
        ]
    }
}

/// One question: no tabs. Any-of draws checkboxes, Other is a row with its field in it, and an
/// Other left empty keeps Submit an outline.
final class QuestionCardSingle: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals] }
    static let sync = "Which settings should sync across Macs?"
    override class var script: CLIScript {
        questionScript([
            Approval.Question(
                id: sync, text: sync, header: "Sync",
                options: [
                    .init(label: "Appearance", description: "Theme, zoom and font sizes"),
                    .init(label: "Shortcuts", description: "Your rebound keys"),
                    .init(label: "Accounts", description: "Which logins exist, never their tokens"),
                ], multiple: true)
        ])
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Ask me"),
            WaitForElement(.id(card.part(.submit))),
            Expect("no tabs for one question") { _ in !shown(tab(0)) },
            Snapshot("single-none"),
            Press(.id(StoryID.Approval.option(Self.sync, "Appearance"))),
            Expect("Submit ready") { _ in shown(card.part(.done)) },
            Press(.id(StoryID.Approval.other(Self.sync))),
            WaitForElement(.id(StoryID.Approval.other(Self.sync).part(.field))),
            Expect("Other open but empty: Submit an outline again, Appearance still ticked") { _ in
                !shown(card.part(.done)) && shown(StoryID.Approval.option(Self.sync, "Appearance").part(.ticks))
            },
            Click(.id(StoryID.Approval.other(Self.sync).part(.field))),
            TypeText("Window size and position"),
            Expect("Submit ready") { _ in shown(card.part(.done)) },
            Snapshot("single-other"),
            Press(.id(card.part(.submit))),
            TurnFinished(1),
            Expect("the pick and the typed answer") { story in try answers(story) == [Self.sync: ["Appearance", "Window size and position"]] },
        ]
    }
}

/// Options with previews: the well shows the current row's, else the picked one's.
final class QuestionCardPreview: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals] }
    static let layout = "Which settings layout?"
    static let previews = [
        "Tabs": "General   Models   Keys\n───────\nTheme        ● Dark\nZoom         100%\nFont size    13",
        "Sidebar": "General   │ Theme      ● Dark\nModels    │ Zoom       100%\nKeys      │ Font size  13",
        "One page": "General\n  Theme ● Dark   Zoom 100%\nModels\n  Default  Haiku",
    ]
    override class var script: CLIScript {
        questionScript([
            Approval.Question(
                id: layout, text: layout, header: "Layout",
                options: [
                    .init(label: "Tabs", description: "One pane per area", preview: previews["Tabs"]),
                    .init(label: "Sidebar", description: "Sections left, detail right", preview: previews["Sidebar"]),
                    .init(label: "One page", description: "A single scroll", preview: previews["One page"]),
                ])
        ])
    }

    private func previewing(_ label: String) -> Bool { shown(StoryID.Approval.preview(Self.layout, label)) }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Ask me"),
            WaitForElement(.id(card.part(.focus))),
            Expect("no preview before a row is current or picked") { _ in !["Tabs", "Sidebar", "One page"].contains(where: self.previewing) },
            Key(.down),
            Expect("Tabs' preview") { _ in self.previewing("Tabs") },
            Key(.down),
            Expect("Sidebar's preview") { _ in self.previewing("Sidebar") && !self.previewing("Tabs") },
            Snapshot("preview-wide"),
            Key(.key("1")),
            Expect("1 picked Tabs: its preview") { _ in self.previewing("Tabs") },
            Key(KeyChord(.returnKey, .command)),
            TurnFinished(1),
            Expect("Tabs sent") { story in try answers(story) == [Self.layout: ["Tabs"]] },
        ]
    }
}

/// The narrowest window: four tabs that don't fit, so the card steps, "1/4 ‹ ›"; previews go under
/// the options.
final class QuestionCardNarrow: ChatStoryline {
    override class var tags: Set<Tag> { [.chat, .approvals] }
    override class var needs: Needs { Needs(window: CGSize(width: 360, height: 700)) }
    static let texts = ["Which settings layout?", "Which settings should sync across Macs?", "Keep a Reset button?", "Export settings as?"]
    static let headers = ["Layout", "Sync across Macs", "Reset buttons", "Export format"]
    override class var script: CLIScript {
        questionScript(
            texts.indices.map { i in
                Approval.Question(
                    id: texts[i], text: texts[i], header: headers[i],
                    options: [
                        .init(label: "One", description: "The first way", preview: i == 0 ? "General │ Theme ● Dark\nModels  │ Zoom  100%" : nil),
                        .init(label: "Two", description: "The second way", preview: i == 0 ? "General\n───────\nTheme ● Dark" : nil),
                    ], multiple: i == 1)
            })
    }

    override func steps() -> [any Step] {
        super.steps() + [
            Send("Ask me"),
            WaitForElement(.id(card.part(.next))),
            Expect("a stepper, not tabs") { _ in !shown(tab(0)) && shown(card.part(.previous)) },
            Key(.down),
            Expect("the first question's preview under its options") { _ in shown(StoryID.Approval.preview(Self.texts[0], "One")) },
            Snapshot("narrow-first"),
            Press(.id(StoryID.Approval.option(Self.texts[0], "One"))),
            Press(.id(card.part(.next))),
            Expect("the second question") { _ in shown(StoryID.Approval.option(Self.texts[1], "Two")) && !shown(StoryID.Approval.option(Self.texts[0], "Two")) },
            Press(.id(StoryID.Approval.option(Self.texts[1], "Two"))),
            Snapshot("narrow-second"),
            Press(.id(card.part(.next))),
            Press(.id(StoryID.Approval.option(Self.texts[2], "One"))),
            Press(.id(card.part(.next))),
            Press(.id(StoryID.Approval.option(Self.texts[3], "Two"))),
            Expect("Submit ready") { _ in shown(card.part(.done)) },
            Press(.id(card.part(.previous))),
            Expect("back to the third") { _ in shown(StoryID.Approval.option(Self.texts[2], "One")) },
            Press(.id(card.part(.submit))),
            TurnFinished(1),
            Expect("the answers") { story in
                try answers(story) == [Self.texts[0]: ["One"], Self.texts[1]: ["Two"], Self.texts[2]: ["One"], Self.texts[3]: ["Two"]]
            },
        ]
    }
}

/// Waits out the corner marks' draw-in (`Motion.drawIn`), so a snapshot shows them whole.
private struct MarksDrawn: Step {
    var label: String { "Wait for the corner marks" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the corner marks") { ContinuousClock.now >= end }
    }
}
