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
                ModeOption(id: "default", label: "Manual", icon: ModeIcons.manual, tint: nil),
                ModeOption(
                    id: "acceptEdits", label: "Edit automatically", icon: ModeIcons.editAutomatically,
                    tint: ModeOption.purple),
                ModeOption(id: "plan", label: "Plan", icon: ModeIcons.plan, tint: ModeOption.teal),
                ModeOption(id: "auto", label: "Auto", icon: ModeIcons.auto, tint: ModeOption.amber),
                // Not offered, as in the extension (Bypass needs its allowDangerouslySkipPermissions
                // setting); kept so the label is right if the CLI reports them.
                ModeOption(
                    id: "bypassPermissions", label: "Bypass permissions", icon: ModeIcons.bypass,
                    tint: ModeOption.red, listed: false),
                ModeOption(id: "dontAsk", label: "Don't ask", icon: ModeIcons.manual, tint: ModeOption.red, listed: false),
            ]
        case .codex:
            [
                ModeOption(
                    id: "askForApproval", label: "Ask for approval", icon: ModeIcons.askForApproval, tint: nil,
                    iconSize: 15),
                ModeOption(
                    id: "approveForMe", label: "Approve for me", icon: ModeIcons.approveForMe, tint: ModeOption.amber,
                    iconSize: 15),
                ModeOption(
                    id: "fullAccess", label: "Full access", icon: ModeIcons.fullAccess, tint: ModeOption.red,
                    iconSize: 15),
            ]
        }
    }

    static let codexPlan = ModeOption(
        id: "plan", label: "Plan", icon: ModeIcons.codexPlan, tint: ModeOption.teal, iconSize: 14)

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
    /// Highlight for the chat while this mode is on; nil for the neutral default.
    let tint: Color?
    /// Shown in the mode menu.
    var listed = true
    /// Display size of the icon. Claude's SVGs center a small glyph in a 20pt box (the
    /// extension shows them at 20); Codex's fill their box (shown at 16).
    var iconSize: CGFloat = 20

    // Claude Code's dark theme: planMode, autoAccept, warning, error.
    static let teal = Color(red: 72 / 255, green: 150 / 255, blue: 140 / 255)
    static let purple = Color(red: 175 / 255, green: 135 / 255, blue: 255 / 255)
    static let amber = Color(red: 255 / 255, green: 193 / 255, blue: 7 / 255)
    static let red = Color(red: 255 / 255, green: 107 / 255, blue: 128 / 255)
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
