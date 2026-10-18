import SwiftUI

/// The composer's context wheel (phase-10 look §9): a ring filling as the context does, a card
/// on hover with the numbers, and a click to compact. While compacting it turns. The slot is
/// kept once the chat has a session, so the bar never shifts; the ring shows from the first
/// usage report.
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
        .anchorPreference(key: ContextCardAnchor.self, value: .bounds) { cardShown.value ? $0 : nil }
        .accessibilityLabel(Text(ContextCard.summary(context)))
        .onAppear { if DevSnapshot.contextCard { cardShown.value = true } }
        .onDisappear { pending.value?.cancel() }
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

/// "Context window   62% · 124k / 200k", what's left, and what a click does.
private struct ContextCard: View {
    let chat: Chat

    var body: some View {
        let context = chat.context
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.md) {
                Text("Context window").font(Chrome.label).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Text(Self.numbers(context)).font(Chrome.labelDigits).foregroundStyle(Theme.text).lineLimit(1)
            }
            if let left = Self.left(context) {
                Text(left).font(Chrome.caption).foregroundStyle(Theme.contextArc(context.fraction ?? 0))
            }
            Text(action).font(Chrome.caption).foregroundStyle(Theme.tertiary)
        }
        .padding(Inset.row)
        .frame(width: Size.contextCard, alignment: .leading)
        .panel(.panel)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var action: String {
        if chat.context.compacting { return "Compacting…" }
        if chat.status.isRunning { return "Compact when this turn ends" }
        if chat.context.usage == nil { return "Usage appears after the first reply" }
        return "Click to compact now"
    }

    /// "62% · 124k / 200k"; "124k tokens" before the window is known; "—" before any report.
    static func numbers(_ context: ContextStore) -> String {
        guard let usage = context.usage else { return "—" }
        guard let window = usage.window, let fraction = context.fraction else {
            return ContextStore.tokens(usage.used) + " tokens"
        }
        return "\(ContextStore.percent(fraction)) · \(ContextStore.tokens(usage.used)) / \(ContextStore.tokens(window))"
    }

    /// "38% left until auto-compact" (just "left" when the CLI doesn't compact by itself), or
    /// "Compacted from 152k" right after a compaction.
    static func left(_ context: ContextStore) -> String? {
        if let from = context.compactedFrom { return "Compacted from " + ContextStore.tokens(from) }
        guard let fraction = context.fraction else { return nil }
        let left = ContextStore.percent(1 - fraction)
        return context.usage?.autoCompacts == false ? "\(left) left" : "\(left) left until auto-compact"
    }

    /// For VoiceOver: the card in one line.
    static func summary(_ context: ContextStore) -> String {
        if context.compacting { return "Compacting context" }
        return "Context window " + numbers(context)
    }
}
