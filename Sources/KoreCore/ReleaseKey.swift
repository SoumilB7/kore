#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The owner's Ed25519 release key: its raw 32-byte public half, base64. Every release's
/// `SHA256SUMS` is signed with the private half (`scripts/sign/sign.swift`, from the owner's
/// Keychain) into `SHA256SUMS.sig`; Kore.app, kore-host and the install scripts check it with this.
/// scripts/kore-host.sh and install.sh carry the same string (a test keeps the three equal).
package enum KoreReleaseKey {
    // PLACEHOLDER until the owner runs `swift scripts/sign/sign.swift --new-key`: nothing verifies.
    package static let base64 = "PLACEHOLDER-run-scripts/sign/sign.swift--new-key"

    /// The key, or nil while it's still the placeholder.
    package static var key: Curve25519.Signing.PublicKey? { try? ReleaseManifest.publicKey(base64) }
}

/// A release's signed `SHA256SUMS`: one header line, `# kore <version> <commit>`, then
/// `<sha256>  <file>` per asset. The signature covers the whole file, header included, so the
/// version and commit are as signed as the hashes.
package struct ReleaseManifest: Equatable, Sendable {
    package var version: String
    package var commit: String
    /// File name → lowercase hex SHA-256.
    package var files: [String: String]

    package init(version: String, commit: String, files: [String: String]) {
        self.version = version
        self.commit = commit
        self.files = files
    }

    /// The file's bytes: the header, then the files sorted by name.
    package var text: String {
        (["# kore \(version) \(commit)"] + files.keys.sorted().map { "\(files[$0]!)  \($0)" }).joined(separator: "\n") + "\n"
    }

    /// `sums` checked against `signature` with `key` (base64, raw 32 bytes), then read.
    package static func verified(sums: Data, signature: Data, key: String = KoreReleaseKey.base64) throws -> ReleaseManifest {
        let publicKey = try publicKey(key)
        guard signature.count == 64, publicKey.isValidSignature(signature, for: sums) else { throw ReleaseError.badSignature }
        return try parse(String(decoding: sums, as: UTF8.self))
    }

    package static func publicKey(_ base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: base64), raw.count == 32 else { throw ReleaseError.noKey }
        return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// Reads the file. Strict: anything but the header and well-formed lines is refused.
    package static func parse(_ text: String) throws -> ReleaseManifest {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        guard let header = lines.first?.split(separator: " ", omittingEmptySubsequences: false),
              header.count == 4, header[0] == "#", header[1] == "kore", isVersion(header[2]), isHex(header[3], 40)
        else { throw ReleaseError.malformed("no `# kore <version> <commit>` header") }
        var files: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[1] == "", isHex(parts[0], 64), isName(parts[2]), files[String(parts[2])] == nil
            else { throw ReleaseError.malformed(String(line.prefix(80))) }
            files[String(parts[2])] = String(parts[0])
        }
        return ReleaseManifest(version: String(header[2]), commit: String(header[3]), files: files)
    }

    /// Checks `file`'s bytes against the entry for `name`.
    package func check(_ file: URL, as name: String) throws {
        guard let want = files[name] else { throw ReleaseError.missing(name) }
        guard try Self.sha256(file) == want else { throw ReleaseError.mismatch(name) }
    }

    /// A file's SHA-256, lowercase hex, read in 1 MiB pieces.
    package static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty { hash.update(data: piece) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "0.10.0" is newer than "0.9.3"; a missing part counts as 0.
    package static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func isHex(_ s: Substring, _ count: Int) -> Bool {
        s.utf8.count == count && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isVersion(_ s: Substring) -> Bool {
        !s.isEmpty && s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// A plain asset name: no folders, no spaces.
    static func isName(_ s: Substring) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && s.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }
}

package enum ReleaseError: Error, Equatable, CustomStringConvertible {
    /// The compiled-in key is still the placeholder (or isn't a key).
    case noKey
    case badSignature
    case malformed(String)
    case missing(String)
    case mismatch(String)
    /// The release's version, and this one's.
    case downgrade(String, String)
    case wrongBinary(String)

    package var description: String {
        switch self {
        case .noKey: "this build has no release key, so nothing can be verified"
        case .badSignature: "SHA256SUMS.sig doesn't match SHA256SUMS: not signed by Kore's release key"
        case .malformed(let line): "SHA256SUMS isn't a Kore manifest (\(line))"
        case .missing(let name): "SHA256SUMS doesn't list \(name)"
        case .mismatch(let name): "\(name) doesn't match its SHA-256 in SHA256SUMS"
        case .downgrade(let new, let now): "\(new) is older than this \(now): --force to install it anyway"
        case .wrongBinary(let said): "the new kore-host doesn't say the release's version (\(said))"
        }
    }
}
