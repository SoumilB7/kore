import Foundation
import KoreTrust
import LinkProtocol

// Phase 18: the box's devices as the link sees them: `devices.set` from an owner Mac,
// `devices.pending` to owner Macs, a revoked device's links ended at once, the grant upgrade's
// owners moved to the device, and `usage.since`.
extension HostDaemon {
    /// `devices.set{rev, records}`: only from an owner Mac proven over KoreNet. The links of
    /// devices no longer in the book end with `bye revoked` at once (the rest would at their next
    /// command anyway).
    func devicesSet(_ data: Data, from client: LinkClient) {
        guard let set = DevicesWire.decode(DevicesWire.Set.self, data) else {
            return client.sendRaw(DevicesWire.encode(DevicesWire.Result(id: StreamWire.id(data) ?? "", ok: false, rev: devices.rev, message: "A malformed devices.set.")))
        }
        guard client.ownerMac, let peer = client.peer, client.current() != nil else {
            client.denied(DevicesWire.set)
            return client.sendRaw(DevicesWire.encode(DevicesWire.Result(id: set.id, ok: false, rev: devices.rev, message: "Only an owner Mac sets this box's devices.")))
        }
        let before = devices.all()
        do {
            let next = set.merge == true ? try devices.merge(records: set.records, from: peer) : try devices.set(rev: set.rev, records: set.records, from: peer)
            let ids = Set(next.devices.map(\.id))
            for gone in before where !ids.contains(gone.id) {
                HostJournal.audit("revoke", ["device": gone.id.uuidString.lowercased(), "kind": gone.kind.rawValue, "by": peer.device.uuidString.lowercased()])
            }
            for added in next.devices where !before.contains(where: { $0.id == added.id }) {
                HostJournal.audit("allow", ["device": added.id.uuidString.lowercased(), "kind": added.kind.rawValue, "by": peer.device.uuidString.lowercased()])
            }
            client.sendRaw(DevicesWire.encode(DevicesWire.Result(id: set.id, ok: true, rev: next.rev)))
            endRevoked()
        } catch {
            client.sendRaw(DevicesWire.encode(DevicesWire.Result(id: set.id, ok: false, rev: devices.rev, message: "\(error)")))
        }
    }

    /// `net.set{on}`: an owner Mac switches the box's KoreNet off (on any route), or on again
    /// over SSH only. The answer goes before the switch (off ends the tailnet links).
    func netSet(_ data: Data, from client: LinkClient) {
        guard let ask = DevicesWire.decode(NetSwitchWire.Set.self, data) else { return }
        func answer(_ ok: Bool, _ message: String? = nil) {
            client.sendRaw(DevicesWire.encode(NetSwitchWire.Result(id: ask.id, ok: ok, on: config.netOn, message: message)))
        }
        guard client.ownerMac, client.current() != nil else {
            client.denied(NetSwitchWire.set)
            return answer(false, "Only an owner Mac switches this box's KoreNet.")
        }
        guard !ask.on || client.route == .ssh else { return answer(false, "Turning KoreNet on needs SSH or the box's own kore-host.") }
        guard ask.on != config.netOn else { return answer(true) }
        var next = config
        next.net = ask.on
        do {
            try next.save(paths.config)
        } catch {
            return answer(false, "\(error)")
        }
        HostJournal.audit("net", ["on": ask.on ? "1" : "0", "device": client.deviceId.map { $0.uuidString.lowercased() }])
        client.sendRaw(DevicesWire.encode(NetSwitchWire.Result(id: ask.id, ok: true, on: ask.on)))
        reloadNet()
    }

    /// Every link whose device (or whose grant's device) has gone from the book ends now.
    func endRevoked() {
        for connection in provenClients where connection.deviceId != nil { _ = connection.current() }
    }

    /// The pending list to one owner Mac (on its connect, when there's any).
    func sendPending(to client: LinkClient) {
        let list = devices.pending()
        guard !list.isEmpty else { return }
        client.sendRaw(DevicesWire.encode(DevicesWire.Pending(pending: list)))
    }

    /// The pending list changed: every owner Mac connected now hears it.
    func pushPending() {
        let message = DevicesWire.encode(DevicesWire.Pending(pending: devices.pending()))
        for connection in provenClients where connection.ownerMac { connection.sendRaw(message) }
    }

    /// The upgrade: what `grant` held (chats it owns, a move it holds, its shells) is its
    /// device's from now on.
    func rehome(grant: String, to device: UUID) {
        let id = device.uuidString.lowercased()
        for hc in chats + closedChats {
            if var owner = hc.record.owner, owner.host == grant {
                owner.host = id
                hc.setOwner(owner)
            }
            if var hold = hc.record.moving, hold.grant == grant {
                hold.grant = id
                hc.setMoving(hold)
            }
        }
        terminals.rehome(grant, to: id)
        if let limits = rateLimits.removeValue(forKey: grant) { rateLimits[id] = limits }
    }

    /// `usage.since{cursor}`: a page of the ledger after the cursor (a full link only: it's the
    /// Mac's usage bookkeeping).
    func usageSince(_ data: Data, from client: LinkClient) {
        guard let ask = try? JSONDecoder().decode(UsageWire.Since.self, from: data) else { return }
        guard client.current() == .full else {
            client.denied(UsageWire.since)
            return client.sendRaw(StreamWire.encode(UsageWire.Page(id: ask.id, lines: [], cursor: ask.cursor ?? 0, more: false)))
        }
        client.sendRaw(StreamWire.encode(usage.since(ask.cursor, id: ask.id)))
    }

    /// Who this box is on KoreNet (`net.node`), for a full link after its welcome: an owner Mac
    /// pins the identity key and enrolls once. Nil before the box has an identity.
    func netNode(enrolled: UUID?) -> NetNodeWire.Node? {
        guard let identity = net?.identity else { return nil }
        let name = String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "box")
        let nodeKey = net?.tailnet != nil ? net?.selfNode?.publicKey : nil
        return NetNodeWire.Node(
            device: identity.device, identityKey: identity.signer.publicKey, name: name, on: config.netOn, nodeKey: nodeKey, enrolled: enrolled)
    }
}
