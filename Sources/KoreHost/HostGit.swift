import Foundation
import KoreCore
import LinkProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Link 1.8's git on the box (`LinkGit.swift`): read-only, on demand. Each root's last status is
/// kept, with what each client was sent of it, so an answer or a push carries only what changed.
/// A root's status runs once at a time; a change it hears of (a turn's end, a command run in a
/// terminal, a file written over the link, the repository's index or HEAD) settles
/// `GitWire.settle`, then one status runs if a client is watching, else the next ask runs it.
/// Nothing polls.
@MainActor
final class HostGit {
    private final class Root {
        let path: String
        /// The folder's place in its work tree; "" at the top. Asked once.
        var prefix: String?
        /// As last read; nil outside a work tree.
        var states: [String: GitWireState]?
        /// Not read yet, or it changed since.
        var stale = true
        var running: Task<Void, Never>?
        var settle: DispatchWorkItem?
        /// Clients watching, and what each was sent.
        var watchers: Set<ObjectIdentifier> = []
        var sent: [ObjectIdentifier: [String: GitWireState]] = [:]
        var clients: [ObjectIdentifier: LinkClient] = [:]
        var gitDir: GitDirWatch?
        /// Diffs and bases run one after another.
        var chain: Task<Void, Never>?

        init(path: String) { self.path = path }
    }

    private var roots: [String: Root] = [:]
    /// Status runs so far (tests, and the measure in the docs).
    private(set) var runs = 0

    // MARK: Status

    /// `git.status`: what `client` hasn't been sent of the root's states.
    func status(_ ask: GitStatusAsk, client: LinkClient, served: [String]) async -> GitStatusResult {
        guard let path = ServedPath.inside(ask.root, served: served, folder: true) else {
            return GitStatusResult(id: ask.id, ok: false, code: .deniedPath, message: "Only folders this box serves.")
        }
        let root = roots[path] ?? Root(path: path)
        roots[path] = root
        let key = ObjectIdentifier(client)
        root.clients[key] = client
        if ask.watch == true {
            root.watchers.insert(key)
            watchGitDir(root)
        } else if ask.watch == false {
            unwatch(root, key)
        }
        guard let states = await read(root) else {
            root.sent[key] = [:]
            return GitStatusResult(id: ask.id, ok: true, root: path, states: GitStates(none: true))
        }
        let delta = GitStates.delta(from: root.sent[key], to: states) ?? GitStates()
        root.sent[key] = states
        return GitStatusResult(id: ask.id, ok: true, root: path, states: capped(delta))
    }

    func unwatch(root path: String, client: LinkClient) {
        guard let root = roots[LinkFiles.normalised(path)] else { return }
        unwatch(root, ObjectIdentifier(client))
    }

    private func unwatch(_ root: Root, _ key: ObjectIdentifier) {
        root.watchers.remove(key)
        if root.watchers.isEmpty {
            root.gitDir?.stop()
            root.gitDir = nil
        }
    }

    /// The link went: its watches and what it was sent go with it.
    func ended(_ client: LinkClient) {
        let key = ObjectIdentifier(client)
        for root in roots.values {
            unwatch(root, key)
            root.sent[key] = nil
            root.clients[key] = nil
        }
    }

