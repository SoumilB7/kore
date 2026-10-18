import AppKit
import Testing

@testable import KoreUI

/// ⇥ through a popup's buttons: the ring's order, its way round the ends, and where it goes when
/// the ringed button does.
@Suite("Tab stops")
@MainActor
struct TabStopsTests {
    private func stops(_ ids: String..., after: [String: String] = [:]) -> [TabStops.Stop] {
        ids.map { TabStops.Stop(id: $0, after: after[$0]) }
    }

    private func key(_ code: UInt16, shift: Bool = false, command: Bool = false) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if command { flags.insert(.command) }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @Test func tabRingsEachStopInTurnAndGoesRound() {
        let focus = TabStops()
        focus.update(stops("a", "b", "c"))
        #expect(focus.current == nil)
        focus.move(1)
        #expect(focus.current == "a")
        focus.move(1)
        focus.move(1)
        #expect(focus.current == "c")
        focus.move(1)
        #expect(focus.current == "a")
        focus.move(-1)
        #expect(focus.current == "c")
    }

    @Test func shiftTabFromNothingRingsTheLast() {
        let focus = TabStops()
        focus.update(stops("a", "b"))
        #expect(focus.handle(key(48, shift: true)))
        #expect(focus.current == "b")
    }

    @Test func returnAndSpacePressOnlyARingedStop() {
        let focus = TabStops()
        focus.update(stops("a"))
        #expect(!focus.handle(key(36)))
        #expect(focus.presses == 0)
        focus.move(1)
        #expect(focus.handle(key(36)))
        #expect(focus.handle(key(49)))
        #expect(focus.presses == 2)
        // A shortcut isn't the popup's.
        #expect(!focus.handle(key(48, command: true)))
    }

    @Test func theRingFollowsTheStopThatTakesItsPlace() {
        let focus = TabStops()
        focus.update(stops("use", "other"))
        focus.move(1)
        // Use reset asks: Yes and No where it was, No taking its place.
        focus.update(stops("allow", "cancel", "other", after: ["cancel": "use"]))
        #expect(focus.current == "cancel")
        // A stop that goes with nothing in its place takes the ring with it.
        focus.update(stops("other"))
        #expect(focus.current == nil)
    }

    @Test func noStopsNoRing() {
        let focus = TabStops()
        focus.move(1)
        #expect(focus.current == nil)
        #expect(focus.handle(key(48)))
    }
}
