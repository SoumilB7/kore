import Foundation
import KoreTrust

/// Raises from a phone (phase 18 §1 "Raises", §11 answer 1), the same on Kore's link and on
/// kore-host: a chat's mode (`modeId` a mode's id), an Arsenal tier (`arsenal.<tier>`), and a risky
/// card's approval (`approve.<cardDigest>`) each need the phone's biometric `kore_raise` signature
/// over a nonce this node handed out on the same session.
///
/// Wire (link bodies on stream 1):
/// - in  `{"t":"raise.chal","id":…,"chatId":…,"modeId":…}`
/// - out `{"t":"raise.chal","id":…,"nonce":"<base64, 32 bytes>"}` (or a refusing `result` keyed `raise.chal:<id>`)
/// - in  `{"t":"cmd","id":…,"cmd":{"type":"raise","chatId":…,"modeId":…,"nonce":…,"sig":…}}` → `result`
/// - in  `{"t":"cmd","id":…,"cmd":{"type":"chat.answer",…,"nonce":…,"sig":…}}`: a risky card's Allow
/// - in  `{"t":"raise.key","id":…,"pub":"<base64 SPKI DER>"}`: a new fingerprint key, taken only once
///   the owner Allows it on the Mac; one `result` keyed `raise.key:<id>` says how it went.
package enum LinkRaiseWire {
    package static let challenge = "raise.chal"
    package static let raise = "raise"
    package static let key = "raise.key"
    /// A risky card's approval signs this mode id.
    package static func approveMode(_ digest: String) -> String { "approve." + digest }
    package static let arsenalPrefix = "arsenal."

    package struct Challenge: Codable, Equatable, Sendable {
        package var t = LinkRaiseWire.challenge
        package var id: String
        package var chatId: String
        package var modeId: String

        package init(id: String, chatId: String, modeId: String) {
            self.id = id
            self.chatId = chatId
            self.modeId = modeId
        }
    }

    package struct ChallengeReply: Codable, Equatable, Sendable {
        package var t = LinkRaiseWire.challenge
        package var id: String
        package var nonce: String

        package init(id: String, nonce: Data) {
            self.id = id
            self.nonce = nonce.base64EncodedString()
        }
    }

    /// A raise's signed parts, as a `raise` command or a risky `chat.answer` carries them.
    package struct Signed: Equatable, Sendable {
        package var chatId: String
        package var modeId: String
        package var nonce: Data
        package var sig: Data
    }

    package struct Key: Codable, Equatable, Sendable {
        package var t = LinkRaiseWire.key
        package var id: String
        package var pub: String

        package init(id: String, pub: Data) {
            self.id = id
            self.pub = pub.base64EncodedString()
        }
    }

    package enum Incoming: Equatable, Sendable {
        case challenge(Challenge)
        /// The `raise` command, by its envelope's id.
        case raise(id: String, Signed)
        case key(id: String, pub: Data)
        /// A message of one of these types that doesn't parse: refused as invalid.
        case malformed(id: String, type: String)
    }

    /// The frames this file reads, before `LinkMessage` sees them; nil for every other one.
    package static func incoming(_ data: Data) -> Incoming? {
        // Most frames aren't these: a byte search before any parse.
        guard data.count <= 16 << 10, data.range(of: Data("\"raise".utf8)) != nil, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let t = object["t"] as? String else {
            return nil
        }
        let id = object["id"] as? String ?? ""
        switch t {
        case challenge:
            guard let chatId = object["chatId"] as? String, let modeId = object["modeId"] as? String, !id.isEmpty else {
                return .malformed(id: id, type: challenge)
            }
            return .challenge(Challenge(id: id, chatId: chatId, modeId: modeId))
        case key:
            guard !id.isEmpty, let text = object["pub"] as? String, let pub = Data(base64Encoded: text), !pub.isEmpty else {
                return .malformed(id: id, type: key)
            }
            return .key(id: id, pub: pub)
        case "cmd":
            guard let cmd = object["cmd"] as? [String: Any], cmd["type"] as? String == raise else { return nil }
            guard let signed = signed(cmd), !id.isEmpty else { return .malformed(id: id, type: raise) }
            return .raise(id: id, signed)
        default:
            return nil
        }
    }

    /// The signature a `chat.answer` carries for a risky card (`modeId` `approve.<digest>`), if any.
    package static func answerProof(_ data: Data) -> Signed? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["t"] as? String == "cmd",
              let cmd = object["cmd"] as? [String: Any], cmd["type"] as? String == "chat.answer",
              let digest = cmd["digest"] as? String, let chatId = cmd["chatId"] as? String,
              let nonceText = cmd["nonce"] as? String, let sigText = cmd["sig"] as? String,
              let nonce = Data(base64Encoded: nonceText), let sig = Data(base64Encoded: sigText)
        else { return nil }
        return Signed(chatId: chatId, modeId: approveMode(digest), nonce: nonce, sig: sig)
    }

    private static func signed(_ cmd: [String: Any]) -> Signed? {
        guard let chatId = cmd["chatId"] as? String, let modeId = cmd["modeId"] as? String, let nonceText = cmd["nonce"] as? String,
              let sigText = cmd["sig"] as? String, let nonce = Data(base64Encoded: nonceText), let sig = Data(base64Encoded: sigText)
        else { return nil }
        return Signed(chatId: chatId, modeId: modeId, nonce: nonce, sig: sig)
    }

    package static func encode(_ value: some Encodable) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(value)) ?? Data()
    }
}