    /// Something under `path` may have changed (or in a root under it).
    func touched(_ path: String) {
        let path = LinkFiles.normalised(path)
        for root in roots.values where LinkFiles.inside(path, root.path) || LinkFiles.inside(root.path, path) {
            root.stale = true
            guard !root.watchers.isEmpty else { continue }
            root.settle?.cancel()
            let work = DispatchWorkItem { [weak self, weak root] in
                MainActor.assumeIsolated {
                    guard let self, let root else { return }
                    root.settle = nil
                    Task { await self.push(root) }
                }
            }
            root.settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + GitWire.settle, execute: work)
        }
    }

    /// One status, then each watcher gets what changed for it (nothing when nothing did).
    private func push(_ root: Root) async {
        guard !root.watchers.isEmpty, let states = await read(root) else { return }
        for key in root.watchers {
            guard let client = root.clients[key], let delta = GitStates.delta(from: root.sent[key], to: states) else { continue }
            root.sent[key] = states
            client.sendRaw(StreamWire.encode(GitChanged(root: root.path, states: capped(delta))))
        }
    }

    /// The root's states: kept ones while nothing changed, else one git run, shared by every ask
    /// meanwhile (a change during it marks them stale for the next). nil outside a work tree.
    private func read(_ root: Root) async -> [String: GitWireState]? {
        while let running = root.running { _ = await running.value }
        if !root.stale { return root.states }
        root.stale = false
        let folder = URL(fileURLWithPath: root.path)
        let known = root.prefix
        runs += 1
        let running = Task.detached(priority: .utility) { () -> (states: [String: GitWireState]?, prefix: String?) in
            guard let prefix = known != nil ? known : await GitStatus.prefix(of: folder),
                let states = await GitStatus.states(in: folder, prefix: prefix)
            else { return (nil, nil) }
            return (states.mapValues(GitWireState.init), prefix)
        }
        root.running = Task { _ = await running.value }
        let (states, prefix) = await running.value
        root.running = nil
        root.prefix = prefix
        root.states = states
        return states
    }

    private func capped(_ states: GitStates) -> GitStates {
        guard let set = states.set, set.count > GitWire.statusMax else { return states }
        var cut = states
        cut.set = Dictionary(uniqueKeysWithValues: set.sorted { $0.key < $1.key }.prefix(GitWire.statusMax).map { ($0.key, $0.value) })
        cut.more = true
        return cut
    }

    /// The repository's own folder, watched while a client watches the root: its index or HEAD
    /// moving is a change no file under the root shows.
    private func watchGitDir(_ root: Root) {
        guard root.gitDir == nil else { return }
        let path = root.path
        root.gitDir = GitDirWatch(folder: path) { [weak self] in self?.touched(path) }
    }

    // MARK: Diffs and bases

    /// `git.diff`: the work tree's (or index's) diff under the root.
    func diff(_ ask: GitDiffAsk, served: [String]) async -> GitTextResult {
        guard let rootPath = ServedPath.inside(ask.root, served: served, folder: true) else {
            return .refused(ask.id, .deniedPath, "Only folders this box serves.")
        }
        var relative: String?
        if let path = ask.path {
            let path = LinkFiles.normalised(path)
            guard LinkFiles.inside(path, rootPath), path == rootPath || ServedPath.inside(path, served: served) != nil || !FileManager.default.fileExists(atPath: path)
            else { return .refused(ask.id, .deniedPath, "Only files in the folders this box serves.") }
            relative = path == rootPath ? nil : String(path.dropFirst(rootPath.count + 1))
        }
        let staged = ask.staged == true
        let folder = URL(fileURLWithPath: rootPath)
        let only = relative
        let text = await serial(rootPath) { await GitDiff.text(in: folder, path: only, staged: staged) }
        guard let text else { return .refused(ask.id, .invalid, "Git couldn't read that here.") }
        let (cut, truncated) = Self.cut(text)
        return GitTextResult(id: ask.id, ok: true, diff: cut, truncated: truncated ? true : nil)
    }

    /// `git.lineChanges`: the file's text at HEAD, for the client to diff its own against.
    func lineChanges(_ ask: GitLineChangesAsk, served: [String]) async -> GitTextResult {
        guard let path = ServedPath.inside(ask.path, served: served) else {
            return .refused(ask.id, .deniedPath, "Only files in the folders this box serves.")
        }
        let rootPath = served.map(LinkFiles.normalised).filter { LinkFiles.inside(path, $0) }.max { $0.count < $1.count } ?? path
        let file = URL(fileURLWithPath: path)
        let base = await serial(rootPath) { await GitBaseline.head(of: file) }
        guard let base else { return GitTextResult(id: ask.id, ok: true) }
        guard base.utf8.count <= GitWire.textMax else { return GitTextResult(id: ask.id, ok: true, truncated: true) }
        return GitTextResult(id: ask.id, ok: true, base: base)
    }

    /// Runs `work` after the root's earlier diffs and bases: one at a time per root.
    private func serial<T: Sendable>(_ path: String, _ work: @escaping @Sendable () async -> T) async -> T {
        let root = roots[path] ?? Root(path: path)
        roots[path] = root
        let before = root.chain
        let task = Task.detached(priority: .userInitiated) { () -> T in
            await before?.value
            return await work()
        }
        root.chain = Task { _ = await task.value }
        return await task.value
    }

    private static func cut(_ text: String) -> (String, Bool) {
        guard text.utf8.count > GitWire.textMax else { return (text, false) }
        var bytes = Data(text.utf8.prefix(GitWire.textMax))
        while !bytes.isEmpty, String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return (String(decoding: bytes, as: UTF8.self), true)
    }

    /// Roots known (tests).
    func watching(_ path: String) -> Bool { !(roots[LinkFiles.normalised(path)]?.watchers.isEmpty ?? true) }
}

