import AppKit
import SwiftUI

/// The divider between a pane and the content beside it: a hairline that drags to resize the
/// pane (on its leading side) within `range`, lit after a moment under the pointer, with the
/// resize cursor; a double-click gives the pane back its own width (`reset`). `dragging` says
/// when a drag starts and ends, however it ends: the content beside it holds still meanwhile
/// (`heldBesideSash`) and wraps anew once, as it ends.
struct PaneSash: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let dragging: (Bool) -> Void
    let reset: () -> Void
    @GestureState private var pressed = false
    @StateObject private var hot = Local(false)
    @StateObject private var held = Local(false)
    @StateObject private var start = Held<CGFloat?>(nil)
    @StateObject private var cut = Held(false)
    @StateObject private var hover = Held<Task<Void, Never>?>(nil)
    @StateObject private var watch = SashDragWatch()

    var body: some View {
        // The hit area is wider than the line, laid out as the line alone and drawn over the
        // panes on either side, so the press is the sash's wherever it lands on it.
        let hit = Layout.Explorer.sashHit
        Color.clear
            .frame(width: hit)
            .frame(maxHeight: .infinity)
            .overlay { Rectangle().fill(hot.value || held.value ? Theme.accentLine : Theme.border).frame(width: Stroke.hairline) }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            // Inside the hover: however far the pointer outruns the line, it never left the sash.
            .overlay { if held.value { SashDragCursor(style: .columnResize) } }
            .allowsWindowActivationEvents(true)
            .onHover { inside in
                hover.value?.cancel()
                SashPointer.over = inside
                if inside {
                    hover.value = Task {
                        try? await Task.sleep(for: .seconds(Motion.sashHover))
                        if !Task.isCancelled { hot.value = true }
                    }
                } else {
                    hot.value = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($pressed) { _, pressed, _ in pressed = true }
                    .onChanged { drag in
                        if start.value == nil { begin(at: drag.translation.width) }
                        let base = start.value ?? width
                        width = min(max(base + drag.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in end() }
            )
            // SwiftUI can drop a drag without `onEnded`: the pressed state still goes back.
            .onChange(of: pressed) { _, now in
                guard !now else { return }
                end()
                cut.value = false
            }
            .onDisappear {
                end()
                if SashPointer.over { SashPointer.over = false }
            }
            .onTapGesture(count: 2, perform: reset)
            .padding(.horizontal, -(hit - Stroke.hairline) / 2)
            .zIndex(2)
    }

    private func begin(at moved: CGFloat) {
        // A drag cut off (the window lost focus) that carries on goes on from the pointer.
        start.value = cut.value ? width - moved : width
        cut.value = false
        held.value = true
        dragging(true)
        watch.start {
            cut.value = true
            end()
        }
    }

    private func end() {
        guard start.value != nil else { return }
        start.value = nil
        held.value = false
        watch.stop()
        dragging(false)
    }
}

extension View {
    /// The content beside a sash, held at `width` through its drag: it keeps its size and stays
    /// put against its far edge while the pane beside it moves over it or away from it, so nothing
    /// in it lays out. With nil it's the room left, as any content.
    func heldBesideSash(_ width: CGFloat?) -> some View {
        frame(width: width, alignment: .leading)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: width == nil ? .leading : .trailing)
    }
}

/// Far wider than anything, clear, over the sash while it drags: the resize cursor holds however
/// far the pointer outruns the line. It takes no press: its drag has the pointer already.
struct SashDragCursor: View {
    let style: PointerStyle

    var body: some View {
        Color.clear.frame(width: 16384, height: 16384).contentShape(Rectangle()).pointerStyle(style)
    }
}

/// A sash under the pointer: a view under it that sets the cursor as the pointer moves leaves
/// the cursor to the sash.
@MainActor
enum SashPointer {
    static var over = false
}

/// Tells a sash's drag it's over when what ends a drag never reached it: the pointer moving
/// or pressing again with no release seen, or the window or the app losing focus. It listens only
/// while the drag runs.
@MainActor
final class SashDragWatch: ObservableObject {
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func start(_ over: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { event in
            MainActor.assumeIsolated { over() }
            return event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { over() } })
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
