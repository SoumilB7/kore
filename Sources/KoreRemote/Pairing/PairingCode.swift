import Foundation

/// What the Mac's QR holds, as `KORE1.` + base64url: its static key, the one-time secret, the
/// relay's host and the mailbox. No URL scheme, no expiry (the Mac enforces 60 s).
package struct PairingCode: Sendable, Equatable {
    package var macKey: Data
    package var secret: Data
    package var relay: String
    package var mailbox: Data

    package init(macKey: Data, secret: Data, relay: String, mailbox: Data) {
        self.macKey = macKey
        self.secret = secret
        self.relay = relay
        self.mailbox = mailbox
    }

    package static let prefix = "KORE1."

    package var text: String {
        let host = Data(relay.utf8)
        var out = Data([0x4B, 0x52, KoreKeys.version, 0])
        out += macKey + secret
        out += Data([UInt8(host.count)]) + host
        out += mailbox
        return Self.prefix + out.base64URL
    }

    /// Strict: exact lengths, a plain host name, nothing trailing.
    package init?(text: String) {
        guard text.hasPrefix(Self.prefix), let data = Data(base64URL: String(text.dropFirst(Self.prefix.count))) else { return nil }
        let b = [UInt8](data)
        guard b.count > 4 + 32 + 32 + 1, b[0] == 0x4B, b[1] == 0x52, b[2] == KoreKeys.version, b[3] == 0 else { return nil }
        var i = 4
        macKey = Data(b[i..<(i + 32)])
        i += 32
        secret = Data(b[i..<(i + 32)])
        i += 32
        let n = Int(b[i])
        i += 1
        guard n > 0, n <= 253, b.count == i + n + 16 else { return nil }
        let host = String(decoding: b[i..<(i + n)], as: UTF8.self)
        guard Self.isHostName(host) else { return nil }
        relay = host
        i += n
        mailbox = Data(b[i..<(i + 16)])
    }

    /// Letters, digits, `-` and `.`, with an optional `:port`.
    package static func isHostName(_ host: String) -> Bool {
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty else { return false }
        if parts.count == 2, UInt16(parts[1]) == nil { return false }
        return parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }
}

extension Data {
    package var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    package init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "_", with: "/")
        guard !s.contains("=") else { return nil }
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
