import Testing

@testable import KoreUI

/// Esc in the composer: one step a press, and the turn stops only when nothing else is left.
struct EscLadderTests {
    private func next(
        overlay: Bool = false, slashMenu: Bool = false, popup: Bool = false, selection: Bool = false, running: Bool = true,
        sheet: Bool = false
    ) -> EscStep {
        EscStep.next(overlay: overlay, slashMenu: slashMenu, popup: popup, selection: selection, running: running, sheet: sheet)
    }

    @Test func eachStepBeforeTheNext() {
        #expect(next(overlay: true, slashMenu: true, popup: true, selection: true) == .closeOverlay)
        #expect(next(slashMenu: true, popup: true, selection: true) == .closeSlashMenu)
        #expect(next(popup: true, selection: true) == .closePopup)
        #expect(next(selection: true) == .clearSelection)
        #expect(next() == .stop)
    }

    @Test func nothingToStop() {
        #expect(next(running: false) == .nothing)
        #expect(next(selection: true, running: false) == .clearSelection)
    }

    @Test func neverUnderASheet() {
        #expect(next(sheet: true) == .nothing)
        #expect(next(slashMenu: true, sheet: true) == .nothing)
    }
}
