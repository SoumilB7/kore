import Foundation
import KoreCore

extension ProviderDescriptor {
    static let codex = ProviderDescriptor(
        id: "codex", name: "Codex", logoSVG: Logos.codex,
        // White glyph; as a template it takes the surrounding foreground colour.
        logoIsTemplate: true,
        modes: CodexModes.all, planToggle: CodexModes.plan, historyAgent: .codex,
        availableModes: { _ in CodexModes.all.filter(\.listed) },
        // Shift+Tab toggles Plan, as in the Codex CLI.
        nextMode: { _, _, _ in .togglePlan },
        makeBackend: { CodexBackend($0) },
        sessions: { folder in try? await CodexHistory.threads(in: folder) },
        setArchived: { id, archived, folder in
            if archived {
                try? await CodexHistory.archive(id, in: folder)
            } else {
                try? await CodexHistory.unarchive(id, in: folder)
            }
        },
        usage: UsageWording(
            product: "Codex", login: "codex login", rows: ["5h limit", "Weekly limit"], resetsCaption: "Reset your current usage limits"),
        account: .codex)
}

/// Codex's permission presets as its VS Code extension shows them, and its separate Plan toggle.
enum CodexModes {
    static let all: [ModeOption] = [
        ModeOption(id: "askForApproval", label: "Ask for approval", icon: ModeIcons.askForApproval, rung: nil, iconSize: 15),
        ModeOption(id: "approveForMe", label: "Approve for me", icon: ModeIcons.approveForMe, rung: .auto, iconSize: 15),
        ModeOption(id: "fullAccess", label: "Full access", icon: ModeIcons.fullAccess, rung: .danger, iconSize: 15),
    ]

    static let plan = ModeOption(id: "plan", label: "Plan", icon: ModeIcons.codexPlan, rung: .plan, iconSize: 14)
}
