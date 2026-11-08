import Foundation
import KoreTrust
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The box's own identity on KoreNet (phase 18 §1): a P-256 key in a 0600 file and a device id,
/// made once (under a lock, so `join` and the daemon never make two).
package struct BoxIdentity: Sendable {
    package let device: UUID
    package let signer: SoftwareIdentity

    /// The 8 hex digits `kore-host join` prints and the Mac's claim card shows.
    package var code: String { DeviceRecord.code(device) }

    package static func loadOrCreate(_ paths: HostPaths) throws -> BoxIdentity {
        try HostPaths.privateFolder(paths.state)
        let fd = open(paths.state.appendingPathComponent(".identity.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TrustError.io("identity lock \(errno)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw TrustError.io("identity flock \(errno)") }
        defer { flock(fd, LOCK_UN) }
        let signer = try IdentityKeyFile.loadOrCreate(at: paths.identityKey)
        if let id = try readId(paths) { return BoxIdentity(device: id, signer: signer) }
        let id = UUID()
        try PrivateFile.write(Data((id.uuidString.lowercased() + "\n").utf8), to: paths.deviceId)
        return BoxIdentity(device: id, signer: signer)
    }

    /// The identity as it is, made by nothing (`status`).
    package static func load(_ paths: HostPaths) -> BoxIdentity? {
        guard let raw = try? PrivateFile.read(paths.identityKey), let signer = try? SoftwareIdentity(raw: raw), let id = try? readId(paths) else { return nil }
        return BoxIdentity(device: id, signer: signer)
    }

    private static func readId(_ paths: HostPaths) throws -> UUID? {
        guard let data = try PrivateFile.read(paths.deviceId) else { return nil }
        guard let id = UUID(uuidString: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TrustError.io("device-id unreadable")
        }
        return id
    }
}

/// `kore-host join`'s time: an unclaimed box takes a claim only within `window` of it (running
/// `join` again opens it again).
package enum NetJoin {
    package static let window: TimeInterval = 600

    package static func mark(_ paths: HostPaths, at time: Date) throws {
        try PrivateFile.write(Data("\(Int(time.timeIntervalSince1970))\n".utf8), to: paths.netJoined)
    }

    package static func at(_ paths: HostPaths) -> Date? {
        guard let data = try? PrivateFile.read(paths.netJoined),
              let seconds = Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Whether a claim may be taken now.
    package static func open(_ paths: HostPaths, now: Date) -> Bool {
        guard let joined = at(paths) else { return false }
        let since = now.timeIntervalSince(joined)
        return since >= 0 && since <= window
    }
}

/// The box's devices (phase 18 §4): the KoreTrust `DeviceBook` in its folder form at
/// `devices/<id>.json`, read on every command as `GrantStore.current` is, and the devices waiting
/// for an Allow (`devices/pending.json`): told apart by node key, at most `pendingCap`, each noted
/// (journal, push to owner Macs) at most once per `coolDown`.
package struct DeviceStore: Sendable {
    package let book: DeviceBook
    package let pendingFile: URL

    package static let pendingCap = 8
    package static let coolDown: TimeInterval = 600

    package init(paths: HostPaths) { self.init(folder: paths.devices) }

    package init(folder: URL) {
        book = DeviceBook(folder: folder)
        pendingFile = folder.appendingPathComponent("pending.json")
    }

    package func all() -> [DeviceRecord] { (try? book.read().devices) ?? [] }

    package var rev: Int { (try? book.read().rev) ?? 0 }

    /// A Mac owns this box: an owner Mac record is held.
    package var claimed: Bool { all().contains { $0.kind == .mac && $0.owner } }

    /// The abilities a device kind gets when it's allowed here (fixed by kind in v1).
    package static func abilities(_ kind: NodeKind) -> Ability {
        switch kind {
        case .mac: [.read, .ask, .run]
        case .phone: [.read, .ask]
        case .box: [.read]
        }
    }

    // MARK: Pending

    package func pending() -> [PendingDevice] {
        guard let data = try? PrivateFile.read(pendingFile), let list = DevicesWire.decode([PendingDevice].self, data) else { return [] }
        return list
    }

    package enum Noted: Equatable, Sendable {
        /// New on the list: journal it, tell the owner Macs.
        case added
        /// On the list, its cool-down over: noted again.
        case seen
        /// On the list and noted lately: nothing more.
        case cooling
        /// The list is full of recent ones: not kept.
        case full
        /// Another node says it's a device already listed, or the listed node another device or
        /// key: refused, the entry untouched.
        case conflict
    }

    /// Keeps a device that reached the box without a record. Entries are told apart by node key
    /// (WhoIs's, never the peer's word): one already listed only gains what it lacked (its device
    /// id, key, kind) and is seen again; its node key, key and name are never replaced. Another
    /// node naming a listed device id, or the listed node naming another id or key, is refused.
    /// A full list lets go of its oldest entry quiet for a cool-down (never the claim), else the
    /// newcomer isn't kept.
    @discardableResult
    package func notePending(_ fresh: PendingDevice, at now: Date) -> Noted {
        (try? lockedPending { list -> Noted in
            if let i = list.firstIndex(where: { $0.nodeKey == fresh.nodeKey }) {
                var entry = list[i]
                if let device = fresh.device, let had = entry.device, device != had { return .conflict }
                if let key = fresh.identityKey, let had = entry.identityKey, key != had { return .conflict }
                entry.device = entry.device ?? fresh.device
                entry.identityKey = entry.identityKey ?? fresh.identityKey
                entry.kind = entry.kind ?? fresh.kind
                entry.raiseKey = entry.raiseKey ?? fresh.raiseKey
                entry.claim = entry.claim || fresh.claim
                entry.lastSeen = now
                let due = now.timeIntervalSince(entry.notedAt) >= Self.coolDown
                if due { entry.notedAt = now }
                list[i] = entry
                return due ? .seen : .cooling
            }
            if let device = fresh.device, list.contains(where: { $0.device == device }) { return .conflict }
            if list.count >= Self.pendingCap {
                let quiet = list.enumerated().filter { !$0.element.claim && now.timeIntervalSince($0.element.lastSeen) >= Self.coolDown }
                guard let oldest = quiet.min(by: { $0.element.lastSeen < $1.element.lastSeen }) else { return .full }
                list.remove(at: oldest.offset)
            }
            var entry = fresh
            entry.firstSeen = now
            entry.lastSeen = now
            entry.notedAt = now
            list.append(entry)
            return .added
        }) ?? .full
    }

    /// The claim candidate: the first Mac of the box's own user while no Mac owns it.
    package var claimant: PendingDevice? { pending().first { $0.claim } }

    /// Drops pending entries for `device` (allowed or denied).
    package func dropPending(device: UUID?, nodeKey: String? = nil) {
        _ = try? lockedPending { list in list.removeAll { ($0.device != nil && $0.device == device) || (nodeKey != nil && $0.nodeKey == nodeKey) } }
    }

    // MARK: Allow, remove, set

    package enum StoreError: Error, Equatable, CustomStringConvertible {
        case noSuch(String)
        case noKey(String)
        case ambiguous(String)

        package var description: String {
            switch self {
            case .noSuch(let what): "no device or pending device \(what)"
            case .noKey(let what): "\(what) hasn't said who it is yet: it needs to connect once more (from Kore's Add device)"
            case .ambiguous(let what): "\(what) names more than one device: use its id"
            }
        }
    }

    /// The pending device `code` or id names, made a record: its abilities by kind, a Mac an
    /// owner (whoever runs this is the box's owner).
    @discardableResult
    package func allow(_ which: String, at now: Date) throws -> DeviceRecord {
        let list = pending()
        let digits = DeviceRecord.codeDigits(which)
        let id = UUID(uuidString: which)
        let matches = list.filter { entry in
            guard let device = entry.device else { return false }
            if let id { return device == id }
            if let digits { return device.uuidString.lowercased().hasPrefix(digits) }
            return false
        }
        guard let entry = matches.first else { throw StoreError.noSuch(which) }
        guard matches.count == 1 else { throw StoreError.ambiguous(which) }
        let record = try Self.record(from: entry, at: now)
        try book.update { devices in
            devices.removeAll { $0.id == record.id }
            devices.append(record)
        }
        dropPending(device: record.id, nodeKey: entry.nodeKey)
        return record
    }

    /// A record for an allowed pending device.
    package static func record(from entry: PendingDevice, owner: Bool? = nil, at now: Date) throws -> DeviceRecord {
        guard let device = entry.device, let key = entry.identityKey else { throw StoreError.noKey(entry.name) }
        let kind = entry.kind ?? .mac
        var abilities = abilities(kind)
        if !entry.tags.isEmpty { abilities = abilities.effective.intersection(AppCap.taggedCap) }
        let record = DeviceRecord(
            id: device, name: entry.name, kind: kind, abilities: abilities, owner: owner ?? (kind == .mac && entry.tags.isEmpty), identityKey: key,
            nodeKeys: [entry.nodeKey], userId: entry.tags.isEmpty ? entry.userId : nil, tags: entry.tags, fqdn: entry.fqdn, raiseKey: entry.raiseKey,
            added: now, lastSeen: now)
        try record.validate()
        return record
    }

    package enum Removed: Equatable, Sendable {
        /// The device and every record a removed Mac issued.
        case device(DeviceRecord, dropped: [DeviceRecord])
        case pending(PendingDevice)
    }

    /// Removes a device by id, code or name (a Mac takes what it issued), or a pending one.
    package func remove(_ which: String) throws -> Removed {
        let digits = DeviceRecord.codeDigits(which)
        let id = UUID(uuidString: which)
        let records = all().filter { r in
            if let id { return r.id == id }
            if let digits, r.id.uuidString.lowercased().hasPrefix(digits) { return true }
            return r.name == which
        }
        if records.count > 1 { throw StoreError.ambiguous(which) }
        if let record = records.first {
            let before = all()
            let after = try book.remove(record.id).devices
            let dropped = before.filter { r in r.id != record.id && !after.contains { $0.id == r.id } }
            return .device(record, dropped: dropped)
        }
        let waiting = pending().filter { p in
            if let id { return p.device == id }
            if let digits, let device = p.device, device.uuidString.lowercased().hasPrefix(digits) { return true }
            return p.name == which || p.nodeKey == which
        }
        guard let entry = waiting.first else { throw StoreError.noSuch(which) }
        guard waiting.count == 1 else { throw StoreError.ambiguous(which) }
        dropPending(device: entry.device, nodeKey: entry.nodeKey)
        return .pending(entry)
    }

    /// `devices.set{rev, records}` from a proven owner Mac: the book becomes the set (records whose
    /// issuing Mac isn't in it dropped), pending entries now allowed leave the list.
    @discardableResult
    package func set(rev: Int, records: [DeviceRecord], from peer: VerifiedPeer) throws -> DeviceBook.Contents {
        // Each kind's abilities at most (a phone never runs, a box only reads), and the box keeps
        // an owner Mac: a set without one would leave nobody able to change it.
        let capped = records.map { record -> DeviceRecord in
            var record = record
            record.abilities = record.abilities.effective.intersection(Self.abilities(record.kind).effective)
            return record
        }
        guard capped.contains(where: { $0.kind == .mac && $0.owner }) else { throw TrustError.refused("a set without an owner Mac") }
        let next = try book.apply(rev: rev, devices: capped, from: peer)
        let ids = Set(next.devices.map(\.id))
        _ = try? lockedPending { list in list.removeAll { $0.device.map(ids.contains) ?? false } }
        return next
    }

    /// A merging `devices.set`: the phones this owner Mac issued, capped to their kind's abilities.
    package func merge(records: [DeviceRecord], from peer: VerifiedPeer) throws -> DeviceBook.Contents {
        let capped = records.map { record -> DeviceRecord in
            var record = record
            record.abilities = record.abilities.effective.intersection(Self.abilities(record.kind).effective)
            return record
        }
        let next = try book.applyIssued(capped, from: peer)
        let ids = Set(next.devices.map(\.id))
        _ = try? lockedPending { list in list.removeAll { $0.device.map(ids.contains) ?? false } }
        return next
    }

    private func lockedPending<T>(_ body: (inout [PendingDevice]) throws -> T) throws -> T {
        let folder = pendingFile.deletingLastPathComponent()
        try PrivateFile.folder(folder)
        let fd = open(folder.appendingPathComponent(".pending.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TrustError.io("pending lock \(errno)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw TrustError.io("pending flock \(errno)") }
        defer { flock(fd, LOCK_UN) }
        var list = pending()
        let before = list
        let out = try body(&list)
        if list != before { try PrivateFile.write(DevicesWire.encode(list), to: pendingFile) }
        return out
    }
}
