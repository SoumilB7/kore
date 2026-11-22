import CryptoKit
import Foundation
import HostClient
import KoreCore
import LinkProtocol
import UniformTypeIdentifiers

/// Box files whose renderer needs the file on this Mac (a workbook or document through Quick
/// Look, a PDF, a film, an image past what `fs.read` sends): their bytes over the link
/// (`fs.read {offset}`), kept under Kore's caches by box and path, one place a file so a renderer
/// reloads it where it is. At most `fileCap` a file and `totalCap` in all (the least lately used
/// go first); a box window's go when it closes. Nothing is written on the box.
@MainActor
final class BoxFileCache {
    static let shared = BoxFileCache(root: KoreFolders.caches.appendingPathComponent("box-files", isDirectory: true))

    /// A file past this: "too large to preview here".
    var fileCap: Int64 = 50 << 20
    /// All the copies together.
    var totalCap: Int64 = 500 << 20
    let root: URL

    struct Copy: Equatable {
        let url: URL
        let stamp: FileStamp?
        /// The bytes came now (not the copy already here).
        let fresh: Bool
    }

    private struct Entry {
        let url: URL
        var stamp: FileStamp?
        var bytes: Int64
        var used: UInt64
        var windows: Set<String>
    }

    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var running: [String: Task<Result<Copy, BoxFetchFailure>, Never>] = [:]

    init(root: URL) {
        self.root = root
        // What an earlier run kept: no window holds it now.
        try? FileManager.default.removeItem(at: root)
    }

    /// The renderers that read the file itself and have no text form (`fs.read` sends no bytes of
    /// these, or not all of them).
    static let renderers: Set<String> = [PDFRenderer.id, QuickLookRenderer.id, MediaRenderer.id, ImageRenderer.id]

    /// A box file of this name opens in one of `renderers`.
    static func wants(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: "/" + name)
        let info = FileInfo(url: url, type: UTType(filenameExtension: url.pathExtension), size: 0, head: Data())
        guard let renderer = Renderers.renderer(for: info) else { return false }
        return renderers.contains(renderer.id)
    }

    /// The copy's place: the box's folder, then the path's, the file's own name last (Quick Look
    /// goes by it).
    func place(alias: String, path: String) -> URL {
        let box = String(alias.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(box, isDirectory: true).appendingPathComponent(hash, isDirectory: true)
            .appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// The box file here: the copy kept when the box says it's still that, else its bytes now.
    /// `window`: the box window it's for, which lets it go on close.
    func copy(_ path: String, from source: any BoxFileSource, window: String) async -> Result<Copy, BoxFetchFailure> {
        let key = source.alias + "\u{0}" + path
        if let run = running[key] {
            let result = await run.value
            if case .success = result { entries[key]?.windows.insert(window) }
            return result.map { Copy(url: $0.url, stamp: $0.stamp, fresh: false) }
        }
        let url = place(alias: source.alias, path: path)
        let held = entries[key].flatMap { FileManager.default.fileExists(atPath: $0.url.path) ? $0 : nil }
        let cap = fileCap
        let run = Task { @MainActor () -> Result<Copy, BoxFetchFailure> in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { return .failure(.refused("Kore can't keep a copy of it on this Mac.")) }
            let base = held?.stamp
            return await source.fetch(path, to: url, cap: cap, base: base).map { Copy(url: url, stamp: $0.written ? $0.stamp : base, fresh: $0.written) }
        }
        running[key] = run
        let result = await run.value
        running[key] = nil
        clock += 1
        switch result {
        case .success(let copy):
            var entry = entries[key] ?? Entry(url: url, stamp: nil, bytes: 0, used: 0, windows: [])
            entry.stamp = copy.stamp
            entry.bytes = Self.size(url)
            entry.used = clock
            entry.windows.insert(window)
            entries[key] = entry
            trim(keeping: key)
        case .failure(.tooLarge):
            drop(key)
        case .failure(.refused):
            // A link that dropped: what's shown stays.
            break
        }
        return result
    }

    /// The box window closed: the copies only it held go.
    func windowClosed(_ window: String) {
        for (key, var entry) in entries where entry.windows.contains(window) {
            entry.windows.remove(window)
            if entry.windows.isEmpty { drop(key) } else { entries[key] = entry }
        }
    }

    /// What the copies hold, in bytes.
    var bytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes } }

    /// Kept for this box path now.
    func holds(_ alias: String, _ path: String) -> Bool { entries[alias + "\u{0}" + path] != nil }

    /// Past `totalCap`: the least lately used go, never the one just kept.
    private func trim(keeping key: String) {
        var total = bytes
        guard total > totalCap else { return }
        for (old, entry) in entries.filter({ $0.key != key }).sorted(by: { $0.value.used < $1.value.used }) {
            guard total > totalCap else { break }
            total -= entry.bytes
            drop(old)
        }
    }

    private func drop(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        try? FileManager.default.removeItem(at: entry.url.deletingLastPathComponent())
    }

    private static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
