import Foundation
import LinkProtocol

// Link 1.7 on the Mac's side: a box's folders listed and its files read, for a box window's
// explorer and the Welcome's folder browser (`LinkFiles.swift`). Nothing here runs until asked;
// nothing is kept on this Mac.

/// A folder's listing as the box gave it.
package struct BoxListing: Sendable, Equatable {
    /// The folder, as the box normalised it.
    package var path: String
    package var entries: [FileEntry]
    /// The box stopped at its cap: there's more in the folder than these.
    package var more: Bool

    package init(path: String, entries: [FileEntry], more: Bool) {
        self.path = path
        self.entries = entries
        self.more = more
    }
}

/// A file as `fs.read` found it.
package struct BoxFileRead: Sendable, Equatable {
    package var path: String
    package var kind: FileReadKind
    package var size: Int64
    package var text: String?
    package var image: Data?
    package var truncated: Bool
    /// The file as it was read: what a save checks it against (1.8; nil from an older box).
    package var stamp: FileStamp?

    package init(path: String, kind: FileReadKind, size: Int64, text: String?, image: Data?, truncated: Bool, stamp: FileStamp? = nil) {
        self.stamp = stamp
        self.path = path
        self.kind = kind
        self.size = size
        self.text = text
        self.image = image
        self.truncated = truncated
    }
}

/// What lists and reads a box's files: the link, or a test's stand-in.
@MainActor
package protocol BoxFileSource: AnyObject {
    var alias: String { get }
    func list(_ path: String?, hidden: Bool) async -> Result<BoxListing, HostRefusal>
    func read(_ path: String, max: Int?) async -> Result<BoxFileRead, HostRefusal>
    func makeFolder(_ path: String) async -> Result<String, HostRefusal>
    // 1.8: a served folder's files edited, found and watched.
    func write(_ path: String, _ bytes: Data, base: FileStamp?) async -> Result<FileStamp, BoxWriteFailure>
    func create(_ path: String, folder: Bool) async -> Result<String, HostRefusal>
    func rename(_ from: String, to: String) async -> Result<String, HostRefusal>
    func trash(_ path: String) async -> Result<Void, HostRefusal>
    func search(_ root: String, _ query: String, text: Bool, max: Int) async -> Result<(hits: [FileHit], more: Bool), HostRefusal>
    /// Watches `folders` for `key` (a window), with the other keys' on this box; `changed` gets
    /// the folders that changed. False when the box can't watch them.
    func watch(_ key: String, _ folders: Set<String>, changed: (@MainActor (Set<String>) -> Void)?) async -> Bool
}

/// Why a save didn't go: the file changed on the box since it was read (its stamp now, if it's
/// still there), or the box refused.
package enum BoxWriteFailure: Error, Equatable, Sendable {
    case conflict(FileStamp?)
    case refused(String)
}

extension HostConnection: BoxFileSource {
    package func list(_ path: String?, hidden: Bool) async -> Result<BoxListing, HostRefusal> {
        let result = await files(.fsList, ControlArgs(path: path, hidden: hidden ? true : nil))
        guard result.ok, let entries = result.entries else { return .failure(refusal(result)) }
        return .success(BoxListing(path: result.path ?? path ?? "", entries: entries, more: result.more == true))
    }

    package func read(_ path: String, max: Int? = nil) async -> Result<BoxFileRead, HostRefusal> {
        let result = await files(.fsRead, ControlArgs(path: path, max: max))
        guard result.ok, let kind = result.kind else { return .failure(refusal(result)) }
        return .success(BoxFileRead(
            path: result.path ?? path, kind: kind, size: result.size ?? 0, text: result.text,
            image: result.data.flatMap { Data(base64Encoded: $0) }, truncated: result.truncated == true,
            stamp: result.mtime.map { FileStamp(size: result.size ?? 0, mtime: $0) }))
    }

    /// Text up to `LinkFiles.inlineMax` goes in the command; more (or bytes that aren't UTF-8)
    /// goes as an upload first (12 MB at most).
    package func write(_ path: String, _ bytes: Data, base: FileStamp?) async -> Result<FileStamp, BoxWriteFailure> {
        var args = ControlArgs(path: path, base: base)
        if bytes.count <= LinkFiles.inlineMax, let text = String(data: bytes, encoding: .utf8) {
            args.text = text
        } else {
            guard bytes.count <= LinkUploads.maxSize else { return .failure(.refused("Files can be at most 12 MB.")) }
            switch await upload(bytes, name: (path as NSString).lastPathComponent, mime: "application/octet-stream") {
            case .success(let blob): args.blob = blob
            case .failure(let why): return .failure(.refused(why.message))
            }
        }
        let result = await files(.fsWrite, args)
        if result.code == .conflict { return .failure(.conflict(result.mtime.map { FileStamp(size: result.size ?? 0, mtime: $0) })) }
        guard result.ok else { return .failure(.refused(refusal(result).message)) }
        return .success(FileStamp(size: result.size ?? Int64(bytes.count), mtime: result.mtime ?? 0))
    }

