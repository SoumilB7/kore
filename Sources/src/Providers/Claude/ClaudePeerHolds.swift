import Foundation
import KoreCore

/// Cross-session messages the CLI held (`system/peer_message_hold`, z-docs/design/cli-wiring.md):
/// one card for the chat while any is held, saying from whom and why in a line. The CLI takes no
/// answer for one message; its `crossSessionInbound` flag setting acts on all held at once. So
/// Allow sets `accept`, and Deny `refuse`, for as short a window as can be: cleared (`null`) as
/// soon as every message on the card has gone through, and after `cap` at most. A message that
/// slips through the window without being on the card gets a line of its own, so none goes by
/// unseen. Messages that end without the model seeing them (the CLI restarted, the hold buffer
/// full) get a line too.
@MainActor
package final class ClaudePeerHolds {
    package static let cardID = "peer-hold"
    /// The longest the policy stays open after an answer.
    package static let cap: TimeInterval = 2

    package struct Held: Equatable, Sendable {
        package let uuid: String
        package let from: String
        package let name: String?
        package let cause: String
    }

    /// What the card says, and whether Allow can work at all.
    package struct Card: Equatable, Sendable {
        package let title: String
        package let senders: [Approval.HeldSender]
        /// The hold comes from a setting a flag can't override (managed, repo, invalid): only Deny.
        package let refuseOnly: Bool
        package let allowNote: String?
    }

    package enum Action: Equatable, Sendable {
        /// `crossSessionInbound` as a flag setting: `accept`, `refuse`, or nil to clear it.
        case policy(String?)
        /// The card as it is now; nil: none.
        case card(Card?)
        case notice(String)
    }

    package private(set) var held: [Held] = []
    /// The answer's window: what it lets in or refuses, the messages on the card then, and when
    /// it closes at the latest.
    private var window: (accept: Bool, uuids: Set<String>, by: String?, closes: Date)?
    package var now: () -> Date = Date.init
    /// This chat runs in Bypass permissions: a mode mismatch is then on this side.
    package var bypass = false
    private var shown: Card?

    package init() {}

    package var open: Bool { window != nil }

    // MARK: Frames

    package func frame(_ hold: PeerHold) -> [Action] {
        var out: [Action] = []
        switch hold.state {
        case .held:
            if !held.contains(where: { $0.uuid == hold.uuid }) {
                held.append(Held(uuid: hold.uuid, from: hold.from, name: hold.name, cause: hold.cause ?? "mode-unknown"))
            }
        case .released:
            let message = take(hold)
            if let window {
                if window.accept, !window.uuids.contains(hold.uuid) {
                    out.append(.notice("Also let in: a message from \(Self.who(message?.name ?? hold.name))"))
                }
                self.window?.uuids.remove(hold.uuid)
            }
        case .dropped:
            let message = take(hold)
            let from = Self.who(message?.name ?? hold.name)
            if let window, !window.accept {
                if !window.uuids.contains(hold.uuid) { out.append(.notice("Also refused: a message from \(from)")) }
                self.window?.uuids.remove(hold.uuid)
            } else if message != nil || hold.outcome != "refused" {
                out.append(.notice("A message from \(from) wasn't delivered: " + Self.why(hold.outcome)))
            }
        }
        if let window, window.uuids.isEmpty { out += close() }
        out += refresh()
        return out
    }

    private func take(_ hold: PeerHold) -> Held? {
        guard let index = held.firstIndex(where: { $0.uuid == hold.uuid }) else { return nil }
        return held.remove(at: index)
    }

    // MARK: Answers

    /// The card answered: Allow opens `accept` for the messages on it, Deny `refuse`. `by`: the
    /// chat that let them in, when not the user. Nothing when there's no card, or one already open.
    package func answer(allow: Bool, by: String? = nil) -> [Action] {
        guard window == nil, !held.isEmpty, !(allow && shown?.refuseOnly == true) else {
            // Nothing done: the card comes back as it was.
            shown = nil
            return refresh()
        }
        window = (allow, Set(held.map(\.uuid)), by, now().addingTimeInterval(Self.cap))
        var out: [Action] = [.policy(allow ? "accept" : "refuse")]
        if allow {
            let names = Self.list(held.map(\.name))
            out.append(.notice(by.map { "Let in by \($0): \(names)" } ?? "Let in: \(names)"))
        }
        return out + refresh()
    }

    /// The window's cap reached: the flag goes whatever is still on its way.
    package func tick() -> [Action] {
        guard let window, now() >= window.closes else { return [] }
        return close() + refresh()
    }

    private func close() -> [Action] {
        window = nil
        return [.policy(nil)]
    }

    /// The CLI's process ended: what it held ended with it.
    package func exited() -> [Action] {
        let lost = held
        held = []
        window = nil
        return lost.map { .notice("A message from \(Self.who($0.name)) wasn't delivered: " + Self.why("discarded")) } + refresh()
    }

    // MARK: The card

    private func refresh() -> [Action] {
        let card = held.isEmpty || window != nil ? nil : card()
        guard card != shown else { return [] }
        shown = card
        return [.card(card)]
    }

    private func card() -> Card {
        let causes = Set(held.map(\.cause))
        let refuseOnly = !causes.isDisjoint(with: ["managed-setting", "repo-setting", "invalid-setting"])
        let what = held.count == 1 ? "A message from \(Self.who(held[0].name))" : "\(held.count) messages from \(Self.list(held.map(\.name)))"
        let title = "\(what) is held: " + Self.reason(held.first?.cause ?? "", bypass: bypass)
        let note = refuseOnly ? "A setting Kore can't change holds it: only Deny works here." : nil
        return Card(
            title: title, senders: held.map { Approval.HeldSender(from: $0.from, name: $0.name) }, refuseOnly: refuseOnly, allowNote: note)
    }

    /// The sender's name, in quotes: it's what the sender says it is.
    static func who(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "another session" }
        return "“\(name)”"
    }

    static func list(_ names: [String?]) -> String {
        var seen: [String] = []
        for name in names.map(who) where !seen.contains(name) { seen.append(name) }
        return seen.joined(separator: ", ")
    }

    /// Why it's held, in a few words.
    static func reason(_ cause: String, bypass: Bool) -> String {
        switch cause {
        case "mode-mismatch": bypass ? "this chat bypasses permissions and it doesn't" : "it bypasses permissions and this chat doesn't"
        case "no-mode-asserted": "it didn't say its permission mode"
        case "explicit-setting": "your crossSessionInbound setting holds messages"
        case "managed-setting": "your organization's settings hold messages"
        case "repo-setting": "this repo's settings hold messages"
        case "invalid-setting": "a settings file has an invalid crossSessionInbound"
        default: "Claude hasn't seen it yet"
        }
    }

    static func why(_ outcome: String?) -> String {
        switch outcome {
        case "expired": "it ran out of time while held"
        case "discarded": "this chat's CLI restarted while it was held"
        case "refused": "this chat refuses messages now"
        case "dropped": "Claude's inbox was full"
        default: "it was dropped"
        }
    }
}
