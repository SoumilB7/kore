import AppKit
import SwiftUI

/// Kore's own hover tip, in place of macOS's tooltip: one line or two on Kore's surface, below
/// and right of the pointer, after the pointer rests on a view for a moment. One at a time; it
/// goes at a press, a key, a scroll or the pointer leaving, and stays away while an option popup
/// or a question (`KoreAsk`) is up. Nothing runs while no view is hovered: a view only notes the
/// pointer coming and going.
@MainActor @Observable
package final class KoreTip {
    package static let shared = KoreTip()

    private(set) var text: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var owner: Int?
    @ObservationIgnored private var host: NSHostingView<TipBubble>?
    @ObservationIgnored private var monitor: Any?
    /// A tip shown a moment ago: the next comes at once, as macOS's do along a toolbar.
    @ObservationIgnored private var warmUntil = Date.distantPast
    package static var delay: Duration = .milliseconds(700)
    static let warmFor: TimeInterval = 1.5
    /// Storylines: the tip up now.
    package static var storyShown: String? { shared.text }

    /// The text the pointer's view asked for (shown, or on its way).
    @ObservationIgnored private var wanted: String?

    /// The pointer came onto the view with id `owner`.
    package func enter(_ text: String, owner: Int) {
        guard !text.isEmpty else { return }
        leave(owner: self.owner ?? owner)
        self.owner = owner
        wanted = text
        let delay: Duration = Date() < warmUntil ? .zero : Self.delay
        pending = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled, self.owner == owner else { return }
            self.show(text)
        }
    }

    /// The pointer left the view with id `owner` (or a later one took over).
    package func leave(owner: Int) {
        guard self.owner == owner else { return }
        pending?.cancel()
        pending = nil
        self.owner = nil
        wanted = nil
        hide()
    }

    /// An AppKit view's tip for what's under the pointer now (a cut-off cell's whole text): the
    /// same text keeps its tip, another starts anew, nil takes it away.
    func set(_ text: String?, owner: Int) {
        guard let text, !text.isEmpty else { return leave(owner: owner) }
        if self.owner == owner, wanted == text { return }
        enter(text, owner: owner)
    }

    /// An id for an AppKit view's tips.
    static func owner(_ view: NSView) -> Int { -abs(ObjectIdentifier(view).hashValue) }

    func hide() {
        if text != nil { warmUntil = Date().addingTimeInterval(Self.warmFor) }
        text = nil
        host?.removeFromSuperview()
        host = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func show(_ text: String) {
        guard !OptionsMenu.shared.isOpen, !KoreAsk.shared.isOpen,
              let window = Self.windowUnderPointer(), let content = window.contentView else { return }
        hide()
        self.text = text
        let host = NSHostingView(rootView: TipBubble(text: text))
        host.setAccessibilityElement(false)
        let size = host.fittingSize
        let pointer = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        host.frame = Self.place(size: size, below: pointer, in: content.bounds, flipped: content.isFlipped)
        content.addSubview(host, positioned: .above, relativeTo: nil)
        self.host = host
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            self?.hide()
            return event
        }
    }

    /// Below and right of the pointer (past the cursor's arrow), kept inside the window.
    static func place(size: CGSize, below pointer: CGPoint, in bounds: CGRect, flipped: Bool) -> CGRect {
        let room = bounds.insetBy(dx: Space.xs, dy: Space.xs)
        let width = min(size.width, room.width), height = min(size.height, room.height)
        let gap = Size.Tip.pointerGap
        var x = pointer.x
        var y = flipped ? pointer.y + gap : pointer.y - gap - height
        // No room below: above the pointer instead.
        if flipped ? y + height > room.maxY : y < room.minY { y = flipped ? pointer.y - Space.xs - height : pointer.y + Space.xs }
        x = min(max(x, room.minX), room.maxX - width)
        y = min(max(y, room.minY), room.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func windowUnderPointer() -> NSWindow? {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: number) ?? KoreAsk.front()
    }
}

/// The tip itself: Kore's raised surface, its border, label text.
struct TipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Chrome.label)
            .foregroundStyle(Theme.text)
            .lineLimit(Size.Tip.lines)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: Size.Tip.maxWidth, alignment: .leading)
            .fixedSize()
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Theme.border, lineWidth: Stroke.hairline))
            .storyID(StoryID.Tip.shown)
    }
}

/// Notes the pointer on the view; the tip itself is `KoreTip`'s.
private struct KoreTipModifier: ViewModifier {
    let text: String
    @StateObject private var id = Held(KoreTipModifier.next())

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { KoreTip.shared.enter(text, owner: id.value) } else { KoreTip.shared.leave(owner: id.value) }
            }
            .onDisappear { KoreTip.shared.leave(owner: id.value) }
            .accessibilityHint(Text(text))
    }

    @MainActor private static var counter = 0
    @MainActor private static func next() -> Int {
        counter += 1
        return counter
    }
}

extension View {
    /// Kore's hover tip (`KoreTip`), where macOS's `.help` was.
    func tip(_ text: String) -> some View { modifier(KoreTipModifier(text: text)) }
}
