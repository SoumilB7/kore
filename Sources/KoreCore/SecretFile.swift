import Foundation

/// A secret Kore keeps in a file of its own (KoreNet's keys, a Claude API key): the folder only
/// its owner may enter (0700), the file only its owner may read (0600), written through a
/// temporary file renamed into place, so a reader sees the old bytes or the new, never half.
package enum SecretFile {
    /// Writes `data` to `url` (0600) in one step; its folder is made 0700 when missing, and
    /// with `narrow` (a folder of Kore's own secrets) made 0700 when it was looser.
    package static func write(_ data: Data, to url: URL, narrow: Bool = false) throws {
        let temp = try staged(data, beside: url, narrow: narrow)
        if rename(temp.path, url.path) != 0 {
            let problem = errno
            unlink(temp.path)
            throw POSIXError(POSIXErrorCode(rawValue: problem) ?? .EIO)
        }
    }

    /// Writes `data` to `url` (0600) only when there's no file there yet, in one step (`link(2)`
    /// of a written temporary file: never over one). Returns what `url` holds after: `data` when
    /// this call made it, else the file another process made first (read as `read` does).
    package static func create(_ data: Data, at url: URL, narrow: Bool = false) throws -> Data {
        let temp = try staged(data, beside: url, narrow: narrow)
        defer { unlink(temp.path) }
        if link(temp.path, url.path) == 0 { return data }
        let problem = errno
        guard problem == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: problem) ?? .EIO) }
        guard let winner = try read(url) else { throw POSIXError(.ENOENT) }
        return winner
    }

    /// `data` in a new 0600 temporary file beside `url`, synced; its folder made 0700 as `write` says.
    private static func staged(_ data: Data, beside url: URL, narrow: Bool) throws -> URL {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if narrow, chmod(dir.path, 0o700) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var problem: Int32 = 0
        // The mode asked for, whatever the umask.
        if fchmod(fd, 0o600) != 0 { problem = errno }
        if problem == 0 {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        problem = errno
                        return
                    }
                    offset += written
                }
            }
        }
        if problem == 0, fsync(fd) != 0 { problem = errno }
        close(fd)
        if problem != 0 {
            unlink(temp.path)
            throw POSIXError(POSIXErrorCode(rawValue: problem) ?? .EIO)
        }
        return temp
    }

    /// The file's text when it's a plain file of this user's that nobody else may read or write;
    /// nil when there's none. A looser one throws `Loose`: its secret may be known.
    package static func read(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Loose(name: url.lastPathComponent) }
        return try Data(contentsOf: url)
    }

    /// A secret's file that others may read: refused.
    package struct Loose: LocalizedError, Equatable {
        package let name: String
        package var errorDescription: String? { "\(name) is readable by others: Kore won't use it" }
    }
}