/// One session's raises: the nonces it handed out (60 s, single use, `RaiseCheck`) and the check
/// of each signature against the device's `raiseKey` over the session's binding B. Kore's link and
/// kore-host each hold one per phone session.
package final class LinkRaiseGate: Sendable {
    package enum Verdict: Equatable, Sendable {
        case ok
        case refused(ResultCode, String)
    }

    private let check: RaiseCheck
    /// The session's binding digest B: what every raise on it signs over.
    package let binding: Data

    package init(binding: Data, clock: @escaping @Sendable () -> Date = { Date() }, random: @escaping @Sendable (Int) -> Data = { secureRandom($0) }) {
        self.binding = binding
        check = RaiseCheck(clock: clock, random: random)
    }

    /// A nonce for `raise.chal`, as its reply.
    package func challenge(_ ask: LinkRaiseWire.Challenge) -> Data {
        LinkRaiseWire.encode(LinkRaiseWire.ChallengeReply(id: ask.id, nonce: check.challenge()))
    }

    /// Spends the nonce and checks the signature by `raiseKey` (nil: the phone has none here, or
    /// its new one waits for the owner's Allow).
    package func verify(_ signed: LinkRaiseWire.Signed, raiseKey: Data?) -> Verdict {
        guard let raiseKey else {
            // Spent anyway: a nonce is never good twice.
            _ = check.verify(signature: signed.sig, raiseKey: Data(), binding: binding, nonce: signed.nonce, chatId: signed.chatId, modeId: signed.modeId)
            return .refused(.raiseMode, "This phone's fingerprint key isn't allowed here; Allow it on the Mac first.")
        }
        switch check.verify(signature: signed.sig, raiseKey: raiseKey, binding: binding, nonce: signed.nonce, chatId: signed.chatId, modeId: signed.modeId) {
        case .ok: return .ok
        case .unknownNonce: return .refused(.raiseMode, "That fingerprint check was used already; try again.")
        case .expired: return .refused(.raiseMode, "That fingerprint check took too long; try again.")
        case .badSignature: return .refused(.raiseMode, "The fingerprint didn't check out.")
        }
    }

    /// The raise's mode id as an Arsenal tier (`arsenal.<tier>`), if it is one.
    package static func arsenalTier(_ modeId: String) -> String? {
        modeId.hasPrefix(LinkRaiseWire.arsenalPrefix) ? String(modeId.dropFirst(LinkRaiseWire.arsenalPrefix.count)) : nil
    }
}
