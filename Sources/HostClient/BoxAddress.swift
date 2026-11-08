import Foundation

/// A box as it's listed: an alias from `~/.ssh/config` ("mybox"), or a destination typed as
/// `user@host[:port]`. A typed one is kept in Kore's own list, never written into the SSH config.
/// Only letters, digits and `._-` make a name, so nothing in it is an option or means anything to
/// a shell; ssh gets the host as one word after `--`, and the user and port as `-o` options.
package struct BoxAddress: Equatable, Hashable, Sendable {
    /// What's listed and shown: the alias, or the destination as typed (trimmed).
    package let name: String
    package let user: String?
    package let host: String
    package let port: Int?

    package init?(_ typed: String) {
        // A box rekeyed to its KoreNet id is still reached over SSH by the alias it was set up by.
        let resolved = NodeDirectory.isNodeKey(typed) ? NodeDirectory.shared.sshAlias(forKey: typed) : typed
        guard let resolved else { return nil }
        let text = resolved.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 255, !text.hasPrefix("-") else { return nil }
        var rest = Substring(text)
        var user: String?
        if let at = rest.firstIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var port: Int?
        if let colon = rest.firstIndex(of: ":") {
            let digits = rest[rest.index(after: colon)...]
            guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let number = Int(digits), (1...65535).contains(number)
            else { return nil }
            port = number
            rest = rest[..<colon]
        }
        guard Self.word(String(rest)), user.map(Self.word) ?? true else { return nil }
        name = text
        self.user = user
        host = String(rest)
        self.port = port
    }

    /// Whether `typed` is a box Kore can list.
    package static func valid(_ typed: String) -> Bool { BoxAddress(typed) != nil && typed == typed.trimmingCharacters(in: .whitespaces) }

    /// A host or user name: letters, digits, `.`, `_`, `-`, not starting with `-`.
    private static func word(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("-") && text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)
        }
    }

    /// Typed with a user or port, rather than an alias from the SSH config.
    package var typed: Bool { user != nil || port != nil }

    /// ssh's (and scp's) options for the user and port, before `--`.
    package var options: [String] {
        (user.map { ["-o", "User=\($0)"] } ?? []) + (port.map { ["-o", "Port=\($0)"] } ?? [])
    }

    /// The same in a command the user runs in Terminal: `ssh -p 2222 me@box`.
    package func command(_ program: String = "ssh") -> String {
        ([program] + (port.map { ["-p", "\($0)"] } ?? []) + [(user.map { $0 + "@" } ?? "") + host]).joined(separator: " ")
    }
}
