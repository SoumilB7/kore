import Foundation
import KoreCore
import LinkProtocol
import Observation

// Two-way sync of a Mac folder with its copy on a box (`~/Code/<name>`), while that copy's box
// window is open. The Mac's side is watched with FSEvents, the box's by kore-host (`sync.watch`);
// files move with rsync over the same SSH alias. What both sides last agreed on (each file's size
// and whole-second mtime) is kept on disk, sorted, one line a file, and read as a stream: a change
// that brings a side to it is the sync's own write coming back, and is let go. A file changed on
// both sides since is kept twice: the Mac's in place, the box's beside it as `<name> (<box>).<ext>`.

// MARK: - Pairs

/// A Mac folder and its copy on a box.
package struct SyncPair: Codable, Equatable, Hashable, Sendable {
    package var mac: String
    package var alias: String
    /// Absolute, on the box.
    package var box: String
    /// The box copy was made for this pair just now: the first sync makes it the Mac's exactly.
    package var fresh: Bool?

    package init(mac: String, alias: String, box: String, fresh: Bool? = nil) {
        self.mac = mac
        self.alias = alias
        self.box = box
        self.fresh = fresh
    }
}

/// The pairs, in the `syncPairs` default.
package enum SyncPairs {
    static let key = "syncPairs"

    package static func all(_ defaults: UserDefaults = .standard) -> [SyncPair] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SyncPair].self, from: data)) ?? []
    }

    package static func pair(mac: String, _ defaults: UserDefaults = .standard) -> SyncPair? { all(defaults).first { $0.mac == mac } }

    package static func pair(alias: String, box: String, _ defaults: UserDefaults = .standard) -> SyncPair? {
        all(defaults).first { $0.alias == alias && $0.box == box }
    }

    /// Kept, in place of any pair for the same Mac folder.
    package static func save(_ pair: SyncPair, _ defaults: UserDefaults = .standard) {
        let pairs = all(defaults).filter { $0.mac != pair.mac } + [pair]
        defaults.set(try? JSONEncoder().encode(pairs), forKey: key)
    }
}

// MARK: - The box's end

/// How the sync reaches the box's files: over SSH, rsync's name for a path there, and a shell
/// there. No name ever becomes part of a remote command's text: paths and names go as separate
/// words, each quoted by `ShellQuote.single` (the box's shell reads rsync's remote paths too).
package struct SyncBox: Sendable {
    package let alias: String
    /// Where new copies go; nil: `~/Code` on the box.
    package let base: String?
    /// The ssh program and its options, before `--` and the alias.
    let ssh: [String]

    package static let sshOptions = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

    /// `ssh <alias>`, the user's own config and agent. Nil for an alias that isn't one.
    package static func ssh(_ alias: String) -> SyncBox? {
        guard validAlias(alias) else { return nil }
        return SyncBox(alias: alias, base: nil, ssh: ["/usr/bin/ssh"] + sshOptions)
    }

    /// Through another ssh program (tests: one that runs the command here, as sshd's shell would).
    package static func via(_ program: String, alias: String, base: String?) -> SyncBox {
        SyncBox(alias: alias, base: base, ssh: [program])
    }

    /// An SSH alias: letters, digits, `.`, `_`, `-`, not starting with `-`.
    package static func validAlias(_ alias: String) -> Bool {
        !alias.isEmpty && !alias.hasPrefix("-") && alias.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)
        }
    }

    /// rsync's name for a path on the box: the alias, then the path quoted for the box's shell.
    func spec(_ path: String) -> String { alias + ":" + ShellQuote.single(path) }

    func rsyncOptions(_ low: Bool) -> [String] {
        ["-e", (ssh + ["--"]).joined(separator: " ")] + (low ? ["--rsync-path=nice -n 10 rsync"] : [])
    }

    /// Runs `script` under sh on the box, `args` as `$1`…, `input` on its stdin.
    package func shell(_ script: String, _ args: [String] = [], input: Data? = nil, low: Bool = false) async -> SyncProcess.Output {
        let command = (low ? "nice -n 10 " : "") + "sh -c " + ShellQuote.single(script) + " sh" + args.map { " " + ShellQuote.single($0) }.joined()
        return await SyncProcess.run(ssh[0], Array(ssh.dropFirst()) + ["--", alias, command], input: input, low: low)
    }
}

