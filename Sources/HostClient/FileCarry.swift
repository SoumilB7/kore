import Foundation
import KoreCore
import LinkProtocol

// Files and folders copied or moved between any two places Kore shows: a folder on this Mac, a
// folder on a box. On one device a move is a rename and a copy is the device's own copy; across
// devices the bytes go by rsync over the box's SSH alias (box to box: tar through this Mac),
// streamed, never held here. A move across devices copies, checks the copy (its files and bytes),
// and only then sends the source to its trash.

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
    package var device: String { alias ?? "this Mac" }
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
    /// One box to another: tar from one, through this Mac, into the other.
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
package struct CarryCount: Equatable, Sendable {
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
}

/// Copies or moves entries into a folder, one after another, on any pair of places. Every path is
/// checked first (a box's by the box: inside a served folder, no link out); nothing is ever
/// overwritten unless the item says replace; a copy goes into a hidden name in the folder and is
/// renamed when whole. Across devices a move's source goes to its trash only after its copy is
/// counted the same; a failure or a cancel leaves the source and removes the partial copy.
@MainActor
package final class FileCarry {
    package let items: [CarryItem]
    package let folder: FilePlace
    package let move: Bool
    /// The boxes it reaches, by alias.
    package let boxes: [String: CarryBox]
    /// Done so far, 0…1, while bytes cross; nil before.
    package private(set) var fraction: Double?
    package var onProgress: (@MainActor () -> Void)?
    /// What it did, in order (`copy name`, `verify name`, `trash name`…), for tests.
    package private(set) var steps: [String] = []
    /// How often the copy's bytes are counted for the progress.
    package var poll: Duration = .seconds(1)
    package private(set) var cancelled = false
    /// Each item's count, once all are checked (a rename's: none).
    package private(set) var counts: [CarryCount?] = []
    private let spawn = Spawn()
    private var totalBytes: Int64 = 0
    private var doneBytes: Int64 = 0

    package init(items: [CarryItem], into folder: FilePlace, move: Bool, boxes: [String: CarryBox]) {
        self.items = items
        self.folder = folder
        self.move = move
        self.boxes = boxes
    }

    /// Stops it: the running copy ends, its partial copy goes, its source stays.
    package func cancel() {
        cancelled = true
        spawn.stop()
    }

    package func route(_ item: CarryItem) -> CarryRoute { CarryRoute.pick(from: item.source, into: folder, move: move) }

    package func run() async -> CarryOutcome {
        var outcome = CarryOutcome()
        func fail(_ why: String) -> CarryOutcome {
            outcome.failure = outcome.failure ?? why
            outcome.cancelled = cancelled
            return outcome
        }
        // Every place checked before anything moves.
        if let why = await checkFolder() { return fail(why) }
        var counts: [CarryCount] = []
        for item in items {
            if let why = Self.refusal(item, into: folder) { return fail(why) }
            if route(item).renames {
                counts.append(CarryCount(files: 0, bytes: 0, dir: false))
                continue
            }
            switch await count(item.source) {
            case .success(let count): counts.append(count)
            case .failure(let why): return fail(why.text)
            }
        }
        totalBytes = counts.reduce(0) { $0 + $1.bytes }
        self.counts = zip(items, counts).map { route($0.0).renames ? nil : $0.1 }
        onProgress?()
        for (item, count) in zip(items, counts) {
            if cancelled { return fail("Cancelled") }
            let result = route(item).renames ? await rename(item) : await copy(item, count: count)
            switch result {
            case .success(let landed): outcome.landed.append(landed)
            case .failure(let why): return fail(why.text)
            }
            doneBytes += count.bytes
        }
        return outcome
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

    // MARK: The folder and the counts

    private func checkFolder() async -> String? {
        switch folder {
        case .mac(let path):
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue ? nil : "\(folder.name) isn't a folder on this Mac."
        case .box(let alias, let path):
            guard let box = boxes[alias] else { return "\(alias) can't be reached." }
            guard Self.plain(path) else { return "\(path) isn't a path Kore takes." }
            switch await box.files.count(path) {
            case .success(let count): return count.dir ? nil : "\(folder.name) isn't a folder on \(alias)."
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
            guard let box = boxes[alias] else { return .failure("\(alias) can't be reached.") }
            return await box.files.count(path).mapError { CarryWhy($0.message) }
        }
    }

    // MARK: On one device: a rename

    private func rename(_ item: CarryItem) async -> Result<FilePlace, CarryWhy> {
        let target = folder.child(item.name)
        if item.source == target { return .success(target) }
        steps.append("rename \(item.name)")
        guard item.replace else { return await rename(item.source, to: target) }
        // Beside it first, then what's there to its trash, then into its name.
        let aside = folder.child(Self.hidden(item.name))
        if case .failure(let why) = await rename(item.source, to: aside) { return .failure(why) }
        if case .failure(let why) = await trash(target) {
            _ = await rename(aside, to: item.source)
            return .failure(why)
        }
        steps.append("trash \(target.name)")
        return await rename(aside, to: target)
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
            guard let box = boxes[alias] else { return .failure("\(alias) can't be reached.") }
            return await box.files.rename(a, to: b).map { _ in to }.mapError { CarryWhy($0.message) }
        default:
            return .failure("Not on one device.")
        }
    }

    // MARK: A copy

    /// Into a hidden name in the folder, counted the same as the source, what the item replaces
    /// to its trash, renamed into place; then for a move, the source to its trash.
    private func copy(_ item: CarryItem, count: CarryCount) async -> Result<FilePlace, CarryWhy> {
        let route = route(item)
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        // Box to box lands in a hidden folder of its own (tar names the entry inside it).
        let scratch: FilePlace? = route == .boxToBox ? folder.child(".kore-copy-" + token) : nil
        let staged = scratch.map { $0.child(item.source.name) } ?? folder.child("." + item.name + ".kore-" + token)
        let target = folder.child(item.name)
        steps.append("copy \(item.name)")
        if let why = await transfer(item.source, to: staged, scratch: scratch, route: route, count: count) {
            await remove(scratch ?? staged)
            return .failure(CarryWhy(cancelled ? "Cancelled" : why))
        }
        if cancelled {
            await remove(scratch ?? staged)
            return .failure("Cancelled")
        }
        steps.append("verify \(item.name)")
        switch await self.count(staged) {
        case .success(let copied) where copied == count: break
        case .success(let copied):
            await remove(scratch ?? staged)
            return .failure("The copy of \(item.name) on \(folder.device) didn't match (\(copied.files) of \(count.files) files). Nothing was moved.")
        case .failure(let why):
            await remove(scratch ?? staged)
            return .failure(why)
        }
        if item.replace, await exists(target) {
            if case .failure(let why) = await trash(target) {
                await remove(scratch ?? staged)
                return .failure(why)
            }
            steps.append("trash \(target.name)")
        }
        if case .failure(let why) = await rename(staged, to: target) {
            await remove(scratch ?? staged)
            return .failure(why)
        }
        if let scratch { await remove(scratch) }
        if move {
            steps.append("trash \(item.source.name)")
            if case .failure(let why) = await trash(item.source) {
                return .failure("Copied \(item.name), but its original stayed: \(why.text)")
            }
        }
        return .success(target)
    }

    /// The bytes from `source` into `staged`, the way the route goes. Nil when they're all there.
    private func transfer(_ source: FilePlace, to staged: FilePlace, scratch: FilePlace?, route: CarryRoute, count: CarryCount) async -> String? {
        switch route {
        case .macCopy:
            let (from, to) = (source.path, staged.path)
            return await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try FileManager.default.copyItem(atPath: from, toPath: to)
                    return nil
                } catch { return error.localizedDescription }
            }.value
        case .boxCopy:
            guard let alias = source.alias, let box = boxes[alias] else { return "\(source.device) can't be reached." }
            if case .failure(let why) = await box.files.copy(source.path, to: staged.path) { return why.message }
            return nil
        case .macToBox:
            guard let alias = staged.alias, let ssh = boxes[alias]?.ssh else { return "\(staged.device) isn't an SSH alias Kore can use." }
            let from = source.path + (count.dir ? "/" : "")
            return await watching(staged) { await self.spawn.run([["/usr/bin/rsync", "-a"] + ssh.rsyncOptions(false) + [from, ssh.spec(staged.path)]]) }
        case .boxToMac:
            guard let alias = source.alias, let ssh = boxes[alias]?.ssh else { return "\(source.device) isn't an SSH alias Kore can use." }
            let from = ssh.spec(source.path + (count.dir ? "/" : ""))
            return await watching(staged) { await self.spawn.run([["/usr/bin/rsync", "-a"] + ssh.rsyncOptions(false) + [from, staged.path]]) }
        case .boxToBox:
            guard let a = source.alias, let b = staged.alias, let from = boxes[a]?.ssh, let to = boxes[b]?.ssh, let into = boxes[b], let scratch else {
                return "\(source.device) or \(staged.device) isn't an SSH alias Kore can use."
            }
            if case .failure(let why) = await into.files.create(scratch.path, folder: true) { return why.message }
            let send = from.shellArgv(#"COPYFILE_DISABLE=1 exec tar -C "$1" -cf - "./$2""#, [source.parent.path, source.name])
            let take = to.shellArgv(#"exec tar -C "$1" -xf -"#, [scratch.path])
            return await watching(staged) { await self.spawn.run([send, take]) }
        case .macRename, .boxRename:
            return "Not a copy."
        }
    }

    /// Runs `work`, counting what has reached `staged` meanwhile for the progress.
    private func watching(_ staged: FilePlace, _ work: @escaping @MainActor () async -> String?) async -> String? {
        let total = max(totalBytes, 1)
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.poll)
                guard !Task.isCancelled else { return }
                if case .success(let now) = await self.count(staged) {
                    self.fraction = min(0.99, Double(self.doneBytes + now.bytes) / Double(total))
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
            guard let box = boxes[alias] else { return .failure("\(alias) can't be reached.") }
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
            if let ssh = box.ssh, Self.plain(path) {
                _ = await Spawn().run([ssh.shellArgv(#"exec rm -rf -- "$1""#, [path])])
            } else {
                _ = await box.files.trash(path)
            }
        }
    }

    /// A name a carry gives a copy on its way (hidden; trees don't show it).
    nonisolated package static func isStaging(_ name: String) -> Bool {
        guard name.hasPrefix(".") else { return false }
        if name.hasPrefix(".kore-copy-") { return true }
        guard let range = name.range(of: ".kore-", options: .backwards) else { return false }
        let token = name[range.upperBound...]
        return token.count == 8 && token.allSatisfy(\.isHexDigit)
    }

    /// A hidden name in the same folder, for an entry on its way.
    private static func hidden(_ name: String) -> String { "." + name + ".kore-" + String(UUID().uuidString.prefix(8)).lowercased() }
}

/// Processes run to their end, each one's output into the next's input, and stopped at once by
/// `stop`. Their errors go to a scratch file, never a pipe held here.
package final class Spawn: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [Process] = []
    private var stopped = false

    package init() {}

    package func stop() {
        let running: [Process] = lock.withLock {
            stopped = true
            return live
        }
        for process in running where process.isRunning { process.terminate() }
    }

    /// Nil when every stage ended well; else the last thing one said.
    package func run(_ stages: [[String]]) async -> String? {
        guard !stages.isEmpty, stages.allSatisfy({ !$0.isEmpty }) else { return "Nothing to run." }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kore-carry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var processes: [Process] = []
        var errors: [URL] = []
        var pipes: [Pipe] = []
        var ends: [AsyncStream<Int32>] = []
        for (index, stage) in stages.enumerated() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: stage[0])
            process.arguments = Array(stage.dropFirst())
            let error = scratch.appendingPathComponent("err\(index)")
            FileManager.default.createFile(atPath: error.path, contents: nil)
            errors.append(error)
            process.standardError = try? FileHandle(forWritingTo: error)
            process.standardInput = index == 0 ? FileHandle.nullDevice : pipes[index - 1]
            if index < stages.count - 1 {
                let pipe = Pipe()
                pipes.append(pipe)
                process.standardOutput = pipe
            } else {
                process.standardOutput = FileHandle.nullDevice
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
        if started.contains(false) { stop() }
        var failed = !go || started.contains(false)
        for (index, end) in ends.enumerated() where index < started.count && started[index] {
            for await status in end where status != 0 { failed = true }
        }
        for process in processes { try? (process.standardError as? FileHandle)?.close() }
        lock.withLock { live = [] }
        guard failed else { return nil }
        if lock.withLock({ stopped }) { return "Cancelled" }
        let said = errors.reversed().compactMap { url -> String? in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(whereSeparator: \.isNewline).last.map(String.init)
        }.first
        return said ?? "The copy stopped."
    }
}
