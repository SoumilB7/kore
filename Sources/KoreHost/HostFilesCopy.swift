import Foundation
import KoreCore
import LinkProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Link 1.11: an entry copied within the served folders (`fs.copy`), and an entry's files and
/// bytes counted (`fs.count`), what a copy across devices checks before its source goes. Both
/// ends are inside served folders (`entry`); a link is copied and counted as itself, never
/// followed, so nothing outside a served folder is read or written.
extension HostFiles {
    /// What's under an entry: files (a file or a link counts one), their bytes, and whether the
    /// entry itself is a folder.
    package struct Tally: Equatable, Sendable {
        package var files = 0
        package var bytes: Int64 = 0
        package var dir = false
    }

    /// Copies `from` (recursively, links as links) to `to`, which mustn't be there yet: into a
    /// hidden name beside `to` first, renamed when whole; a failure leaves nothing.
    package func copy(id: String, from: String, to: String, run: CopyRun = CopyRun()) -> FilesResult {
        let source: (path: String, real: String)
        let target: (path: String, real: String)
        switch (entry(from), entry(to)) {
        case (.failure(let refusal), _), (_, .failure(let refusal)): return .refused(id, refusal.code, refusal.message)
        case (.success(let a), .success(let b)): (source, target) = (a, b)
        }
        guard Self.look(source.real) != nil else { return .refused(id, .goneFile, "Not there on this box.") }
        guard !served.contains(target.path) else { return .refused(id, .invalid, "That's a served folder itself.") }
        guard !LinkFiles.inside(target.path, source.path), !LinkFiles.inside(target.real, source.real) else {
            return .refused(id, .invalid, "A folder can't go inside itself.")
        }
        let name = (target.path as NSString).lastPathComponent
        if Self.look(target.real) != nil { return .refused(id, .invalid, "\(name) is already there.") }
        let folder = (target.real as NSString).deletingLastPathComponent
        let temp = folder + "/." + name + ".kore-" + String(UUID().uuidString.prefix(8)).lowercased()
        run.start(total: Self.tally(source.real).bytes)
        guard Self.copyTree(source.real, temp, run: run) else {
            try? FileManager.default.removeItem(atPath: temp)
            if run.cancelled { return .refused(id, .invalid, "Cancelled.") }
            return .refused(id, .deniedPath, "Can't copy it there on this box.")
        }
        guard Self.look(target.real) == nil, FileCalls.rename(temp, target.real) == 0 else {
            try? FileManager.default.removeItem(atPath: temp)
            return .refused(id, .invalid, "\(name) is already there.")
        }
        var result = FilesResult(id: id, ok: true, path: target.path)
        let tally = Self.tally(target.real)
        result.files = tally.files
        result.size = tally.bytes
        result.dir = tally.dir
        return result
    }

    /// `fs.count`: the entry's files and bytes, links not followed.
    package func count(id: String, path: String) -> FilesResult {
        let entry: (path: String, real: String)
        switch self.entry(path) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): entry = found
        }
        guard Self.look(entry.real) != nil else { return .refused(id, .goneFile, "Not there on this box.") }
        let tally = Self.tally(entry.real)
        var result = FilesResult(id: id, ok: true, path: entry.path, size: tally.bytes)
        result.files = tally.files
        result.dir = tally.dir
        return result
    }

    /// Files and bytes under `path` (itself not followed): folders walked, anything else neither
    /// a file nor a link skipped.
    package static func tally(_ path: String) -> Tally {
        var tally = Tally()
        guard let info = linkInfo(path) else { return tally }
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            tally.dir = true
            var queue = [path]
            while let folder = queue.popLast() {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                    let child = folder + "/" + name
                    guard let info = linkInfo(child) else { continue }
                    switch info.st_mode & mode_t(S_IFMT) {
                    case mode_t(S_IFDIR): queue.append(child)
                    case mode_t(S_IFREG):
                        tally.files += 1
                        tally.bytes += Int64(info.st_size)
                    case mode_t(S_IFLNK): tally.files += 1
                    default: break
                    }
                }
            }
        case mode_t(S_IFREG):
            tally.files = 1
            tally.bytes = Int64(info.st_size)
        case mode_t(S_IFLNK): tally.files = 1
        default: break
        }
        return tally
    }

    /// One entry copied, a folder with all in it: files with their mode and time, links as the
    /// same link. False at the first thing that can't be made.
    static func copyTree(_ from: String, _ to: String, run: CopyRun) -> Bool {
        guard !run.cancelled else { return false }
        guard let info = linkInfo(from) else { return false }
        let manager = FileManager.default
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            guard FileCalls.mkdir(to, 0o700) == 0 else { return false }
            guard let names = try? manager.contentsOfDirectory(atPath: from) else { return false }
            for name in names where !copyTree(from + "/" + name, to + "/" + name, run: run) { return false }
            _ = chmod(to, info.st_mode & 0o7777)
            return true
        case mode_t(S_IFREG):
            guard copyFile(from, to, run: run) else { return false }
            _ = chmod(to, info.st_mode & 0o7777)
            let seconds = Double(millis(info)) / 1000
            try? manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: to)
            return true
        case mode_t(S_IFLNK):
            guard let destination = try? manager.destinationOfSymbolicLink(atPath: from) else { return false }
            return (try? manager.createSymbolicLink(atPath: to, withDestinationPath: destination)) != nil
        default:
            // A socket or a pipe: not a file to copy.
            return true
        }
    }

    /// A file's bytes, a MiB at a time (each counted on `run`, which can stop it between them).
    static func copyFile(_ from: String, _ to: String, run: CopyRun) -> Bool {
        guard let input = FileHandle(forReadingAtPath: from) else { return false }
        defer { try? input.close() }
        let fd = open(to, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        while true {
            guard !run.cancelled else { return false }
            // Nil or empty: the end.
            let chunk: Data
            do { chunk = try input.read(upToCount: 1 << 20) ?? Data() } catch { return false }
            if chunk.isEmpty { return true }
            guard (try? output.write(contentsOf: chunk)) != nil else { return false }
            run.add(Int64(chunk.count))
        }
    }
}

/// One running `fs.copy`: its bytes so far said at most every 250 ms (`fs.progress`), and a stop
/// (`fs.cancel`, or the link ending) that ends it at the next MiB.
package final class CopyRun: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var bytes: Int64 = 0
    private var total: Int64 = 0
    private var said = Date.distantPast
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    /// Least time between two `fs.progress`.
    static let every: TimeInterval = 0.25

    package init(progress: (@Sendable (Int64, Int64) -> Void)? = nil) { self.progress = progress }

    package var cancelled: Bool { lock.withLock { stopped } }

    package func cancel() { lock.withLock { stopped = true } }

    func start(total: Int64) { lock.withLock { self.total = total } }

    func add(_ count: Int64) {
        let due: (Int64, Int64)? = lock.withLock {
            bytes += count
            let now = Date()
            guard now.timeIntervalSince(said) >= Self.every else { return nil }
            said = now
            return (bytes, total)
        }
        if let due { progress?(due.0, due.1) }
    }
}