/// A process run to its end: rsync, ssh, git, sort.
package enum SyncProcess {
    package struct Output: Sendable {
        package var status: Int32
        package var out: String
        package var err: String
        /// The last line it said, for a notice.
        package var said: String {
            (err + "\n" + out).split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(status)"
        }
    }

    /// Its output goes to files, not pipes: a pipe's end inherited by a process spawned at the
    /// same moment would hold a read open past this one's exit.
    package static func run(_ executable: String, _ arguments: [String], input: Data? = nil, low: Bool = false, environment: [String: String]? = nil) async -> Output {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kore-sync-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outURL = scratch.appendingPathComponent("out"), errURL = scratch.appendingPathComponent("err"), inURL = scratch.appendingPathComponent("in")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        FileManager.default.createFile(atPath: inURL.path, contents: input ?? Data())
        guard let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL),
            let stdin = try? FileHandle(forReadingFrom: inURL)
        else { return Output(status: -1, out: "", err: "couldn't open a scratch file") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        process.qualityOfService = low ? .utility : .userInitiated
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
        for handle in [out, err, stdin] { try? handle.close() }
        func text(_ url: URL) -> String { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        return Output(status: status, out: text(outURL), err: text(errURL))
    }

}

// MARK: - Line files

/// "path\tsize\tmtime" a line, sorted by the path's bytes (sort(1) under LC_ALL=C): the agreed
/// list and the two sides' lists are read as streams, never held whole.
package enum SyncLines {
    static func line(_ path: String, _ stat: SyncStat) -> String { "\(path)\t\(stat.size)\t\(stat.mtime)\n" }

    static func parse(_ line: Substring) -> (String, SyncStat)? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 3, let size = Int64(parts[1]), let mtime = Int64(parts[2]) else { return nil }
        return (String(parts[0]), SyncStat(size: size, mtime: mtime))
    }


    static func before(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// sort(1) under LC_ALL=C, waited for here (off the main thread).
    static func sortNow(_ file: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sort")
        process.arguments = ["-o", file.path, file.path]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.qualityOfService = .utility
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// Reads a line file in pieces.
    final class Reader {
        private let handle: FileHandle?
        private var buffer = Data()
        private var done = false

        init(_ url: URL) { handle = try? FileHandle(forReadingFrom: url) }
        deinit { try? handle?.close() }

        func next() -> (String, SyncStat)? {
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...end)
                    if let entry = SyncLines.parse(Substring(line)) { return entry }
                    continue
                }
                guard !done, let handle, let more = try? handle.read(upToCount: 64 * 1024), !more.isEmpty else {
                    done = true
                    if buffer.isEmpty { return nil }
                    let line = String(decoding: buffer, as: UTF8.self)
                    buffer = Data()
                    return SyncLines.parse(Substring(line))
                }
                buffer.append(more)
            }
        }
    }

    /// Writes a line file, buffered.
    final class Writer {
        let url: URL
        private let handle: FileHandle?
        private var buffer = Data()

        init(_ url: URL) {
            self.url = url
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }

        func write(_ path: String, _ stat: SyncStat) { raw(SyncLines.line(path, stat)) }

        func raw(_ text: String) {
            buffer.append(Data(text.utf8))
            if buffer.count > 64 * 1024 { flush() }
        }

        private func flush() {
            try? handle?.write(contentsOf: buffer)
            buffer = Data()
        }

        func close() {
            flush()
            try? handle?.close()
        }
    }
}

/// What both sides last agreed on, on disk under `Kore/hosts/<alias>/sync/`.
package final class SyncManifest: @unchecked Sendable {
    package let url: URL

    package init(url: URL) { self.url = url }

    package var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The entries for these paths and anything under them (as folders), and how many entries
    /// there are in all: one pass, each line checked against the set by its own path and its
    /// folders (hashed, never against every path).
    func lookup(_ paths: Set<String>) -> (found: [String: SyncStat], count: Int) {
        var found: [String: SyncStat] = [:]
        var count = 0
        let reader = SyncLines.Reader(url)
        while let (path, stat) = reader.next() {
            count += 1
            guard !paths.isEmpty else { continue }
            if paths.contains(path) {
                found[path] = stat
                continue
            }
            var folder = Substring(path)
            while let slash = folder.lastIndex(of: "/") {
                folder = folder[..<slash]
                if paths.contains(String(folder)) {
                    found[path] = stat
                    break
                }
            }
        }
        return (found, count)
    }

    /// Writes changes in as a stream: a stat, or nil to drop the path.
    func apply(_ changes: [String: SyncStat?]) {
        guard !changes.isEmpty else { return }
        let sorted = changes.keys.sorted(by: SyncLines.before)
        let next = url.appendingPathExtension("new")
        let writer = SyncLines.Writer(next)
        let reader = SyncLines.Reader(url)
        var i = 0
        func emitChanges(before path: String?) {
            while i < sorted.count, path.map({ SyncLines.before(sorted[i], $0) }) ?? true {
                if let stat = changes[sorted[i]] ?? nil { writer.write(sorted[i], stat) }
                i += 1
            }
        }
        while let (path, stat) = reader.next() {
            emitChanges(before: path)
            if i < sorted.count, SyncLines.same(sorted[i], path) {
                if let changed = changes[sorted[i]] ?? nil { writer.write(path, changed) }
                i += 1
            } else {
                writer.write(path, stat)
            }
        }
        emitChanges(before: nil)
        writer.close()
        replace(with: next)
    }

    func replace(with file: URL) {
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: file)
        if !exists { try? FileManager.default.moveItem(at: file, to: url) }
    }
}

// MARK: - A pair's sync

