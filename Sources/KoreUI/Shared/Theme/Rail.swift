import SwiftUI

// The transcript's message scroller: one tick per user message, on the right.

extension Theme {
    /// A message that's loaded.
    static let railTick = secondary
    /// One that isn't yet: a click loads it.
    static let railTickUnloaded = secondary.opacity(0.32)  // lint:allow the rail's one dim step
    /// The one being read, and the one under the pointer.
    static let railTickCurrent = text
}

extension Size {
    static let railTick: CGFloat = 10
    static let railTickCurrent: CGFloat = 14
    /// Under the pointer, then its neighbours, stepping down to `railTick`.
    static let railTickHover: CGFloat = 22
    static let railTickHoverStep: CGFloat = 4
    static let railStroke: CGFloat = 2
    /// The most ticks shown at once, however long the chat.
    static let railMost = 20
    /// Between ticks, closer in a window too short for them.
    static let railSpacing: CGFloat = 8
    /// A message's row this near the top of the view is the one being read.
    static let railReadLine: CGFloat = 40
    /// What takes the pointer, from the scroll bar's edge in.
    static let railWidth: CGFloat = 26
    /// Clear of the scroll bar.
    static let railInset: CGFloat = 12
    static let railMargin: CGFloat = 16
    static let railCard: CGFloat = 300
    static let railCardGap: CGFloat = 10
    /// Ticks beside a gap in the list fade over this many.
    static let railFade = 4
}
