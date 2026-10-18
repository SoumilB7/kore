import SwiftUI

extension Theme {
    /// What a list sits on: the window's ground (the docked explorer, the agent map, Welcome) or
    /// a panel (`surface`: menus, popups, the floating explorer).
    enum Ground: Sendable {
        case window, surface
    }

    /// The one hover and selection vocabulary for every list and row (design review 2026-10 §1.4):
    /// the row under the pointer is one step above its ground at 60%, the selected row the whole
    /// step, so neither ever matches what it sits on. A list that keeps its own keyboard focus
    /// (the tree, Search) tints its selection with the accent while it has it. In a menu there is
    /// one highlight, the selected row: the pointer moves it.
    enum Row {
        static func hover(_ ground: Ground) -> Color { ground == .window ? hoverOnWindow : hoverOnSurface }
        static func selected(_ ground: Ground) -> Color { ground == .window ? surface : surfaceHover }
        static let selectedFocused = accent.opacity(0.16)

        private static let hoverOnWindow = surface.opacity(0.6)
        private static let hoverOnSurface = surfaceHover.opacity(0.6)
    }
}

private struct ListGroundKey: EnvironmentKey {
    static let defaultValue = Theme.Ground.window
}

extension EnvironmentValues {
    /// The ground the rows below are drawn on, for lists that sit on either (the explorer and
    /// Search, docked or floating).
    var listGround: Theme.Ground {
        get { self[ListGroundKey.self] }
        set { self[ListGroundKey.self] = newValue }
    }
}
