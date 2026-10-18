import AppKit
import SwiftUI

/// Where the pointer was when the keys last moved a list's highlight. A row that scrolls under a
/// resting pointer (the keys scrolled the list) or a list that opens under it reports a hover as
/// if the pointer had moved there; until the pointer really moves, those leave the highlight
/// where the keys put it.
@MainActor
enum PointerGate {
    private static var keyedAt: CGPoint?

    /// The keys moved a highlight, or a list opened by a key.
    static func keyed() { keyedAt = NSEvent.mouseLocation }

    /// The pointer has moved since: a hover is its own.
    static var moved: Bool { NSEvent.mouseLocation != keyedAt }
}

extension View {
    /// A row of a list with one highlight (a menu, quick open, History, Welcome): the pointer
    /// entering it moves the highlight to it, as in a menu, so the keys and the pointer never light
    /// two rows. The lit row reads as selected, unless the list keeps a selection of its own
    /// (`selects` false: the import picker's pick). `id` names the row for storylines: `.hover`
    /// stands in for the pointer, and `.lit` is there while the row is lit.
    func highlightRow(_ id: StoryID?, lit: Bool, selects: Bool = true, take: @escaping @MainActor () -> Void) -> some View {
        modifier(HighlightRow(id: id, lit: lit, selects: selects, take: take))
    }
}

private struct HighlightRow: ViewModifier {
    let id: StoryID?
    let lit: Bool
    let selects: Bool
    let take: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onHover { inside in if inside, PointerGate.moved { take() } }
            .accessibilityAddTraits(lit && selects ? .isSelected : [])
            .background(StoryAnchor(id: id?.part(.hover).raw, press: take))
            .background(StoryAnchor(id: lit ? id?.part(.lit).raw : nil, press: nil))
    }
}
