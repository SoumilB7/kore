import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The devices this one trusts: a 0600 JSON file, read on every call (a revoke holds from the next
/// command on, like `GrantStore.current`), written whole by rename under a lock, its `rev` raised
/// on every change so offline peers catch up by comparing revs.
package struct DeviceBook: Sendable {
    package let url: URL

    package init(url: URL) { self.url = url }

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
        guard let data = try PrivateFile.read(url) else { return .empty }
        do {
            return try TrustJSON.decoder().decode(Contents.self, from: data)
        } catch {
            throw TrustError.io("unreadable (\(error))")
        }
    }

    package func record(_ id: UUID) throws -> DeviceRecord? { try read().devices.first { $0.id == id } }

    /// The device a node key belongs to.
    package func record(nodeKey: String) throws -> DeviceRecord? { try read().devices.first { $0.nodeKeys.contains(nodeKey) } }

    /// Changes the devices under the book's lock; the rev rises once when they changed.
    @discardableResult
    package func update(_ change: (inout [DeviceRecord]) throws -> Void) throws -> Contents {
        try locked {
            var book = try read()
            var devices = book.devices
            try change(&devices)
            guard devices != book.devices else { return book }
            for record in devices { try record.validate() }
            guard Set(devices.map(\.id)).count == devices.count else { throw TrustError.invalidRecord("duplicate id") }
            book.devices = devices
            book.rev += 1
            try write(book)
            return book
        }
    }

    /// `devices.set{rev, records}`: taken only from an owner Mac this book already trusts, and only
    /// when newer than what's here.
    @discardableResult
    package func apply(rev: Int, devices: [DeviceRecord], from issuer: VerifiedPeer) throws -> Contents {
        try locked {
            let book = try read()
            guard let mac = book.devices.first(where: { $0.id == issuer.device }), mac.kind == .mac, mac.owner,
                  mac.identityKey == issuer.identityKey else { throw TrustError.refused("devices.set from a non-owner") }
            guard rev > book.rev else { throw TrustError.staleRev }
            for record in devices { try record.validate() }
            guard Set(devices.map(\.id)).count == devices.count else { throw TrustError.invalidRecord("duplicate id") }
            let next = Contents(rev: rev, devices: devices)
            try write(next)
            return next
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
    /// failure (no user, no tags) refuses, and the SSH route's `"ssh"` is never appended.
    @discardableResult
    package func appendNodeKey(_ peer: VerifiedPeer, whoisUserId: Int64?, whoisTags: [String]) throws -> NodeKeyAppend {
        guard peer.binding.route == Binding.Route.tailnet.rawValue, peer.nodeKey != Binding.Route.sshNodeKey else {
            throw TrustError.refused("node key off the tailnet")
        }
        var outcome = NodeKeyAppend.known
        try update { devices in
            guard let i = devices.firstIndex(where: { $0.id == peer.device }) else { throw TrustError.unknownDevice }
            let record = devices[i]
            guard record.identityKey == peer.identityKey else { throw TrustError.refused("identity key differs") }
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

    private func write(_ book: Contents) throws {
        try PrivateFile.write(try TrustJSON.encoder().encode(book), to: url)
    }

    /// Runs `body` holding an exclusive `flock` on the book's lock file (other processes too).
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try PrivateFile.folder(url.deletingLastPathComponent())
        let path = url.path + ".lock"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TrustError.io("lock \(errno)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw TrustError.io("flock \(errno)") }
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
