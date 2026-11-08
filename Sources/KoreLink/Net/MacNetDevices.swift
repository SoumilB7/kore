import Foundation
import HostClient
import KoreNet
import KoreTrust
import KoreUI

/// The phones' side of Devices (step 7) over the phones' listener (`MacNet`, step 5b): the phones
/// in this Mac's book with their links and presence, the Add device window, and ⋯ on a phone
/// (rename, remove, take offline / bring online through the book and `devices.set` to the boxes).
/// While KoreNet is off there's no `MacNet`: no phones are read and the window can't open.
@MainActor
package final class MacNetDevices: PhoneDevices {
    /// The listener now (Kore: `MacNet.shared`; tests: theirs).
    private let net: @MainActor () -> MacNet?

    package init(net: @escaping @MainActor () -> MacNet? = { MacNet.shared }) { self.net = net }

    /// The book as the rows read it: from memory until its file changes (the title-row icon asks
    /// on every look), and a read that fails shows the last good one.
    private var cache: DeviceBookCache?

    package func allowedPhones(_ mac: MacNet) -> [DeviceRecord] {
        if cache?.book.url != mac.host.book.url { cache = DeviceBookCache(mac.host.book) }
        return (cache?.read().devices ?? []).filter { $0.kind == .phone }
    }

    /// At launch: Devices reads phones through this.
    package static func install() {
        Devices.shared.phones = MacNetDevices()
        StayAwakePhones.onScreen = { LinkFeed.shared.phonesOnScreen }
    }

    package var phones: [PhoneFacts] {
        guard let mac = net() else { return [] }
        let titles = mac.phones.values.contains { $0.client.watching != nil } ? LinkSnapshot.chatsByID() : [:]
        return allowedPhones(mac).map { record in
            let link = mac.phones[record.id].flatMap { $0.ended ? nil : $0 }
            let presence = link?.client.watching.flatMap { titles[$0]?.title }.flatMap { $0.isEmpty ? nil : $0 }
            return PhoneFacts(
                id: record.id, name: record.name, connected: link != nil && !record.isPaused, presence: presence, lastSeen: record.lastSeen,
                paused: record.isPaused, nodeKeys: record.nodeKeys)
        }
    }

    package var addUntil: Date? { net()?.addOpen == true ? net()?.addUntil : nil }
    package var refusals: [DeviceRefusal] { net()?.refusals ?? [] }

    package func openAddWindow() { net()?.openAddWindow() }
    package func closeAddWindow() { net()?.closeAddWindow() }

    package func rename(_ id: UUID, to name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty else { return }
        update(id) { $0.name = name }
    }

    /// Removed: its record goes, the boxes hear (`bye revoked` there at once), its link ends.
    package func remove(_ id: UUID) {
        guard let mac = net() else { return }
        do {
            try mac.host.book.update { $0.removeAll { $0.id == id } }
        } catch {
            return
        }
        NetAudit.line("revoke", ["device": id.uuidString.lowercased()])
        mac.phones[id]?.end(NetControl.Reason.revoked)
        mac.phonesChanged()
    }

    /// Taken offline: kept, but served nothing here (parked) and refused at every box (`paused`)
    /// until brought online.
    package func setPaused(_ id: UUID, _ paused: Bool) {
        update(id) { $0.paused = paused ? true : nil }
        // Its link stays, parked: Bring online tells it to come back at once.
        if paused { net()?.phones[id]?.park() } else { net()?.phones[id]?.unpark() }
        NetAudit.line(paused ? "pause" : "resume", ["device": id.uuidString.lowercased()])
    }

    private func update(_ id: UUID, _ change: (inout DeviceRecord) -> Void) {
        guard let mac = net() else { return }
        do {
            try mac.host.book.update { devices in
                guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
                change(&devices[i])
            }
        } catch {
            return
        }
        mac.phonesChanged()
    }

    /// A device waiting at a box: its card (Tailscale's facts as the box saw them); on Allow it's
    /// this Mac's record, by its kind's abilities, and the boxes hear.
    package func ask(_ pending: PendingRow) {
        guard let mac = net() else { return }
        let device = pending.device
        let address = KoreNetSwitch.shared?.status?.peers.first { $0.publicKey == device.nodeKey }?.tailscaleIPs.first ?? "—"
        let node = MacNet.shortName(device.fqdn.isEmpty ? device.name : device.fqdn)
        var info: DeviceCardInfo = pending.kind == .box
            ? .box(name: device.name, node: node, address: address, login: device.login, firstSeen: device.firstSeen, device: device.device)
            : .phone(name: device.name, node: node, address: address, login: device.login, firstSeen: device.firstSeen)
        // A record this phone clearly replaces (reinstalled or left) shows on the card; Allow
        // looks at the tailnet again before retiring anything (`MacNet.replaced`).
        let probe = Self.probe(device, kind: pending.kind)
        let peers = KoreNetSwitch.shared?.status?.peers
        if let probe, let peers {
            info.replaces = mac.replacing(probe, peers: peers).first.map { MacNet.replacesLine($0, peers: peers, now: Date()) }
        }
        mac.asks.ask(info) { [weak self] answer in
            guard answer == .allow else {
                if answer != .gone { NetAudit.line("deny", ["node": device.nodeKey, "at": pending.box]) }
                return
            }
            guard let probe else {
                self?.allow(device)
                return
            }
            mac.peers { [weak self] peers in self?.allow(device, retire: mac.replacing(probe, peers: peers).map(\.id)) }
        }
    }

    /// A waiting phone as a record, for what it replaces; nil for anything else.
    static func probe(_ device: PendingDevice, kind: DeviceRow.Kind) -> DeviceRecord? {
        guard kind == .phone, let id = device.device, let key = device.identityKey else { return nil }
        var probe = DeviceRecord(
            id: id, name: device.name, kind: .phone, abilities: [.read, .ask], identityKey: key, nodeKeys: [device.nodeKey], userId: device.userId,
            fqdn: device.fqdn, added: Date())
        probe.model = device.name
        return probe
    }

    private func allow(_ device: PendingDevice, retire: [UUID] = []) {
        guard let mac = net(), let id = device.device, let key = device.identityKey, let issuer = mac.device else { return }
        let kind = device.kind ?? .phone
        guard kind != .mac else { return }
        var record = DeviceRecord(
            id: id, name: MacNet.clean(device.name), kind: kind, abilities: kind == .phone ? [.read, .ask] : [.read, .ask, .run], identityKey: key,
            nodeKeys: [device.nodeKey], userId: device.userId, tags: device.tags, fqdn: device.fqdn, raiseKey: device.raiseKey, issuedBy: issuer,
            added: Date())
        if kind == .phone { record.model = record.name }
        guard (try? record.validate()) != nil else { return }
        do {
            try mac.host.book.update { devices in
                devices.removeAll { $0.id == id || ($0.kind == .phone && retire.contains($0.id)) }
                devices.append(record)
            }
        } catch {
            return
        }
        for old in retire { NetAudit.line("retire", ["device": old.uuidString.lowercased(), "by": id.uuidString.lowercased()]) }
        NetAudit.line("allow", ["device": id.uuidString.lowercased(), "kind": kind.rawValue, "how": "pending"])
        mac.phonesChanged()
    }
}
