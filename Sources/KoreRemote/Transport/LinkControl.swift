import Foundation

/// A link's own messages, apart from the sync layer's: pairing (`pair.*`) and access (`link.*`).
/// JSON with a `t`, as every APP record is.
package struct LinkControl: Codable, Sendable, Equatable {
    package var t: String
    package var name: String?
    package var model: String?
    package var key: String?
    package var sig: String?
    package var r: String?
    package var nonce: String?
    package var level: String?
    package var reason: String?
    package var tries: Int?
    package var screen: Bool?
    package var app: String?

    package init(_ t: String) { self.t = t }

    package static func isControl(_ type: String) -> Bool { type.hasPrefix("pair.") || type.hasPrefix("link.") }

    package var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    package static func decode(_ data: Data) -> LinkControl? { try? JSONDecoder().decode(LinkControl.self, from: data) }
}

/// The type of a JSON message, without decoding the rest.
package func messageType(_ data: Data) -> String? {
    struct Head: Decodable { let t: String }
    return (try? JSONDecoder().decode(Head.self, from: data))?.t
}

/// What a phone may see and do on its link right now.
package enum RemoteAccess: String, Sendable {
    /// Alerts only: the background connection.
    case watch
    /// Chats and actions, after a biometric step-up.
    case full
}

/// A phone's signature over one answer to one card, as it was shown.
package struct ApprovalProof: Sendable, Equatable {
    package var cardId: String
    package var digest: String
    package var action: String
    package var sig: String

    package init(cardId: String, digest: String, action: String, sig: String) {
        self.cardId = cardId
        self.digest = digest
        self.action = action
        self.sig = sig
    }
}
