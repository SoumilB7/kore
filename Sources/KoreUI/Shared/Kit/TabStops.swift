import AppKit
import Observation
import SwiftUI

/// Tab (⇥) through a popup's buttons while the composer keeps the keys (design review 2026-10
/// §1.7): the popup's key monitor moves a 1pt ring between the buttons marked as tab stops, in
/// the order they're laid out, and Return or Space presses the ringed one. Nothing is ringed
/// until Tab; a click takes the ring off, and so does the ringed button going, unless another
/// takes its place (No, go back where Use reset was).
@MainActor @Observable
final class TabStops {
    struct Stop: Equatable, Sendable {
        let id: String
        /// The stop whose place this one takes when that one goes.
        let after: String?
    }

    @ObservationIgnored private(set) var order: [Stop] = []
    /// The ringed stop.
    private(set) var current: String?
    /// Presses of the ringed stop, counted, so each is a change its button sees.
    private(set) var presses = 0

    /// The stops as the popup lays them out now.
    func update(_ stops: [Stop]) {
        order = stops
        guard let current, !stops.contains(where: { $0.id == current }) else { return }
        self.current = stops.first { $0.after == current }?.id
    }

    /// The ring to the next stop (`step` 1) or the one before (-1), round the end; from none, to
    /// the first or the last.
    func move(_ step: Int) {
        guard !order.isEmpty else { return current = nil }
        let index = current.flatMap { id in order.firstIndex { $0.id == id } }
        let next = index.map { (($0 + step) % order.count + order.count) % order.count } ?? (step > 0 ? 0 : order.count - 1)
        current = order[next].id
    }

    func clear() { current = nil }

    /// Presses the ringed stop; false with none.
    func press() -> Bool {
        guard current != nil else { return false }
        presses += 1
        return true
    }

    /// The keys a popup gives its stops: ⇥ and ⇧⇥ move the ring, and Return, Enter and Space
    /// press the ringed stop. True when taken.
    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 48:
            move(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 36, 76, 49: return press()
        default: return false
        }
    }
}

private struct TabStopKey: PreferenceKey {
    static let defaultValue: [TabStops.Stop] = []
    static func reduce(value: inout [TabStops.Stop], nextValue: () -> [TabStops.Stop]) { value += nextValue() }
}

extension View {
    /// A popup whose buttons Tab reaches: collects its tab stops into `stops`, in layout order.
    func tabStops(_ stops: TabStops) -> some View {
        environment(stops).onPreferenceChange(TabStopKey.self) { value in
            MainActor.assumeIsolated { stops.update(value) }
        }
    }

    /// A button its popup's Tab reaches: ringed while it has the keys, pressed by Return or
    /// Space. Off (`.disabled` outside it) or `skipped`, Tab passes it by. `after`: the stop it
    /// takes the place of.
    func tabStop(
        _ id: StoryID, after: StoryID? = nil, skipped: Bool = false, radius: CGFloat = Radius.chip,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(TabStop(id: id, after: after, skipped: skipped, radius: radius, action: action))
    }
}

private struct TabStop: ViewModifier {
    let id: StoryID
    let after: StoryID?
    let skipped: Bool
    let radius: CGFloat
    let action: @MainActor () -> Void
    @Environment(TabStops.self) private var stops: TabStops?
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let isEnabled = isEnabled && !skipped
        let ringed = isEnabled && stops?.current == id.raw
        content
            // Just outside the button, as a focus ring is, so it never stands in for the button's own edge.
            .overlay {
                if ringed {
                    RoundedRectangle(cornerRadius: radius + Space.xxs)
                        .strokeBorder(Theme.accentLine, lineWidth: Stroke.hairline)
                        .padding(-Space.xxs)
                }
            }
            .preference(key: TabStopKey.self, value: isEnabled ? [TabStops.Stop(id: id.raw, after: after?.raw)] : [])
            .onChange(of: stops?.presses) { if ringed { action() } }
            .background(StoryAnchor(id: ringed ? id.part(.focus).raw : nil, press: nil))
    }
}
