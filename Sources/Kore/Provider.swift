import AppKit
import SwiftUI

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Permission modes as each VS Code extension's mode picker shows them (labels, icons,
    /// order), highlighted in Claude Code's mode colors; the first is the default.
    /// Codex's Plan mode is a separate toggle: `Provider.codexPlan`.
    var modes: [ModeOption] {
        switch self {
        case .claude:
            [
                ModeOption(id: "default", label: "Manual", icon: ModeIcons.manual, rung: nil),
                ModeOption(
                    id: "acceptEdits", label: "Edit automatically", icon: ModeIcons.editAutomatically,
                    rung: .edits),
                ModeOption(id: "plan", label: "Plan", icon: ModeIcons.plan, rung: .plan),
                ModeOption(id: "auto", label: "Auto", icon: ModeIcons.auto, rung: .auto),
                // Not offered, as in the extension (Bypass needs its allowDangerouslySkipPermissions
                // setting); kept so the label is right if the CLI reports them.
                ModeOption(
                    id: "bypassPermissions", label: "Bypass permissions", icon: ModeIcons.bypass,
                    rung: .danger, listed: false),
                ModeOption(id: "dontAsk", label: "Don't ask", icon: ModeIcons.manual, rung: .danger, listed: false),
            ]
        case .codex:
            [
                ModeOption(
                    id: "askForApproval", label: "Ask for approval", icon: ModeIcons.askForApproval, rung: nil,
                    iconSize: 15),
                ModeOption(
                    id: "approveForMe", label: "Approve for me", icon: ModeIcons.approveForMe, rung: .auto,
                    iconSize: 15),
                ModeOption(
                    id: "fullAccess", label: "Full access", icon: ModeIcons.fullAccess, rung: .danger,
                    iconSize: 15),
            ]
        }
    }

    static let codexPlan = ModeOption(
        id: "plan", label: "Plan", icon: ModeIcons.codexPlan, rung: .plan, iconSize: 14)

    @MainActor var logo: NSImage { Self.logos[self]! }

    @MainActor private static let logos: [Provider: NSImage] = [
        .claude: image(Logos.claude, template: false),
        // White glyph; as a template it takes the surrounding foreground color.
        .codex: image(Logos.codex, template: true),
    ]

    private static func image(_ svg: String, template: Bool) -> NSImage {
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = template
        return image
    }
}

struct ProviderLogo: View {
    let provider: Provider
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: provider.logo)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(Theme.text)
    }
}

/// A permission mode as its VS Code extension presents it.
struct ModeOption: Identifiable {
    /// The CLI's own mode name.
    let id: String
    let label: String
    /// SVG from `ModeIcons`.
    let icon: String
    /// The composer outline while this mode is on; nil for the neutral default.
    let rung: Rung?
    /// Shown in the mode menu.
    var listed = true
    /// Display size of the icon. Claude's SVGs center a small glyph in a 20pt box (the
    /// extension shows them at 20); Codex's fill their box (shown at 16).
    var iconSize: CGFloat = 20

    /// The mode's color (label, outline); nil for the neutral default.
    var tint: Color? { rung?.color }

    /// A step on the mode ladder, all in the theme's one hue: the outline gets brighter, more
    /// saturated, then thicker the less the agent asks before acting. Only the last step leaves
    /// the hue, for danger. The labels and icons still come from the VS Code extensions.
}

struct ModeIcon: View {
    let mode: ModeOption

    var body: some View {
        let size = mode.iconSize * Zoom.shared.scale
        Image(nsImage: ModeIcons.image(mode.icon))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
