import Foundation
import src

// KoreLink 1.14: a CLI login moved between the owner's devices (`account-move.html` §8), and the
// fingerprints that tell one sign-in held twice. Only the owner's Mac, proven over KoreNet with
// the run ability, may send these: the login travels sealed in that session, never in a log,
// never through the phone.
//
// - `account.import` (prepare | commit | abort, by `moveId`): prepare carries the credential
//   (`data`, base64), its `sha` and what the CLI shows of the account (`text`: Claude's minimal
//   `.claude.json`). The device writes it 0600 to a staging place nothing runs, checks the bytes
//   and that its CLI reads it signed in. Commit puts it in place as `login`; abort removes it.
// - `account.export` (prepare | commit | abort): prepare pauses the device's `login` (nothing
//   starts on it until commit or abort), checks nothing runs on it, and answers its bytes and
//   sha. Commit deletes it there; abort un-pauses it.
// - `account.fingerprints` (`key`, base64): each login's `LoginFingerprint` under that key.

/// A `account.*` move's answer (raw on the link, as `MoveResult` is).
package struct LoginMoveResult: Codable, Sendable, Equatable {
    package var t = "result"
    package var id: String
    package var ok: Bool
    package var code: ResultCode?
    package var message: String?
    /// `account.export` prepare: the credential (base64) and its sha.
    package var data: String?
    package var sha: String?
    /// `account.import` commit: the name the login was placed under.
    package var login: String?
    /// `account.fingerprints`: each login's.
    package var prints: [LoginPrint]?

    package init(
        id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, data: String? = nil, sha: String? = nil, login: String? = nil,
        prints: [LoginPrint]? = nil
    ) {
        (self.id, self.ok, self.code, self.message) = (id, ok, code, message)
        (self.data, self.sha, self.login, self.prints) = (data, sha, login, prints)
    }

    package static func refused(_ id: String, _ code: ResultCode, _ message: String) -> LoginMoveResult {
        LoginMoveResult(id: id, ok: false, code: code, message: message)
    }
}

/// One login's fingerprint on a device: which CLI, its name there ("main" or its folder's), who
/// it is, and the keyed fingerprint of its refresh token. Never the token.
package struct LoginPrint: Codable, Sendable, Equatable {
    package var cli: String
    package var login: String
    package var email: String?
    package var fingerprint: String

    package init(cli: String, login: String, email: String?, fingerprint: String) {
        (self.cli, self.login, self.email, self.fingerprint) = (cli, login, email, fingerprint)
    }
}

package enum LinkLogins {
    /// The cap a device that takes these says in its welcome.
    package static let cap = "loginMove"
    /// A credential's most bytes on the link (a Claude or Codex file is a few KB).
    package static let maxBytes = 64 * 1024
    /// The CLIs whose logins move.
    package static let clis: Set<String> = ["claude", "codex"]

    /// Why the link refuses one of these from a client other than the owner's Mac on KoreNet.
    package static let ownerOnly = "Only the owner's Mac moves a login, over KoreNet."

    /// A login's name on a box: its email's local part, made plain (letters, digits, `.`, `_`,
    /// `-`), "moved" when nothing is left; never "main".
    package static func name(forEmail email: String?) -> String {
        let local = (email ?? "").split(separator: "@").first.map(String.init) ?? ""
        let plain = local.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
        let trimmed = String(plain.trimmingCharacters(in: CharacterSet(charactersIn: ".-_")).prefix(40))
        return trimmed.isEmpty || trimmed == LinkAccount.main ? "moved" : trimmed
    }

    /// The policy for one of these (full grants only; `LinkClient` also requires the owner Mac).
    package static func check(_ kind: ControlKind, _ args: ControlArgs) -> LinkPolicy.Verdict {
        guard let cli = args.provider, clis.contains(cli) else { return .deny(.invalid, "Name the CLI.") }
        if kind == .accountFingerprints {
            guard let key = args.key.flatMap({ Data(base64Encoded: $0) }), key.count >= 32 else { return .deny(.invalid, "A key of 32 bytes or more.") }
            return .allow
        }
        guard let phase = args.phase.flatMap(MovePhase.init(rawValue:)), LinkMoves.plainMoveID(args.moveId) else {
            return .deny(.invalid, "Name the move and the phase.")
        }
        if let login = args.login, !LinkPolicy.plainID(login) { return .deny(.invalid, "That isn't a login's name.") }
        if let host = args.host, host.count > 100 || host.contains(where: \.isNewline) { return .deny(.invalid, "A name is one line.") }
        switch (kind, phase) {
        case (.accountImport, .prepare):
            guard let data = args.data, let bytes = Data(base64Encoded: data), !bytes.isEmpty, bytes.count <= maxBytes else {
                return .deny(.invalid, "The login's bytes, up to 64 KB.")
            }
            guard let sha = args.sha, sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return .deny(.invalid, "The login's sha256.") }
            if let text = args.text, text.utf8.count > maxBytes { return .deny(.invalid, "The account's file is too big.") }
            return .allow
        case (.accountExport, .prepare):
            return args.login == nil ? .deny(.invalid, "Name the login.") : .allow
        default:
            return .allow
        }
    }
}
