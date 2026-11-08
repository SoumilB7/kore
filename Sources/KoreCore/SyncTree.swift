import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A synced file as both ends compare it: its size and modification time in whole seconds (rsync
/// from macOS keeps whole seconds only).
package struct SyncStat: Codable, Sendable, Equatable, Hashable {
    package var size: Int64
    package var mtime: Int64

    package init(size: Int64, mtime: Int64) {
        self.size = size
        self.mtime = mtime
    }
}

/// One word for a POSIX shell: single-quoted, any `'` inside closed, escaped and reopened. Every
/// name that reaches a shell on a box (a remote command, rsync's remote path) goes through this.
package enum ShellQuote {
    package static func single(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// A synced path as either end may send it: relative, each part a plain name (no empty, `.` or
/// `..` part), no control characters. Anything else is dropped where it arrives.
package enum SyncPath {
    package static func valid(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"), path.utf8.count <= 4096 else { return false }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

/// The files a folder's two-way sync carries, and the ones it leaves alone: `.git/`, `.build/`,
/// `node_modules/`, `.DS_Store`, and what each folder's `.gitignore` names (patterns with `*`, `?`,
/// `[…]`, `**`, a leading `/` or a `/` inside anchoring to that folder, a trailing `/` for folders
/// only, `!` taking a name back; the last match wins). Both ends of a sync read the same rules, so
/// what one end lists is what the other expects. Only regular files are carried.
package final class SyncTree: @unchecked Sendable {
    package let root: URL
    private let lock = NSLock()
    /// Each folder's `.gitignore` rules, by its path from the root ("" for the root), read once.
    private var rules: [String: [Rule]] = [:]

    package static let skipped: Set<String> = [".git", ".build", "node_modules", ".DS_Store"]

    /// The root's volume finds `Foo` for `foo` (APFS by default): a name is there only when it is,
    /// exactly, in its folder's list.
    package let caseless: Bool

    package init(root: URL) {
        self.root = root.standardizedFileURL
        #if canImport(Darwin)
        caseless = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames != true
        #else
        caseless = false
        #endif
    }

    /// Each part of the path is in its folder's list as written (always, on a volume that minds
    /// case).
    package func exact(_ relative: String) -> Bool {
        guard caseless else { return true }
        var folder = ""
        for part in relative.split(separator: "/") {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []
            guard names.contains(String(part)) else { return false }
            folder = folder.isEmpty ? String(part) : folder + "/" + part
        }
        return true
    }

    // MARK: Listing

    /// Every carried file under the root, by its path from the root.
    package func list() -> [String: SyncStat] {
        var out: [String: SyncStat] = [:]
        walk("", into: &out)
        return out
    }

    /// Every carried file under the root, one at a time (nothing kept).
    package func each(_ visit: (String, SyncStat) -> Void) { walk("", visit) }

    /// One walk: every carried file (nil past `fileCap`: a list cut short is never used) and the
    /// carried real folders, the root's "" first (counted past `folderCap`, listed up to it).
    package func scan(fileCap: Int, folderCap: Int) -> (files: [String: SyncStat]?, folders: [String], folderCount: Int) {
        var files: [String: SyncStat] = [:]
        var over = false
        var folders = [""]
        var count = 1
        var queue = [""]
        while let folder = queue.popLast() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []
            for name in names {
                let relative = folder.isEmpty ? name : folder + "/" + name
                var info = Glue.statInfo()
                guard lstat(url(relative).path, &info) == 0 else { continue }
                let dir = isDirectory(info)
                guard !ignoredHere(relative, isDirectory: dir) else { continue }
                if dir {
                    count += 1
                    if folders.count < folderCap { folders.append(relative) }
                    queue.append(relative)
                } else if isRegular(info) {
                    if files.count >= fileCap { over = true } else { files[relative] = Self.stat(of: info) }
                }
            }
            if over { break }
        }
        return (over ? nil : files, folders, count)
    }

    /// The root is there and is a folder.
    package var rootExists: Bool {
        var info = Glue.statInfo()
        return Glue.follow(root.path, &info) == 0 && isDirectory(info)
    }

    /// Every carried file, up to `cap` of them: nil past it (a list cut short is never used).
    package func list(cap: Int) -> [String: SyncStat]? {
        var out: [String: SyncStat] = [:]
        var over = false
        walk("") { path, stat in
            if out.count >= cap { over = true } else { out[path] = stat }
        }
        return over ? nil : out
    }

    /// The real folders right inside a folder (no links), by path from the root.
    package func subfolders(_ relative: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url(relative).path)) ?? []
        return names.compactMap { name in
            let child = relative.isEmpty ? name : relative + "/" + name
            var info = Glue.statInfo()
            return lstat(url(child).path, &info) == 0 && isDirectory(info) ? child : nil
        }
    }

    /// The path's folders above it are real folders inside the root: none is a symlink or a
    /// file. Nothing is read or written through a link.
    package func plain(_ relative: String) -> Bool {
        guard SyncPath.valid(relative) else { return false }
        var path = ""
        for part in relative.split(separator: "/").dropLast() {
            path = path.isEmpty ? String(part) : path + "/" + part
            var info = Glue.statInfo()
            // Not there yet: nothing below it is either, and a copy makes it a folder.
            guard lstat(url(path).path, &info) == 0 else { return true }
            guard isDirectory(info) else { return false }
        }
        return true
    }

    /// The carried files at and under `relative` (a file, or a folder's whole tree), as they are now.
    package func list(at relative: String) -> [String: SyncStat] {
        guard !relative.isEmpty else { return list() }
        guard plain(relative), !ignored(relative), exact(relative) else { return [:] }
        var info = Glue.statInfo()
        guard lstat(url(relative).path, &info) == 0 else { return [:] }
        if isDirectory(info) {
            var out: [String: SyncStat] = [:]
            walk(relative, into: &out)
            return out
        }
        return isRegular(info) ? [relative: Self.stat(of: info)] : [:]
    }

    /// One file's stat; nil when it isn't there, isn't a regular file, or isn't carried.
    package func stat(_ relative: String) -> SyncStat? {
        guard plain(relative), !ignored(relative), exact(relative) else { return nil }
        var info = Glue.statInfo()
        guard lstat(url(relative).path, &info) == 0, isRegular(info) else { return nil }
        return Self.stat(of: info)
    }

    package func url(_ relative: String) -> URL { relative.isEmpty ? root : root.appendingPathComponent(relative) }

    /// A path inside the root as a path from it; nil outside it.
    package func relative(_ path: String) -> String? {
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if path == root.path { return "" }
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    private func walk(_ folder: String, into out: inout [String: SyncStat]) {
        walk(folder) { out[$0] = $1 }
    }

    private func walk(_ folder: String, _ visit: (String, SyncStat) -> Void) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []
        for name in names.sorted() {
            let relative = folder.isEmpty ? name : folder + "/" + name
            var info = Glue.statInfo()
            guard lstat(url(relative).path, &info) == 0 else { continue }
            let dir = isDirectory(info)
            guard !ignoredHere(relative, isDirectory: dir) else { continue }
            if dir {
                walk(relative, visit)
            } else if isRegular(info) {
                visit(relative, Self.stat(of: info))
            }
        }
    }

    // MARK: Rules

    /// Whether a path is left out: by the fixed names, or a `.gitignore` here or above, or a
    /// folder above it being left out.
    package func ignored(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return false }
        var path = ""
        for (i, part) in parts.enumerated() {
            path = path.isEmpty ? part : path + "/" + part
            let last = i == parts.count - 1
            let dir = last ? isDirectoryNow(path) : true
            if ignoredHere(path, isDirectory: dir) { return true }
        }
        return false
    }

    /// A `.gitignore` changed: its rules are read again on next use.
    package func forget(_ relative: String) {
        guard relative == ".gitignore" || relative.hasSuffix("/.gitignore") else { return }
        let folder = relative == ".gitignore" ? "" : String(relative.dropLast("/.gitignore".count))
        _ = lock.withLock { rules.removeValue(forKey: folder) }
    }

    /// Every `.gitignore` is read again on next use.
    package func forgetAll() { lock.withLock { rules = [:] } }

    /// The path alone (its folders above already let through).
    private func ignoredHere(_ relative: String, isDirectory dir: Bool) -> Bool {
        let name = relative.split(separator: "/").last.map(String.init) ?? relative
        if Self.skipped.contains(name) { return true }
        var verdict = false
        // From the root down: a deeper folder's rule comes later, so it wins.
        var folders = [""]
        var walked = ""
        for part in relative.split(separator: "/").dropLast() {
            walked = walked.isEmpty ? String(part) : walked + "/" + part
            folders.append(walked)
        }
        for folder in folders {
            let inside = folder.isEmpty ? relative : String(relative.dropFirst(folder.count + 1))
            for rule in rules(in: folder) where rule.matches(inside, name: name, isDirectory: dir) { verdict = !rule.negated }
        }
        return verdict
    }

    private func rules(in folder: String) -> [Rule] {
        if let known = lock.withLock({ rules[folder] }) { return known }
        let text = (try? String(contentsOf: url(folder).appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
        let read = Self.parse(text)
        lock.withLock { rules[folder] = read }
        return read
    }

    package static func parse(_ text: String) -> [Rule] {
        text.split(whereSeparator: \.isNewline).compactMap { Rule(String($0)) }
    }

    /// One `.gitignore` line.
    package struct Rule: Sendable {
        let pattern: String
        let negated: Bool
        let folderOnly: Bool
        let anchored: Bool

        init?(_ line: String) {
            var text = line
            while text.hasSuffix(" "), !text.hasSuffix("\\ ") { text.removeLast() }
            guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
            negated = text.hasPrefix("!")
            if negated { text.removeFirst() }
            if text.hasPrefix("\\") { text.removeFirst() }
            folderOnly = text.hasSuffix("/")
            if folderOnly { text.removeLast() }
            anchored = text.contains("/")
            if text.hasPrefix("/") { text.removeFirst() }
            guard !text.isEmpty else { return nil }
            pattern = text
        }

        /// `inside`: the path from the rule's folder; `name`: its last part.
        func matches(_ inside: String, name: String, isDirectory: Bool) -> Bool {
            if folderOnly && !isDirectory { return false }
            if !anchored { return Self.match(pattern, name, slashes: true) }
            if pattern.hasPrefix("**/") {
                // Any depth: the rest against the path and each of its tails.
                let rest = String(pattern.dropFirst(3))
                var tail = inside
                while true {
                    if Self.match(rest, tail, slashes: !rest.contains("**")) { return true }
                    guard let slash = tail.firstIndex(of: "/") else { return false }
                    tail = String(tail[tail.index(after: slash)...])
                }
            }
            return Self.match(pattern, inside, slashes: !pattern.contains("**"))
        }

        /// fnmatch: `slashes` keeps `*` from crossing a `/` (a `**` pattern lets it).
        static func match(_ pattern: String, _ text: String, slashes: Bool) -> Bool {
            fnmatch(pattern, text, slashes ? FNM_PATHNAME : 0) == 0
        }
    }

    // MARK: Stat

    private func isDirectoryNow(_ relative: String) -> Bool {
        var info = Glue.statInfo()
        return lstat(url(relative).path, &info) == 0 && isDirectory(info)
    }

    private func isDirectory(_ info: Glue.Info) -> Bool { (info.st_mode & S_IFMT) == S_IFDIR }
    private func isRegular(_ info: Glue.Info) -> Bool { (info.st_mode & S_IFMT) == S_IFREG }

    private static func stat(of info: Glue.Info) -> SyncStat {
        #if canImport(Darwin)
        SyncStat(size: Int64(info.st_size), mtime: Int64(info.st_mtimespec.tv_sec))
        #else
        SyncStat(size: Int64(info.st_size), mtime: Int64(info.st_mtim.tv_sec))
        #endif
    }
}

private enum Glue {
    typealias Info = stat
    static func statInfo() -> Info { Info() }
    /// stat(2), following a link (the root may be one).
    static func follow(_ path: String, _ info: inout Info) -> Int32 { stat(path, &info) }
}
