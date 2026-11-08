import Foundation
import KoreNet
import KoreTrust
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// A Mac keeping a box current (phase 19): `host.keep` for `status`, `host.update` refused or run
/// apart as `kore-host update --by` (a stand-in here), its failure answered.
@Suite("box updates from a Mac", .serialized)
@MainActor
struct HostUpdatePushTests {
    func up(_ rig: NetRig, _ device: Device) async throws -> Dialled {
        let dialled = try rig.dial(device, route: .tailnet, whois: nil)
        try await dialled.until { dialled.types.contains("snapshot") || dialled.closed != nil }
        #expect(dialled.up, "\(dialled.closed ?? "")")
        return dialled
    }

    func results(_ dialled: Dialled) -> [UpdateWire.Result] { dialled.decoded(UpdateWire.Result.self).filter { $0.t == UpdateWire.result } }

    @Test func aFullMacKeepsTheBoxAndAFailedUpdateIsAnswered() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        let host = rig.rig.host
        host.updateAsset = "kore-host-linux-x86_64.xz"
        var spawned: [[String]] = []
        host.updateSpawn = { arguments, out in
            spawned.append(arguments)
            return HostDaemon.spawnDetached("/bin/sh", ["-c", "echo 'update: 0.2.3 → 99.0.0'; echo \"error: can't reach github.com\"; exit 1"], out: out)
        }
        let mac = Device("mac")
        try rig.allow(mac)
        let dialled = try await up(rig, mac)
        #expect(host.welcome(control: .full).caps.contains(UpdateWire.cap))
        #expect(!host.welcome(control: .act).caps.contains(UpdateWire.cap))

        try dialled.send(UpdateWire.Keep(on: true, by: "Soumil's MacBook Air"))
        try await dialled.until { UpdateState.load(rig.rig.paths).keptBy != nil }
        #expect(UpdateState.load(rig.rig.paths).rows(current: HostVersion.string, now: rig.clock.now).first! == ("update", "kept up to date by Soumil's MacBook Air"))

        try dialled.send(UpdateWire.Update(id: "u1", version: "0.0.1", by: "Soumil's MacBook Air"))
        try await dialled.until { !results(dialled).isEmpty }
        #expect(results(dialled).map(\.outcome) == [.current])

        try dialled.send(UpdateWire.Update(id: "u2", version: "99.0.0", by: "Soumil's MacBook Air"))
        try await dialled.until { results(dialled).count == 3 }
        #expect(spawned == [["update", "--by", "Soumil's MacBook Air"]])
        // GitHub out of reach: the Mac hears which file to send instead.
        #expect(results(dialled).dropFirst().map(\.outcome) == [.started, .offline])
        #expect(results(dialled).last == UpdateWire.Result(id: "u2", outcome: .offline, line: "can't reach github.com", asset: "kore-host-linux-x86_64.xz"))

