import SwiftUI

/// The composer's context wheel (phase-10 look §9): a ring filling as the context does, a
/// one-line card on hover with the tokens, and a click to compact. Under the pointer the ring
/// takes the button hover fill and a compress glyph, so the click explains itself. While
/// compacting it turns. The slot is kept once the chat has a session, so the bar never shifts;
/// the ring and card show from the first usage report.
struct ContextWheel: View {
    let chat: Chat
    @StateObject private var hovered = Local(false)
    @StateObject private var cardShown = Local(false)
    @StateObject private var pending = Held<Task<Void, Never>?>(nil)

    var body: some View {
        let context = chat.context
        Button {
            chat.compact()
        } label: {
            ZStack {
                if context.compacting {
                    SpinningArc(lineWidth: Size.contextRingStroke)
                } else if context.usage != nil {
                    ContextRing(fraction: context.fraction ?? 0)
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
        .onHover(perform: hover)
        // The card is drawn by the chat (`contextCard`), over the composer box, which clips.
        .anchorPreference(key: ContextCardAnchor.self, value: .bounds) { cardShown.value && context.usage != nil ? $0 : nil }
        .accessibilityLabel(Text(Self.accessibility(context)))
        .onAppear {
            // The dev hook holds the hover state: card and glyph.
            if DevSnapshot.contextCard {
                cardShown.value = true
                hovered.value = true
            }
        }
        .onDisappear { pending.value?.cancel() }
    }

    /// "Context 62% used, 597k of 967k tokens. Compact."
    private static func accessibility(_ context: ContextStore) -> String {
        if context.compacting { return "Compacting context" }
        guard let usage = context.usage else { return "Context" }
        guard let window = usage.window, let fraction = context.fraction else {
            return "Context, \(ContextStore.tokens(usage.used)) tokens. Compact."
        }
        return "Context \(ContextStore.percent(fraction)) used, \(ContextStore.tokens(usage.used)) of \(ContextStore.tokens(window)) tokens. Compact."
    }

    /// The card after a short rest, gone at once on leaving.
    private func hover(_ inside: Bool) {
        hovered.value = inside
        if DevSnapshot.contextCard { return }
        pending.value?.cancel()
        guard inside else {
            cardShown.value = false
            return
        }
        pending.value = Task {
            try? await Task.sleep(for: .seconds(Motion.cardDelay))
            if !Task.isCancelled { cardShown.value = true }
        }
    }
}

/// The ring: a track and the used arc from 12 o'clock, clockwise.
private struct ContextRing: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.contextTrack, lineWidth: Size.contextRingStroke)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.contextArc(fraction), style: StrokeStyle(lineWidth: Size.contextRingStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(Size.contextRingStroke / 2)
        .animation(reduceMotion ? nil : Motion.contextArc, value: fraction)
    }
}

/// Where the wheel is while its card shows.
struct ContextCardAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

extension View {
    /// Shows the context wheel's card above the wheel, inside this view (the chat), so the
    /// composer's box doesn't clip it.
    func contextCard(_ chat: Chat) -> some View {
        overlayPreferenceValue(ContextCardAnchor.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let wheel = geometry[anchor]
                    // Its bottom-left corner just above the wheel's top-left.
                    ContextCard(chat: chat)
                        .padding(.leading, max(wheel.minX + Size.contextCardLead, 0))
                        .padding(.bottom, max(geometry.size.height - wheel.minY + Size.contextCardGap, 0))
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// "597k / 967k tokens": the card, one line (look §9, revised).
private struct ContextCard: View {
    let chat: Chat

    var body: some View {
        Text(Self.tokens(chat.context))
            .font(Chrome.labelDigits)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .fixedSize()
            .padding(Inset.row)
            .panel(.panel)
    }

    /// "597k / 967k tokens"; "182k tokens" before the CLI says its window.
    static func tokens(_ context: ContextStore) -> String {
        guard let usage = context.usage else { return "" }
        guard let window = usage.window else { return ContextStore.tokens(usage.used) + " tokens" }
        return "\(ContextStore.tokens(usage.used)) / \(ContextStore.tokens(window)) tokens"
    }
}
