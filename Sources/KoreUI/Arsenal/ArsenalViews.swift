import SwiftUI

extension Theme {
    enum Arsenal {
        /// Tiers follow the mode ladder.
        static let watch = Blue.b200
        /// The K's stem behind its arms.
        static let stem = 0.5
    }
}

extension Size {
    enum Arsenal {
        static let width: CGFloat = 9
        static let height: CGFloat = 12
        static let button: CGFloat = 20
    }
}

/// The K alone, in one colour with its stem fainter. Paths and no image, so a colour change can fade.
struct ArsenalMark: View {
    let color: Color

    var body: some View {
        ZStack {
            SizedPath(Self.stem).fill(color.opacity(Theme.Arsenal.stem))
            SizedPath(Self.arms).fill(color)
        }
        .frame(width: Size.Arsenal.width, height: Size.Arsenal.height)
        .accessibilityHidden(true)
    }

    // The K's own 148 × 204 box.
    private static func point(_ x: CGFloat, _ y: CGFloat, _ size: CGSize) -> CGPoint {
        CGPoint(x: (x - 78) / 148 * size.width, y: (y - 26) / 204 * size.height)
    }

    private static let stem: @Sendable (CGSize) -> Path = { size in
        let origin = point(112, 30, size)
        let end = point(144, 226, size)
        let rect = CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
        return Path(roundedRect: rect, cornerRadius: rect.width / 4)
    }

    private static let arms: @Sendable (CGSize) -> Path = { size in
        var path = Path()
        path.addLines([point(84, 147.96, size), point(220, 33.72, size), point(220, 67.72, size), point(84, 181.96, size)])
        path.closeSubpath()
        path.addLines([point(84, 74.04, size), point(220, 188.28, size), point(220, 222.28, size), point(84, 108.04, size)])
        path.closeSubpath()
        return path
    }
}

/// The K on a chat's tab. Off, it shows only while the tab is hovered; on, always, in the tier's
/// colour, with the tier's name and its chevron under the pointer. It reads the switch and the
/// chat's tier here, so a change redraws this and no more of the bar.
struct ArsenalTabControl: View {
    let chat: Chat
    let tab: UUID
    let hoveredTab: Bool
    /// The tab has room for the tier's name; otherwise its chevron alone.
    let showsName: Bool
    @StateObject private var hovered = Local(false)
    /// Just turned on: no × until the pointer has left, so a second click isn't invited.
    @StateObject private var fresh = Local(false)

    private var tabHovered: Bool { hoveredTab || Arsenal.shared.storyHover }

    var body: some View {
        if Arsenal.shared.allowed, chat.arsenal != nil || tabHovered {
            HStack(spacing: 0) {
                // The name grows to the left, so the K stays under the pointer: a second click turns it
                // off, and doesn't land on what appeared.
                if let tier = chat.arsenal, tabHovered { word(tier) }
                if chat.arsenal == nil, let reason = Arsenal.unavailable(chat) {
                    unavailable(reason)
                } else {
                    button
                }
            }
        }
    }

    private var button: some View {
        let on = chat.arsenal != nil
        return Button {
            fresh.value = !on
            Arsenal.shared.toggle(chat)
        } label: {
            Group {
                if on, hovered.value, !fresh.value {
                    Image(systemName: "xmark.circle.fill").font(TextStyle.label).foregroundStyle(Theme.Arsenal.watch)
                } else {
                    ArsenalMark(color: on ? Theme.Arsenal.watch : Theme.secondary)
                }
            }
            .frame(width: Size.Arsenal.button, height: Size.Arsenal.button)
            .contentShape(Rectangle())
            // Fades on; off is instant.
            .animation(on ? Motion.fade : nil, value: on)
        }
        .buttonStyle(.plain)
        .onHover {
            hovered.value = $0
            if !$0 { fresh.value = false }
        }
        .help(on ? "Turn off Arsenal" : "Turn on Arsenal · \(chat.arsenalLast.title)")
        .accessibilityLabel("Arsenal")
        .storyID(StoryID.Tabs.arsenal(tab))
    }

    /// Dim, and a click says why.
    private func unavailable(_ reason: String) -> some View {
        OptionMenuButton(source: "arsenal", items: { [OptionItem(reason, enabled: false)] }, chevron: false) {
            ArsenalMark(color: Theme.tertiary)
                .frame(width: Size.Arsenal.button, height: Size.Arsenal.button)
                .contentShape(Rectangle())
        }
        .help(reason)
        .accessibilityLabel("Arsenal unavailable")
        .storyID(StoryID.Tabs.arsenalUnavailable(tab))
    }

    private func word(_ tier: ArsenalTier) -> some View {
        OptionMenuButton(source: "arsenal", items: { Arsenal.shared.tierItems(chat) }) {
            if showsName {
                Text(tier.title).font(Chrome.label).foregroundStyle(Theme.Arsenal.watch).lineLimit(1).fixedSize()
            }
        }
        .help("\(tier.title) · reads chats, can't change anything")
        .accessibilityLabel("Arsenal tiers")
        .storyID(StoryID.Tabs.arsenalTiers(tab))
    }
}

/// A tab too narrow for the control: the K, while on.
struct ArsenalOnBadge: View {
    let chat: Chat

    var body: some View {
        if chat.arsenal != nil { ArsenalMark(color: Theme.Arsenal.watch).allowsHitTesting(false) }
    }
}

/// "Let chats use Arsenal", and Stop agent control while a chat has it on. Kore has no Settings
/// window: this sits in the Account popup, which ⌘, opens.
struct ArsenalSettings: View {
    var body: some View {
        let arsenal = Arsenal.shared
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.md) {
                Text("Let chats use Arsenal").font(TextStyle.body).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: Space.xl)
                Toggle("", isOn: Binding(get: { arsenal.allowed }, set: { arsenal.setAllowed($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .tint(Theme.accent)
                    .accessibilityLabel("Let chats use Arsenal")
                    .storyID(StoryID.Composer.arsenalSwitch, press: { arsenal.setAllowed(!arsenal.allowed) })
            }
            .help("Off: no chat can have it, and any that do go off at once")
            if arsenal.anyOn {
                Button("Stop agent control") { arsenal.stopAll() }
                    .smallButton(danger: true)
                    .storyID(StoryID.Composer.arsenalStop)
            }
        }
    }
}
