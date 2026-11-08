import Foundation
import KoreCore
import LinkProtocol

// Files and folders copied or moved between any two places Kore shows: a folder on this Mac, a
// folder on a box. On one device a move is a rename and a copy is the device's own copy; across
// devices the bytes go by rsync over the box's SSH alias (box to box: through a folder kept on
// this Mac), streamed, never held in memory. A move across devices copies, checks the copy (its
// files and bytes), and only then sends the source to its trash.

/// Where an entry is: a path on this Mac, or on a box (its alias, and the path there).
package enum FilePlace: Hashable, Sendable {
    case mac(String)
    case box(alias: String, path: String)

    package var path: String {
        switch self {
        case .mac(let path), .box(_, let path): path
        }
    }

    /// The box's alias; nil: this Mac.
    package var alias: String? {
        if case .box(let alias, _) = self { return alias }
        return nil
    }

    package var name: String { (path as NSString).lastPathComponent }

    package var parent: FilePlace { with((path as NSString).deletingLastPathComponent) }

    package func child(_ name: String) -> FilePlace { with(path == "/" ? "/" + name : path + "/" + name) }

    /// The same device, another path.
    package func with(_ path: String) -> FilePlace {
        switch self {
        case .mac: .mac(path)
        case .box(let alias, _): .box(alias: alias, path: path)
        }
    }

    package func sameDevice(_ other: FilePlace) -> Bool { alias == other.alias }

    /// This is `other` or inside it, on the same device.
    package func within(_ other: FilePlace) -> Bool { sameDevice(other) && LinkFiles.inside(path, other.path) }

    /// The device, as a line names it: the alias, or "this Mac".
    package var device: String { alias.map(NodeNames.name) ?? "this Mac" }
}

/// How one entry gets from where it is into a folder.
package enum CarryRoute: String, Sendable, Equatable, CaseIterable {
    /// A move on this Mac: a rename (FileManager).
    case macRename
    /// A copy on this Mac (FileManager).
    case macCopy
    /// A move on one box: `fs.rename`.
    case boxRename
    /// A copy on one box: `fs.copy`.
    case boxCopy
    /// This Mac to a box, and back: rsync over the box's alias.
    case macToBox, boxToMac
    /// One box to another: rsync from one into a folder kept on this Mac, then on into the other.
    case boxToBox

    package static func pick(from source: FilePlace, into folder: FilePlace, move: Bool) -> CarryRoute {
        switch (source, folder) {
        case (.mac, .mac): move ? .macRename : .macCopy
        case (.box(let a, _), .box(let b, _)) where a == b: move ? .boxRename : .boxCopy
        case (.mac, .box): .macToBox
        case (.box, .mac): .boxToMac
        case (.box, .box): .boxToBox
        }
    }

    /// The bytes leave the device they're on.
    package var crossDevice: Bool { [.macToBox, .boxToMac, .boxToBox].contains(self) }

    /// A rename: nothing is copied.
    package var renames: Bool { self == .macRename || self == .boxRename }
}

/// Names Finder gives: a copy in its own folder is "name copy.ext", then "name copy 2.ext"…; a
/// name taken elsewhere is kept as "name 2.ext", "name 3.ext"….
package enum CopyNames {
    package static func free(_ name: String, duplicate: Bool, taken: (String) -> Bool) -> String {
        if !duplicate, !taken(name) { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty || stem.isEmpty ? "" : "." + ext
        let base = stem.isEmpty ? name : stem
        var n = duplicate ? 1 : 2
        while true {
            let candidate = base + (duplicate ? (n == 1 ? " copy" : " copy \(n)") : " \(n)") + suffix
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}

/// What's under an entry: files (a file or a link counts one; folders none), their bytes, and
/// whether the entry itself is a folder. Both ends of a copy across devices must say the same.
package struct CarryCount: Equatable, Sendable, Codable {
    package var files: Int
    package var bytes: Int64
    package var dir: Bool

    package init(files: Int, bytes: Int64, dir: Bool) {
        self.files = files
        self.bytes = bytes
        self.dir = dir
    }

    /// An entry on this Mac, links not followed; nil when it isn't there.
    package static func mac(_ path: String) -> CarryCount? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        var count = CarryCount(files: 0, bytes: 0, dir: false)
        func add(_ info: stat) {
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                count.files += 1
                count.bytes += Int64(info.st_size)
            case S_IFLNK: count.files += 1
            default: break
            }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            add(info)
            return count
        }
        count.dir = true
        var queue = [path]
        while let folder = queue.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                var child = stat()
                guard lstat(folder + "/" + name, &child) == 0 else { continue }
                if child.st_mode & S_IFMT == S_IFDIR { queue.append(folder + "/" + name) } else { add(child) }
            }
        }
        return count
    }
}

