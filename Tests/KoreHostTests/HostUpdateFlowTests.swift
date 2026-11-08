import CryptoKit
import Foundation
import Testing

@testable import KoreCore
@testable import KoreHost

/// `kore-host update`'s words, over a release folder made here (a throwaway key, a script for a
/// binary) and a stand-in curl that copies from it or fails like an offline box.
@Suite("kore-host update words")
struct HostUpdateFlowTests {
    let key = Curve25519.Signing.PrivateKey()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kh-flow-\(UUID().uuidString)")
    var release: URL { root.appendingPathComponent("release") }
    var target: URL { root.appendingPathComponent("bin/kore-host") }
    var scratch: URL { root.appendingPathComponent("scratch") }
    let asset = "kore-host-linux-x86_64.xz"
    let paths: HostPaths
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        paths = HostPaths(environment: [
            "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        ])
        for folder in [release, scratch, target.deletingLastPathComponent()] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try HostUpdateTests.binary(says: "0.2.3").write(to: target)
    }

    /// A signed release of `version`; `edit` changes SHA256SUMS after signing.
    func publish(_ version: String, edit: ((String) -> String)? = nil) throws {
        try HostUpdateTests.binary(says: version).write(to: release.appendingPathComponent(asset))
        let text = ReleaseManifest(version: version, commit: String(repeating: "c", count: 40), files: [asset: try ReleaseManifest.sha256(release.appendingPathComponent(asset))]).text
        try key.signature(for: Data(text.utf8)).write(to: release.appendingPathComponent("SHA256SUMS.sig"))
        try Data((edit?(text) ?? text).utf8).write(to: release.appendingPathComponent("SHA256SUMS"))
        // Up two days before `at`, as curl -R keeps it.
        try FileManager.default.setAttributes([.modificationDate: at.addingTimeInterval(-2 * 86_400)], ofItemAtPath: release.appendingPathComponent("SHA256SUMS").path)
    }

    final class Asked: @unchecked Sendable {
        var urls: [String] = []
        var restarts = 0
    }

    /// The flow with curl copying from `release` (or failing when `offline`); `chats` as the daemon says them.
    func flow(tty: Bool = true, offline: Bool = false, chats: (working: Int, open: Int)? = (0, 2), asked: Asked = Asked(), said: Said) -> UpdateFlow {
        var updater = HostUpdate(target: target)
        updater.current = "0.2.3"
        updater.platform = "linux-x86_64"
        updater.key = key.publicKey.rawRepresentation.base64EncodedString()
        updater.unpack = { from, to in try FileManager.default.copyItem(at: from, to: to) }
        let release = release
        updater.run = { args in
            guard args.first == "curl" else { return HostService.system(args) }
            let url = args.last!, out = args[args.firstIndex(of: "-o")! + 1]
            asked.urls.append(url)
            if offline { return HostRan(status: 6, output: "curl: (6) Could not resolve host: github.com") }
            let from = release.appendingPathComponent(URL(string: url)!.lastPathComponent)
            try? FileManager.default.removeItem(atPath: out)
            guard (try? FileManager.default.copyItem(atPath: from.path, toPath: out)) != nil else { return HostRan(status: 22, output: "curl: (22) 404") }
            if args.contains("-fsSLR") {
                let time = (try? FileManager.default.attributesOfItem(atPath: from.path))?[.modificationDate] as? Date
                try? FileManager.default.setAttributes([.modificationDate: time ?? Date()], ofItemAtPath: out)
            }
            return HostRan(status: 0)
        }
        var flow = UpdateFlow(
            updater: updater, paths: paths, base: HostUpdate.latest, scratch: scratch, tty: tty, say: { said.lines.append($0) },
            chats: { chats }, restart: { asked.restarts += 1; return (true, "") })
        let now = at
        flow.now = { now }
        return flow
    }

    final class Said: @unchecked Sendable { var lines: [String] = [] }

    func installed() throws -> String { String(decoding: try Data(contentsOf: target), as: UTF8.self) }

    @Test func aTerminalSeesEachStep() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try publish("0.3.0")
        let said = Said(), asked = Asked()
        #expect(flow(asked: asked, said: said).update() == 0)
        #expect(said.lines == [
            "kore-host 0.2.3 → 0.3.0",
            "  ✓ found 0.3.0 (github.com/SoumilB7/kore, released 2 days ago)",
            "  ✓ downloaded kore-host-linux-x86_64 (1 KB)",
            "  ✓ signature checks out (SoumilB7 release key)",
            "  ✓ 2 chats idle, safe to restart",
            "  ✓ swapped, restarting… phones and Macs reconnect by themselves",
            "kore-host 0.3.0 is running",
        ])
        #expect(try installed().contains("kore-host 0.3.0 "))
        #expect(asked.restarts == 1)
        #expect(UpdateState.load(paths).latest == "0.3.0")
    }

    @Test func aPipeGetsKeyValueLines() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try publish("0.3.0")
        let said = Said()
        #expect(flow(tty: false, said: said).update() == 0)
        #expect(said.lines == [
            "update: 0.2.3 → 0.3.0", "found: 0.3.0 github.com/SoumilB7/kore", "downloaded: kore-host-linux-x86_64.xz 1 KB",
            "signature: ok", "chats: 2 idle", "swapped: 0.3.0", "running: 0.3.0",
        ])
    }

    @Test func currentWorkingOfflineAndForgedEachSayOneThingAndChangeNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try installed()

        try publish("0.2.3")
        var said = Said()
        #expect(flow(said: said).update() == 0)
        #expect(said.lines == ["kore-host 0.2.3 is the latest"])

        try publish("0.3.0")
        said = Said()
        let asked = Asked()
        #expect(flow(chats: (2, 3), asked: asked, said: said).update() == 1)
        #expect(said.lines == ["2 chats are working · run again when they finish, or --now"])
        #expect(asked.urls.isEmpty)

        said = Said()
        #expect(flow(offline: true, said: said).update() == 1)
        #expect(said.lines.first == "can't reach github.com/SoumilB7/kore (curl: (6) Could not resolve host: github.com) · nothing changed")
        #expect(said.lines.last?.contains("kore-host update --file kore-host-linux-x86_64.xz") == true)
        #expect(said.lines.count == 2)

        try publish("0.3.0") { $0.replacingOccurrences(of: "0.3.0", with: "0.4.0") }
        said = Said()
        #expect(flow(said: said).update() == 1)
        #expect(said.lines == ["  ✗ SHA256SUMS isn't signed by Kore's release key · nothing changed"])

        try publish("0.2.1")
        said = Said()
        #expect(flow(said: said).update() == 1)
        #expect(said.lines == ["kore-host 0.2.3 is newer than 0.2.1 · --force installs 0.2.1"])

        #expect(try installed() == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["kore-host"])
    }

    @Test func aBinaryChangedAfterSigningIsRefusedAfterItsDownload() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try publish("0.3.0")
        try Data("#!/bin/sh\necho evil\n".utf8).write(to: release.appendingPathComponent(asset))
        let said = Said()
        #expect(flow(said: said).update() == 1)
        #expect(said.lines.last == "  ✗ kore-host-linux-x86_64.xz doesn't match its signed hash · nothing changed")
        #expect(try installed().contains("0.2.3"))
    }

    @Test func checkSaysOneLineAndDownloadsNoBinary() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try publish("0.3.0")
        var said = Said()
        let asked = Asked()
        #expect(flow(asked: asked, said: said).check() == 0)
        #expect(said.lines == ["0.3.0 is out (you have 0.2.3) · kore-host update"])
        #expect(!asked.urls.contains { $0.hasSuffix(".xz") })
        try publish("0.2.3")
        said = Said()
        #expect(flow(said: said).check() == 0)
        #expect(said.lines == ["kore-host 0.2.3 is the latest"])
        said = Said()
        #expect(flow(offline: true, said: said).check() == 1)
        #expect(said.lines.count == 1)
    }

    @Test func aMacsPushIsJournalledAndShowsInStatus() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try publish("0.3.0")
        let journal = JournalLines()
        defer { journal.stop() }
        #expect(flow(tty: false, said: Said()).update(by: "Soumil's MacBook Air") == 0)
        #expect(journal.lines.contains("updated from=0.2.3 to=0.3.0 by=\"Soumil's MacBook Air\""))
        let state = UpdateState.load(paths)
        #expect(state.pushed == UpdateState.Pushed(from: "0.2.3", to: "0.3.0", by: "Soumil's MacBook Air", at: at))
        #expect(state.rows(current: "0.3.0", now: at.addingTimeInterval(300)).last! == ("updated", "to 0.3.0 by Soumil's MacBook Air, 5 min ago"))
    }

    @Test func statusSaysOnlyWhatsKnown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = UpdateState()
        func rows(_ current: String = "0.2.3") -> [String] { state.rows(current: current, now: now).map { $0.0 + " " + $0.1 } }
        #expect(rows() == ["update not checked · kore-host update --check"])
        state.latest = "0.3.0"
        state.checked = now.addingTimeInterval(-7200)
        #expect(rows() == ["update 0.3.0 available · kore-host update"])
        #expect(rows("0.3.0") == ["update latest, checked 2 h ago"])
        state.keptBy = "Soumil's MacBook Air"
        state.keptAt = now.addingTimeInterval(-86_400)
        #expect(rows() == ["update kept up to date by Soumil's MacBook Air"])
        // A Mac that stopped saying so for two weeks no longer counts.
        state.keptAt = now.addingTimeInterval(-15 * 86_400)
        #expect(rows() == ["update 0.3.0 available · kore-host update"])
        // What a Mac put here shows while it's the version running.
        state.pushed = UpdateState.Pushed(from: "0.2.3", to: "0.3.0", by: "mac", at: now.addingTimeInterval(-60))
        #expect(rows("0.3.0").last == "updated to 0.3.0 by mac, 1 min ago")
        #expect(rows("0.3.1").count == 1)
    }
}

/// Journal lines while a test runs.
final class JournalLines: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []
    private var id: UUID?
    init() { id = HostJournal.watch { [weak self] line in self?.lock.withLock { self?.kept.append(line) } } }
    var lines: [String] { lock.withLock { kept } }
    func stop() { id.map(HostJournal.unwatch) }
}
