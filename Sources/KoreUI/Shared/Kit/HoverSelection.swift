import SwiftUI

extension View {
    /// Text selection that costs nothing until the pointer reaches the text. SwiftUI gives each
    /// selectable `Text` an AppKit view of its own, which lays the text out again: in a transcript
    /// that was about two fifths of building the rows. The pointer always crosses the text before a
    /// click, drag or right-click can select it, so selection is switched on then, and stays on.
    func selectableOnHover() -> some View {
        modifier(HoverSelection())
    }
}

private struct HoverSelection: ViewModifier {
    @StateObject private var on = Local(false)

    func body(content: Content) -> some View {
        if on.value {
            content.textSelection(.enabled)
        } else {
            content.onHover { if $0 { on.value = true } }
        }
    }
}