        try dialled.send(UpdateWire.Keep(on: false, by: "Soumil's MacBook Air"))
        try await dialled.until { UpdateState.load(rig.rig.paths).keptBy == nil }
    }

    @Test func theBoxPullsTheFilesFromTheMacThenUpdatesFromThem() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        let host = rig.rig.host
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("kh-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inbox) }
        host.updateInbox = inbox
        host.updateAsset = "kore-host-test.xz"
        var spawned: [[String]] = []
        var landed: [String: Data] = [:]
        host.updateSpawn = { arguments, out in
            spawned.append(arguments)
            for name in ["SHA256SUMS", "SHA256SUMS.sig", "kore-host-test.xz"] { landed[name] = try? Data(contentsOf: inbox.appendingPathComponent(name)) }
            return HostDaemon.spawnDetached("/bin/sh", ["-c", "echo 'error: kore-host-test.xz doesn'\\''t match its signed hash'; exit 1"], out: out)
        }
        let mac = Device("mac")
        try rig.allow(mac)
        let dialled = try await up(rig, mac)
        // Three files, the last over two pieces.
        let files = [
            "SHA256SUMS": Data("# kore 99.0.0 sums\n".utf8), "SHA256SUMS.sig": Data(repeating: 7, count: 64),
            "kore-host-test.xz": Data((0..<(UpdateWire.pieceSize + 10)).map { UInt8($0 % 251) }),
        ]
        try dialled.send(UpdateWire.Update(id: "m1", version: "99.0.0", by: "Soumil's MacBook Air", from: UpdateWire.fromMac))
        var served = 0
        while spawned.isEmpty {
            try await dialled.until { dialled.decoded(UpdateWire.Get.self).filter { $0.t == UpdateWire.get }.count > served || !spawned.isEmpty }
            guard spawned.isEmpty else { break }
            let get = dialled.decoded(UpdateWire.Get.self).filter { $0.t == UpdateWire.get }[served]
            served += 1
            let file = try #require(files[get.name])
            let piece = file.subdata(in: get.offset..<min(file.count, get.offset + UpdateWire.pieceSize))
            try dialled.send(UpdateWire.Piece(id: "m1", name: get.name, offset: get.offset, total: file.count, data: piece.base64EncodedString()))
        }
        #expect(served == 4)
        #expect(spawned == [["update", "--file", inbox.appendingPathComponent("kore-host-test.xz").path, "--by", "Soumil's MacBook Air"]])
        #expect(landed == files)
        // `update --file` refused them: the Mac hears it, and the files go.
        try await dialled.until { results(dialled).count == 2 }
        #expect(results(dialled).map(\.outcome) == [.started, .failed])
        #expect(results(dialled).last?.line == "kore-host-test.xz doesn't match its signed hash")
        #expect(!FileManager.default.fileExists(atPath: inbox.path))
    }

    @Test func aMacWithoutTheFileStopsThePull() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        let host = rig.rig.host
        host.updateInbox = FileManager.default.temporaryDirectory.appendingPathComponent("kh-inbox-\(UUID().uuidString)")
        host.updateSpawn = { _, _ in Issue.record("spawned"); return nil }
        let mac = Device("mac")
        try rig.allow(mac)
        let dialled = try await up(rig, mac)
        try dialled.send(UpdateWire.Update(id: "m1", version: "99.0.0", by: "mac", from: UpdateWire.fromMac))
        try await dialled.until { dialled.types.contains(UpdateWire.get) }
        try dialled.send(UpdateWire.Piece(id: "m1", name: "SHA256SUMS", offset: 0, total: 0, data: ""))
        try await dialled.until { results(dialled).count == 2 }
        #expect(results(dialled).last == UpdateWire.Result(id: "m1", outcome: .failed, line: "mac has no SHA256SUMS to send"))
        #expect(!FileManager.default.fileExists(atPath: host.updateInbox.path))
        // A dev build as new as the release is never taken down.
        try dialled.send(UpdateWire.Update(id: "m2", version: HostVersion.string, by: "mac", from: UpdateWire.fromMac))
        try await dialled.until { results(dialled).count == 3 }
        #expect(results(dialled).last?.outcome == .current)
    }

    @Test func aPhoneMayNotUpdateTheBox() async throws {
        let rig = try await NetRig.make()
        defer { rig.finish() }
        rig.rig.host.updateSpawn = { _, _ in Issue.record("spawned"); return nil }
        let phone = Device("pixel", kind: .phone)
        try rig.allow(phone)
        let dialled = try await up(rig, phone)
        try dialled.send(UpdateWire.Update(id: "u1", version: "99.0.0", by: "pixel"))
        try await dialled.until { !results(dialled).isEmpty }
        #expect(results(dialled).first?.outcome == .failed)
        try dialled.send(UpdateWire.Keep(on: true, by: "pixel"))
        try dialled.send(UpdateWire.Update(id: "u2", version: "0.0.1", by: "pixel"))
        try await dialled.until { results(dialled).count == 2 }
        #expect(UpdateState.load(rig.rig.paths).keptBy == nil)
    }

    @Test func chatsStateFollowsTheDaemonsChats() throws {
        let rig = try HostRig()
        defer { rig.finish() }
        try rig.host.start()
        _ = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: "haiku"))
        rig.host.noteChats()
        #expect(try String(contentsOf: rig.paths.chatsState, encoding: .utf8) == "0 0\n")
        #expect(HostUpdate.chats(rig.paths).map { [$0.working, $0.open] } == [0, 0])
    }
}
