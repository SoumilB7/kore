/// The words on a card's buttons, one set for the Mac's cards and the link's (a phone, a box's
/// cards on the Mac): the same answer reads the same wherever it's given.
package enum CardLabels {
    /// A plan card (Claude's ExitPlanMode).
    package enum Plan {
        package static let keepPlanning = "No, keep planning"
        package static let approve = "Yes, manually approve edits"
        package static let autoAccept = "Yes, auto-accept edits"
    }

    /// Codex's "Implement this plan?" after a plan in Plan mode.
    package enum Implement {
        package static let title = "Implement this plan?"
        package static let implement = "Yes, implement this plan"
        package static let stay = "No, stay in Plan mode"
    }

    /// A question card: answers sent, or the question turned down.
    package enum Question {
        package static let submit = "Submit"
        package static let skip = "Skip"
    }
}
