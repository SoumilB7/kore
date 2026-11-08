import Foundation

/// Which permission cards a phone approves only with its fingerprint (owner, phase 18 §11 answer
/// 1): running a shell command, writing a file outside the chat's folder, and network access.
/// Every other card is a plain tap; Deny is always free. Decided where the chat runs (Kore's link,
/// kore-host), for Claude's tools and Codex's approvals alike, from the tool's name and the paths
/// it writes (`Approval.tool`, `Approval.targets`): strings only, no file system reads.
package enum CardRisk: String, Codable, Sendable, CaseIterable {
    case shell, write, network

    /// Claude's tools that run a command.
    static let claudeShell: Set<String> = ["Bash"]
    /// Claude's tools that write the file they name.
    static let claudeWrite: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]
    /// Claude's tools that reach the network.
    static let claudeNetwork: Set<String> = ["WebFetch", "WebSearch"]

    /// Codex's approvals, as Kore names them (`Approval.tool`).
    package static let codexCommand = "commandExecution"
    package static let codexNetwork = "commandExecution.network"
    package static let codexFileChange = "fileChange"
    package static let codexPermissions = "permissions"

    /// A permission card's risk, or nil for a plain one. `targets`: the paths it writes, as the
    /// tool gave them (relative ones against `folder`).
    package static func classify(tool: String?, targets: [String], folder: String) -> CardRisk? {
        guard let tool else { return nil }
        if claudeShell.contains(tool) || tool == codexCommand { return .shell }
        if claudeNetwork.contains(tool) || tool == codexNetwork { return .network }
        // Codex's extra sandbox permissions are network access or wider file access.
        if tool == codexPermissions { return .network }
        if claudeWrite.contains(tool) || tool == codexFileChange {
            // A write that names no path can't be shown inside the folder.
            if targets.isEmpty { return .write }
            return targets.contains { outside($0, folder: folder) } ? .write : nil
        }
        return nil
    }

    /// Whether `path` lands outside `folder` once `..` and `.` are taken out (and `~` read as home).
    package static func outside(_ path: String, folder: String) -> Bool {
        let base = standard(folder)
        guard !base.isEmpty, base != "/" else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : base + "/" + expanded
        let target = standard(full)
        return !(target == base || target.hasPrefix(base + "/"))
    }

    private static func standard(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The answer a risky card's signature covers: the one that lets it go ahead. Deny, and every
    /// answer to a plan or questions card, stays a plain tap.
    package static func needsProof(_ action: CardAction.ID) -> Bool { action == .allow }
}
