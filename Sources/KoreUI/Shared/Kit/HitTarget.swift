import SwiftUI

/// Small controls take clicks across at least `Size.hitTarget` (WCAG 2.5.8), however small
/// they're drawn. A button only takes clicks inside its own frame, so its label grows by the
/// reach (after its look, which stays the size it was), and the button gives the room back
/// outside, so it sits where it did.
enum HitTarget {
    /// How far past each edge a control drawn `width` × `height` reaches to be `Size.hitTarget`
    /// across; a side it's already big enough on reaches nowhere.
    static func reach(width: CGFloat = Size.hitTarget, height: CGFloat = Size.hitTarget) -> EdgeInsets {
        let x = max((Size.hitTarget - width) / 2, 0), y = max((Size.hitTarget - height) / 2, 0)
        return EdgeInsets(top: y, leading: x, bottom: y, trailing: x)
    }
}

extension View {
    /// Inside a button's label, after its look: the label, and so where the button takes
    /// clicks, grows by `reach`.
    func hitTarget(_ reach: EdgeInsets) -> some View {
        padding(reach).contentShape(Rectangle())
    }

    /// On the button: the room its label's `hitTarget` took is given back.
    func hitTargetRoom(_ reach: EdgeInsets) -> some View {
        padding(EdgeInsets(top: -reach.top, leading: -reach.leading, bottom: -reach.bottom, trailing: -reach.trailing))
    }
}