/// One pair's sync while its box window is open: nothing of it runs otherwise. Rounds are decided
/// off the main thread; only their outcome comes back to it.
///
/// It never deletes in bulk on its own: a side that's missing or empty, or a round that would
/// delete more than half of what was agreed (10 files or more), stops with one line and waits for
/// `allowDeletes()`. A path one side leaves out because of an ignore rule is never deleted on the
/// other. On a Mac volume that ignores case, names are compared as it does: a rename that changes
/// only case is a rename, and two box names that differ only by case are left alone.
@MainActor @Observable
package final class HostSync {
    package let pair: SyncPair
    /// One quiet line for the box window: both kept, the box not watching, or why it paused.
    package private(set) var notice: String?
    /// The box watches its copy; when it can't, it lists again on `refresh()`.
    package private(set) var boxWatches = true
    /// A round stopped before deleting this many files: `allowDeletes()` lets it go on.
    package private(set) var askDeletes: Int?

    @ObservationIgnored private let connection: HostConnection
    @ObservationIgnored private let box: SyncBox
    @ObservationIgnored private let tree: SyncTree
    @ObservationIgnored private let manifest: SyncManifest
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let scratch: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let caseless: Bool
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var macPending: Set<String> = []
    /// The box's changes: a file's stat, or nil once it's gone.
    @ObservationIgnored private var boxPending: [String: SyncStat?] = [:]
    /// The box's whole list while its pieces arrive, then while it waits its turn.
    @ObservationIgnored private var listing: SyncLines.Writer?
    @ObservationIgnored private var listed: URL?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var started = false
    /// The whole lists were compared on this link: changes may go one by one.
    @ObservationIgnored private var compared = false
    /// The next round may delete in bulk (the user said so).
    @ObservationIgnored private var deletesAllowed = false
    /// Files moved either way so far, and rounds run (tests: an echo would add to them).
    @ObservationIgnored package private(set) var carried = 0
    @ObservationIgnored package private(set) var rounds = 0
    /// After each round (tests).
    @ObservationIgnored package var onRound: (() -> Void)?
    /// The Mac's watch latency: changes gathered for this long go together.
    @ObservationIgnored package var settle: TimeInterval = 0.3

    /// The pairs syncing now, by Mac folder: one sync per pair, however its windows come and go.
    private static var live: [String: HostSync] = [:]

    /// Nil for a pair whose alias isn't one (`SyncBox.validAlias`).
    package init?(pair: SyncPair, connection: HostConnection, box: SyncBox? = nil, root: URL = HostCache.root(), defaults: UserDefaults = .standard) {
        guard let box = box ?? .ssh(pair.alias) else { return nil }
        self.pair = pair
        self.connection = connection
        self.box = box
        self.defaults = defaults
        tree = SyncTree(root: URL(fileURLWithPath: pair.mac))
        caseless = tree.caseless
        folder = HostCache(alias: pair.alias, root: root).folder.appendingPathComponent("sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = HostCache.safe(StableID.of(pair.mac + "\n" + pair.box, prefix: "p_"))
        manifest = SyncManifest(url: folder.appendingPathComponent(name + ".tsv"))
        scratch = folder.appendingPathComponent(name + ".work", isDirectory: true)
    }

    private var key: String { "sync:" + pair.mac }

    package func start() {
        guard !started else { return }
        // Another sync of this pair (a window closed and opened again quickly) ends first.
        Self.live[pair.mac]?.stop()
        Self.live[pair.mac] = self
        started = true
        // A round cut short (Kore quit) leaves its scratch files: none of them is used again.
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let real = realPath(pair.mac)
        let base = real.hasSuffix("/") ? real : real + "/"
        watcher = FolderWatcher(URL(fileURLWithPath: pair.mac), latency: settle) { [weak self] paths in
            guard let self else { return }
            for path in paths where path.hasPrefix(base) {
                let relative = String(path.dropFirst(base.count))
                // A changed `.gitignore` is read again before the next round decides anything.
                self.tree.forget(relative)
                self.macPending.insert(relative)
            }
            self.kick()
        }
        connection.onSync(pair.box) { [weak self] raw in self?.received(raw) }
        connection.onSnapshot(key) { [weak self] in self?.watch() }
        if connection.isOnline { watch() }
    }

    /// Everything stops: the Mac's watch, the box's, and what was waiting. A round under way
    /// finishes its copy but changes nothing after.
    package func stop() {
        guard started else { return }
        started = false
        if Self.live[pair.mac] === self { Self.live[pair.mac] = nil }
        watcher?.stop()
        watcher = nil
        connection.onSync(pair.box, nil)
        connection.onSnapshot(key, nil)
        if connection.isOnline {
            let folder = pair.box, connection = connection
            Task { _ = await connection.command { HostWire.syncUnwatch(id: $0, folder: folder) } }
        }
        macPending = []
        boxPending = [:]
        listing?.close()
        listing = nil
        listed = nil
    }

    /// The box can't watch its copy: it lists it again now (the window came forward, a turn ended).
    package func refresh() {
        guard started, !boxWatches, listing == nil, listed == nil, connection.isOnline else { return }
        watch()
    }

    /// The user's OK for the bulk delete a round stopped at: the lists are compared again, and
    /// that round may delete.
    package func allowDeletes() {
        guard started, askDeletes != nil else { return }
        askDeletes = nil
        deletesAllowed = true
        notice = nil
        watch()
    }

    /// Asks the box to watch (or list) its copy: its whole list follows.
    private func watch() {
        compared = false
        listing?.close()
        listing = nil
        let folder = pair.box, connection = connection
        Task { [weak self] in
            let result = await connection.command { HostWire.syncWatch(id: $0, folder: folder) }
            if !result.ok, let self, self.started {
                self.notice = result.code == .invalid ? "\(self.pair.alias) can't sync yet · update it" : result.message ?? "Sync paused"
            }
        }
    }

    /// `~/Code/x` as the box window shows it.
    private var shownBox: String {
        let home = pair.box.range(of: "/home/").map { range in pair.box[range.upperBound...].split(separator: "/", maxSplits: 1) }
        return home.flatMap { $0.count == 2 ? "~/" + $0[1] : nil } ?? pair.box
    }

    private var shownMac: String { (pair.mac as NSString).abbreviatingWithTildeInPath }

    private func received(_ raw: Data) {
        guard started, let changed = HostWire.syncChanged(raw) else { return }
        // Every path the box names is checked here: relative, plain parts, no control characters.
        // One that isn't is dropped and said once.
        let paths = changed.paths.filter { SyncPath.valid($0.p) }
        if paths.count < changed.paths.count { notice = "\(pair.alias) sent a path outside the folder" }
        if changed.all == true {
            if changed.missing == true {
                listing?.close()
                listing = nil
                notice = "Sync paused: \(shownBox) is missing on \(pair.alias)"
                return
            }
            if let capped = changed.capped {
                // Too many files to list: no round runs on part of a list.
                listing?.close()
                listing = nil
                notice = "Sync paused: over \(capped.formatted()) files on \(pair.alias)"
                return
            }
            if listing == nil { listing = SyncLines.Writer(scratch.appendingPathComponent("box-\(UUID().uuidString).tsv")) }
            for path in paths where !(path.gone ?? false) {
                listing?.write(path.p, SyncStat(size: path.s ?? 0, mtime: path.m ?? 0))
            }
            guard changed.more != true, let writer = listing else { return }
            writer.close()
            listing = nil
            if let old = listed { try? FileManager.default.removeItem(at: old) }
            listed = writer.url
            boxWatches = changed.watching ?? true
            if !boxWatches {
                let limit = changed.limit.map { $0.formatted() } ?? "?"
                notice = "\(pair.alias) can't watch \((changed.folders ?? 0).formatted())+ folders (limit \(limit)) · syncs on focus"
            }
        } else {
            for path in paths {
                boxPending[path.p] = path.gone == true ? .some(nil) : .some(SyncStat(size: path.s ?? 0, mtime: path.m ?? 0))
            }
        }
        kick()
    }

    /// One round at a time: the whole lists when they're due, else what changed. Box changes that
    /// came while a whole round waited stay for the round after it.
    private func kick() {
        guard started, !running, listing == nil, connection.isOnline else { return }
        if let file = listed {
            listed = nil
            macPending = []
            running = true
            Task {
                await self.whole(file)
                self.compared = true
                self.finished()
            }
        } else if compared, !macPending.isEmpty || !boxPending.isEmpty {
            let mac = macPending, boxSide = boxPending
            macPending = []
            boxPending = [:]
            running = true
            Task {
                await self.changes(mac: mac, box: boxSide)
                self.finished()
            }
        }
    }

    private func finished() {
        running = false
        rounds += 1
        onRound?()
        kick()
    }

    // MARK: Deciding

    nonisolated package enum Act: Equatable, Sendable { case agree, push, pull, deleteMac, deleteBox, both }

    /// What to do with a path: `mac` and `box` as they are, `agreed` as they last agreed.
    /// `seed`: a fresh box copy, made the Mac's exactly.
    nonisolated package static func decide(mac: SyncStat?, box: SyncStat?, agreed: SyncStat?, seed: Bool = false) -> Act {
        if mac == box { return .agree }
        if seed { return mac != nil ? .push : .deleteBox }
        if mac == agreed { return box != nil ? .pull : .deleteMac }
        if box == agreed { return mac != nil ? .push : .deleteBox }
        if mac == nil { return .pull }
        if box == nil { return .push }
        return .both
    }

    // MARK: Rounds

    /// The whole lists, compared as three sorted streams (the Mac's, the box's, the agreed), off
    /// the main thread at low priority: on opening and after the link was down.
    private func whole(_ boxFile: URL) async {
        defer { try? FileManager.default.removeItem(at: boxFile) }
        guard tree.rootExists else {
            notice = "Sync paused: \(shownMac) is missing on this Mac"
            return
        }
        let seed = pair.fresh == true && !manifest.exists
        if seed {
            // Seed mode lasts one listing: a retry after a failed first round treats the box's
            // files as its own (new ones come here, conflicts keep both).
            var settled = pair
            settled.fresh = nil
            SyncPairs.save(settled, defaults)
        }
        tree.forgetAll()
        let work = SyncRound(tree: tree, manifest: manifest, scratch: scratch, alias: pair.alias, caseless: caseless)
        let plan = await Task.detached(priority: .utility) { work.whole(boxFile: boxFile, seed: seed) }.value
        defer { try? FileManager.default.removeItem(at: plan.agreedFile) }
        guard started, allowed(plan, whole: true), await carry(plan, low: true) else { return }
        manifest.replace(with: plan.agreedFile)
    }

    /// The changes since the last round: each changed path against its agreed state, the other
    /// side taken as agreed unless it said otherwise.
    private func changes(mac: Set<String>, box boxSide: [String: SyncStat?]) async {
        let work = SyncRound(tree: tree, manifest: manifest, scratch: scratch, alias: pair.alias, caseless: caseless)
        let plan = await Task.detached(priority: .utility) { work.changes(mac: mac, box: boxSide) }.value
        guard started, allowed(plan, whole: false), await carry(plan, low: false) else { return }
        let manifest = manifest, updates = plan.updates
        await Task.detached(priority: .utility) { manifest.apply(updates) }.value
    }

    /// Whether a round may go ahead: never on an empty side, never a bulk delete without the
    /// user's OK.
    private func allowed(_ plan: SyncPlan, whole: Bool) -> Bool {
        if plan.skippedLinks { notice = "Skipped a path through a link" }
        if let clash = plan.clash { notice = "Can't sync \(clash) to a Mac that ignores case" }
        if whole, plan.agreedBefore > 0 {
            if plan.boxFiles == 0 {
                notice = "Sync paused: \(shownBox) is empty on \(pair.alias)"
                return false
            }
            if plan.macFiles == 0 {
                notice = "Sync paused: \(shownMac) is empty on this Mac"
                return false
            }
        }
        let deletes = max(plan.deleteMac.count, plan.deleteBox.count)
        if !deletesAllowed, deletes >= Self.bulk, deletes * 2 > plan.agreedBefore {
            let side = plan.deleteMac.count >= plan.deleteBox.count ? "this Mac" : pair.alias
            askDeletes = deletes
            notice = "Sync paused: \(deletes.formatted()) files would be deleted on \(side)"
            return false
        }
        deletesAllowed = false
        return true
    }

    /// Deletes from this many files on ask first, when they're over half of what was agreed.
    package static let bulk = 10

    /// Moves the files a round decided on: case-only renames on the Mac first, then the box's
    /// copies of files changed on both, pulls, deletes, pushes. False when something failed (the
    /// agreed list stays as it was).
    private func carry(_ plan: SyncPlan, low: Bool) async -> Bool {
        defer {
            try? FileManager.default.removeItem(at: plan.pushList)
            try? FileManager.default.removeItem(at: plan.pullList)
        }
        let mac = tree.root.path + "/", remote = box.spec(pair.box + "/")
        let rsync = ["-a"] + box.rsyncOptions(low)
        func ok(_ output: SyncProcess.Output) -> Bool {
            // 23/24: a file went between the listing and the copy; the next round sees it.
            guard [0, 23, 24].contains(output.status) else {
                notice = "Sync paused: " + output.said
                return false
            }
            return true
        }
        // rename(2): a case-only rename on a volume that ignores case.
        for (from, to) in plan.renames where tree.plain(from) && tree.plain(to) { _ = rename(tree.url(from).path, tree.url(to).path) }
        // The box's side of files changed on both: pulled by the same list form into a scratch
        // folder, then moved beside the Mac's own. No box path becomes an argument or a
        // destination of its own.
        if !plan.both.isEmpty {
            let landing = scratch.appendingPathComponent("both-\(UUID().uuidString)", isDirectory: true)
            let list = landing.appendingPathExtension("txt")
            defer {
                try? FileManager.default.removeItem(at: landing)
                try? FileManager.default.removeItem(at: list)
            }
            try? FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: list.path, contents: Data(plan.both.map { $0.path + "\n" }.joined().utf8))
            guard ok(await SyncProcess.run("/usr/bin/rsync", rsync + ["--files-from=" + list.path, remote, landing.path + "/"], low: low)) else { return false }
            for (path, copy) in plan.both where tree.plain(copy) {
                let into = tree.url(copy)
                try? FileManager.default.createDirectory(at: into.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: landing.appendingPathComponent(path), to: into)
            }
        }
        if plan.pulls > 0 {
            guard ok(await SyncProcess.run("/usr/bin/rsync", rsync + ["--files-from=" + plan.pullList.path, remote, mac], low: low)) else { return false }
        }
        for path in plan.deleteMac where tree.plain(path) {
            try? FileManager.default.removeItem(at: tree.url(path))
            removeEmptyFolders(above: path)
        }
        if !plan.deleteBox.isEmpty {
            // On the box, a path with a link among its folders is left alone.
            let script = """
                cd -- "$1" || exit 1
                xargs -0 sh -c 'for f; do d=$(dirname -- "$f"); ok=1; while [ "$d" != . ]; do if [ -L "$d" ]; then ok=0; break; fi; d=$(dirname -- "$d"); done; if [ $ok = 1 ] && [ ! -d "$f" ]; then rm -f -- "$f"; fi; done' sh
                """
            guard ok(await box.shell(script, [pair.box], input: Data(plan.deleteBox.joined(separator: "\0").utf8), low: low)) else { return false }
            let folders = Set(plan.deleteBox.compactMap { path in path.lastIndex(of: "/").map { String(path[..<$0]) } })
            if !folders.isEmpty {
                let script = "cd -- \"$1\" && xargs -0 rmdir -p -- 2>/dev/null; true"
                _ = await box.shell(script, [pair.box], input: Data(folders.sorted().joined(separator: "\0").utf8), low: low)
            }
        }
        if plan.pushes > 0 {
            guard ok(await SyncProcess.run("/usr/bin/rsync", rsync + ["--files-from=" + plan.pushList.path, mac, remote], low: low)) else { return false }
        }
        carried += plan.pushes + plan.pulls + plan.both.count + plan.deleteMac.count + plan.deleteBox.count + plan.renames.count
        if let first = plan.both.first {
            notice = plan.both.count == 1
                ? "Kept both: \(URL(fileURLWithPath: first.copy).lastPathComponent)"
                : "Kept both copies of \(plan.both.count) files"
        } else if notice?.hasPrefix("Sync paused") == true {
            notice = nil
        }
        return true
    }

    private func removeEmptyFolders(above path: String) {
        var folder = path
        while let slash = folder.lastIndex(of: "/") {
            folder = String(folder[..<slash])
            let url = tree.url(folder)
            guard ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["x"]).isEmpty else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// A round's decisions, made off the main thread: the lists to copy each way, the deletes, the
/// files kept twice, the Mac's case-only renames, and the agreed state after.
package final class SyncPlan: @unchecked Sendable {
    let pushList: URL
    let pullList: URL
    let push: SyncLines.Writer
    let pull: SyncLines.Writer
    package var pushes = 0, pulls = 0
    package var deleteMac: [String] = []
    package var deleteBox: [String] = []
    /// A path changed on both sides, and where the box's copy goes on the Mac.
    package var both: [(path: String, copy: String)] = []
    /// Mac names whose case the box changed: from, to.
    package var renames: [(from: String, to: String)] = []
    /// The whole round's agreed list (sorted when done); the changes round's updates.
    let agreedFile: URL
    var updates: [String: SyncStat?] = [:]
    /// What was agreed before, and what each side listed (a whole round).
    var agreedBefore = 0
    var macFiles = 0, boxFiles = 0
    package var skippedLinks = false
    /// Two box names that differ only by case ("Foo.swift and foo.swift").
    package var clash: String?

    init(scratch: URL) {
        let id = UUID().uuidString
        pushList = scratch.appendingPathComponent("push-\(id).txt")
        pullList = scratch.appendingPathComponent("pull-\(id).txt")
        agreedFile = scratch.appendingPathComponent("agreed-\(id).tsv")
        push = SyncLines.Writer(pushList)
        pull = SyncLines.Writer(pullList)
    }
}

/// One round's work, off the main thread.
package struct SyncRound: Sendable {
    let tree: SyncTree
    let manifest: SyncManifest
    let scratch: URL
    let alias: String
    let caseless: Bool

    package init(tree: SyncTree, manifest: SyncManifest, scratch: URL, alias: String, caseless: Bool) {
        self.tree = tree
        self.manifest = manifest
        self.scratch = scratch
        self.alias = alias
        self.caseless = caseless
    }

    /// A name as a case-insensitive Mac volume compares it.
    func fold(_ path: String) -> String {
        caseless ? path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil) : path
    }

    package func whole(boxFile: URL, seed: Bool) -> SyncPlan {
        let plan = SyncPlan(scratch: scratch)
        let macFile = scratch.appendingPathComponent("mac-\(UUID().uuidString).tsv")
        defer { try? FileManager.default.removeItem(at: macFile) }
        let writer = SyncLines.Writer(macFile)
        tree.each { path, stat in
            guard SyncPath.valid(path) else { return }
            writer.write(path, stat)
            plan.macFiles += 1
        }
        writer.close()
        SyncLines.sortNow(macFile)
        SyncLines.sortNow(boxFile)
        // The box's names that fold together on this Mac: neither is synced.
        var folds: [String: String] = [:]
        var clashing: Set<String> = []
        let scan = SyncLines.Reader(boxFile)
        while let (path, _) = scan.next() {
            plan.boxFiles += 1
            guard caseless else { continue }
            let folded = fold(path)
            if let other = folds[folded], other != path {
                clashing.insert(folded)
                if plan.clash == nil { plan.clash = "\(other) and \(path)" }
            } else {
                folds[folded] = path
            }
        }
        let agreed = SyncLines.Writer(plan.agreedFile)
        var taken: Set<String> = []
        var pulled: [String: String] = [:]
        let macs = SyncLines.Reader(macFile), boxes = SyncLines.Reader(boxFile), olds = SyncLines.Reader(manifest.url)
        var m = macs.next(), b = boxes.next(), o = olds.next()
        while m != nil || b != nil || o != nil {
            // The least path of the three, and each stream's entry for it.
            var path: String?
            for candidate in [m?.0, b?.0, o?.0].compactMap({ $0 }) where path.map({ SyncLines.before(candidate, $0) }) ?? true { path = candidate }
            guard let path else { break }
            let mac = m.flatMap { SyncLines.same($0.0, path) ? $0.1 : nil }
            let boxStat = b.flatMap { SyncLines.same($0.0, path) ? $0.1 : nil }
            let old = o.flatMap { SyncLines.same($0.0, path) ? $0.1 : nil }
            if mac != nil { m = macs.next() }
            if boxStat != nil { b = boxes.next() }
            if old != nil {
                o = olds.next()
                plan.agreedBefore += 1
            }
            // A path through a link on this Mac, or one of two box names that fold together, is
            // left alone, its agreed state kept.
            guard tree.plain(path), !clashing.contains(fold(path)) else {
                if let old { agreed.write(path, old) }
                if !tree.plain(path) { plan.skippedLinks = true }
                continue
            }
            let act = HostSync.decide(mac: mac, box: boxStat, agreed: old, seed: seed)
            if act == .pull { pulled[fold(path)] = path }
            for (p, stat) in take(act, path, mac: mac, box: boxStat, into: plan, taken: &taken) {
                if let stat { agreed.write(p, stat) }
            }
        }
        caseRenames(plan, pulled: pulled)
        agreed.close()
        SyncLines.sortNow(plan.agreedFile)
        plan.push.close()
        plan.pull.close()
        return plan
    }

    package func changes(mac: Set<String>, box boxSide: [String: SyncStat?]) -> SyncPlan {
        let plan = SyncPlan(scratch: scratch)
        defer {
            plan.push.close()
            plan.pull.close()
        }
        let macTouched = mac.filter { SyncPath.valid($0) && !tree.ignored($0) }
        let touched = macTouched.union(boxSide.keys)
        var paths = Set<String>()
        for path in macTouched {
            paths.insert(path)
            paths.formUnion(tree.list(at: path).keys)
        }
        for (path, stat) in boxSide where stat != nil { paths.insert(path) }
        let (agreed, count) = manifest.lookup(touched)
        plan.agreedBefore = count
        paths.formUnion(agreed.keys)
        func boxNow(_ path: String) -> SyncStat? {
            if let said = boxSide[path] { return said }
            // Under a folder the box said is gone.
            var folder = path
            while let slash = folder.lastIndex(of: "/") {
                folder = String(folder[..<slash])
                if let said = boxSide[folder], said == nil { return nil }
            }
            return agreed[path]
        }
        var taken: Set<String> = []
        var pulled: [String: String] = [:]
        for path in paths.sorted(by: SyncLines.before) where SyncPath.valid(path) {
            guard tree.plain(path) else {
                plan.skippedLinks = true
                continue
            }
            let macNow = tree.stat(path), boxStat = boxNow(path)
            let act = HostSync.decide(mac: macNow, box: boxStat, agreed: agreed[path])
            if act == .agree, macNow == agreed[path] { continue }
            if act == .pull { pulled[fold(path)] = path }
            for (p, stat) in take(act, path, mac: macNow, box: boxStat, into: plan, taken: &taken) { plan.updates[p] = .some(stat) }
        }
        caseRenames(plan, pulled: pulled)
        return plan
    }

    /// On a Mac that ignores case, a delete of a name whose other-case twin is pulled in the same
    /// round is the box renaming it: the Mac renames its file instead of deleting it.
    private func caseRenames(_ plan: SyncPlan, pulled: [String: String]) {
        guard caseless, !pulled.isEmpty else { return }
        plan.deleteMac.removeAll { path in
            guard let to = pulled[fold(path)], to != path else { return false }
            plan.renames.append((path, to))
            return true
        }
    }

    /// Records a decision; the path's agreed state after the round, if any. A path one side left
    /// out because the folder's rules ignore it is never deleted on the other: it leaves the sync.
    private func take(_ act: HostSync.Act, _ path: String, mac: SyncStat?, box: SyncStat?, into plan: SyncPlan, taken: inout Set<String>) -> [(String, SyncStat?)] {
        switch act {
        case .agree:
            return [(path, mac)]
        case .push:
            plan.push.raw(path + "\n")
            plan.pushes += 1
            return [(path, mac)]
        case .pull:
            plan.pull.raw(path + "\n")
            plan.pulls += 1
            return [(path, box)]
        case .deleteMac:
            if !tree.ignored(path) { plan.deleteMac.append(path) }
            return [(path, nil)]
        case .deleteBox:
            if !tree.ignored(path) { plan.deleteBox.append(path) }
            return [(path, nil)]
        case .both:
            let copy = conflictName(path, taken: &taken)
            plan.both.append((path, copy))
            plan.push.raw(path + "\n" + copy + "\n")
            plan.pushes += 2
            return [(path, mac), (copy, box)]
        }
    }

    /// `notes (mybox).md` beside `notes.md`, numbered when that's taken too.
    private func conflictName(_ path: String, taken: inout Set<String>) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        let folder = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) + "/" : ""
        var n = 1
        while true {
            let mark = n == 1 ? alias : "\(alias) \(n)"
            let name = folder + "\(stem) (\(mark))\(ext)"
            if !taken.contains(fold(name)), tree.stat(name) == nil, !FileManager.default.fileExists(atPath: tree.url(name).path) {
                taken.insert(fold(name))
                return name
            }
            n += 1
        }
    }
}

