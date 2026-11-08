import CryptoKit
import Foundation
import HostClient
import KoreCore
import Synchronization
import Testing

/// How `kore-tailnet` gets to a box from this Mac: Set up puts it beside kore-host (unless the
/// same one is there), and the binary comes from a dev folder, the cache, or the release, taken
/// only when its signed SHA256SUMS checks out. No ssh (FakeSSH), no network (a fetch in memory).
@Suite("box tailnet binary")
struct BoxTailnetBinaryTests {
    @Test func setUpPutsItBesideKoreHost() async throws {
        let fake = try FakeSSH()
        defer { fake.finish() }
        let helper = fake.root.appendingPathComponent("kore-tailnet-linux-x86_64")
        try Data("kore-tailnet for linux".utf8).write(to: helper)
        let asked = Mutex<[String]>([])
        let setup = BoxSetup(alias: "mybox", grant: "Soumils-Mac", shell: fake.shell, binary: fake.binary()) { platform in
            asked.withLock { $0.append(platform) }
            return (helper, false)
        }
        let steps = Steps()
        try await setup.run(allow: true) { steps.add($0) }
        #expect(asked.withLock { $0 } == ["linux-x86_64"])
        let calls = fake.calls
        let at = try #require(calls.firstIndex(of: "scp mybox:.local/bin/kore-tailnet.new"))
        #expect(calls[at - 2] == "ssh mybox mv -f .local/bin/kore-host.new .local/bin/kore-host")
        #expect(calls[at - 1].hasPrefix("ssh mybox sha256sum .local/bin/kore-tailnet"))
        #expect(calls[at + 1].contains("usage: kore-tailnet") && calls[at + 1].contains("mv -f .local/bin/kore-tailnet.new .local/bin/kore-tailnet"))
        // Before the daemon starts: it runs Kore's own tailnet when the box has no Tailscale.
        #expect(calls[at + 2] == "ssh mybox .local/bin/kore-host install-service")
        let said = await MainActor.run { steps.all }
        #expect(said.contains("Copying kore-tailnet to mybox…"))
    }

    @Test func withoutOneSetUpGoesOnAsBefore() async throws {
        let fake = try FakeSSH()
        defer { fake.finish() }
        let setup = BoxSetup(alias: "mybox", grant: "Soumils-Mac", shell: fake.shell, binary: fake.binary()) { _ in nil }
        try await setup.run(allow: true) { _ in }
        #expect(!fake.calls.contains { $0.contains("kore-tailnet") })
    }

    /// The release's, only when its sums are signed by the key and its hash matches; kept after.
    @Test func theReleasesIsTakenOnlyWhenSigned() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ktb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let build = BoxHostBuild(support: root, version: "0.2.3", commit: String(repeating: "a", count: 40), builtFrom: nil)
        let key = Curve25519.Signing.PrivateKey()
        let plain = Data("kore-tailnet linux x86_64".utf8)
        let packed = try (plain as NSData).compressed(using: .lzma) as Data
        func sums(_ asset: Data) -> Data {
            let hash = SHA256.hash(data: asset).map { String(format: "%02x", $0) }.joined()
            return Data("# kore 0.2.3 \(String(repeating: "b", count: 40))\n\(hash)  kore-tailnet-linux-x86_64.xz\n".utf8)
        }
        func fetch(_ files: [String: Data]) -> BoxTailnetBinary.Fetch { { url in files[url.lastPathComponent] } }
        let good = sums(packed)
        let files = ["SHA256SUMS": good, "SHA256SUMS.sig": try key.signature(for: good), "kore-tailnet-linux-x86_64.xz": packed]
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        // Another key's signature, or a file that isn't the one signed: nothing.
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(await BoxTailnetBinary.local("linux-x86_64", override: nil, helper: nil, build: build, fetch: fetch(files), key: other) == nil)
        var swapped = files
        swapped["kore-tailnet-linux-x86_64.xz"] = try (Data("something else".utf8) as NSData).compressed(using: .lzma) as Data
        #expect(await BoxTailnetBinary.local("linux-x86_64", override: nil, helper: nil, build: build, fetch: fetch(swapped), key: publicKey) == nil)

        let got = try #require(await BoxTailnetBinary.local("linux-x86_64", override: nil, helper: nil, build: build, fetch: fetch(files), key: publicKey))
        #expect(try Data(contentsOf: got.url) == plain && !got.temporary)
        // Kept: the next box takes it without the network.
        let again = try #require(await BoxTailnetBinary.local("linux-x86_64", override: nil, helper: nil, build: build, fetch: fetch([:]), key: publicKey))
        #expect(again.url == got.url)
    }

    /// A Mac box gets Kore.app's own helper; a dev folder's comes first.
    @Test func aMacBoxGetsTheAppsHelper() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ktb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("kore-tailnet")
        try Data("app's".utf8).write(to: helper)
        let build = BoxHostBuild(support: root, version: nil, commit: nil, builtFrom: nil)
        let none: BoxTailnetBinary.Fetch = { _ in nil }
        #expect(await BoxTailnetBinary.local("macos-arm64", override: nil, helper: helper, build: build, fetch: none)?.url == helper)
        #expect(await BoxTailnetBinary.local("linux-aarch64", override: nil, helper: helper, build: build, fetch: none) == nil)
        let dev = root.appendingPathComponent("dev")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try Data("dev's".utf8).write(to: dev.appendingPathComponent("kore-tailnet-macos-arm64"))
        #expect(await BoxTailnetBinary.local("macos-arm64", override: dev.path, helper: helper, build: build, fetch: none)?.url.lastPathComponent == "kore-tailnet-macos-arm64")
    }
}
