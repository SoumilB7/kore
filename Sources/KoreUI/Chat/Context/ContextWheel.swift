import AppKit
import SwiftUI

/// The composer's context wheel (phase-10 look §9): a ring filling as the context does, a card
/// on hover with the tokens and the auto-compact point, and a click to compact. Under the
/// pointer the ring takes the button hover fill and a compress glyph, so the click explains
/// itself. While compacting it turns. The wheel shows once the chat has a session, so the bar
/// never shifts: an empty ring until the first usage report (a thread resumed with none, or one
/// whose turns all failed), the card from that report on.
struct ContextWheel: View {
    let chat: Chat
    @StateObject private var hovered = Local(false)
    @FocusState private var focused: Bool

    var body: some View {
        let context = chat.context
        let card = chat.contextCard
        Button {
            chat.compact()
        } label: {
            ZStack {
                switch Self.face(context) {
                case .spinning:
                    SpinningArc(lineWidth: Size.contextRingStroke)
                case .ring:
                    ContextRing(fraction: context.fraction ?? 0, threshold: context.threshold)
                        .overlay {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(Glyph.contextCompress)
                                .foregroundStyle(Theme.text)
                                .opacity(hovered.value && chat.canCompact ? 1 : 0)
                                .animation(Motion.fade, value: hovered.value && chat.canCompact)
                        }
                }
            }
            .frame(width: Size.contextRing, height: Size.contextRing)
            .frame(width: Size.iconButtonSmall, height: Size.iconButtonSmall)
            .hoverFill(hovered.value && chat.canCompact, Theme.toolHover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!chat.canCompact)
        .focused($focused)
        .onHover(perform: hover)
        // Reached from the keyboard, the card opens at once.
        .onChange(of: focused) { _, now in if now { card.open() } }
        // The card is drawn by the chat (`contextCard`), over the composer box, which clips.
        .anchorPreference(key: ContextCardAnchor.self, value: .bounds) { card.shown && context.usage != nil ? $0 : nil }
        .accessibilityLabel(Text(Self.accessibility(context)))
        .onAppear {
            // The dev hook holds the hover state: card and glyph.
            if DevSnapshot.contextCard {
                card.open()
                hovered.value = true
            }
        }
        .onDisappear { card.close() }
    }

    enum Face { case spinning, ring }

    /// What the slot draws: never nothing, so its hover fill always has a ring in it.
    static func face(_ context: ContextStore) -> Face { context.compacting ? .spinning : .ring }

    /// "Context 62% used, 597k of 967k tokens. Compact."
    private static func accessibility(_ context: ContextStore) -> String {
        if context.compacting { return "Compacting context" }
        guard let usage = context.usage else { return "Context" }
        guard let window = usage.window, let fraction = context.fraction else {
            return "Context, \(context.usedText) tokens. Compact."
        }
        let percent = (usage.approximate ? "about " : "") + ContextStore.percent(fraction)
        return "Context \(percent) used, \(context.usedText) of \(ContextStore.tokens(window)) tokens. Compact."
    }

    private func hover(_ inside: Bool) {
        hovered.value = inside
        if DevSnapshot.contextCard { return }
        chat.contextCard.wheel(inside)
    }
}

/// The context card's presence, shared by the wheel and the card (drawn apart, over the chat):
/// it shows after a rest on the wheel, holds while the pointer is on the wheel, the bridge up
/// to the card or the card, or a drag lasts, and goes a grace period after the pointer leaves
/// them. `intent`: the pointer has been in the card, so the track is out.
@MainActor @Observable
final class ContextCardPresence {
    private(set) var shown = false
    private(set) var intent = false
    private(set) var dragging = false
    @ObservationIgnored private var onWheel = false
    @ObservationIgnored private var onCard = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// The card with its bridge, and the wheel, in the window: a click outside both closes it.
    @ObservationIgnored var frames: [CGRect] = []
    /// The track has the keyboard, so keys are its own.
    @ObservationIgnored var trackFocused = false
    /// As it shows: the chat's other popups close (`Chat.closePopups`).
    @ObservationIgnored var opening: (() -> Void)?

