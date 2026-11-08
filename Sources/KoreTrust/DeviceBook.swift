import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The devices this one trusts, read on every call (a revoke holds from the next command on, like
/// `GrantStore.current`), changed under a lock, its `rev` raised on every change so offline peers
/// catch up by comparing revs. Kept as one 0600 JSON file (a Mac, a phone), or as a 0700 folder
/// of `<id>.json` records plus `rev.json` (a box's `devices/`, phase 18 §4), where a command's
/// check reads its one record.
package struct DeviceBook: Sendable {
    /// The book's file, or (folder form) its folder.
    package let url: URL
    package let folder: Bool

    package init(url: URL) {
        self.url = url
        folder = false
    }

    /// The folder form: `<id>.json` per device, `rev.json` for the rev.
    package init(folder: URL) {
        url = folder
        self.folder = true
    }

    private var revFile: URL { url.appendingPathComponent("rev.json") }

    private func recordFile(_ id: UUID) -> URL { url.appendingPathComponent(id.uuidString.lowercased() + ".json") }

    package struct Contents: Codable, Equatable, Sendable {
        package var v = 1
        package var rev: Int
        package var devices: [DeviceRecord]

        package init(rev: Int, devices: [DeviceRecord]) {
            self.rev = rev
            self.devices = devices
        }

        package static let empty = Contents(rev: 0, devices: [])

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = try c.decode(Int.self, forKey: .v)
            guard v == 1 else { throw TrustError.io("version \(v)") }
            rev = try c.decode(Int.self, forKey: .rev)
            devices = try c.decode([DeviceRecord].self, forKey: .devices)
            guard rev >= 0, Set(devices.map(\.id)).count == devices.count else { throw TrustError.io("rev or ids") }
        }
    }

    /// The book as it is on disk now; empty at rev 0 before the first write.
    package func read() throws -> Contents {
        guard folder else { return try readFile() }
        return try locked(LOCK_SH) { try readFolder() }
    }

    private func readFile() throws -> Contents {
        guard let data = try PrivateFile.read(url) else { return .empty }
        do {
            return try TrustJSON.decoder().decode(Contents.self, from: data)
        } catch {
            throw TrustError.io("unreadable (\(error))")
        }
    }

    private struct RevFile: Codable {
        var v = 1
        var rev: Int
    }

    private func readFolder() throws -> Contents {
        var rev = 0
        if let data = try PrivateFile.read(revFile) {
            guard let kept = try? TrustJSON.decoder().decode(RevFile.self, from: data), kept.v == 1, kept.rev >= 0 else {
                throw TrustError.io("unreadable rev")
            }
            rev = kept.rev
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        var devices: [DeviceRecord] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            if let record = try readRecord(id) { devices.append(record) }
        }
        devices.sort { $0.added == $1.added ? $0.id.uuidString < $1.id.uuidString : $0.added < $1.added }
        return Contents(rev: rev, devices: devices)
    }

    private func readRecord(_ id: UUID) throws -> DeviceRecord? {
        guard let data = try PrivateFile.read(recordFile(id)) else { return nil }
        guard let record = try? TrustJSON.decoder().decode(DeviceRecord.self, from: data), record.id == id else {
            throw TrustError.io("unreadable \(id.uuidString.lowercased()).json")
        }
        return record
    }

    /// One device's record; the folder form reads just its file (each command's check).
    package func record(_ id: UUID) throws -> DeviceRecord? {
        if folder { return try readRecord(id) }
        return try read().devices.first { $0.id == id }
    }

    /// The device a node key belongs to.
    package func record(nodeKey: String) throws -> DeviceRecord? { try read().devices.first { $0.nodeKeys.contains(nodeKey) } }

    /// Changes the devices under the book's lock; the rev rises once when they changed.
    @discardableResult
    package func update(_ change: (inout [DeviceRecord]) throws -> Void) throws -> Contents {
        try locked {
            var book = try readUnlocked()
            var devices = book.devices
            try change(&devices)
            guard devices != book.devices else { return book }
            for record in devices { try record.validate() }
            guard Set(devices.map(\.id)).count == devices.count else { throw TrustError.invalidRecord("duplicate id") }
            let before = book
            book.devices = devices
            book.rev += 1
            try write(book, over: before)
            return book
        }
    }

    /// `devices.set{rev, records}`: taken only from an owner Mac this book already trusts, and only
    /// when newer than what's here.
    @discardableResult
    package func apply(rev: Int, devices: [DeviceRecord], from issuer: VerifiedPeer) throws -> Contents {
        try locked {
            let book = try readUnlocked()
            guard let mac = book.devices.first(where: { $0.id == issuer.device }), mac.kind == .mac, mac.owner,
                  mac.identityKey == issuer.identityKey else { throw TrustError.refused("devices.set from a non-owner") }
            guard rev > book.rev else { throw TrustError.staleRev }
            for record in devices { try record.validate() }
            guard Set(devices.map(\.id)).count == devices.count else { throw TrustError.invalidRecord("duplicate id") }
            // Records the set's Macs didn't issue stay out: a Mac gone takes what it issued.
            let macs = Set(devices.filter { $0.kind == .mac }.map(\.id))
            let kept = devices.filter { $0.issuedBy.map(macs.contains) ?? true }
            let next = Contents(rev: rev, devices: kept)
            try write(next, over: book)
            return next
        }
    }

    /// `devices.set{merge}` (phase 18 step 5b): the records an owner Mac issued (its phones) become
    /// these; every other record stays. A record of another issuer, or a Mac, can't be set so.
    @discardableResult
    package func applyIssued(_ records: [DeviceRecord], from issuer: VerifiedPeer) throws -> Contents {
        try locked {
            var book = try readUnlocked()
            guard let mac = book.devices.first(where: { $0.id == issuer.device }), mac.kind == .mac, mac.owner,
                  mac.identityKey == issuer.identityKey else { throw TrustError.refused("devices.set from a non-owner") }
            for record in records {
                guard record.issuedBy == issuer.device, record.kind != .mac, record.id != issuer.device else {
                    throw TrustError.refused("a merged record the Mac didn't issue")
                }
                try record.validate()
            }
            let ids = Set(records.map(\.id))
            guard ids.count == records.count else { throw TrustError.invalidRecord("duplicate id") }
            let kept = book.devices.filter { $0.issuedBy != issuer.device }
            guard !kept.contains(where: { ids.contains($0.id) }) else { throw TrustError.refused("another device's record") }
            let devices = kept + records
            guard devices != book.devices else { return book }
            let before = book
            book.devices = devices
            book.rev += 1
            try write(book, over: before)
            return book
        }
    }

    /// Removes a device, and with a Mac every record it issued.
    @discardableResult
    package func remove(_ id: UUID) throws -> Contents {
        try update { devices in devices.removeAll { $0.id == id || $0.issuedBy == id } }
    }

    package enum NodeKeyAppend: Equatable, Sendable {
        case known
        /// Appended; `dropped` is the oldest key let go to keep three.
        case appended(dropped: String?)
    }

    /// A node key the device signed a binding with (rotation): kept only after the identity proof
    /// and a fresh WhoIs of the same user (or the same tags); the last three are kept. A WhoIs
    /// failure (no user, no tags) refuses, and the SSH route's `"ssh"` is never appended. A device
    /// enrolled over SSH (no user yet) takes its first node key only from a WhoIs of `ownUser`,
    /// this device's own Tailscale user, and is that user's from then on. On a tagged device
    /// (`ownUser` nil) it takes it when Kore's app capability in that WhoIs (`cap`) allows the
    /// record's abilities, and is that WhoIs's tags' (or user's) from then on.
    @discardableResult
    package func appendNodeKey(_ peer: VerifiedPeer, whoisUserId: Int64?, whoisTags: [String], ownUser: Int64? = nil, cap: Ability? = nil) throws -> NodeKeyAppend {
        guard peer.binding.route == Binding.Route.tailnet.rawValue, peer.nodeKey != Binding.Route.sshNodeKey else {
            throw TrustError.refused("node key off the tailnet")
        }
        var outcome = NodeKeyAppend.known
        try update { devices in
            guard let i = devices.firstIndex(where: { $0.id == peer.device }) else { throw TrustError.unknownDevice }
            let record = devices[i]
            guard record.identityKey == peer.identityKey else { throw TrustError.refused("identity key differs") }
            if record.sshOnly {
                if let ownUser {
                    guard let user = whoisUserId, whoisTags.isEmpty, user == ownUser else { throw TrustError.refused("whois") }
                    devices[i].userId = user
                } else {
                    guard let cap, cap.allows(record.abilities) else { throw TrustError.refused("whois") }
                    if whoisTags.isEmpty {
                        guard let user = whoisUserId else { throw TrustError.refused("whois") }
                        devices[i].userId = user
                    } else {
                        devices[i].tags = whoisTags
                    }
                }
                devices[i].nodeKeys = [peer.nodeKey]
                outcome = .appended(dropped: nil)
                return
            }
            let sameOwner: Bool = if let user = record.userId {
                whoisUserId == user && whoisTags.isEmpty
            } else {
                whoisUserId == nil && !whoisTags.isEmpty && Set(whoisTags) == Set(record.tags)
            }
            guard sameOwner else { throw TrustError.refused("whois") }
            guard !record.nodeKeys.contains(peer.nodeKey) else { return }
            var keys = record.nodeKeys + [peer.nodeKey]
            let dropped = keys.count > DeviceRecord.maxNodeKeys ? keys.removeFirst() : nil
            devices[i].nodeKeys = keys
            outcome = .appended(dropped: dropped)
        }
        return outcome
    }

    private func readUnlocked() throws -> Contents { folder ? try readFolder() : try readFile() }

    /// The file form: written whole. The folder form: changed records written, gone ones removed,
    /// then the rev (a reader holds the shared lock, so it never sees half).
    private func write(_ book: Contents, over before: Contents) throws {
        guard folder else { return try PrivateFile.write(try TrustJSON.encoder().encode(book), to: url) }
        let old = Dictionary(before.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for record in book.devices where old[record.id] != record {
            try PrivateFile.write(try TrustJSON.encoder().encode(record), to: recordFile(record.id))
        }
        let ids = Set(book.devices.map(\.id))
        for id in old.keys where !ids.contains(id) {
            if unlink(recordFile(id).path) != 0 && errno != ENOENT { throw TrustError.io("remove \(errno)") }
        }
        try PrivateFile.write(try TrustJSON.encoder().encode(RevFile(rev: book.rev)), to: revFile)
    }

    /// Runs `body` holding a `flock` (exclusive unless asked) on the book's lock file (other
    /// processes too).
    private func locked<T>(_ mode: Int32 = LOCK_EX, _ body: () throws -> T) throws -> T {
        let path: String
        if folder {
            try PrivateFile.folder(url)
            path = url.appendingPathComponent(".lock").path
        } else {
            try PrivateFile.folder(url.deletingLastPathComponent())
            path = url.path + ".lock"
        }
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TrustError.io("lock \(errno)") }
        defer { close(fd) }
        guard flock(fd, mode) == 0 else { throw TrustError.io("flock \(errno)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Files only this user reads: made 0600 in a 0700 folder, replaced whole by rename after fsync,
/// refused when someone else owns them or others can read them.
package enum PrivateFile {
    /// The file's bytes; nil when there's none.
    package static func read(_ url: URL) throws -> Data? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw TrustError.io("stat \(errno)")
        }
        guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw TrustError.io("\(url.lastPathComponent) is not private") }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw TrustError.io("read \(url.lastPathComponent)")
        }
    }

    package static func write(_ data: Data, to url: URL) throws {
        try folder(url.deletingLastPathComponent())
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TrustError.io("create \(errno)") }
        var ok = data.withUnsafeBytes { raw -> Bool in
            var done = 0
            while done < raw.count {
                let n = Glue.write(fd, raw.baseAddress! + done, raw.count - done)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                done += n
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temp, url.path) == 0 else {
            unlink(temp)
            throw TrustError.io("write \(url.lastPathComponent)")
        }
    }

    /// Makes the folder 0700 when it's missing.
    package static func folder(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

private enum Glue {
    static func write(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buf, count)
        #elseif canImport(Glibc)
        Glibc.write(fd, buf, count)
        #else
        Musl.write(fd, buf, count)
        #endif
    }
}
