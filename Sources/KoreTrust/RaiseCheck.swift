import Foundation
import Synchronization

/// Raising a chat's mode from a phone (phase 18 §1 "Raises"): the Run node hands out a 32-byte
/// nonce (`raise.chal`, 60 s, single use); the phone signs
/// `SHA256("kore-raise/1" | B | nonce | chatId | modeId)` with its biometric `kore_raise` key; the
/// node checks it against the phone's `raiseKey`. A nonce is spent by its first check, whatever
/// the outcome.
package final class RaiseCheck: Sendable {
    package static let label = "kore-raise/1"
    package static let nonceSize = 32
    package static let lifetime: TimeInterval = 60
    /// Outstanding nonces kept at most; the oldest goes first.
    package static let maxOutstanding = 16

    package enum Outcome: Equatable, Sendable {
        case ok
        case unknownNonce
        case expired
        case badSignature
    }

    private let clock: @Sendable () -> Date
    private let random: @Sendable (Int) -> Data
    private let issued = Mutex<[(nonce: Data, expires: Date)]>([])

    package init(clock: @escaping @Sendable () -> Date = { Date() }, random: @escaping @Sendable (Int) -> Data = { secureRandom($0) }) {
        self.clock = clock
        self.random = random
    }

    /// A fresh nonce, good for `lifetime` from now.
    package func challenge() -> Data {
        let nonce = random(Self.nonceSize)
        let now = clock()
        issued.withLock { list in
            list.removeAll { $0.expires <= now }
            if list.count >= Self.maxOutstanding { list.removeFirst(list.count - Self.maxOutstanding + 1) }
            list.append((nonce, now.addingTimeInterval(Self.lifetime)))
        }
        return nonce
    }

    /// The signed digest.
    package static func digest(binding: Data, nonce: Data, chatId: String, modeId: String) -> Data {
        var p = Prefixed()
        p.add(label)
        p.add(binding)
        p.add(nonce)
        p.add(chatId)
        p.add(modeId)
        return p.sha256
    }

    /// Spends `nonce` and checks `signature` (DER) by `raiseKey` (SPKI DER) over the digest.
    package func verify(signature: Data, raiseKey: Data, binding: Data, nonce: Data, chatId: String, modeId: String) -> Outcome {
        let now = clock()
        let expires: Date? = issued.withLock { list in
            guard let i = list.firstIndex(where: { $0.nonce == nonce }) else { return nil }
            return list.remove(at: i).expires
        }
        guard let expires else { return .unknownNonce }
        guard now < expires else { return .expired }
        let digest = Self.digest(binding: binding, nonce: nonce, chatId: chatId, modeId: modeId)
        return IdentityProof.verify(signature, over: digest, key: raiseKey) ? .ok : .badSignature
    }
}
