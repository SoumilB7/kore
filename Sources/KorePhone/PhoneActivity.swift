import Foundation
import KoreRemote

/// The Activity list's words: what a phone did, never what was said.
enum PhoneActivity {
    /// The gate's events, as the list says them.
    static let text = [
        "paired": "paired", "connected": "connected", "unlocked": "unlocked (fingerprint)", "removed": "removed",
        "pair-denied": "pairing refused", "step-up-refused": "unlock refused", "refused": "a connection was refused",
    ]

    /// A phone's command, by its kind and the chat's title.
    static func command(_ command: RemoteCommand, ok: Bool, title: String?) -> String {
        let what: String =
            switch command {
            case .send: "sent a message"
            case .stop: "stopped the turn"
            case .answer(_, _, let action, _, _): "answered: \(action.rawValue)"
            case .setMode(_, let mode): "set the mode to \(mode)"
            case .setPlan(_, let on): on ? "turned plan on" : "turned plan off"
            case .planReady(_, let choice): "plan: \(choice.rawValue)"
            case .new: "started a chat"
            }
        return (ok ? what : "refused: " + what) + (title.map { " · " + $0 } ?? "")
    }
}
