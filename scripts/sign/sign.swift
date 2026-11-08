// Kore's release signature: Ed25519 over SHA256SUMS, written raw (64 bytes) to SHA256SUMS.sig,
// the form `openssl pkeyutl -verify -rawin` and KoreCore's ReleaseManifest both read. The private
// key lives only in the login Keychain (generic password `kore-release-ed25519`, its raw 32 bytes
// as base64): never in the repo, a file, an argument or a log.
//
//   swift scripts/sign/sign.swift sign <SHA256SUMS> [--expect <public key>]   Keychain key
//   swift scripts/sign/sign.swift sign --ephemeral <SHA256SUMS>              throwaway key (tests, dry runs); prints its public key
//   swift scripts/sign/sign.swift verify <file> <file.sig> <public key>
//   swift scripts/sign/sign.swift pubkey                                     the Keychain key's public half
//   swift scripts/sign/sign.swift --new-key                                  the owner, once
//   swift scripts/sign/sign.swift --restore                                  the key back from a backup, base64 on stdin
import CryptoKit
import Foundation
import Security

let service = "kore-release-ed25519"
let account = "kore-release"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("sign: " + message + "\n").utf8))
    exit(1)
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    return data
}

func keychainKey() -> Curve25519.Signing.PrivateKey {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
        fail(status == errSecItemNotFound ? "no \(service) in the Keychain (--new-key, or --restore from the backup)" : "Keychain: error \(status)")
    }
    guard let raw = Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("\(service) in the Keychain isn't an Ed25519 key") }
    return key
}

func store(_ key: Curve25519.Signing.PrivateKey) {
    let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        kSecAttrLabel as String: service, kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8),
    ]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail(status == errSecDuplicateItem ? "\(service) is in the Keychain already" : "Keychain: error \(status)") }
}

func publicKey(_ base64: String) -> Curve25519.Signing.PublicKey {
    guard let raw = Data(base64Encoded: base64), raw.count == 32, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("not an Ed25519 public key (base64 of 32 bytes): \(base64)")
    }
    return key
}

var args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "sign":
    args.removeFirst()
    let ephemeral = args.contains("--ephemeral")
    args.removeAll { $0 == "--ephemeral" }
    var expect: String?
    if let at = args.firstIndex(of: "--expect"), at + 1 < args.count {
        expect = args[at + 1]
        args.removeSubrange(at...(at + 1))
    }
    guard args.count == 1 else { fail("sign [--ephemeral] <file> [--expect <public key>]") }
    let key = ephemeral ? Curve25519.Signing.PrivateKey() : keychainKey()
    let mine = key.publicKey.rawRepresentation.base64EncodedString()
    if let expect, expect != mine { fail("the key here (\(mine)) isn't KoreReleaseKey (\(expect)): nothing would verify") }
    let data = read(args[0])
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("the signature didn't verify") }
    guard FileManager.default.createFile(atPath: args[0] + ".sig", contents: signature) else { fail("can't write \(args[0]).sig") }
    if ephemeral { print(mine) } else { FileHandle.standardError.write(Data("signed \(args[0]).sig with \(mine)\n".utf8)) }
case "verify":
    guard args.count == 4 else { fail("verify <file> <file.sig> <public key>") }
    guard publicKey(args[3]).isValidSignature(read(args[2]), for: read(args[1])) else { fail("\(args[2]) doesn't verify \(args[1])") }
    print("verified \(args[1])")
case "pubkey":
    print(keychainKey().publicKey.rawRepresentation.base64EncodedString())
case "--new-key":
    let key = Curve25519.Signing.PrivateKey()
    store(key)
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    print("""
        Kore's release key is in your login Keychain (\(service)). Its public key:

            \(pub)

        1. Put that string in place of the placeholder in Sources/KoreCore/ReleaseKey.swift
           (KoreReleaseKey.base64), scripts/kore-host.sh and install.sh (KORE_RELEASE_KEY), and commit.
        2. Back the private key up offline, encrypted, before the first release. It goes from the
           Keychain straight into the encrypted file, never onto disk in the clear:
               security find-generic-password -s \(service) -w | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -out kore-release-ed25519.enc
           Keep kore-release-ed25519.enc on a drive you keep offline, and its passphrase apart from it.
           Restore on a new Mac:
               openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in kore-release-ed25519.enc | swift scripts/sign/sign.swift --restore
        """)
case "--restore":
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("stdin isn't the backed-up key") }
    store(key)
    print("restored \(service): \(key.publicKey.rawRepresentation.base64EncodedString())")
default:
    fail("sign <file> | sign --ephemeral <file> | verify <file> <sig> <public key> | pubkey | --new-key | --restore")
}