/// A box a carry reaches: its files over the link (where each path is checked), and its SSH
/// alias for the bytes.
@MainActor
package struct CarryBox {
    package let alias: String
    package let files: any BoxFileSource
    package let ssh: SyncBox?

    package init(alias: String, files: any BoxFileSource, ssh: SyncBox?) {
        self.alias = alias
        self.files = files
        self.ssh = ssh
    }

    /// Its link is up (a stand-in's always is): a step that failed while it wasn't is gone on
    /// from once it is.
    package var reachable: Bool { (files as? HostConnection)?.isOnline ?? true }

    /// The files and links under a folder, by path inside it: `fs.find` on a 1.12 box, else `find`
    /// over SSH. Nil when it can't be listed (or has more than the box lists).
    package func listing(_ root: String) async -> Set<String>? {
        if files.fsOps2 { return (try? await files.find(root).get()) ?? nil }
        guard let ssh else { return nil }
        let output = await ssh.shell(#"cd "$1" && exec find . \( -type f -o -type l \) -print"#, [root])
        guard output.status == 0 else { return nil }
        return Set(output.out.split(separator: "\n").map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) })
    }

    /// A carry's own partial copy (a landing) gone: to the box's trash on a 1.12 box
    /// (`fs.delete {landing}`); else `rm -rf` over SSH, and the trash when that didn't go.
    /// `there`: whether it's still there.
    package func removeLanding(_ path: String, there: () async -> Bool) async {
        if files.fsOps2 {
            _ = await files.trashLanding(path)
            return
        }
        if let ssh, FileCarry.plain(path) {
            _ = await Spawn().run([ssh.shellArgv(#"exec rm -rf -- "$1""#, [path])])
        }
        // No SSH, or it didn't go: to the box's trash.
        if await there() { _ = await files.trash(path) }
    }
}

/// One entry to carry, and the name it takes in the folder; `replace`: what has that name there
/// goes to its trash once the copy is whole (the user chose so).
package struct CarryItem: Sendable, Equatable {
    package var source: FilePlace
    package var name: String
    package var replace: Bool

    package init(source: FilePlace, name: String? = nil, replace: Bool = false) {
        self.source = source
        self.name = name ?? source.name
        self.replace = replace
    }
}

/// Why a step didn't go, in words for the line.
package struct CarryWhy: Error, Equatable, ExpressibleByStringInterpolation {
    package let text: String
    package init(_ text: String) { self.text = text }
    package init(stringLiteral text: String) { self.text = text }
}

/// How a carry ended: where each entry landed, and the first thing that went wrong.
package struct CarryOutcome: Sendable, Equatable {
    package var landed: [FilePlace] = []
    package var failure: String?
    package var cancelled = false
    /// Paused by the user: what landed is kept, and Resume goes on from it.
    package var paused = false
    /// Stopped by something it goes on after (the link dropped, rsync ended, a quit, a sleep):
    /// what landed is kept, and its checkpoint says it's still running.
    package var interrupted = false

    package init(landed: [FilePlace] = [], failure: String? = nil, cancelled: Bool = false) {
        self.landed = landed
        self.failure = failure
        self.cancelled = cancelled
    }

    /// It can go on from where it stopped.
    package var resumable: Bool { paused || interrupted }
}

/// Copies or moves entries into a folder, one after another, on any pair of places. Every path is
/// checked first (a box's by the box: inside a served folder, no link out); nothing is ever
/// overwritten unless the item says replace; a copy goes into a hidden name in the folder and is
/// renamed when whole. Across devices a move's source goes to its trash only after its copy is
/// counted the same.
///
/// Resumable: its checkpoint (`CarryJournal`) names each item's hidden landing, and a stop of any
/// kind (pause, a dropped link, rsync ending, a failed check) keeps what landed there. A later
/// run from the checkpoint (`init(resuming:)`) goes on from it: rsync `--partial` sends only what
/// isn't there yet, a box's `fs.copy` with `resume` skips the files it finished, box to box both
/// legs do the same through a folder kept on this Mac. Only `cancel` and `discard` remove it.
@MainActor
package final class FileCarry {
    package let items: [CarryItem]
    package let folder: FilePlace
    package let move: Bool
    /// The boxes it reaches, by alias.
    package let boxes: [String: CarryBox]
    /// Its checkpoint, as it goes.
    package private(set) var journal: CarryJournal
    /// Where the checkpoint is written; nil: nowhere (tests).
    package let journals: CarryJournals?
    package var id: UUID { journal.id }
    /// Bytes copied so far, of `total` (every copied item's, once all are checked).
    package private(set) var bytes: Int64 = 0
    package var total: Int64 { totalBytes }
    /// Done so far, 0…1, while bytes cross; nil before.
    package var fraction: Double? { totalBytes > 0 && bytes > 0 ? min(1, Double(bytes) / Double(totalBytes)) : nil }
    /// Told as the bytes move: at most every `tick`, and never while nothing moves.
    package var onProgress: (@MainActor () -> Void)?
    /// What it did, in order (`copy name`, `resume name`, `verify name`, `trash name`…), for tests.
    package private(set) var steps: [String] = []
    /// How often the bytes said so far are read for the progress.
    package var tick: Duration = .milliseconds(250)
    /// How often the bytes landed at an rsync's destination are measured while it runs (macOS's
    /// rsync prints no progress into a pipe): `fs.count` on a box, a walk on this Mac.
    package var pollEvery: Duration = .seconds(2)
    /// How often the checkpoint is written while the bytes move.
    package var saveEvery: TimeInterval = 5
    /// rsync gives up after this long without a byte either way (a link that died quietly).
    package var rsyncTimeout = 60
    /// Measures the bytes at a place in place of `landedBytes` (tests).
    package var measure: (@MainActor (FilePlace) async -> Int64?)?
    /// Measures taken so far (tests).
    package private(set) var polls = 0
    package private(set) var cancelled = false
    package private(set) var paused = false
    package private(set) var interrupted = false
    /// Each item's count, once all are checked (a rename's: none).
    package private(set) var counts: [CarryCount?] = []
    /// rsync passes over one item before a copy that still doesn't count the same fails (a source
    /// that changed while it went is sent again).
    package var passes = 3
    private let spawn = Spawn()
    private let meter = CarryMeter()
    private var boxCopy: BoxCopyRun?
    private var totalBytes: Int64 = 0
    private var doneBytes: Int64 = 0
    /// The bytes the checkpoint said: the bar never goes back below them.
    private var floor: Int64 = 0
    /// Box to box: each leg is half of an item's bytes; the second starts at half.
    private var legBase: Int64 = 0
    private var halve = false
    private var saved = Date.distantPast
    /// From a checkpoint: what a run before left is looked for first.
    private let resuming: Bool

    package convenience init(items: [CarryItem], into folder: FilePlace, move: Bool, boxes: [String: CarryBox], journals: CarryJournals? = nil) {
        self.init(journal: CarryJournal(items: items, into: folder, move: move), boxes: boxes, journals: journals, resuming: false)
    }

    /// Goes on from a checkpoint (a run before it stopped, or Kore quit).
    package convenience init(resuming journal: CarryJournal, boxes: [String: CarryBox], journals: CarryJournals? = nil) {
        self.init(journal: journal, boxes: boxes, journals: journals, resuming: true)
    }

    /// A run of `journal`'s carry; `resuming`: what a run before left is looked for first.
    package init(journal: CarryJournal, boxes: [String: CarryBox], journals: CarryJournals?, resuming: Bool) {
        self.journal = journal
        self.items = journal.items.map(\.carry)
        self.folder = journal.folder
        self.move = journal.move
        self.boxes = boxes
        self.journals = journals
        self.resuming = resuming
    }

    /// Stops it and removes its partial copy; the source stays.
    package func cancel() {
        cancelled = true
        stopRunning()
    }

    /// Stops it, keeping what landed: Resume (a run from its checkpoint) goes on from there.
    package func pause() {
        paused = true
        journal.state = .paused
        stopRunning()
        save()
    }

    /// Stops it for something it goes on after (a dropped link, a quit, a sleep): what landed is
    /// kept and its checkpoint, written now, still says running.
    package func interrupt() {
        interrupted = true
        stopRunning()
        save()
    }

    private func stopRunning() {
        spawn.stop()
        boxCopy?.cancel()
    }

    package func route(_ item: CarryItem) -> CarryRoute { CarryRoute.pick(from: item.source, into: folder, move: move) }

    /// Why a run stopped: something it goes on from, or not.
    private enum Stop: Error {
        case failed(String)
        case interrupted(String)
    }

    /// A step that didn't go: worth going on after when a box it needs can't be reached.
    private func stop(_ why: String) -> Stop {
        boxes.values.contains { !$0.reachable } ? .interrupted(why) : .failed(why)
    }

    /// Asked to stop, as a stop.
    private func halted() -> Stop? {
        if cancelled { return .failed("Cancelled") }
        if paused { return .interrupted("Paused") }
        if interrupted { return .interrupted("Interrupted") }
        return nil
    }

    package func run() async -> CarryOutcome {
        var outcome = CarryOutcome(landed: journal.landed)
        journal.state = .running
        journal.failure = nil
        save()
        log("carry-start", "\(move ? "move" : "copy") \(items.count) into \(folder.device):\(folder.path)\(resuming ? " resume done=\(journal.done) bytes=\(journal.bytes)" : "")")
        // Every place checked before anything moves.
        if let why = await checkFolder() { return await end(outcome, stop(why)) }
        var counts: [CarryCount] = []
        for (index, entry) in journal.items.enumerated() {
            let item = entry.carry
            // Carried already (a move's source may be gone): as counted then.
            if index < journal.done || (index == journal.done && journal.placed), let known = entry.count {
                counts.append(known)
                continue
            }
            if let why = Self.refusal(item, into: folder) { return await end(outcome, .failed(why)) }
            if route(item).renames {
                counts.append(CarryCount(files: 0, bytes: 0, dir: false))
                continue
            }
            switch await count(item.source) {
            case .success(let count):
                counts.append(count)
                journal.items[index].count = count
            case .failure(let why): return await end(outcome, stop(why.text))
            }
        }
        totalBytes = counts.reduce(0) { $0 + $1.bytes }
        self.counts = zip(items, counts).map { route($0.0).renames ? nil : $0.1 }
        doneBytes = counts.prefix(journal.done).reduce(0) { $0 + $1.bytes }
        floor = min(max(journal.bytes, doneBytes), totalBytes)
        bytes = floor
        journal.total = totalBytes
        journal.bytes = bytes
        save()
        onProgress?()
        for index in journal.done..<items.count {
            if let halt = halted() { return await end(outcome, halt) }
            let item = items[index]
            let count = counts[index]
            let result = route(item).renames ? await rename(item) : await copy(index, count: count)
            switch result {
            case .success(let landed):
                outcome.landed.append(landed)
                journal.landed.append(landed)
            case .failure(let stop): return await end(outcome, stop)
            }
            journal.done = index + 1
            journal.placed = false
            doneBytes += count.bytes
            if bytes < doneBytes {
                bytes = doneBytes
                journal.bytes = bytes
                onProgress?()
            }
            save()
        }
        return await end(outcome, nil)
    }

    /// The run's end, as the checkpoint keeps it: done, its checkpoint gone; cancelled, its
    /// partial copy gone too; paused or interrupted, kept to go on; failed, kept for Retry.
    private func end(_ outcome: CarryOutcome, _ stop: Stop?) async -> CarryOutcome {
        var outcome = outcome
        guard let stop else {
            journal.state = .done
            journals?.remove(id)
            removeMacStaging()
            log("carry-end", "done \(outcome.landed.count) bytes=\(bytes)")
            return outcome
        }
        if cancelled {
            outcome.cancelled = true
            outcome.failure = "Cancelled"
            await discard()
            log("carry-end", "cancelled")
            return outcome
        }
        let why: String
        switch stop {
        case .failed(let text), .interrupted(let text): why = text
        }
        outcome.failure = why
        journal.failure = why
        if paused {
            outcome.paused = true
            journal.state = .paused
        } else if case .interrupted = stop {
            outcome.interrupted = true
            journal.state = .running
        } else if interrupted {
            outcome.interrupted = true
            journal.state = .running
        } else {
            journal.state = .failed
        }
        // Refused before anything moved: nothing to go on from on disk (Retry still can).
        if journal.state == .failed, steps.isEmpty, journal.done == 0 {
            journals?.remove(id)
        } else {
            save()
        }
        log("carry-end", "\(journal.state.rawValue) bytes=\(bytes)/\(totalBytes): \(why)")
        return outcome
    }

    /// Its partial copies removed for good, and its checkpoint: Cancel, or a paused or failed
    /// one dismissed. What's wholly carried stays.
    package func discard() async {
        for index in journal.done..<items.count where !route(items[index]).renames {
            if index == journal.done, journal.placed { continue }
            let staged = journal.landing(index)
            await remove(staged)
            if route(items[index]) == .boxCopy { await remove(staged.with(LinkFiles.copyLanding(staged.path))) }
        }
        removeMacStaging()
        journals?.remove(id)
    }

    /// Why an entry can't go into the folder: a folder into itself or below it, or a name that
    /// isn't one.
    package static func refusal(_ item: CarryItem, into folder: FilePlace) -> String? {
        if folder.within(item.source) { return "\(item.source.name) can't go inside itself." }
        if item.name.isEmpty || item.name.contains("/") || item.name == "." || item.name == ".." || item.name.contains("\0") {
            return "\(item.name) isn't a name."
        }
        if case .box = item.source, !Self.plain(item.source.path) { return "\(item.source.path) isn't a path Kore takes." }
        if case .box = folder, !Self.plain(folder.path) { return "\(folder.path) isn't a path Kore takes." }
        return nil
    }

    /// A box path as the box would keep it: absolute, normalised (no `.`, `..` or empty part),
    /// no control characters.
    package static func plain(_ path: String) -> Bool {
        guard LinkFiles.plainPath(path), path != "/", LinkFiles.normalised(path) == path else { return false }
        return !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    // MARK: The checkpoint and the log

    /// The checkpoint now (tests: never without `journals`).
    private func save() {
        guard let journals else { return }
        journal.updated = Date()
        journals.save(journal)
        saved = Date()
    }

    /// The checkpoint while the bytes move: at most every `saveEvery`.
    private func checkpoint() {
        if Date().timeIntervalSince(saved) >= saveEvery { save() }
    }

    /// One line in hosts.log, under the box it reaches.
    private func log(_ event: String, _ detail: String) {
        let alias = folder.alias ?? items.lazy.compactMap(\.source.alias).first ?? "mac"
        HostLog.note(alias, event, String(id.uuidString.prefix(8)).lowercased() + " " + detail)
    }

    /// A box-to-box carry's bytes on this Mac between its legs: beside its checkpoint, or in a
    /// temporary folder when it has none.
    private var macStaging: URL {
        journals?.staging(id) ?? FileManager.default.temporaryDirectory.appendingPathComponent("kore-carry-" + id.uuidString.lowercased(), isDirectory: true)
    }

    private func removeMacStaging() { try? FileManager.default.removeItem(at: macStaging) }

    // MARK: The folder and the counts

    private func checkFolder() async -> String? {
        switch folder {
        case .mac(let path):
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue ? nil : "\(folder.name) isn't a folder on this Mac."
        case .box(let alias, let path):
            guard let box = boxes[alias] else { return "\(NodeNames.name(alias)) can't be reached." }
            guard Self.plain(path) else { return "\(path) isn't a path Kore takes." }
            switch await box.files.count(path) {
            case .success(let count): return count.dir ? nil : "\(folder.name) isn't a folder on \(NodeNames.name(alias))."
            case .failure(let why): return why.message
            }
        }
    }

    private func count(_ place: FilePlace) async -> Result<CarryCount, CarryWhy> {
        switch place {
        case .mac(let path):
            let found = await Task.detached(priority: .userInitiated) { CarryCount.mac(path) }.value
            return found.map { .success($0) } ?? .failure("\(place.name) isn't there any more.")
        case .box(let alias, let path):
            guard let box = boxes[alias] else { return .failure("\(NodeNames.name(alias)) can't be reached.") }
            return await box.files.count(path).mapError { CarryWhy($0.message) }
        }
    }

    // MARK: On one device: a rename

    private func rename(_ item: CarryItem) async -> Result<FilePlace, Stop> {
        let target = folder.child(item.name)
        if item.source == target { return .success(target) }
        steps.append("rename \(item.name)")
        guard item.replace else { return await rename(item.source, to: target).mapError { stop($0.text) } }
        // Beside it first, then what's there to its trash, then into its name.
        let aside = folder.child(Self.hidden(item.name))
        if case .failure(let why) = await rename(item.source, to: aside) { return .failure(stop(why.text)) }
        if case .failure(let why) = await trash(target) {
            _ = await rename(aside, to: item.source)
            return .failure(stop(why.text))
        }
        steps.append("trash \(target.name)")
        return await rename(aside, to: target).mapError { stop($0.text) }
    }

    private func rename(_ from: FilePlace, to: FilePlace) async -> Result<FilePlace, CarryWhy> {
        switch (from, to) {
        case (.mac(let a), .mac(let b)):
            guard !FileManager.default.fileExists(atPath: b) else { return .failure("\(to.name) is already there.") }
            let moved = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try FileManager.default.moveItem(atPath: a, toPath: b)
                    return nil
                } catch { return error.localizedDescription }
            }.value
            return moved.map { .failure(CarryWhy($0)) } ?? .success(to)
        case (.box(let alias, let a), .box(_, let b)):
            guard let box = boxes[alias] else { return .failure("\(NodeNames.name(alias)) can't be reached.") }
            return await box.files.rename(a, to: b).map { _ in to }.mapError { CarryWhy($0.message) }
        default:
            return .failure("Not on one device.")
        }
    }

    // MARK: A copy

    /// Into its hidden landing in the folder, counted the same as the source, what the item
    /// replaces to its trash, renamed into place; then for a move, the source to its trash. From a
    /// checkpoint, what a run before left in the landing is gone on from.
    private func copy(_ index: Int, count: CarryCount) async -> Result<FilePlace, Stop> {
        let item = items[index]
        let route = route(item)
        let staged = journal.landing(index)
        let target = folder.child(item.name)
        // In place before the last stop: its copy checked again, and only then the source goes.
        if index == journal.done, journal.placed {
            steps.append("verify \(item.name)")
            switch await self.count(target) {
            case .success(let there) where there == count: return await trashSource(item, target)
            case .success: return .failure(.failed("\(item.name) on \(folder.device) doesn't match its original any more, so the original stayed."))
            case .failure(let why): return .failure(stop(why.text))
            }
        }
        var whole = false
        if resuming, case .success(let there) = await self.count(staged) {
            whole = there == count
            steps.append("resume \(item.name)")
        } else {
            steps.append("copy \(item.name)")
        }
        // rsync passes: the first sends it; another goes when the copy doesn't count the same
        // (a source that changed meanwhile), sending only what differs.
        var pass = 0
        while true {
            pass += 1
            if !whole, let stop = await transfer(index, item.source, to: staged, route: route, count: count) { return .failure(stop) }
            if let halt = halted() { return .failure(halt) }
            steps.append("verify \(item.name)")
            let source: Result<CarryCount, CarryWhy> = if pass == 1 { .success(count) } else { await self.count(item.source) }
            guard case .success(let expected) = source else { return .failure(stop("\(item.name) isn't there any more.")) }
            switch await self.count(staged) {
            case .success(let copied) where copied == expected:
                whole = true
            case .success(let copied):
                log("carry-verify", "\(item.name) pass \(pass): files \(copied.files)/\(expected.files) bytes \(copied.bytes)/\(expected.bytes)")
                await logDifference(item.source, staged)
                let rsyncs = [.macToBox, .boxToMac, .boxToBox].contains(route)
                if rsyncs, pass < passes {
                    whole = false
                    continue
                }
                return .failure(.failed(Self.mismatch(item.name, on: folder.device, copied: copied, expected: expected)))
            case .failure(let why): return .failure(stop(why.text))
            }
            break
        }
        log("carry-verify", "\(item.name) ok: files \(count.files) bytes \(count.bytes)")
        if item.replace, await exists(target) {
            if case .failure(let why) = await trash(target) { return .failure(stop(why.text)) }
            steps.append("trash \(target.name)")
        }
        if case .failure(let why) = await rename(staged, to: target) { return .failure(stop(why.text)) }
        journal.placed = true
        save()
        try? FileManager.default.removeItem(at: macStaging.appendingPathComponent(journal.items[index].token))
        return await trashSource(item, target)
    }

    /// "The copy of NCDEX on mybox didn't match: 114980 of 115013 files. …", or with the same
    /// files, their bytes exactly ("2123694504 of 2123694510 bytes").
    package static func mismatch(_ name: String, on device: String, copied: CarryCount, expected: CarryCount) -> String {
        let what = copied.files != expected.files ? "\(copied.files) of \(expected.files) files"
            : copied.bytes != expected.bytes ? "\(copied.bytes) of \(expected.bytes) bytes" : "a file where a folder is"
        return "The copy of \(name) on \(device) didn't match: \(what). Nothing was moved; Retry goes on from it."
    }

    /// A move's source to its trash, once its copy is in place: never on doubt.
    private func trashSource(_ item: CarryItem, _ target: FilePlace) async -> Result<FilePlace, Stop> {
        guard move else { return .success(target) }
        steps.append("trash \(item.source.name)")
        guard case .failure(let why) = await trash(item.source) else { return .success(target) }
        if case .interrupted(let text) = stop(why.text) { return .failure(.interrupted(text)) }
        // Gone already: trashed just before the last stop.
        if !(await exists(item.source)) { return .success(target) }
        return .failure(.failed("Copied \(item.name), but its original stayed: \(why.text)"))
    }

    /// The bytes from `source` into `staged`, the way the route goes. Nil when they're all there.
    private func transfer(_ index: Int, _ source: FilePlace, to staged: FilePlace, route: CarryRoute, count: CarryCount) async -> Stop? {
        switch route {
        case .macCopy:
            let (from, to) = (source.path, staged.path)
            let why = await Task.detached(priority: .userInitiated) { () -> String? in
                // What a stopped copy left: made again (a copy on one Mac is quick).
                try? FileManager.default.removeItem(atPath: to)
                do {
                    try FileManager.default.copyItem(atPath: from, toPath: to)
                    return nil
                } catch { return error.localizedDescription }
            }.value
            return why.map { .failed($0) }
        case .boxCopy:
            guard let alias = source.alias, let box = boxes[alias] else { return stop("\(source.device) can't be reached.") }
            // A landing a run before finished but that doesn't count the same: copied again.
            if resuming, await exists(staged) { await remove(staged) }
            let meter = meter
            let run = BoxCopyRun { done, _ in meter.set(done) }
            boxCopy = run
            defer { boxCopy = nil }
            if cancelled || paused || interrupted { run.cancel() }
            let result = await metering { await box.files.copy(source.path, to: staged.path, run: run, resume: true) }
            if case .failure(let why) = result {
                log("carry-copy", "fs.copy \(source.name): \(why.message)")
                return why.message.contains("needs an update") ? .failed(why.message) : .interrupted(why.message)
            }
            return nil
        case .macToBox:
            guard let alias = staged.alias, let ssh = boxes[alias]?.ssh else { return .failed("\(staged.device) isn't an SSH alias Kore can use.") }
            return await rsync(ssh, source.path + (count.dir ? "/" : ""), ssh.spec(staged.path), landing: staged, dir: count.dir)
        case .boxToMac:
            guard let alias = source.alias, let ssh = boxes[alias]?.ssh else { return .failed("\(source.device) isn't an SSH alias Kore can use.") }
            return await rsync(ssh, ssh.spec(source.path + (count.dir ? "/" : "")), staged.path, landing: staged, dir: count.dir)
        case .boxToBox:
            // Two legs, each resumable: box A to a folder kept on this Mac, then on to box B.
            guard let a = source.alias, let b = staged.alias, let from = boxes[a]?.ssh, let to = boxes[b]?.ssh else {
                return .failed("\(source.device) or \(staged.device) isn't an SSH alias Kore can use.")
            }
            let between = macStaging.appendingPathComponent(journal.items[index].token).path
            try? FileManager.default.createDirectory(at: macStaging, withIntermediateDirectories: true)
            let slash = count.dir ? "/" : ""
            defer {
                halve = false
                legBase = 0
            }
            halve = true
            legBase = 0
            if let stop = await rsync(from, from.spec(source.path + slash), between, landing: .mac(between), dir: count.dir) { return stop }
            if let halt = halted() { return halt }
            legBase = count.bytes / 2
            return await rsync(to, between + slash, to.spec(staged.path), landing: staged, dir: count.dir)
        case .macRename, .boxRename:
            return .failed("Not a copy.")
        }
    }

    /// rsync into `landing`, resumable: `--partial` keeps a file cut off halfway for the next run
    /// to finish, what's there already with the same size and time is skipped, and `--delete`
    /// (a folder: only ever the hidden landing) drops what a source no longer has. The bytes
    /// there are measured as it runs, its progress lines read too when it prints any.
    private func rsync(_ ssh: SyncBox, _ from: String, _ to: String, landing: FilePlace, dir: Bool) async -> Stop? {
        let command = ["/usr/bin/rsync", "-a", "--partial", "--timeout=\(rsyncTimeout)", "--progress"] + (dir ? ["--delete"] : [])
            + ssh.rsyncOptions(false) + [from, to]
        let meter = meter
        let parser = RsyncReader()
        let spawn = spawn
        let why = await metering(landing: landing) { await spawn.run([command], output: { meter.set(parser.feed($0)) }) }
        log("carry-rsync", "exit \(spawn.lastStatus) \(landing.device)\(spawn.lastErrors.isEmpty ? "" : ": " + spawn.lastErrors)")
        return why.map { .interrupted($0) }
    }

    /// On a copy that doesn't count the same: the first paths each side lacks, in hosts.log.
    private func logDifference(_ source: FilePlace, _ copy: FilePlace) async {
        guard let want = await listing(source), let have = await listing(copy) else { return }
        let missing = want.subtracting(have).sorted().prefix(5)
        let extra = have.subtracting(want).sorted().prefix(5)
        log("carry-missing", "\(want.count - have.intersection(want).count) missing [\(missing.joined(separator: ", "))] extra [\(extra.joined(separator: ", "))]")
    }

    /// The files and links under a folder, by path inside it: a walk here, the box's own
    /// (`CarryBox.listing`) on a box. Nil when it can't be listed.
    private func listing(_ place: FilePlace) async -> Set<String>? {
        switch place {
        case .mac(let root):
            return await Task.detached(priority: .utility) { () -> Set<String>? in
                guard let walk = FileManager.default.enumerator(atPath: root) else { return nil }
                var found = Set<String>()
                while let path = walk.nextObject() as? String {
                    var info = stat()
                    guard lstat(root + "/" + path, &info) == 0 else { continue }
                    let kind = info.st_mode & S_IFMT
                    if kind == S_IFREG || kind == S_IFLNK { found.insert(path) }
                }
                return found
            }.value
        case .box(let alias, let root):
            return await boxes[alias]?.listing(root)
        }
    }

    /// The bytes at a place now (a folder's files', a file's), nil when it isn't there yet.
    package func landedBytes(_ place: FilePlace) async -> Int64? {
        switch place {
        case .mac(let path):
            return await Task.detached(priority: .utility) { CarryCount.mac(path)?.bytes }.value
        case .box(let alias, let path):
            guard let box = boxes[alias] else { return nil }
            return try? await box.files.count(path).get().bytes
        }
    }

    /// Runs `work`, reading the meter every `tick` for the progress: one number read, no matter
    /// how fast the bytes go. `landing`: measured every `pollEvery` meanwhile, into the meter.
    private func metering<T>(landing: FilePlace? = nil, _ work: @escaping @MainActor () async -> T) async -> T {
        meter.reset()
        let poll = landing.map { place in
            LandedPoll.start(every: pollEvery, into: meter) { [weak self] in
                guard let self else { return nil }
                self.polls += 1
                if let measure = self.measure { return await measure(place) }
                return await self.landedBytes(place)
            }
        }
        defer { poll?.cancel() }
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.tick)
                guard !Task.isCancelled else { return }
                let current = self.halve ? self.meter.value / 2 : self.meter.value
                let now = max(self.floor, min(self.doneBytes + self.legBase + current, self.totalBytes))
                if now != self.bytes {
                    self.bytes = now
                    self.journal.bytes = now
                    self.checkpoint()
                    self.onProgress?()
                }
            }
        }
        defer { ticker.cancel() }
        return await work()
    }

    // MARK: Trash and clean-up

    private func exists(_ place: FilePlace) async -> Bool {
        switch place {
        case .mac(let path): return FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        case .box: return (try? await count(place).get()) != nil
        }
    }

    /// To its trash: the macOS Trash, or the box's (`fs.delete`). Never removed for good.
    private func trash(_ place: FilePlace) async -> Result<Void, CarryWhy> {
        switch place {
        case .mac(let path):
            let why = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    return nil
                } catch { return error.localizedDescription }
            }.value
            return why.map { .failure(CarryWhy($0)) } ?? .success(())
        case .box(let alias, let path):
            guard let box = boxes[alias] else { return .failure("\(NodeNames.name(alias)) can't be reached.") }
            return await box.files.trash(path).mapError { CarryWhy($0.message) }
        }
    }

    /// A partial copy of this carry's own (a hidden name it made) removed for good.
    private func remove(_ place: FilePlace) async {
        guard place.name.contains(".kore-") else { return }
        switch place {
        case .mac(let path):
            await Task.detached { try? FileManager.default.removeItem(atPath: path) }.value
        case .box(let alias, let path):
            guard let box = boxes[alias], (try? await count(place).get()) != nil else { return }
            await box.removeLanding(path) { (try? await self.count(place).get()) != nil }
        }
    }

    /// A name a carry gives a copy on its way (hidden; trees don't show it).
    nonisolated package static func isStaging(_ name: String) -> Bool { LinkFsOps.isLanding(name) }

    /// A hidden name in the same folder, for an entry on its way.
    private static func hidden(_ name: String) -> String { "." + name + ".kore-" + CarryJournal.token() }
}

