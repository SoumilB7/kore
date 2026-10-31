import Foundation

/// A phone paired with this run of Kore. Nothing of it outlives the run.
package struct PhoneRecord: Sendable, Equatable {
    /// Short and stable for the run: from its watch key.
    package let id: String
    package var name: String
    package var model: String?
    /// X25519, the static key its links prove.
    package let watchKey: Data
    /// P-256, the key its step-ups and approvals are signed with.
    package let actKey: Data
    package let pskLink: Data
    /// The SHA-256 of the token it joins the relay with.
    package let relayToken: Data
    package let pairedAt: Date
    package var lastSeen: Date
    /// Until its first link, it's pending (and purged after 10 minutes).
    package var active: Bool
}

/// A pairing waiting for the owner to type the code the phone shows.
package struct PairPrompt: Sendable, Equatable {
    package let id: UUID
    /// What the phone says it is: shown as a claim, never as fact.
    package let claimedName: String
    package var triesLeft: Int
    package let deadline: Date
}