    func wheel(_ inside: Bool) {
        onWheel = inside
        if inside && !shown { after(Motion.cardDelay) { $0.show() } } else { settle() }
    }

    /// The card or its bridge; `intent` for the card itself.
    func card(_ inside: Bool, intent: Bool = false) {
        onCard = inside
        if inside && intent && !self.intent { self.intent = true }
        settle()
    }

    func drag(_ on: Bool, endedInside: Bool = true) {
        dragging = on
        if !on && !endedInside { (onCard, onWheel) = (false, false) }
        settle()
    }

    func open() {
        pending?.cancel()
        show()
    }

    private func show() {
        guard !shown else { return }
        opening?()
        shown = true
    }

    func close() {
        pending?.cancel()
        guard shown else { return }
        (shown, intent, dragging, onCard, onWheel, trackFocused) = (false, false, false, false, false, false)
    }

    /// While the pointer is on a part, or a drag lasts, it stays; else it goes after the grace.
    private func settle() {
        pending?.cancel()
        guard shown, !onWheel, !onCard, !dragging else { return }
        after(Motion.cardGrace) { $0.close() }
    }

    private func after(_ delay: Double, _ then: @escaping (ContextCardPresence) -> Void) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            then(self)
        }
    }
}

/// The ring: a track and the used arc from 12 o'clock, clockwise; with an auto-compact point, an
/// accent tick across the ring there, cut out of the arc.
private struct ContextRing: View {
    let fraction: Double
    let threshold: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.contextTrack, lineWidth: Size.contextRingStroke)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    Theme.contextArc(fraction, threshold: threshold),
                    style: StrokeStyle(lineWidth: Size.contextRingStroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : Motion.contextArc, value: fraction)
            if let threshold {
                RingTick(at: threshold)
                    .stroke(.black, style: StrokeStyle(lineWidth: Size.contextTick + 2 * Size.contextTickCut, lineCap: .round))
                    .blendMode(.destinationOut)
                RingTick(at: threshold)
                    .stroke(Theme.contextNotch, style: StrokeStyle(lineWidth: Size.contextTick, lineCap: .round))
            }
        }
        .padding(Size.contextRingStroke / 2)
        .compositingGroup()
    }
}

/// A short line across the ring at `fraction` of the way round from 12 o'clock.
private struct RingTick: Shape {
    let at: Double

    func path(in rect: CGRect) -> Path {
        let angle = at * 2 * .pi
        let radius = rect.width / 2
        let reach = Size.contextRingStroke * 0.9
        func point(_ r: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + r * sin(angle), y: rect.midY - r * cos(angle))
        }
        var path = Path()
        path.move(to: point(radius - reach))
        path.addLine(to: point(radius + reach))
        return path
    }
}

/// Where the wheel is while its card shows.
struct ContextCardAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

extension View {
    /// Shows the context wheel's card above the wheel, inside this view (the chat), so the
    /// composer's box doesn't clip it. Under it, a bridge as wide as the wheel spans the gap, so
    /// the pointer can go from one to the other without leaving.
    func contextCard(_ chat: Chat) -> some View {
        overlayPreferenceValue(ContextCardAnchor.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let wheel = geometry[anchor]
                    let origin = geometry.frame(in: .global).origin
                    // Its bottom-left corner just above the wheel's top-left.
                    VStack(alignment: .leading, spacing: 0) {
                        ContextCard(chat: chat)
                        Color.clear
                            .frame(width: wheel.width, height: Size.contextCardGap)
                            .contentShape(Rectangle())
                            .padding(.leading, -Size.contextCardLead)
                    }
                    .onHover { chat.contextCard.card($0) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { card in
                        chat.contextCard.frames = [card, wheel.offsetBy(dx: origin.x, dy: origin.y)]
                    }
                    .padding(.leading, max(wheel.minX + Size.contextCardLead, 0))
                    .padding(.bottom, max(geometry.size.height - wheel.minY, 0))
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                }
            }
        }
    }
}

