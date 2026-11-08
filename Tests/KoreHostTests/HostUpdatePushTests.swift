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
        #expect(results(dialled).dropFirst().map(\.outcome) == [.started, .failed])
        #expect(results(dialled).last == UpdateWire.Result(id: "u2", outcome: .failed, line: "can't reach github.com"))

        try dialled.send(UpdateWire.Keep(on: false, by: "Soumil's MacBook Air"))
        try await dialled.until { UpdateState.load(rig.rig.paths).keptBy == nil }
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