/// Bytes so far: said by a copy's reader on another thread, or measured where they land
/// (`land`); the higher of the two, read every tick.
package final class CarryMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var landed: Int64 = 0
    package init() {}
    package var value: Int64 { lock.withLock { max(bytes, landed) } }
    package func set(_ value: Int64) { lock.withLock { bytes = value } }
    package func add(_ count: Int64) { lock.withLock { bytes += count } }
    /// Measured at the destination: never lower than before.
    package func land(_ value: Int64) { lock.withLock { landed = max(landed, value) } }
    package func reset() {
        lock.withLock {
            bytes = 0
            landed = 0
        }
    }
}

/// The bytes landed at a copy's destination, measured every `every` while it runs: one measure
/// at a time, into `meter`, until the task is cancelled (when the copy ends).
package enum LandedPoll {
    @MainActor
    package static func start(every: Duration, into meter: CarryMeter, measure: @escaping @MainActor () async -> Int64?) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                if let bytes = await measure(), !Task.isCancelled { meter.land(bytes) }
            }
        }
    }
}

/// rsync's `--progress` lines, as openrsync and rsync print them: per file, "<bytes> <n>% <rate>
/// <time>", redrawn after `\r` while it goes and ended with "(xfer#…)" ("xfr#" in rsync 3) when
/// it's done. Bytes so far: the files done, and the one going.
package struct RsyncProgress: Sendable {
    private var pending: [UInt8] = []
    private var completed: Int64 = 0
    private var current: Int64 = 0

    package init() {}

    package var bytes: Int64 { completed + current }

    package mutating func feed(_ data: Data) {
        for byte in data {
            if byte == 0x0D || byte == 0x0A {
                parse(pending)
                pending.removeAll(keepingCapacity: true)
            } else if pending.count < 4096 {
                pending.append(byte)
            }
        }
    }

    private mutating func parse(_ line: [UInt8]) {
        let text = String(decoding: line, as: UTF8.self)
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2, words[1].hasSuffix("%"), let count = Int64(words[0].replacingOccurrences(of: ",", with: "")) else { return }
        if text.contains("xfer#") || text.contains("xfr#") {
            completed += count
            current = 0
        } else {
            current = count
        }
    }
}