/// "597k / 967k tokens" over the ring laid flat (look §9, option A): the used fill and the
/// auto-compact notch on a hairline. In the card, the hairline becomes a track and the point's
/// readout shows; the card's size never changes. Esc, a click outside, or typing closes it.
private struct ContextCard: View {
    let chat: Chat
    @StateObject private var monitor = Held<Any?>(nil)
    @FocusState private var trackFocused: Bool

    var body: some View {
        let context = chat.context
        let presence = chat.contextCard
        HStack(spacing: Space.xl) {
            if context.compacting {
                Text("Compacting…").foregroundStyle(Theme.secondary)
            } else {
                Text(Self.tokens(context)).foregroundStyle(Theme.text)
            }
            Spacer(minLength: 0)
            readout(context, presence)
        }
        .font(Chrome.labelDigits)
        .lineLimit(1)
        .frame(minWidth: Size.contextCardMinWidth, minHeight: Size.contextCardLine, maxHeight: Size.contextCardLine)
        .fixedSize()
        // The track spans the line above it.
        .padding(.bottom, Space.xxs + Size.contextTrackRow)
        .overlay(alignment: .bottom) {
            ContextTrack(chat: chat, live: presence.intent && !context.compacting)
                .focused($trackFocused)
        }
        .padding(Inset.row)
        .panel(.panel)
        .cornerMarks(Theme.cornerOption)
        .onHover { if $0 { presence.card(true, intent: true) } }
        .onChange(of: trackFocused) { _, now in
            presence.trackFocused = now
            if now { presence.card(true, intent: true) }
        }
        .onAppear {
            monitor.value = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
                Self.handle($0, presence)
            }
        }
        .onDisappear {
            if let m = monitor.value { NSEvent.removeMonitor(m) }
            monitor.value = nil
        }
    }

    /// "80%", "80% · 774k" while dragging, "after this turn" once a running turn is past it,
    /// "Off": only on intent, in a slot as wide as the widest, so the card keeps its size.
    private func readout(_ context: ContextStore, _ presence: ContextCardPresence) -> some View {
        let past = chat.status.isRunning && context.pastPoint
        let text: String =
            if let point = context.autoCompactAt {
                past ? "after this turn" : "\(point)%" + (presence.dragging ? Self.at(point, context) : "")
            } else { "Off" }
        return ZStack(alignment: .trailing) {
            ForEach(["after this turn", "90% · 870k"], id: \.self) { widest in
                label(widest).hidden()
            }
            label(text).foregroundStyle(past ? Theme.warning : Theme.secondary)
        }
        .opacity(presence.intent && !context.compacting ? 1 : 0)
        .animation(Motion.fade, value: presence.intent)
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(Glyph.contextReadout)
            Text(text)
        }
    }

    /// " · 774k": the point in tokens, when the window is known.
    static func at(_ point: Int, _ context: ContextStore) -> String {
        guard let window = context.usage?.window else { return "" }
        return " · " + ContextStore.tokens(window * point / 100)
    }

    /// Esc closes the card (and goes no further); typing in the field, or a click outside it and
    /// the wheel, closes it and goes on.
    private static func handle(_ event: NSEvent, _ presence: ContextCardPresence) -> NSEvent? {
        if event.type == .keyDown {
            if event.keyCode == 53 {
                presence.close()
                return nil
            }
            // Tab leads to the track; the track's own keys adjust it.
            if !presence.trackFocused && event.keyCode != 48 { presence.close() }
            return event
        }
        guard let content = event.window?.contentView else { return event }
        let location = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !presence.frames.contains(where: { $0.contains(location) }) { presence.close() }
        return event
    }

    /// "597k / 967k tokens"; "182k tokens" before the CLI says its window.
    static func tokens(_ context: ContextStore) -> String {
        guard let usage = context.usage else { return "" }
        guard let window = usage.window else { return context.usedText + " tokens" }
        return "\(context.usedText) / \(ContextStore.tokens(window)) tokens"
    }
}