// MARK: - The first copy

/// Set once, on the main actor: which of two racing answers came first.
final class SyncOnce: @unchecked Sendable {
    var done = false
}

extension HostSync {
    /// What a first copy would carry, and whether it fits the box.
    package enum Preflight: Equatable, Sendable {
        case go
        /// Big: asked once ("4.2 GB · 61k files — copy to mybox?").
        case ask(String)
        case refuse(String)
    }

    /// Asked about above this.
    package static let askBytes: Int64 = 1 << 30
    package static let askFiles = 20_000

    /// Counts the Mac folder's carried files and bytes, and asks the box for its free space.
    package static func preflight(mac: URL, box: SyncBox) async -> Preflight {
        let (files, bytes) = await Task.detached(priority: .userInitiated) {
            var files = 0, bytes: Int64 = 0
            SyncTree(root: mac).each { _, stat in
                files += 1
                bytes += stat.size
            }
            return (files, bytes)
        }.value
        let df = await box.shell("df -Pk \"$HOME\" | tail -1")
        let free = df.out.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.flatMap { Int64($0) }.map { $0 * 1024 }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if let free, bytes + bytes / 10 > free {
            return .refuse("Needs \(size) · \(box.alias) has \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
        }
        guard bytes > askBytes || files > askFiles else { return .go }
        let count = files >= 1000 ? "\(files / 1000)k" : "\(files)"
        return .ask("\(size) · \(count) files — copy to \(box.alias)?")
    }

    /// The box copy's name: the folder's, each character outside `[A-Za-z0-9._-]` a dash, never
    /// starting with `.` or `-`.
    package static func boxName(_ mac: URL) -> String {
        let name = String(mac.lastPathComponent.unicodeScalars.map { scalar -> Character in
            let plain = ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || "._-".unicodeScalars.contains(scalar)
            return plain ? Character(scalar) : "-"
        })
        return name.isEmpty || name.hasPrefix(".") || name.hasPrefix("-") ? "folder" + name : name
    }

    /// Why a first copy didn't happen.
    package enum CopyFailure: Error, Equatable, Sendable {
        /// kore-host on the box didn't answer in time.
        case unreachable
        case refused(String)
    }

    /// How long a first copy waits for the box.
    package static let reachWithin: Duration = .seconds(20)

    /// The box copy, made by one script whose names go as its arguments, never in its text.
    static let copyScript = """
        set -e
        base=${1:-"$HOME/Code"}
        mkdir -p -- "$base"
        d="$base/$2"
        n=1
        while [ -e "$d" ] || [ -L "$d" ]; do n=$((n + 1)); d="$base/$2-$n"; done
        if [ -n "$3" ] && GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=https:ssh GIT_SSH_COMMAND='ssh -o BatchMode=yes' git clone -q -- "$3" "$d" >/dev/null 2>&1; then
          cd -- "$d"
          if [ -n "$4" ] && [ -n "$5" ]; then git checkout -q -B "$4" "$5" -- 2>/dev/null || git checkout -q "$4" -- 2>/dev/null || true; fi
        elif [ -n "$3" ]; then
          mkdir -p -- "$d"; cd -- "$d"; git init -q; git remote add origin "$3" 2>/dev/null || true
        elif [ -n "$6" ]; then
          mkdir -p -- "$d"; cd -- "$d"; git init -q
        else
          mkdir -p -- "$d"
        fi
        echo fresh
        cd -- "$d" && pwd
        """

    /// Makes the box copy at `~/Code/<name>` (`<name>-2`, … when that's taken: a copy is never
    /// shared by two Mac folders): `git clone` of the folder's origin at its branch and
    /// commit (`git init` for a repo without one), then has the box serve it, and keeps the pair.
    /// The files themselves go once its window opens (a fresh copy is made the Mac's exactly).
    /// Gives up after `reachWithin` when kore-host doesn't answer.
    package static func firstCopy(mac: URL, connection: HostConnection, box: SyncBox, defaults: UserDefaults = .standard) async -> Result<SyncPair, CopyFailure> {
        guard await reach(connection, within: reachWithin) else { return .failure(.unreachable) }
        let git = await gitState(mac)
        let args = [box.base ?? "", boxName(mac), git.origin ?? "", git.branch ?? "", git.commit ?? "", git.repo ? "repo" : ""]
        let made = await box.shell(copyScript, args)
        guard !Task.isCancelled else { return .failure(.unreachable) }
        let lines = made.out.split(whereSeparator: \.isNewline).map(String.init)
        guard made.status == 0, lines.count >= 2, let path = lines.last, path.hasPrefix("/"),
            !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return .failure(.refused("Couldn't make the copy on \(box.alias): " + made.said)) }
        guard let added = await within(reachWithin, { await connection.addFolder(path) }) else { return .failure(.unreachable) }
        if case .failure(let refusal) = added { return .failure(.refused(refusal.message)) }
        let pair = SyncPair(mac: mac.standardizedFileURL.path, alias: box.alias, box: path, fresh: lines.first == "fresh" ? true : nil)
        SyncPairs.save(pair, defaults)
        return .success(pair)
    }

