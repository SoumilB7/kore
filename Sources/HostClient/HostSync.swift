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

/// How the sync reaches the box's files: rsync's name for a path there, and a shell there.
package struct SyncBox: Sendable {
    package let alias: String
    /// Where new copies go: `$HOME/Code` on a box.
    package let base: String
    let spec: @Sendable (String) -> String
    let rsyncOptions: @Sendable (_ low: Bool) -> [String]
    package let shell: @Sendable (_ script: String, _ input: Data?, _ low: Bool) async -> SyncProcess.Output

    package static let sshOptions = ["-T", "-o", "BatchMode=yes"]

    /// Over SSH (`ssh <alias>`, the user's own config and agent). Low priority runs under `nice`.
    package static func ssh(_ alias: String) -> SyncBox {
        SyncBox(
            alias: alias, base: "$HOME/Code", spec: { alias + ":" + $0 },
            rsyncOptions: { low in ["-e", "ssh " + sshOptions.joined(separator: " ")] + (low ? ["--rsync-path=nice -n 10 rsync"] : []) },
            shell: { script, input, low in
                let command = (low ? "nice -n 10 " : "") + "sh -c " + SyncProcess.quoted(script)
                return await SyncProcess.run("/usr/bin/ssh", sshOptions + [alias, command], input: input, low: low)
            })
    }

    /// The box's files on this Mac (tests): `base` stands for `~/Code`.
    package static func local(alias: String, base: String) -> SyncBox {
        SyncBox(
            alias: alias, base: base, spec: { $0 }, rsyncOptions: { _ in [] },
            shell: { script, input, low in await SyncProcess.run("/bin/sh", ["-c", script], input: input, low: low) })
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

    /// One word for sh.
    package static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
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

    /// A name a line can carry.
    static func carried(_ path: String) -> Bool { !path.contains("\t") && !path.contains("\n") && !path.contains("\r") }

    static func before(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    static func sort(_ file: URL) async {
        _ = await SyncProcess.run("/usr/bin/sort", ["-o", file.path, file.path], low: true, environment: ["LC_ALL": "C"])
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

    /// The entries for these paths and anything under them (as folders).
    func lookup(_ paths: Set<String>) -> [String: SyncStat] {
        guard !paths.isEmpty else { return [:] }
        let prefixes = paths.map { $0 + "/" }
        var found: [String: SyncStat] = [:]
        let reader = SyncLines.Reader(url)
        while let (path, stat) = reader.next() {
            if paths.contains(path) || prefixes.contains(where: { path.hasPrefix($0) }) { found[path] = stat }
        }
        return found
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

/// One pair's sync while its box window is open: nothing of it runs otherwise.
@MainActor @Observable
package final class HostSync {
    package let pair: SyncPair
    /// One quiet line for the box window: both kept, the box not watching, or why it paused.
    package private(set) var notice: String?
    /// The box watches its copy; when it can't, it lists again on `refresh()`.
    package private(set) var boxWatches = true

    @ObservationIgnored private let connection: HostConnection
    @ObservationIgnored private let box: SyncBox
    @ObservationIgnored private let tree: SyncTree
    @ObservationIgnored private let manifest: SyncManifest
    @ObservationIgnored private let scratch: URL
    @ObservationIgnored private let defaults: UserDefaults
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
    @ObservationIgnored private var serial = 0
    /// Files moved either way so far, and rounds run (tests: an echo would add to them).
    @ObservationIgnored package private(set) var carried = 0
    @ObservationIgnored package private(set) var rounds = 0
    /// After each round (tests).
    @ObservationIgnored package var onRound: (() -> Void)?
    /// The Mac's watch latency: changes gathered for this long go together.
    @ObservationIgnored package var settle: TimeInterval = 0.3

    package init(pair: SyncPair, connection: HostConnection, box: SyncBox? = nil, root: URL = HostCache.root(), defaults: UserDefaults = .standard) {
        self.pair = pair
        self.connection = connection
        self.box = box ?? .ssh(pair.alias)
        self.defaults = defaults
        tree = SyncTree(root: URL(fileURLWithPath: pair.mac))
        let folder = HostCache(alias: pair.alias, root: root).folder.appendingPathComponent("sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = HostCache.safe(StableID.of(pair.mac + "\n" + pair.box, prefix: "p_"))
        manifest = SyncManifest(url: folder.appendingPathComponent(name + ".tsv"))
        scratch = folder.appendingPathComponent(name + ".work", isDirectory: true)
    }

    private var key: String { "sync:" + pair.mac }

    package func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let real = realPath(pair.mac)
        let base = real.hasSuffix("/") ? real : real + "/"
        watcher = FolderWatcher(URL(fileURLWithPath: pair.mac), latency: settle) { [weak self] paths in
            guard let self else { return }
            for path in paths where path.hasPrefix(base) { self.macPending.insert(String(path.dropFirst(base.count))) }
            self.kick()
        }
        connection.onSync(pair.box) { [weak self] raw in self?.received(raw) }
        connection.onSnapshot(key) { [weak self] in self?.watch() }
        if connection.isOnline { watch() }
    }

    /// Everything stops: the Mac's watch, the box's, and what was waiting.
    package func stop() {
        guard started else { return }
        started = false
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
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The box can't watch its copy: it lists it again now (the window came forward, a turn ended).
    package func refresh() {
        guard started, !boxWatches, listing == nil, listed == nil, connection.isOnline else { return }
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

    private func received(_ raw: Data) {
        guard started, let changed = HostWire.syncChanged(raw) else { return }
        if changed.all == true {
            if listing == nil {
                serial += 1
                listing = SyncLines.Writer(scratch.appendingPathComponent("box-\(serial).tsv"))
            }
            for path in changed.paths where !(path.gone ?? false) && SyncLines.carried(path.p) {
                listing?.write(path.p, SyncStat(size: path.s ?? 0, mtime: path.m ?? 0))
            }
            guard changed.more != true, let writer = listing else { return }
            writer.close()
            listing = nil
            listed = writer.url
            boxWatches = changed.watching ?? true
            if !boxWatches {
                let limit = changed.limit.map { $0.formatted() } ?? "?"
                notice = "\(pair.alias) can't watch \((changed.folders ?? 0).formatted())+ folders (limit \(limit)) · syncs on focus"
            }
        } else {
            for path in changed.paths where SyncLines.carried(path.p) {
                boxPending[path.p] = path.gone == true ? .some(nil) : .some(SyncStat(size: path.s ?? 0, mtime: path.m ?? 0))
            }
        }
        kick()
    }

    /// One round at a time: the whole lists when they're due, else what changed.
    private func kick() {
        guard started, !running, listing == nil, connection.isOnline else { return }
        if let file = listed {
            listed = nil
            macPending = []
            boxPending = [:]
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

    package enum Act: Equatable { case agree, push, pull, deleteMac, deleteBox, both }

    /// What to do with a path: `mac` and `box` as they are, `agreed` as they last agreed.
    /// `seed`: a fresh box copy, made the Mac's exactly.
    package static func decide(mac: SyncStat?, box: SyncStat?, agreed: SyncStat?, seed: Bool = false) -> Act {
        if mac == box { return .agree }
        if seed { return mac != nil ? .push : .deleteBox }
        if mac == agreed { return box != nil ? .pull : .deleteMac }
        if box == agreed { return mac != nil ? .push : .deleteBox }
        if mac == nil { return .pull }
        if box == nil { return .push }
        return .both
    }

    /// What a round does, built as it decides.
    private final class Round {
        let push: SyncLines.Writer
        let pull: SyncLines.Writer
        var pushes = 0, pulls = 0
        var deleteMac: [String] = []
        var deleteBox: [String] = []
        /// A path changed on both sides, and where the box's copy goes on the Mac.
        var both: [(path: String, copy: String)] = []

        init(_ scratch: URL, _ n: Int) {
            push = SyncLines.Writer(scratch.appendingPathComponent("push-\(n).txt"))
            pull = SyncLines.Writer(scratch.appendingPathComponent("pull-\(n).txt"))
        }
    }

    /// Records a decision; the path's agreed state after the round, if any.
    private func take(_ act: Act, _ path: String, mac: SyncStat?, box: SyncStat?, into round: Round, taken: inout Set<String>) -> [(String, SyncStat?)] {
        switch act {
        case .agree:
            return [(path, mac)]
        case .push:
            round.push.raw(path + "\n")
            round.pushes += 1
            return [(path, mac)]
        case .pull:
            round.pull.raw(path + "\n")
            round.pulls += 1
            return [(path, box)]
        case .deleteMac:
            round.deleteMac.append(path)
            return [(path, nil)]
        case .deleteBox:
            round.deleteBox.append(path)
            return [(path, nil)]
        case .both:
            let copy = conflictName(path, taken: &taken)
            round.both.append((path, copy))
            round.push.raw(path + "\n" + copy + "\n")
            round.pushes += 2
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
            let mark = n == 1 ? pair.alias : "\(pair.alias) \(n)"
            let name = folder + "\(stem) (\(mark))\(ext)"
            if !taken.contains(name), tree.stat(name) == nil, !FileManager.default.fileExists(atPath: tree.url(name).path) {
                taken.insert(name)
                return name
            }
            n += 1
        }
    }

    // MARK: Rounds

    /// The whole lists, compared as three sorted streams (the Mac's, the box's, the agreed), at low
    /// priority: on opening and after the link was down.
    private func whole(_ boxFile: URL) async {
        serial += 1
        let n = serial
        let macFile = scratch.appendingPathComponent("mac-\(n).tsv")
        let tree = tree
        await Task.detached(priority: .utility) {
            let writer = SyncLines.Writer(macFile)
            tree.each { path, stat in if SyncLines.carried(path) { writer.write(path, stat) } }
            writer.close()
        }.value
        await SyncLines.sort(macFile)
        await SyncLines.sort(boxFile)
        let seed = pair.fresh == true && !manifest.exists
        let round = Round(scratch, n)
        let agreedFile = scratch.appendingPathComponent("agreed-\(n).tsv")
        let agreed = SyncLines.Writer(agreedFile)
        var taken: Set<String> = []
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
            if old != nil { o = olds.next() }
            let act = Self.decide(mac: mac, box: boxStat, agreed: old, seed: seed)
            for (p, stat) in take(act, path, mac: mac, box: boxStat, into: round, taken: &taken) {
                if let stat { agreed.write(p, stat) }
            }
        }
        agreed.close()
        await SyncLines.sort(agreedFile)
        if await carry(round, low: true) {
            manifest.replace(with: agreedFile)
            if seed {
                var settled = pair
                settled.fresh = nil
                SyncPairs.save(settled, defaults)
            }
        }
        for file in [macFile, boxFile, agreedFile] { try? FileManager.default.removeItem(at: file) }
    }

    /// The changes since the last round: each changed path against its agreed state, the other
    /// side taken as agreed unless it said otherwise.
    private func changes(mac: Set<String>, box boxSide: [String: SyncStat?]) async {
        serial += 1
        let round = Round(scratch, serial)
        let touched = Set(mac.filter { !tree.ignored($0) }).union(boxSide.keys)
        var paths = Set<String>()
        for path in mac where !tree.ignored(path) {
            paths.insert(path)
            paths.formUnion(tree.list(at: path).keys)
        }
        for (path, stat) in boxSide where stat != nil { paths.insert(path) }
        let agreed = manifest.lookup(touched)
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
        var updates: [String: SyncStat?] = [:]
        var taken: Set<String> = []
        for path in paths.sorted(by: SyncLines.before) where SyncLines.carried(path) {
            let macStat = tree.stat(path), boxStat = boxNow(path)
            let act = Self.decide(mac: macStat, box: boxStat, agreed: agreed[path])
            if act == .agree, macStat == agreed[path] { continue }
            for (p, stat) in take(act, path, mac: macStat, box: boxStat, into: round, taken: &taken) { updates[p] = .some(stat) }
        }
        if await carry(round, low: false) { manifest.apply(updates) }
    }

    /// Moves the files a round decided on: the box's copies of files changed on both sides first,
    /// then pulls, deletes, pushes. False when something failed (the agreed list stays as it was).
    private func carry(_ round: Round, low: Bool) async -> Bool {
        round.push.close()
        round.pull.close()
        defer {
            try? FileManager.default.removeItem(at: round.push.url)
            try? FileManager.default.removeItem(at: round.pull.url)
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
        for (path, copy) in round.both {
            guard ok(await SyncProcess.run("/usr/bin/rsync", rsync + [box.spec(pair.box + "/" + path), mac + copy], low: low)) else { return false }
        }
        if round.pulls > 0 {
            guard ok(await SyncProcess.run("/usr/bin/rsync", rsync + ["--files-from=" + round.pull.url.path, remote, mac], low: low)) else { return false }
        }
        for path in round.deleteMac {
            try? FileManager.default.removeItem(at: tree.url(path))
            removeEmptyFolders(above: path)
        }
        if !round.deleteBox.isEmpty {
            let list = Data(round.deleteBox.joined(separator: "\0").utf8)
            let script = "cd " + SyncProcess.quoted(pair.box) + " && xargs -0 rm -f -- && true"
            guard ok(await box.shell(script, list, low)) else { return false }
            let folders = Set(round.deleteBox.compactMap { path in path.lastIndex(of: "/").map { String(path[..<$0]) } })
            if !folders.isEmpty {
                let script = "cd " + SyncProcess.quoted(pair.box) + " && xargs -0 rmdir -p 2>/dev/null; true"
                _ = await box.shell(script, Data(folders.sorted().joined(separator: "\0").utf8), low)
            }
        }
        if round.pushes > 0 {
            guard ok(await SyncProcess.run("/usr/bin/rsync", rsync + ["--files-from=" + round.push.url.path, mac, remote], low: low)) else { return false }
        }
        carried += round.pushes + round.pulls + round.both.count + round.deleteMac.count + round.deleteBox.count
        if let first = round.both.first {
            notice = round.both.count == 1
                ? "Kept both: \(URL(fileURLWithPath: first.copy).lastPathComponent)"
                : "Kept both copies of \(round.both.count) files"
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

// MARK: - The first copy

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
        let df = await box.shell("df -Pk \"$HOME\" | tail -1", nil, false)
        let free = df.out.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.flatMap { Int64($0) }.map { $0 * 1024 }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if let free, bytes + bytes / 10 > free {
            return .refuse("Needs \(size) · \(box.alias) has \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
        }
        guard bytes > askBytes || files > askFiles else { return .go }
        let count = files >= 1000 ? "\(files / 1000)k" : "\(files)"
        return .ask("\(size) · \(count) files — copy to \(box.alias)?")
    }

    /// The box copy's name: the folder's, spaces as dashes.
    package static func boxName(_ mac: URL) -> String {
        let name = mac.lastPathComponent.replacingOccurrences(of: " ", with: "-")
        return name.isEmpty || name.hasPrefix(".") ? "folder" + name : name
    }

    /// Makes the box copy at `<base>/<name>`: `git clone` of the folder's origin at its branch and
    /// commit (`git init` for a repo without one), then has the box serve it, and keeps the pair.
    /// The files themselves go once its window opens (a fresh copy is made the Mac's exactly).
    package static func firstCopy(mac: URL, connection: HostConnection, box: SyncBox, defaults: UserDefaults = .standard) async -> Result<SyncPair, HostRefusal> {
        let git = await gitState(mac)
        var script = "set -e\nmkdir -p \"\(box.base)\"\nd=\"\(box.base)/\(boxName(mac))\"\n"
        script += "if [ -e \"$d\" ]; then echo existed; else\n"
        if let origin = git.origin {
            let q = SyncProcess.quoted(origin)
            script += "if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git clone -q \(q) \"$d\" >/dev/null 2>&1; then\n"
            script += "cd \"$d\"\n"
            if let branch = git.branch, let commit = git.commit {
                script += "git checkout -q -B \(SyncProcess.quoted(branch)) \(commit) 2>/dev/null || git checkout -q \(SyncProcess.quoted(branch)) 2>/dev/null || true\n"
            }
            script += "else mkdir -p \"$d\"; cd \"$d\"; git init -q; git remote add origin \(q); fi\n"
        } else if git.repo {
            script += "mkdir -p \"$d\"; cd \"$d\"; git init -q\n"
        } else {
            script += "mkdir -p \"$d\"\n"
        }
        script += "echo fresh\nfi\ncd \"$d\" && pwd\n"
        let made = await box.shell(script, nil, false)
        let lines = made.out.split(whereSeparator: \.isNewline).map(String.init)
        guard made.status == 0, lines.count >= 2, let path = lines.last, path.hasPrefix("/") else {
            return .failure(HostRefusal(message: "Couldn't make the copy on \(box.alias): " + made.said))
        }
        if case .failure(let refusal) = await connection.addFolder(path) { return .failure(refusal) }
        let pair = SyncPair(mac: mac.standardizedFileURL.path, alias: box.alias, box: path, fresh: lines.first == "fresh" ? true : nil)
        SyncPairs.save(pair, defaults)
        return .success(pair)
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
        return GitState(
            repo: true, origin: await git(["remote", "get-url", "origin"]), branch: branch == "HEAD" ? nil : branch,
            commit: await git(["rev-parse", "HEAD"]))
    }
}
