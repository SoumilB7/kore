import Foundation

/// A chat's Arsenal tier (`z-docs/design/kore-access.html`). Each adds to the one before; Full has no
/// commands behind it yet, so the popup leaves it out. The raw values are the wire and defaults ids
/// (`watch`, `own`, `drive`, `device`); `title` is what the user and the agent read. Act device
/// (the owner, 2026-11-20) is Act unlimited and files fetched from another device.
package enum ArsenalTier: String, CaseIterable, Sendable {
    case watch, own, drive, device, full

    package var title: String {
        switch self {
        case .watch: "Read"
        case .own: "Act limited"
        case .drive: "Act unlimited"
        case .device: "Act device"
        case .full: "Full"
        }
    }
    package var built: Bool { self != .full }

    /// What it lets the chat's agent do, in a line.
    package var reach: String {
        switch self {
        case .watch: "reads this folder's chats"
        case .own: "also sets this chat's name, model, effort, and lowers its mode"
        case .drive: "also opens chats, sends and answers questions, in chats at its mode or lower"
        case .device: "also fetches files across your devices"
        case .full: "not built yet"
        }
    }
}