    /// Waits for the connection to be online, up to `limit`; false on a timeout, a refusal or a cancel.
    static func reach(_ connection: HostConnection, within limit: Duration) async -> Bool {
        let end = ContinuousClock.now + limit
        while !connection.isOnline {
            if case .refused = connection.phase { return false }
            guard ContinuousClock.now < end, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// `work`'s answer, or nil when it hasn't come by `limit`.
    static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @MainActor () async -> T) async -> T? {
        let once = SyncOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task { @MainActor in
                let value = await work()
                if !once.done {
                    once.done = true
                    continuation.resume(returning: value)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if !once.done {
                    once.done = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    struct GitState: Sendable {
        var repo = false
        var origin: String?
        var branch: String?
        var commit: String?
    }

    static func gitState(_ mac: URL) async -> GitState {
        func git(_ args: [String]) async -> String? {
            let out = await SyncProcess.run("/usr/bin/git", ["-C", mac.path] + args)
            let text = out.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.status == 0 && !text.isEmpty ? text : nil
        }
        guard await git(["rev-parse", "--show-toplevel"]).map({ realPath($0) == realPath(mac.path) }) == true else { return GitState() }
        let branch = await git(["rev-parse", "--abbrev-ref", "HEAD"])
        let origin = await git(["remote", "get-url", "origin"])
        let commit = await git(["rev-parse", "HEAD"])
        return GitState(
            repo: true, origin: origin.flatMap { safeOrigin($0) ? $0 : nil },
            branch: branch.flatMap { $0 == "HEAD" || $0.hasPrefix("-") || !SyncPath.valid($0) ? nil : $0 },
            commit: commit.flatMap { $0.count >= 40 && $0.allSatisfy(\.isHexDigit) ? $0 : nil })
    }

    /// An origin the box may clone: not an option, no `ext::`-style transport, one line.
    package static func safeOrigin(_ origin: String) -> Bool {
        !origin.isEmpty && !origin.hasPrefix("-") && !origin.contains("::") && !origin.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
