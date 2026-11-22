import src
import SwiftUI

extension Theme {
    enum Arsenal {
        /// Tiers follow the mode ladder: deeper blue as a tier does more.
        static let watch = Blue.b200
        static let own = Blue.b400
        /// A tab's corner marks while its chat has Arsenal on, whatever the tier: which chats have it, at a glance.
        static let mark = Blue.b300

        static func color(_ tier: ArsenalTier) -> Color {
            switch tier {
            case .watch: watch
            case .own: own
            case .drive: mark
            case .device: Blue.b500
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

/// "Switch models when flagged", at the foot of a Claude chat's model picker: a Claude turn its
/// model's safeguards refuse goes again on the CLI's fallback model. A chat's CLI takes it when
/// it next starts.
struct RefusalSettings: View {
    var body: some View {
        let fallback = RefusalFallback.shared
        HStack(spacing: Space.md) {
            Text("Switch models when flagged").font(TextStyle.body).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: Space.xl)
            Toggle("", isOn: Binding(get: { fallback.on }, set: { fallback.on = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityLabel("Switch models when flagged")
                .storyID(StoryID.Composer.refusalSwitch, press: { fallback.on.toggle() })
        }
        .help("A turn the model's safeguards refuse goes on with an earlier model, as the CLI picks")
    }
}

/// A chat tab's corner marks while its chat has Arsenal on, at any tier: the option popups' frame
/// (`cornerMarks`) on the tab's own radius, in `Theme.Arsenal.mark`, each arm by its own edge so
/// they fit every tab width. Whole at once, as a state: no draw-in. The tier is read here, so
/// turning Arsenal on or off redraws these and nothing else of the tab. `story`: the tab's name;
/// its `.arsenal` part is there while drawn.
struct ArsenalCorners: View {
    let chat: Chat
    let story: StoryID

    /// The marks' colour at `tier`: Arsenal's one blue at any tier; nil (off) draws none.
    static func color(_ tier: ArsenalTier?) -> Color? { tier == nil ? nil : Theme.Arsenal.mark }

    var body: some View {
        if let color = Self.color(chat.arsenal) {
            Color.clear
                .cornerMarks(color, radius: Radius.control, fit: .eachSide, grows: false)
                .allowsHitTesting(false)
                .storyMark(story.part(.arsenal))
        }
    }
}