extension GitWireState {
    init(_ state: GitStatus.State) {
        switch state {
        case .ignored: self = .ignored
        case .untracked: self = .untracked
        case .added: self = .added
        case .renamed: self = .renamed
        case .modified: self = .modified
        case .deleted: self = .deleted
        case .conflicted: self = .conflicted
        }
    }
}

/// A repository's own folder (`.git`, or a worktree's), watched by itself: inotify on Linux,
/// FSEvents on a Mac box. Its lock files and objects aren't changes.
@MainActor
final class GitDirWatch {
    private let changed: @MainActor () -> Void
    #if canImport(Darwin)
    private var watcher: FolderWatcher?
    #else
    private var source: DispatchSourceRead?
    #endif

    init?(folder: String, changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        guard let dir = Self.gitDir(folder) else { return nil }
        #if canImport(Darwin)
        watcher = FolderWatcher(URL(fileURLWithPath: dir), latency: 0.1) { [weak self] paths in
            let telling = paths.contains { path in
                let name = (path as NSString).lastPathComponent
                return !name.hasSuffix(".lock") && !path.contains("/objects/") && !path.contains("/logs/")
            }
            if telling { self?.changed() }
        }
        #else
        let fd = inotify_init1(Int32(O_NONBLOCK | O_CLOEXEC))
        guard fd >= 0 else { return nil }
        // IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE, the folder alone.
        guard inotify_add_watch(fd, dir, 0x8 | 0x80 | 0x100 | 0x200) >= 0 else {
            _ = close(fd)
            return nil
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain(fd) } }
        source.setCancelHandler { _ = close(fd) }
        self.source = source
        source.resume()
        #endif
    }

    func stop() {
        #if canImport(Darwin)
        watcher?.stop()
        watcher = nil
        #else
        source?.cancel()
        source = nil
        #endif
    }

    #if !canImport(Darwin)
    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var telling = false
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, raw.count) }
            guard count > 0 else { break }
            var offset = 0
            while offset + 16 <= count {
                let length = buffer.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self)) }
                let nameBytes = buffer[(offset + 16)..<min(count, offset + 16 + length)].prefix { $0 != 0 }
                let name = String(decoding: nameBytes, as: UTF8.self)
                if !name.hasSuffix(".lock") { telling = true }
                offset += 16 + length
            }
        }
        if telling { changed() }
    }
    #endif

    /// The folder git keeps the repository in, for the work tree at `folder`: `.git` found by
    /// walking up (a worktree's `gitdir:` file followed). No git run.
    static func gitDir(_ folder: String) -> String? {
        var at = folder
        while true {
            let candidate = at + "/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir) {
                if isDir.boolValue { return candidate }
                if let text = try? String(contentsOfFile: candidate, encoding: .utf8), text.hasPrefix("gitdir:") {
                    let dir = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    return dir.hasPrefix("/") ? dir : LinkFiles.normalised(at + "/" + dir)
                }
                return nil
            }
            guard at != "/", !at.isEmpty else { return nil }
            at = (at as NSString).deletingLastPathComponent
        }
    }
}
