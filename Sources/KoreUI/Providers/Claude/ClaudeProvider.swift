import Foundation
import KoreCore

extension ProviderDescriptor {
    static let claude = ProviderDescriptor(
        id: "claude", name: "Claude", logoSVG: Logos.claude, logoIsTemplate: false,
        modes: ClaudeModes.all, planToggle: nil, historyAgent: .claude,
        availableModes: { model in
            // Auto only where the model supports it.
            ClaudeModes.all.filter { $0.listed && ($0.id != "auto" || model?.supportsAutoMode != false) }
        },
        nextMode: { mode, _, available in
            // Manual → Edit automatically → Plan → Auto (if offered) → Manual.
            let auto = available.contains { $0.id == "auto" }
            let next =
                switch mode {
                case "default": "acceptEdits"
                case "acceptEdits": "plan"
                case "plan": auto ? "auto" : "default"
                default: "default"
                }
            return .mode(next)
        },
        makeBackend: { ClaudeBackend($0) },
        sessions: { folder in
            let hidden = ClaudeArchive.ids
            return ClaudeHistory.sessions(in: folder).map { session in
                var session = session
                session.archived = hidden.contains(session.id)
                return session
            }
        },
        setArchived: { id, archived, _ in ClaudeArchive.set(id, archived: archived) },
        historyFile: { id, folder in
            let file = ClaudeHistory.transcript(sessionId: id, in: folder)
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        },
        usage: UsageWording(product: "Claude Code", rows: ["Session (5hr)", "Weekly (7 day)"], resetsCaption: nil,
            // Opus 5.5 fast: $8/$40 per MTok against $4/$20; paid from usage credits, not the plan.
            fastCost: FastCost(times: "2×", detail: "Fast mode: 2× the price per token, paid from usage credits")),
        account: .claude)
}

/// Claude Code's permission modes as its VS Code extension's picker shows them (labels, icons,
/// order).
enum ClaudeModes {
    static let all: [ModeOption] = [
        ModeOption(id: "default", label: "Manual", icon: ModeIcons.manual, rung: nil),
        ModeOption(id: "acceptEdits", label: "Edit automatically", icon: ModeIcons.editAutomatically, rung: .edits),
        ModeOption(id: "plan", label: "Plan", icon: ModeIcons.plan, rung: .plan),
        ModeOption(id: "auto", label: "Auto", icon: ModeIcons.auto, rung: .auto),
        // Not offered, as in the extension (Bypass needs its allowDangerouslySkipPermissions
        // setting); kept so the label is right if the CLI reports them.
        ModeOption(id: "bypassPermissions", label: "Bypass permissions", icon: ModeIcons.bypass, rung: .danger, listed: false),
        ModeOption(id: "dontAsk", label: "Don't ask", icon: ModeIcons.manual, rung: .danger, listed: false),
    ]
}

/// Archived Claude sessions. The Claude CLI has no archive for local sessions (each of its
/// clients keeps a hidden list; the VS Code extension's is `hiddenSessionIds`), so this is Kore's.
enum ClaudeArchive {
    private static let key = "archivedClaudeSessions"

    static var ids: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    static func set(_ id: String, archived: Bool) {
        var ids = ids
        if archived { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.sorted(), forKey: key)
    }
}
