import Foundation
import KoreCore
import LinkProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Link 1.8: a served folder's files edited from the Mac's explorer and editor. Every path is
/// inside a served folder (never the home alone), and its folder's real place stays inside it:
/// a link is renamed or trashed as itself, and written through only when it leads inside.
/// Nothing is ever removed for good: a delete moves to the box's trash.
extension HostFiles {
    /// Where a deleted entry goes: the freedesktop trash (`~/.local/share/Trash`, Linux) or
    /// `~/.Trash` (a Mac box).
    package enum Trash: Sendable {
        case freedesktop(String)
        case mac(String)

        package static func standard(home: String, env: [String: String] = ProcessInfo.processInfo.environment) -> Trash {
            #if os(macOS)
            return .mac(home + "/.Trash")
            #else
            let data = env["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/.local/share"
            return .freedesktop(data + "/Trash")
            #endif
        }
    }

    // MARK: Commands

    /// Writes a file whole (temp file, then rename), keeping its permissions. With `base`, the file
    /// has to be as the client read it, else `conflict`. `bytes` are the text's or the upload's.
    package func write(id: String, path: String, bytes: Data, base: FileStamp?) -> FilesResult {
        let entry: (path: String, real: String)
        switch self.entry(path) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): entry = found
        }
        var target = entry.real
        var mode: mode_t = 0o644
        if let found = Self.look(target) {
            if found.kind == .link {
                // Written through only when it leads inside the folder.
                guard let real = Self.real(target), roots(entry.path, .served).contains(where: { LinkFiles.inside(real, Self.real($0) ?? $0) }),
                    Self.look(real)?.kind == .file
                else { return .refused(id, .deniedPath, "A link out of the folder, not followed.") }
                target = real
            }
            guard let now = Self.look(target), now.kind == .file else { return .refused(id, .invalid, "Not a file.") }
            if let base, base != FileStamp(size: now.size ?? -1, mtime: now.mtime) {
                return FilesResult(id: id, ok: false, code: .conflict, message: "Changed on the box since it was read.", size: now.size, mtime: now.mtime)
            }
            if let info = linkInfo(target) { mode = info.st_mode & 0o7777 }
        } else if base != nil {
            return .refused(id, .conflict, "Deleted on the box since it was read.")
        }
        let folder = (target as NSString).deletingLastPathComponent
        let temp = folder + "/." + (target as NSString).lastPathComponent + ".kore-" + String(UUID().uuidString.prefix(8))
        guard FileManager.default.createFile(atPath: temp, contents: bytes, attributes: [.posixPermissions: Int(mode)]) else {
            return .refused(id, .deniedPath, "Can't write there on this box.")
        }
        guard FileCalls.rename(temp, target) == 0 else {
            unlink(temp)
            return .refused(id, .deniedPath, "Can't write there on this box.")
        }
        let now = Self.look(target)
        return FilesResult(id: id, ok: true, path: entry.path, size: now?.size, mtime: now?.mtime)
    }

    /// A new empty file, or a folder (`dir`). Nothing is replaced.
    package func create(id: String, path: String, dir: Bool) -> FilesResult {
        let entry: (path: String, real: String)
        switch self.entry(path) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): entry = found
        }
        let name = (entry.path as NSString).lastPathComponent
        if Self.look(entry.real) != nil { return .refused(id, .invalid, "\(name) is already there.") }
        if dir {
            guard FileCalls.mkdir(entry.real, 0o755) == 0 else { return .refused(id, .deniedPath, "Can't make \(name) there.") }
        } else {
            let fd = open(entry.real, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0 else { return .refused(id, .deniedPath, "Can't make \(name) there.") }
            close(fd)
        }
        let made = Self.look(entry.real)
        return FilesResult(id: id, ok: true, path: entry.path, size: made?.size, mtime: made?.mtime)
    }

    /// Renames or moves an entry (a link as itself) within the served folders. Nothing is replaced.
    package func rename(id: String, from: String, to: String) -> FilesResult {
        let source: (path: String, real: String)
        let target: (path: String, real: String)
        switch (entry(from), entry(to)) {
        case (.failure(let refusal), _), (_, .failure(let refusal)): return .refused(id, refusal.code, refusal.message)
        case (.success(let a), .success(let b)): (source, target) = (a, b)
        }
        guard !served.contains(source.path) else { return .refused(id, .invalid, "That's a served folder itself.") }
        guard Self.look(source.real) != nil else { return .refused(id, .goneFile, "Not there on this box.") }
        guard !LinkFiles.inside(target.path, source.path) else { return .refused(id, .invalid, "A folder can't go inside itself.") }
        // A change of case alone is the same entry on a volume that ignores case.
        let sameEntry = source.real.lowercased() == target.real.lowercased() && source.real != target.real
        if !sameEntry, Self.look(target.real) != nil {
            return .refused(id, .invalid, "\((target.path as NSString).lastPathComponent) is already there.")
        }
        guard FileCalls.rename(source.real, target.real) == 0 else { return .refused(id, .deniedPath, "Can't move it there on this box.") }
        return FilesResult(id: id, ok: true, path: target.path)
    }

    /// Moves an entry (a link as itself) to the box's trash. Never removes it.
    package func delete(id: String, path: String, trash: Trash) -> FilesResult {
        let entry: (path: String, real: String)
        switch self.entry(path) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): entry = found
        }
        guard !served.contains(entry.path) else { return .refused(id, .invalid, "That's a served folder itself.") }
        guard Self.look(entry.real) != nil else { return .refused(id, .goneFile, "Not there on this box.") }
        let name = (entry.path as NSString).lastPathComponent
        switch trash {
        case .mac(let folder):
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let place = Self.free(in: folder, name: name, info: nil)
            guard FileCalls.rename(entry.real, folder + "/" + place) == 0 else { return Self.notTrashed(id) }
        case .freedesktop(let folder):
            let files = folder + "/files", infos = folder + "/info"
            for made in [folder, files, infos] {
                try? FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let place = Self.free(in: files, name: name, info: infos)
            let info = infos + "/" + place + ".trashinfo"
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime, .withColonSeparatorInTime])
            let original = entry.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.path
            let text = "[Trash Info]\nPath=\(original)\nDeletionDate=\(String(stamp.prefix(19)))\n"
            let fd = open(info, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return Self.notTrashed(id) }
            _ = text.utf8CString.withUnsafeBufferPointer { FileCalls.write(fd, $0.baseAddress, $0.count - 1) }
            close(fd)
            guard FileCalls.rename(entry.real, files + "/" + place) == 0 else {
                unlink(info)
                return Self.notTrashed(id)
            }
        }
        return FilesResult(id: id, ok: true, path: entry.path)
    }

    /// Finds files by name (each part of the query in order, best first), or lines holding the
    /// query (any case), under a served folder: `rg` when the box has it, else a walk that skips
    /// what `.gitignore` names. Stops at `max` hits or `searchSeconds`, and never follows a link.
    package func search(id: String, root: String, query: String, text: Bool, max: Int?, rg: String? = HostFiles.ripgrep()) -> FilesResult {
        let place: (path: String, real: String)
        switch self.place(root, .served) {
        case .failure(let refusal): return .refused(id, refusal.code, refusal.message)
        case .success(let found): place = found
        }
        guard Self.look(place.real)?.kind == .dir else { return .refused(id, .invalid, "Not a folder.") }
        let cap = Swift.min(Swift.max(max ?? 200, 1), LinkFiles.searchMax)
        let deadline = Date().addingTimeInterval(LinkFiles.searchSeconds)
        func absolute(_ relative: String) -> String { place.path + "/" + relative }
        if text {
            if let rg, let found = Self.ripgrep(rg, query: query, in: place.real, cap: cap, deadline: deadline) {
                return FilesResult(id: id, ok: true, path: place.path, more: found.more ? true : nil,
                    hits: found.hits.map { FileHit(path: absolute($0.path), line: $0.line, text: $0.text) })
            }
            var hits: [FileHit] = []
            var more = false
            let lowered = query.lowercased()
            SyncTree(root: URL(fileURLWithPath: place.real)).until { relative, stat in
                guard Date() < deadline else {
                    more = true
                    return false
                }
                guard stat.size <= 1_048_576, let data = FileManager.default.contents(atPath: place.real + "/" + relative),
                    !data.prefix(8192).contains(0)
                else { return true }
                for (index, line) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.lowercased().contains(lowered) {
                    guard hits.count < cap else {
                        more = true
                        return false
                    }
                    hits.append(FileHit(path: absolute(relative), line: index + 1, text: String(line.prefix(300))))
                }
                return true
            }
            return FilesResult(id: id, ok: true, path: place.path, more: more ? true : nil, hits: hits)
        }
        // Names: gather a few times the cap, rank, keep the best.
        var found: [(path: String, score: Int)] = []
        var more = false
        SyncTree(root: URL(fileURLWithPath: place.real)).until { relative, _ in
            guard Date() < deadline, found.count < cap * 5 else {
                more = true
                return false
            }
            if let score = Self.score(relative, query) { found.append((relative, score)) }
            return true
        }
        found.sort { $0.score != $1.score ? $0.score > $1.score : $0.path.count < $1.path.count }
        if found.count > cap { more = true }
        return FilesResult(id: id, ok: true, path: place.path, more: more ? true : nil, hits: found.prefix(cap).map { FileHit(path: absolute($0.path)) })
    }

    // MARK: Where an entry may be

    /// An entry by its path, which needn't exist: its folder is a real folder inside a served
    /// folder (links in it resolved and checked), and its name is plain. `real` is the folder's
    /// real place and the name, the last part never followed.
    func entry(_ path: String) -> Result<(path: String, real: String), Refusal> {
        guard LinkFiles.plainPath(path) else { return .failure(Refusal(code: .invalid, message: "An absolute path.")) }
        let path = LinkFiles.normalised(path)
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return .failure(Refusal(code: .invalid, message: "Name it.")) }
        let folder = (path as NSString).deletingLastPathComponent
        let roots = roots(path, .served)
        guard !roots.isEmpty else { return .failure(Refusal(code: .deniedPath, message: "Only files in the folders this box serves.")) }
        // The served folder itself: its own real place.
        if served.contains(path) {
            guard let real = Self.real(path) else { return .failure(Refusal(code: .goneFile, message: "Not there on this box.")) }
            return .success((path, real))
        }
        guard let real = Self.real(folder), Self.look(real)?.kind == .dir else {
            return .failure(Refusal(code: .goneFile, message: "Its folder isn't there on this box."))
        }
        guard roots.contains(where: { LinkFiles.inside(real, Self.real($0) ?? $0) }) else {
            return .failure(Refusal(code: .deniedPath, message: "A link out of the folder, not followed."))
        }
        return .success((path, real + "/" + name))
    }

    // MARK: Helpers

    private static func notTrashed(_ id: String) -> FilesResult {
        .refused(id, .deniedPath, "Can't move it to the trash on this box (another disk?). Nothing was deleted.")
    }

    /// A name not taken in the trash: `name`, then `name.2`, `name.3`… (its info file too).
    private static func free(in folder: String, name: String, info: String?) -> String {
        var candidate = name
        var n = 1
        while look(folder + "/" + candidate) != nil || info.map({ look($0 + "/" + candidate + ".trashinfo") != nil }) == true {
            n += 1
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            candidate = ext.isEmpty || stem.isEmpty ? "\(name).\(n)" : "\(stem).\(n).\(ext)"
        }
        return candidate
    }

    /// How well a path matches a typed name: the name holding it whole first, then the path, then
    /// its letters in order. Nil: no match.
    static func score(_ relative: String, _ query: String) -> Int? {
        let path = relative.lowercased(), typed = query.lowercased()
        let name = (path as NSString).lastPathComponent
        if name == typed { return 1000 }
        if name.hasPrefix(typed) { return 800 }
        if name.contains(typed) { return 600 }
        if path.contains(typed) { return 400 }
        var rest = Substring(path)
        for char in typed where char != " " {
            guard let at = rest.firstIndex(of: char) else { return nil }
            rest = rest[rest.index(after: at)...]
        }
        return 100
    }

    /// `rg` on the box's PATH, if it's there.
    package static func ripgrep(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let dirs = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init) + [HostPaths.home(env).path + "/.local/bin"]
        return dirs.map { $0 + "/rg" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `rg` over the folder, fixed strings in any case, a few hits a file. Nil when it couldn't run.
    static func ripgrep(_ rg: String, query: String, in folder: String, cap: Int, deadline: Date)
        -> (hits: [(path: String, line: Int, text: String)], more: Bool)?
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rg)
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.arguments = [
            "--no-config", "--no-heading", "--line-number", "--color", "never", "--fixed-strings", "--ignore-case", "--max-count", "20",
            "--max-columns", "300", "--max-filesize", "1M", "--", query, ".",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var hits: [(String, Int, String)] = []
        var more = false
        var pending = Data()
        let handle = out.fileHandleForReading
        reading: while true {
            if Date() >= deadline {
                more = true
                break
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let number = Int(parts[1]) else { continue }
                var path = String(parts[0])
                if path.hasPrefix("./") { path.removeFirst(2) }
                guard SyncPath.valid(path) else { continue }
                if hits.count >= cap {
                    more = true
                    break reading
                }
                hits.append((path, number, String(parts[2])))
            }
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return (hits, more)
    }
}

