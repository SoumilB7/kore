import SwiftUI

extension Theme {
    enum Arsenal {
        /// Tiers follow the mode ladder: deeper blue as a tier does more.
        static let watch = Blue.b200
        static let own = Blue.b400

        static func color(_ tier: ArsenalTier) -> Color {
            switch tier {
            case .watch: watch
            case .own: own
            case .drive: Blue.b300
            case .full: Theme.warning
            }
        }
    }
}

/// Arsenal in the window's top row, beside the cup and the clock, for the chat in front: there only
/// while it has Arsenal on, in its tier's colour. A click opens the tiers, Off and Stop agent
/// control; the tab's right-click or ⌥⌘K turns it on. It reads the chat's tier here, so a change
/// redraws this and no more of the row.
struct ArsenalTitlebarButton: View {
    let chat: Chat
    let size: CGFloat
    @StateObject private var hovered = Local(false)

    /// A charge in a ring: power handed to this chat. Line art, as the cup and the clock are.
    static let symbol = "bolt.horizontal.circle"

    var body: some View {
        if let tier = chat.arsenal {
            OptionMenuButton(source: "arsenal", items: { Arsenal.shared.tierItems(chat) }, chevron: false) {
                Image(systemName: Self.symbol)
                    .font(Chrome.bodyMedium)
                    .foregroundStyle(Theme.Arsenal.color(tier))
                    .frame(width: size, height: size)
                    .background(hovered.value ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.control))
            }
            .onHover { hovered.value = $0 }
            .help("Arsenal · \(tier.title)")
            .accessibilityLabel("Arsenal")
            .accessibilityValue(tier.title)
            .storyID(StoryID.Titlebar.arsenal)
            // Fades on; off is instant.
            .transition(.asymmetric(insertion: .opacity.animation(Motion.fade), removal: .identity))
        }
    }
}

/// "Let chats use Arsenal", and Stop agent control while a chat has it on, in the Account popup
/// (⌘,): where everything turns off. The tab's right-click or ⌥⌘K turns the switch on with a chat.
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