/// The ring laid flat: the base, the used fill, and the auto-compact notch (none when Off). Live
/// (on intent) it's a track: thicker, with the snap points' dots and the end's mark, and the
/// notch a knob that a drag or a click moves to the nearest snap point, past 90% to Off at the
/// end. ← → step, Delete sets Off. Drawn in one canvas, with no animation.
private struct ContextTrack: View {
    let chat: Chat
    let live: Bool
    @StateObject private var frame = Held(CGRect.zero)

    var body: some View {
        let context = chat.context
        let fraction = context.fraction ?? 0
        let point = context.autoCompactAt
        let fill = Theme.contextArc(fraction, threshold: context.threshold)
        Canvas { canvas, size in
            let line = live ? Size.contextTrack.intent : Size.contextTrack.rest
            let mid = size.height / 2
            func bar(_ width: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: 0, y: mid - line / 2, width: width, height: line), cornerRadius: line / 2)
            }
            canvas.fill(bar(size.width), with: .color(Theme.contextTrack))
            if fraction > 0 { canvas.fill(bar(max(size.width * fraction, line)), with: .color(fill)) }
            if live {
                let dot = Size.contextSnap.dot
                for snap in ContextStore.snapPoints {
                    let x = size.width * Double(snap) / 100
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - dot / 2, y: mid + Size.contextSnap.drop - dot / 2, width: dot, height: dot)),
                        with: .color(Theme.tertiary))
                }
                let end = Size.contextTrackEnd
                canvas.fill(
                    Path(CGRect(x: size.width - end.width, y: mid - end.height / 2, width: end.width, height: end.height)),
                    with: .color(Theme.tertiary))
            }
            guard point != nil || live else { return }
            let knob = live ? Size.contextNotch.intent : Size.contextNotch.rest
            let x = min(max(size.width * Double(point ?? 100) / 100, knob.width / 2), size.width - knob.width / 2)
            let body = CGRect(x: x - knob.width / 2, y: mid - knob.height / 2, width: knob.width, height: knob.height)
            let ring = Size.contextKnobRing
            canvas.fill(Path(roundedRect: body.insetBy(dx: -ring, dy: -ring), cornerRadius: knob.width / 2 + ring), with: .color(Theme.surface))
            canvas.fill(Path(roundedRect: body, cornerRadius: knob.width / 2), with: .color(point == nil ? Theme.tertiary : Theme.contextNotch))
        }
        .frame(height: Size.contextTrackRow)
        .contentShape(Rectangle())
        .disabled(context.compacting)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.value = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    if !chat.contextCard.dragging { chat.contextCard.drag(true) }
                    chat.setAutoCompact(Self.snap(drag.location.x, in: frame.value))
                }
                .onEnded { drag in
                    chat.contextCard.drag(false, endedInside: chat.contextCard.frames.contains { $0.contains(drag.location) })
                }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in step(-1) }
        .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in step(1) }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            chat.setAutoCompact(nil)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Auto-compact"))
        .accessibilityValue(Text(Self.spoken(context)))
        .accessibilityAdjustableAction { direction in
            _ = step(direction == .increment ? 1 : -1)
        }
    }

    /// The nearest snap point to `x`; nil (Off) at the end.
    static func snap(_ x: CGFloat, in frame: CGRect) -> Int? {
        guard frame.width > 0 else { return nil }
        let percent = Double((x - frame.minX) / frame.width) * 100
        let nearest = (ContextStore.snapPoints + [100]).min { abs(Double($0) - percent) < abs(Double($1) - percent) } ?? 100
        return nearest == 100 ? nil : nearest
    }

    /// One snap point along; past the last is Off.
    private func step(_ by: Int) -> KeyPress.Result {
        let points = ContextStore.snapPoints.map(Optional.some) + [nil]
        let at = points.firstIndex(of: chat.context.autoCompactAt) ?? points.count - 1
        chat.setAutoCompact(points[min(max(at + by, 0), points.count - 1)])
        return .handled
    }

    /// "80 percent, 774 thousand tokens", or "Off".
    private static func spoken(_ context: ContextStore) -> String {
        guard let point = context.autoCompactAt else { return "Off" }
        guard let window = context.usage?.window else { return "\(point) percent" }
        return "\(point) percent, \(window * point / 100 / 1000) thousand tokens"
    }
}
