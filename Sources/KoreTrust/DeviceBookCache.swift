import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A book's contents for readers that ask often (a title-row icon, a popup's rows): read again
/// only when its file changed (every write replaces it, so its inode changes), else one `stat`.
/// A read that fails keeps the last good contents: a book that can't be read now hasn't removed
/// anyone. The file form only (a box's folder form reads one record per check).
package final class DeviceBookCache: @unchecked Sendable {
    package let book: DeviceBook
    private let lock = NSLock()
    private var stamp: Stamp?
    private var kept: DeviceBook.Contents?

    private struct Stamp: Equatable {
        var inode: UInt64
        var size: Int64
        var seconds: Int
        var nanos: Int
    }

    package init(_ book: DeviceBook) { self.book = book }

    /// The book now: from memory while its file is unchanged; the last good read when it can't
    /// be read; empty before anything was ever read.
    package func read() -> DeviceBook.Contents {
        lock.lock()
        defer { lock.unlock() }
        let now = Self.stamp(book.url)
        if let kept, !book.folder, now == stamp { return kept }
        do {
            let contents = try book.read()
            kept = contents
            stamp = now
            return contents
        } catch {
            return kept ?? .empty
        }
    }

    /// Drops what's kept (a write of ours that should show at once is caught by the stamp anyway).
    package func forget() {
        lock.lock()
        defer { lock.unlock() }
        stamp = nil
        kept = nil
    }

    private static func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim
        #endif
        return Stamp(inode: UInt64(info.st_ino), size: Int64(info.st_size), seconds: time.tv_sec, nanos: time.tv_nsec)
    }
}