/// `RsyncProgress` fed from the reader's thread.
final class RsyncReader: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = RsyncProgress()
    func feed(_ data: Data) -> Int64 {
        lock.withLock {
            progress.feed(data)
            return progress.bytes
        }
    }
}

/// Processes run to their end, each one's output into the next's input, and stopped at once by
/// `stop`. Their errors go to a scratch file, never a pipe held here.
package final class Spawn: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [Process] = []
    private var stopped = false
    private var status: Int32 = 0
    private var errorLines = ""

    package init() {}

    /// The last run's exit status (the first stage's that failed), and its last few error lines,
    /// for the log.
    package var lastStatus: Int32 { lock.withLock { status } }
    package var lastErrors: String { lock.withLock { errorLines } }

    package func stop() {
        let running: [Process] = lock.withLock {
            stopped = true
            return live
        }
        for process in running where process.isRunning { process.terminate() }
    }

    /// Nil when every stage ended well; else the last thing one said. `output`: the last stage's
    /// output as it comes. `passed`: with two stages, what goes from one to the other runs
    /// through here, counted as it goes (never held: a piece at a time).
    package func run(
        _ stages: [[String]], output: (@Sendable (Data) -> Void)? = nil, passed: (@Sendable (Int) -> Void)? = nil
    ) async -> String? {
        guard !stages.isEmpty, stages.allSatisfy({ !$0.isEmpty }) else { return "Nothing to run." }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kore-carry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var processes: [Process] = []
        var errors: [URL] = []
        var pipes: [Pipe] = []
        var ends: [AsyncStream<Int32>] = []
        // Counted between two stages: the first's output and the second's input are two pipes.
        let pump: (from: Pipe, to: Pipe)? = passed != nil && stages.count == 2 ? (Pipe(), Pipe()) : nil
        let read: Pipe? = output.map { _ in Pipe() }
        for (index, stage) in stages.enumerated() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: stage[0])
            process.arguments = Array(stage.dropFirst())
            let error = scratch.appendingPathComponent("err\(index)")
            FileManager.default.createFile(atPath: error.path, contents: nil)
            errors.append(error)
            process.standardError = try? FileHandle(forWritingTo: error)
            if let pump {
                process.standardInput = index == 0 ? FileHandle.nullDevice : pump.to
            } else {
                process.standardInput = index == 0 ? FileHandle.nullDevice : pipes[index - 1]
            }
            if index < stages.count - 1 {
                if let pump {
                    process.standardOutput = pump.from
                } else {
                    let pipe = Pipe()
                    pipes.append(pipe)
                    process.standardOutput = pipe
                }
            } else {
                process.standardOutput = read ?? FileHandle.nullDevice
            }
            let (end, ended) = AsyncStream<Int32>.makeStream()
            process.terminationHandler = { ended.yield($0.terminationStatus); ended.finish() }
            ends.append(end)
            processes.append(process)
        }
        var started: [Bool] = []
        let go: Bool = lock.withLock {
            guard !stopped else { return false }
            live = processes
            return true
        }
        if go {
            for process in processes {
                do {
                    try process.run()
                    started.append(true)
                } catch {
                    started.append(false)
                }
            }
        }
        // This side's ends of the pipes closed: the reader sees the end when the writer goes.
        for pipe in pipes {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        var readers: [AsyncStream<Void>] = []
        if let pump, let passed {
            try? pump.from.fileHandleForWriting.close()
            try? pump.to.fileHandleForReading.close()
            let (source, sink) = (pump.from.fileHandleForReading, pump.to.fileHandleForWriting)
            // A write after the reader went fails, not SIGPIPE in Kore.
            _ = fcntl(sink.fileDescriptor, F_SETNOSIGPIPE, 1)
            readers.append(Self.background {
                while let piece = try? source.read(upToCount: 256 * 1024), !piece.isEmpty {
                    guard (try? sink.write(contentsOf: piece)) != nil else { break }
                    passed(piece.count)
                }
                try? sink.close()
                try? source.close()
            })
        }
        if let read, let output {
            try? read.fileHandleForWriting.close()
            let source = read.fileHandleForReading
            readers.append(Self.background {
                while let piece = try? source.read(upToCount: 64 * 1024), !piece.isEmpty { output(piece) }
                try? source.close()
            })
        }
        if started.contains(false) { stop() }
        var failed = !go || started.contains(false)
        var exit: Int32 = failed ? -1 : 0
        for (index, end) in ends.enumerated() where index < started.count && started[index] {
            for await status in end where status != 0 {
                failed = true
                if exit == 0 { exit = status }
            }
        }
        for reader in readers {
            for await _ in reader {}
        }
        for process in processes { try? (process.standardError as? FileHandle)?.close() }
        let tail = errors.flatMap { url -> [Substring] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(whereSeparator: \.isNewline).suffix(3)
        }.suffix(3).joined(separator: " | ")
        lock.withLock {
            live = []
            status = exit
            errorLines = String(tail.prefix(600))
        }
        guard failed else { return nil }
        if lock.withLock({ stopped }) { return "Cancelled" }
        let said = errors.reversed().compactMap { url -> String? in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(whereSeparator: \.isNewline).last.map(String.init)
        }.first
        return said ?? "The copy stopped."
    }

    /// `work` on a thread of its own; the stream ends when it does.
    private static func background(_ work: @escaping @Sendable () -> Void) -> AsyncStream<Void> {
        let (stream, done) = AsyncStream<Void>.makeStream()
        Thread.detachNewThread {
            work()
            done.finish()
        }
        return stream
    }
}