extension SyncTree {
    /// Every carried file, one at a time, until `visit` says stop.
    package func until(_ visit: (String, SyncStat) -> Bool) {
        var going = true
        var queue = [""]
        while going, let folder = queue.popLast() {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []).sorted()
            for name in names {
                let relative = folder.isEmpty ? name : folder + "/" + name
                guard let info = linkInfo(url(relative).path) else { continue }
                let kind = info.st_mode & mode_t(S_IFMT)
                guard !ignored(relative) else { continue }
                if kind == mode_t(S_IFDIR) {
                    queue.insert(relative, at: 0)
                } else if kind == mode_t(S_IFREG) {
                    guard visit(relative, SyncStat(size: Int64(info.st_size), mtime: Int64(millis(info) / 1000))) else {
                        going = false
                        break
                    }
                }
            }
        }
    }
}

/// The C calls whose Swift names clash with the methods here.
enum FileCalls {
    static func rename(_ from: String, _ to: String) -> Int32 {
        #if canImport(Darwin)
        Darwin.rename(from, to)
        #elseif canImport(Glibc)
        Glibc.rename(from, to)
        #else
        Musl.rename(from, to)
        #endif
    }

    static func mkdir(_ path: String, _ mode: mode_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.mkdir(path, mode)
        #elseif canImport(Glibc)
        Glibc.mkdir(path, mode)
        #else
        Musl.mkdir(path, mode)
        #endif
    }

    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #elseif canImport(Glibc)
        Glibc.write(fd, buffer, count)
        #else
        Musl.write(fd, buffer, count)
        #endif
    }
}
