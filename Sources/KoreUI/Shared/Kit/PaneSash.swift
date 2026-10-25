import AppKit
import SwiftUI

/// The divider between a pane and the content beside it: a hairline that drags to resize the
/// pane (on its leading side) within `range`, lit after a moment under the pointer, with the
/// resize cursor; a double-click gives the pane back its own width (`reset`).
struct PaneSash: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let reset: () -> Void
    @StateObject private var hot = Local(false)
    @StateObject private var start = Held<CGFloat?>(nil)
    @StateObject private var hover = Held<Task<Void, Never>?>(nil)

    var body: some View {
        // The hit area is wider than the line, laid out as the line alone and drawn over the
        // panes on either side, so the press is the sash's wherever it lands on it.
        let hit = Layout.Explorer.sashHit
        Color.clear
            .frame(width: hit)
            .frame(maxHeight: .infinity)
            .overlay { Rectangle().fill(hot.value || start.value != nil ? Theme.accentLine : Theme.border).frame(width: Stroke.hairline) }
            .contentShape(Rectangle())
            .allowsWindowActivationEvents(true)
            .onHover { inside in
                hover.value?.cancel()
                if inside {
                    NSCursor.resizeLeftRight.push()
                    hover.value = Task {
                        try? await Task.sleep(for: .seconds(Motion.sashHover))
                        if !Task.isCancelled { hot.value = true }
                    }
                } else {
                    NSCursor.pop()
                    hot.value = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let base = start.value ?? width
                        start.value = base
                        width = min(max(base + drag.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start.value = nil }
            )
            .onTapGesture(count: 2, perform: reset)
            .padding(.horizontal, -(hit - Stroke.hairline) / 2)
            .zIndex(2)
    }
}
