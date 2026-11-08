import CryptoKit
import Foundation
import Testing

@testable import KoreCore
@testable import KoreHost

/// `kore-host update` and `verify` over a release folder made here, signed with a throwaway key.
/// The "binary" is a script that says its version; "unpacking" copies it.
@Suite("kore-host update")
struct HostUpdateTests {
    let key = Curve25519.Signing.PrivateKey()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kh-update-\(UUID().uuidString)")
    var release: URL { root.appendingPathComponent("release") }
    var target: URL { root.appendingPathComponent("bin/kore-host") }
    let asset = "kore-host-linux-x86_64.xz"

    init() throws {
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.binary(says: "0.2.3").write(to: target)
    }

    static func binary(says version: String) -> Data { Data("#!/bin/sh\necho 'kore-host \(version) (link 1.12)'\n".utf8) }

    /// A release of `version` whose binary says `says`; `edit` changes SHA256SUMS after signing.
    @discardableResult
    func publish(_ version: String, says: String? = nil, edit: ((String) -> String)? = nil) throws -> URL {
        let file = release.appendingPathComponent(asset)
        try Self.binary(says: says ?? version).write(to: file)
        try Data("#!/bin/sh\n".utf8).write(to: release.appendingPathComponent("kore-host.sh"))
        var files: [String: String] = [:]
        for name in [asset, "kore-host.sh"] { files[name] = try ReleaseManifest.sha256(release.appendingPathComponent(name)) }
        let text = ReleaseManifest(version: version, commit: String(repeating: "c", count: 40), files: files).text
        try key.signature(for: Data(text.utf8)).write(to: release.appendingPathComponent("SHA256SUMS.sig"))
        try Data((edit?(text) ?? text).utf8).write(to: release.appendingPathComponent("SHA256SUMS"))
        return file
    }

    var updater: HostUpdate {
        var u = HostUpdate(target: target)
        u.current = "0.2.3"
        u.platform = "linux-x86_64"
        u.key = key.publicKey.rawRepresentation.base64EncodedString()
        u.unpack = { from, to in try FileManager.default.copyItem(at: from, to: to) }
        return u
    }

    func installed() throws -> String { String(decoding: try Data(contentsOf: target), as: UTF8.self) }
    /// Only the binary is in its folder: nothing staged is left behind.
    func onlyTheBinary() throws -> Bool { try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["kore-host"] }

    @Test func aNewerSignedReleaseIsSwappedIn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try publish("0.3.0")
        #expect(try updater.apply(file, force: false) == .updated(from: "0.2.3", to: "0.3.0"))
        #expect(try installed().contains("kore-host 0.3.0 "))
        #expect(try onlyTheBinary())
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func anOlderOneNeedsForce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try publish("0.2.1")
        #expect(throws: ReleaseError.downgrade("0.2.1", "0.2.3")) { try updater.apply(file, force: false) }
        #expect(try installed().contains("kore-host 0.2.3 "))
        #expect(try updater.apply(file, force: true) == .updated(from: "0.2.3", to: "0.2.1"))
        #expect(try installed().contains("kore-host 0.2.1 "))
    }

    @Test func theSameVersionChangesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try publish("0.2.3")
        try Data("other".utf8).write(to: target)
        #expect(try updater.apply(file, force: false) == .same("0.2.3"))
        #expect(try installed() == "other")
    }

    /// Each failure leaves the old binary as it was, and nothing staged beside it.
    @Test func everyFailureKeepsTheOldBinary() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try installed()
        func refused(_ expected: some Error & Equatable, _ make: () throws -> URL, updater u: HostUpdate? = nil) throws {
            let file = try make()
            #expect(throws: expected) { try (u ?? updater).apply(file, force: true) }
            #expect(try installed() == old)
            #expect(try onlyTheBinary())
        }
        // The version line edited after signing.
        try refused(ReleaseError.badSignature, { try publish("0.3.0") { $0.replacingOccurrences(of: "# kore 0.3.0", with: "# kore 0.4.0") } })
        // A hash edited after signing.
        try refused(ReleaseError.badSignature, {
            try publish("0.3.0") { text in
                let real = (try? ReleaseManifest.sha256(release.appendingPathComponent(asset))) ?? "?"
                return text.replacingOccurrences(of: real, with: String(repeating: "0", count: 64))
            }
        })
        // The asset changed after its hash was taken.
        try refused(ReleaseError.mismatch(asset), {
            let file = try publish("0.3.0")
            try Data("#!/bin/sh\necho 'kore-host 0.3.0 (evil)'\n".utf8).write(to: file)
            return file
        })
        // Another key's signature.
        try refused(ReleaseError.badSignature, {
            let file = try publish("0.3.0")
            try Curve25519.Signing.PrivateKey().signature(for: Data(contentsOf: release.appendingPathComponent("SHA256SUMS")))
                .write(to: release.appendingPathComponent("SHA256SUMS.sig"))
            return file
        })
        // A binary that doesn't say the signed version.
        try refused(ReleaseError.wrongBinary("kore-host 0.9.9 (link 1.12)"), { try publish("0.3.0", says: "0.9.9") })
        // Unpacking fails halfway.
        var broken = updater
        broken.unpack = { _, to in
            try Data("half".utf8).write(to: to)
            throw HostUpdateError.failed("xz", "couldn't unpack")
        }
        try refused(HostUpdateError.failed("xz", "couldn't unpack"), { try publish("0.3.0") }, updater: broken)
        // No release for this machine's platform.
        var arm = updater
        arm.platform = "linux-aarch64"
        try refused(ReleaseError.missing("kore-host-linux-aarch64.xz"), { try publish("0.3.0") }, updater: arm)
        // No signature at all.
        try refused(ReleaseError.missing("SHA256SUMS.sig"), {
            let file = try publish("0.3.0")
            try FileManager.default.removeItem(at: release.appendingPathComponent("SHA256SUMS.sig"))
            return file
        })
    }

    @Test func verifyChecksTheSignatureAndEachFileBesideIt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try publish("0.3.0")
        let sums = release.appendingPathComponent("SHA256SUMS")
        #expect(try updater.verify(sums) == ["kore 0.3.0 (ccccccc): signed by Kore's release key", "ok \(asset)", "ok kore-host.sh"])
        #expect(try updater.verify(file) == ["kore 0.3.0 (ccccccc): signed by Kore's release key", "ok \(asset)"])
        try Data("changed".utf8).write(to: release.appendingPathComponent("kore-host.sh"))
        #expect(throws: ReleaseError.mismatch("kore-host.sh")) { try updater.verify(sums) }
        #expect(try updater.verify(file).count == 2)
    }

    @Test func theRealUnpackerWritesXzContentsOrSaysWhy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad.xz"), out = root.appendingPathComponent("out")
        try Data("not xz".utf8).write(to: bad)
        #expect(throws: HostUpdateError.self) { try HostUpdate.unxz(bad, out) }
    }
}
