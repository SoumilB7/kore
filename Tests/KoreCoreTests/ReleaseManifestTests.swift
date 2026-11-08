import CryptoKit
import Foundation
import Testing

@testable import KoreCore

@Suite("Release signature")
struct ReleaseManifestTests {
    let key = Curve25519.Signing.PrivateKey()
    var pub: String { key.publicKey.rawRepresentation.base64EncodedString() }
    let commit = String(repeating: "ab", count: 20)
    var manifest: ReleaseManifest {
        ReleaseManifest(version: "0.3.0", commit: commit, files: [
            "kore-host-linux-x86_64.xz": String(repeating: "1", count: 64), "kore-host.sh": String(repeating: "2", count: 64),
        ])
    }

    func signed(_ text: String) throws -> (Data, Data) {
        let data = Data(text.utf8)
        return (data, try key.signature(for: data))
    }

    @Test func aSignedManifestReadsBack() throws {
        let (sums, sig) = try signed(manifest.text)
        #expect(manifest.text.hasPrefix("# kore 0.3.0 \(commit)\n\(String(repeating: "1", count: 64))  kore-host-linux-x86_64.xz\n"))
        #expect(try ReleaseManifest.verified(sums: sums, signature: sig, key: pub) == manifest)
    }

    @Test func anyChangedByteIsRefused() throws {
        let (sums, sig) = try signed(manifest.text)
        let tamperedSum = manifest.text.replacingOccurrences(of: String(repeating: "1", count: 64), with: String(repeating: "3", count: 64))
        let tamperedVersion = manifest.text.replacingOccurrences(of: "# kore 0.3.0", with: "# kore 9.3.0")
        for text in [tamperedSum, tamperedVersion] {
            #expect(throws: ReleaseError.badSignature) { try ReleaseManifest.verified(sums: Data(text.utf8), signature: sig, key: pub) }
        }
        var flipped = sig
        flipped[5] ^= 1
        #expect(throws: ReleaseError.badSignature) { try ReleaseManifest.verified(sums: sums, signature: flipped, key: pub) }
        #expect(throws: ReleaseError.badSignature) { try ReleaseManifest.verified(sums: sums, signature: sig.prefix(63), key: pub) }
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(throws: ReleaseError.badSignature) { try ReleaseManifest.verified(sums: sums, signature: sig, key: other) }
    }

    @Test func thePlaceholderKeyVerifiesNothing() throws {
        let (sums, sig) = try signed(manifest.text)
        #expect(throws: ReleaseError.noKey) { try ReleaseManifest.verified(sums: sums, signature: sig, key: "PLACEHOLDER-x") }
        if KoreReleaseKey.base64.hasPrefix("PLACEHOLDER") { #expect(KoreReleaseKey.key == nil) }
    }

    @Test func onlyAStrictManifestParses() {
        let line = String(repeating: "a", count: 64) + "  kore.apk"
        for bad in [
            "", "kore 0.3.0 \(commit)\n", "# kore 0.3 x\n", "# kore v0.3.0 \(commit)\n",
            "# kore 0.3.0 \(commit)\n\(line)\n\(line)\n", "# kore 0.3.0 \(commit)\n\(line.uppercased())\n",
            "# kore 0.3.0 \(commit)\n" + String(repeating: "a", count: 64) + "  ../x\n",
            "# kore 0.3.0 \(commit)\n" + String(repeating: "a", count: 64) + " kore.apk\n",
        ] {
            #expect(throws: ReleaseError.self) { try ReleaseManifest.parse(bad) }
        }
        #expect((try? ReleaseManifest.parse("# kore 0.3.0 \(commit)\n\(line)\n"))?.files == ["kore.apk": String(repeating: "a", count: 64)])
    }

    @Test func aFileIsCheckedByItsHash() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try ReleaseManifest.sha256(file) == abc)
        let m = ReleaseManifest(version: "1", commit: commit, files: ["a": abc, "b": String(repeating: "0", count: 64)])
        try m.check(file, as: "a")
        #expect(throws: ReleaseError.mismatch("b")) { try m.check(file, as: "b") }
        #expect(throws: ReleaseError.missing("c")) { try m.check(file, as: "c") }
    }

    @Test func versionsCompareByNumber() {
        #expect(ReleaseManifest.newer("0.10.0", than: "0.9.3"))
        #expect(!ReleaseManifest.newer("0.2.3", than: "0.2.3.0"))
        #expect(!ReleaseManifest.newer("0.2.2", than: "0.2.10"))
    }
}