    package func create(_ path: String, folder: Bool) async -> Result<String, HostRefusal> {
        let result = await files(.fsCreate, ControlArgs(path: path, dir: folder ? true : nil))
        return result.ok ? .success(result.path ?? path) : .failure(refusal(result))
    }

    package func rename(_ from: String, to: String) async -> Result<String, HostRefusal> {
        let result = await files(.fsRename, ControlArgs(from: from, to: to))
        return result.ok ? .success(result.path ?? to) : .failure(refusal(result))
    }

    package func trash(_ path: String) async -> Result<Void, HostRefusal> {
        let result = await files(.fsDelete, ControlArgs(path: path))
        return result.ok ? .success(()) : .failure(refusal(result))
    }

    package func search(_ root: String, _ query: String, text: Bool, max: Int) async -> Result<(hits: [FileHit], more: Bool), HostRefusal> {
        let result = await files(.fsSearch, ControlArgs(mode: text ? "text" : "name", max: max, root: root, query: query))
        guard result.ok else { return .failure(refusal(result)) }
        return .success((result.hits ?? [], result.more == true))
    }

    package func watch(_ key: String, _ folders: Set<String>, changed: (@MainActor (Set<String>) -> Void)?) async -> Bool {
        if folders.isEmpty { fileWatchers[key] = nil } else { fileWatchers[key] = (folders, changed) }
        return await sendWatches()
    }

    /// Every window's open folders on this box, as one `fs.watch` (the box keeps one set a link).
    @discardableResult
    package func sendWatches() async -> Bool {
        let all = fileWatchers.values.reduce(into: Set<String>()) { $0.formUnion($1.folders) }
        guard isOnline else { return false }
        let result = await files(.fsWatch, ControlArgs(folders: Array(all.sorted().prefix(LinkFiles.watchMax))))
        return result.ok && result.watching != false && all.count <= LinkFiles.watchMax
    }

    /// `fs.changed`: to each window whose folders it names.
    func filesChanged(_ raw: Data) {
        guard let changed = try? JSONDecoder().decode(FilesChanged.self, from: raw) else { return }
        let folders = Set(changed.folders)
        for watcher in fileWatchers.values {
            let mine = folders.intersection(watcher.folders)
            if !mine.isEmpty { watcher.changed?(mine) }
        }
    }

    package func makeFolder(_ path: String) async -> Result<String, HostRefusal> {
        let result = await files(.fsMkdir, ControlArgs(path: path))
        guard result.ok else { return .failure(refusal(result)) }
        return .success(result.path ?? path)
    }

    /// One `fs.*` command: at once while linked, after the dial while it's connecting; a link that
    /// can't be reached says so at once rather than waiting.
    private func files(_ kind: ControlKind, _ args: ControlArgs) async -> FilesResult {
        switch phase {
        case .refused(let why): return .refused("", .unknown, why.line(alias))
        case .offline, .idle: return .refused("", .unknown, "\(alias) can't be reached")
        case .connecting, .online: break
        }
        let (result, raw) = await commandRaw { HostWire.command(id: $0, .control(kind, args)) }
        if let raw, let decoded = try? JSONDecoder().decode(FilesResult.self, from: raw) { return decoded }
        return FilesResult(id: result.id, ok: result.ok, code: result.code, message: result.message)
    }

    /// The box's words, or what's wrong in Kore's: a box from before 1.7 doesn't know the command.
    private func refusal(_ result: FilesResult) -> HostRefusal {
        if result.ok { return HostRefusal(message: "\(alias) sent nothing") }
        if result.code == .invalid, ["Unknown command.", "Not taken here."].contains(result.message) {
            return HostRefusal(message: "\(alias) needs an update to show files")
        }
        if result.code == .deniedControl { return HostRefusal(message: "Files need a grant with full control on \(alias)") }
        return HostRefusal(message: result.message ?? "\(alias) refused it")
    }
}
