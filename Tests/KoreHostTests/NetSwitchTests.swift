import Foundation
import KoreNet
import KoreTrust
import Synchronization
import Tailnet
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// KoreNet off by default and switchable: off holds no port, no watcher, never asks Tailscale;
/// SSH keeps working; an owner Mac can switch it off (and on only over SSH); paused devices.
@Suite("korenet switch", .serialized)
@MainActor
struct NetSwitchTests {
    /// A daemon whose tailnet factory counts its calls.
    final class Made {
        var count = 0
        let tailnet = FakeTailnet(status: FakeTailnet.status(.running, ips: ["127.0.0.1"]))
    }

    func rig(on: Bool) throws -> (HostRig, Made) {
        let rig = try HostRig()
        if on { try HostConfig(folders: [rig.folder.path], net: true).save(rig.paths.config) }
        rig.restart()
        let made = Made()
        rig.host.makeTailnet = { made.count += 1; return made.tailnet }
        rig.host.netPort = 0
        try rig.host.start()
        return (rig, made)
    }

    @Test func offByDefaultHoldsNoPortAndWatchesNothing() throws {
        let (rig, made) = try rig(on: false)
        defer { rig.finish() }
        let net = try #require(rig.host.net)
        #expect(net.tailnet == nil && !net.listening && !net.watching && net.bound.isEmpty)
        #expect(made.count == 0 && made.tailnet.buses.withLock { $0 } == 0)
        #expect(!HostConfig.load(rig.paths.config).netOn)
        let lines = HostStatus.net(paths: rig.paths, on: false, tailnet: { made.count += 1; return made.tailnet }, portHolder: { nil })
        #expect(lines.first == "net      off (kore-host net on)" && !lines.contains { $0.hasPrefix("tailnet") } && made.count == 0)
        // The SSH route's socket stays for `attach --proto 2`.
        #expect(FileManager.default.fileExists(atPath: rig.paths.netSocket.path))
    }

    @Test func onBindsThenOffLetsEverythingGo() async throws {
        let (rig, made) = try rig(on: true)
        defer { rig.finish() }
        let net = try #require(rig.host.net)
        #expect(made.count == 1 && net.listening && net.bound == ["127.0.0.1"])
        try rig.host.setNet(false)
        #expect(!net.listening && !net.watching && net.tailnet == nil && net.bound.isEmpty)
        // The bus reader lets go once its task ends.
        let end = ContinuousClock.now + .seconds(5)
        while made.tailnet.buses.withLock({ $0 }) > 0, ContinuousClock.now < end { await Task.yield() }
        #expect(made.tailnet.buses.withLock { $0 } == 0)
        #expect(HostConfig.load(rig.paths.config).net == false)
        try rig.host.setNet(true)
        #expect(made.count == 2 && net.listening)
    }

    @Test func anOwnerMacSwitchesItOffAndOnlySSHTurnsItOn() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        try rig.rig.host.setNet(true)
        let mac = Device("mac"), phone = Device("pixel", kind: .phone), desk = Device("imac")
        try rig.allow(mac)
        try rig.allow(phone)
        try rig.allow(desk)
        let viaPhone = try rig.dial(phone)
        try await viaPhone.until { viaPhone.types.contains("snapshot") || viaPhone.closed != nil }
        try viaPhone.send(NetSwitchWire.Set(id: "p", on: false))
        try await viaPhone.until { viaPhone.types.contains(NetSwitchWire.result) }
        #expect(viaPhone.decoded(NetSwitchWire.Result.self).first?.ok == false)
        // Another Mac over SSH (the same Mac's tailnet link would replace its SSH one).
        let overSSH = try rig.dial(desk, route: .ssh)
        try await overSSH.until { overSSH.types.contains("snapshot") || overSSH.closed != nil }
        let tailnet = try rig.dial(mac)
        try await tailnet.until { tailnet.types.contains("snapshot") || tailnet.closed != nil }
        try tailnet.send(NetSwitchWire.Set(id: "off", on: false))
        try await tailnet.until { tailnet.closed != nil }
        #expect(tailnet.decoded(NetSwitchWire.Result.self).first == .init(id: "off", ok: true, on: false))
        #expect(!rig.rig.host.config.netOn && rig.net.tailnet == nil && !rig.net.watching)
        // Off: tailnet links went, the SSH link stayed.
        try await viaPhone.until { viaPhone.closed != nil }
        overSSH.pump()
        #expect(overSSH.up)
        // On again: over SSH only.
        try overSSH.send(NetSwitchWire.Set(id: "on", on: true))
        try await overSSH.until { overSSH.types.contains(NetSwitchWire.result) }
        #expect(overSSH.decoded(NetSwitchWire.Result.self).first == .init(id: "on", ok: true, on: true))
        #expect(rig.rig.host.config.netOn && rig.net.tailnet != nil)
    }

    @Test func aPausedDeviceIsRefusedAndKept() async throws {
        let rig = try NetRig()
        defer { rig.finish() }
        let mac = Device("mac"), phone = Device("pixel", kind: .phone)
        try rig.allow(mac)
        try rig.allow(phone, issuedBy: mac.id)
        let owner = try rig.dial(mac)
        try await owner.until { owner.types.contains("snapshot") || owner.closed != nil }
        let watching = try rig.dial(phone)
        try await watching.until { watching.types.contains("snapshot") || watching.closed != nil }
        var paused = rig.record(phone, issuedBy: mac.id)
        paused.paused = true
        try owner.sendRaw(DevicesWire.encode(DevicesWire.Set(id: "s", rev: 5, records: [rig.record(mac), paused])))
        try await watching.until { watching.closed != nil }
        #expect(watching.got.contains { (try? LinkMessage.decode($0)) == .bye(.paused) })
        let again = try rig.dial(phone)
        try await again.until { again.closed != nil }
        #expect(again.closed == "bye paused")
        #expect(try rig.store.book.record(phone.id)?.isPaused == true)
    }

    @Test func statusSaysNetTailnetPortHolderDevicesAndPending() throws {
        let (rig, made) = try rig(on: true)
        defer { rig.finish() }
        let store = rig.host.devices
        let mac = Device("mac")
        try store.book.update { devices in
            devices.append(DeviceRecord(
                id: mac.id, name: "MacBook", kind: .mac, abilities: [.read, .ask, .run], owner: true, identityKey: mac.key.publicKey,
                nodeKeys: [mac.nodeKey], userId: 7, fqdn: "m.ts.net.", added: Date()))
        }
        store.notePending(PendingDevice(nodeKey: "nk:p", device: UUID(), name: "Pixel 9", kind: .phone, identityKey: nil, userId: 7, tags: [], fqdn: "", login: "me@x", at: Date()), at: Date())
        let lines = HostStatus.net(paths: rig.paths, on: true, tailnet: { made.tailnet }, portHolder: { 4242 })
        let me = try #require(BoxIdentity.load(rig.paths))
        #expect(lines.contains("net      on"))
        #expect(lines.contains("device   \(me.device.uuidString.lowercased()) (code \(me.code))"))
        #expect(lines.contains("tailnet  Running · 127.0.0.1"))
        #expect(lines.contains("port     47470 held by uid 4242"))
        #expect(lines.contains("devices  MacBook (mac, \(DeviceRecord.code(mac.id)))"))
        #expect(lines.contains { $0.hasPrefix("pending  Pixel 9 ") && $0.hasSuffix("· me@x") })
    }
}
