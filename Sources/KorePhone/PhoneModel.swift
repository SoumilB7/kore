import Foundation
import KoreRemote
import Observation

/// What the Mac's Phone popup and title-row button show: the switch, Tailscale, the phones, a
/// pairing in progress, and what the phones did this run. Nothing of it is saved.
@MainActor
@Observable
package final class PhoneModel {
    /// The Mac's mailbox on the relay.
    package enum Relay: Equatable {
        /// No relay host set (`phone.relay`).
        case notSetUp
        case connecting
        case connected
        case offline(String)
        case off

        init(_ status: RelayHost.Status) {
            switch status {
            case .connecting: self = .connecting
            case .connected: self = .connected
            case .offline(let why): self = .offline(why)
            case .stopped: self = .off
            }
        }
    }

    package struct Row: Equatable, Identifiable {
        package let id: String
        package var name: String
        package var connected: Bool
        package var access: RemoteAccess
        package var lastSeen: Date
    }

    package struct Activity: Equatable, Identifiable {
        package let id = UUID()
        package let at: Date
        package let phone: String?
        package let text: String
    }

    package enum Pairing: Equatable {
        case none
        /// The QR is up: its text and when it stops working.
        case code(String, until: Date)
        /// A phone scanned it; the owner types the code it shows.
        case typing(PairPrompt, wrong: Bool)
        case failed(String)
    }

    package var isOn = false
    package var relay = Relay.off
    /// The "What the relay sees" table, open in the popup.
    package var showingRelay = false
    package var rows: [Row] = []
    package var pairing = Pairing.none
    package var activity: [Activity] = []
    /// The popup over a chat's composer: open in which chat, and which part.
    package var openIn: UUID?
    package var showingActivity = false

    /// The title-row button: lit while a phone has full access.
    package var anyFull: Bool { rows.contains { $0.connected && $0.access == .full } }
    package var anyConnected: Bool { rows.contains(where: \.connected) }

    package func note(_ text: String, phone: String? = nil) {
        activity.insert(Activity(at: Date(), phone: phone, text: text), at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
    }

    func reset() {
        isOn = false
        relay = .off
        rows = []
        pairing = .none
    }

    /// The one line the title-row button says on hover.
    package var line: String {
        if let full = rows.first(where: { $0.connected && $0.access == .full }) { return "\(full.name) · open, full access" }
        if let connected = rows.first(where: \.connected) { return "\(connected.name) · alerts only" }
        return switch relay {
        case .notSetUp: "Phone · the relay isn't set up"
        case .offline: "Phone · the relay can't be reached"
        default: "Phone · no phone connected"
        }
    }
}
