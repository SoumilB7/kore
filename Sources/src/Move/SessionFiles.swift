import Foundation
import KoreCore

// A chat moving between this Mac and a box takes its CLI's own session files with it: Claude's
// `projects/<key>/<session>.jsonl` and its `<session>/` folder (subagents, tool results), or a
// Codex rollout. Only the folder is rewritten: each row's `cwd`, and Claude's project-key folder.
// The Mac and the box both use this one helper, in both directions, so a round trip is
// byte-identical. Files are read and written a piece at a time: a rollout can be hundreds of MB.

/// Where one CLI keeps its sessions on this machine, and which files make one session.
package enum SessionFiles {
    /// `$CLAUDE_CONFIG_DIR/projects`, else `$HOME/.claude/projects`.
    package static func claudeProjects(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir).appendingPathComponent("projects") }
        return home(env).appendingPathComponent(".claude/projects")
    }

    /// `$CODEX_HOME/sessions`, else `$HOME/.codex/sessions`.
    package static func codexSessions(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = env["CODEX_HOME"], !dir.isEmpty { return URL(fileURLWithPath: dir).appendingPathComponent("sessions") }
        return home(env).appendingPathComponent(".codex/sessions")
    }

    static func home(_ env: [String: String]) -> URL {
        if let home = env["HOME"], !home.isEmpty { return URL(fileURLWithPath: home) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// The folder as the CLI writes it: its real path (`/tmp` is `/private/tmp` on a Mac).
    package static func real(_ folder: String) -> String {
        guard let resolved = realpath(folder, nil) else { return folder }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A session's files on this machine: the folder they sit in, and their paths from it.
    /// Claude: `<session>.jsonl` and everything under `<session>/`; Codex: the rollout. Empty
    /// when the CLI never wrote the session.
    package struct Found: Sendable, Equatable {
        package var root: URL
        package var files: [String]
        package init(root: URL, files: [String]) {
            self.root = root
            self.files = files
        }
    }

    /// Claude's files of `session`, made in `folder`.
    package static func claude(_ session: String, folder: String, env: [String: String] = ProcessInfo.processInfo.environment) -> Found {
        let root = claudeProjects(env).appendingPathComponent(ClaudeHistory.projectKey(for: URL(fileURLWithPath: folder)))
        var files: [String] = []
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(session + ".jsonl").path) { files.append(session + ".jsonl") }
        files += tree(root, under: session)
        return Found(root: root, files: files)
    }

    /// The Codex rollout of `session`: `known` when the box kept its path, else looked for by name
    /// under `sessions/` (`rollout-<time>-<id>.jsonl`, in day folders).
    package static func codex(_ session: String, known: String? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> Found {
        let sessions = codexSessions(env)
        if let known, FileManager.default.fileExists(atPath: known) {
            let url = URL(fileURLWithPath: known)
            if known.hasPrefix(sessions.path + "/") { return Found(root: sessions, files: [String(known.dropFirst(sessions.path.count + 1))]) }
            return Found(root: url.deletingLastPathComponent(), files: [url.lastPathComponent])
        }
        let suffix = "-" + session + ".jsonl"
        // Newest day first: a session's rollout is in the day it began.
        for year in sorted(sessions) {
            for month in sorted(sessions.appendingPathComponent(year)) {
                for day in sorted(sessions.appendingPathComponent("\(year)/\(month)")) {
                    let dir = sessions.appendingPathComponent("\(year)/\(month)/\(day)")
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                    if let name = names.first(where: { $0.hasSuffix(suffix) }) { return Found(root: sessions, files: ["\(year)/\(month)/\(day)/\(name)"]) }
                }
            }
        }
        return Found(root: sessions, files: [])
    }

    private static func sorted(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted(by: >)
    }

    /// Every regular file under `root/name`, as paths from `root`, links left out.
    package static func tree(_ root: URL, under name: String) -> [String] {
        let base = root.appendingPathComponent(name)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var files: [String] = []
        let prefix = base.standardizedFileURL.path + "/"
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            files.append(name + "/" + path.dropFirst(prefix.count))
        }
        return files.sorted()
    }

    /// The bytes of a session's files together.
    package static func bytes(_ found: Found) -> Int64 {
        found.files.reduce(Int64(0)) { sum, path in
            sum + (((try? FileManager.default.attributesOfItem(atPath: found.root.appendingPathComponent(path).path)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Whether a file of a session is one of its transcripts (rows with `cwd`): the rest is copied as it is.
    package static func rewrites(_ path: String) -> Bool { path.hasSuffix(".jsonl") }

    /// A path from a session's root that stays inside it: relative, plain parts only.
    package static func plain(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 1024, !path.contains("\0"), !path.contains(where: \.isNewline) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// The folder in a session's rows, from one machine's to another's: a row whose `cwd` is
/// `from` or inside it gets `to` in its place; every other byte stays.
package struct FolderRewrite: Sendable, Equatable {
    package let pairs: [(from: [UInt8], to: [UInt8])]
    /// A copy's session ids (`SessionCopy`): every value that is exactly the old id
    /// (`:"<old>"`, Claude's `sessionId`, Codex's thread `id`) becomes the new one.
    package private(set) var ids: (from: [UInt8], to: [UInt8])?
    /// A copy of a running chat: a last row the CLI is still writing (no newline, not JSON yet)
    /// is left out rather than copied torn.
    package var dropsPartial = false

    package static func == (a: FolderRewrite, b: FolderRewrite) -> Bool {
        a.pairs.map(\.from) == b.pairs.map(\.from) && a.pairs.map(\.to) == b.pairs.map(\.to) && a.ids?.from == b.ids?.from
            && a.ids?.to == b.ids?.to && a.dropsPartial == b.dropsPartial
    }

    /// The folder as before, and the session's id `old` as `new` in every row.
    package init(from: [String], to: String, session old: String, as new: String) {
        self.init(from: from, to: to)
        if old != new { ids = (Array(("\"" + old + "\"").utf8), Array(("\"" + new + "\"").utf8)) }
    }

    /// `from` may be said several ways (as given and as its real path): each goes to `to`.
    package init(from: [String], to: String) {
        var seen: Set<String> = []
        pairs = from.filter { !$0.isEmpty && seen.insert($0).inserted && $0 != to }.map { (Array(Self.escaped($0).utf8), Array(Self.escaped(to).utf8)) }
    }

    /// The folder as JSON writes it inside a string (both CLIs leave `/` alone).
    static func escaped(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static let key = Array(#""cwd":""#.utf8)

    /// One row with its `cwd` values moved (and a copy's session id); the same bytes when none matches.
    package func line(_ line: Data) -> Data {
        let moved = folders(line)
        guard let ids else { return moved }
        return Self.values(moved, ids.from, ids.to)
    }

    /// Each `:"<from>"` (a JSON value that is exactly it) as `:"<to>"`.
    static func values(_ line: Data, _ from: [UInt8], _ to: [UInt8]) -> Data {
        let bytes = [UInt8](line)
        var out: [UInt8] = []
        var copied = 0
        var at = 0
        while let found = find(from, in: bytes, from: at) {
            at = found + from.count
            guard found > 0, bytes[found - 1] == UInt8(ascii: ":") else { continue }
            if out.isEmpty { out.reserveCapacity(bytes.count + 16) }
            out += bytes[copied..<found]
            out += to
            copied = at
        }
        guard copied > 0 else { return line }
        out += bytes[copied...]
        return Data(out)
    }

    private func folders(_ line: Data) -> Data {
        guard !pairs.isEmpty else { return line }
        let bytes = [UInt8](line)
        var out: [UInt8] = []
        var copied = 0
        var at = 0
        let key = Self.key
        while at + key.count <= bytes.count {
            guard let found = Self.find(key, in: bytes, from: at) else { break }
            let value = found + key.count
            at = value
            for pair in pairs where Self.starts(bytes, at: value, with: pair.from) {
                let end = value + pair.from.count
                // The folder itself, or a folder inside it: never a sibling that shares its start.
                guard end < bytes.count, bytes[end] == UInt8(ascii: "\"") || bytes[end] == UInt8(ascii: "/") else { continue }
                if out.isEmpty { out.reserveCapacity(bytes.count + 64) }
                out += bytes[copied..<value]
                out += pair.to
                copied = end
                at = end
                break
            }
        }
        guard copied > 0 else { return line }
        out += bytes[copied...]
        return Data(out)
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard from <= bytes.count, needle.count <= bytes.count - from else { return nil }
        return bytes.withUnsafeBufferPointer { buffer -> Int? in
            needle.withUnsafeBufferPointer { pattern -> Int? in
                guard let base = buffer.baseAddress, let p = pattern.baseAddress,
                    let hit = memmem(base + from, buffer.count - from, p, pattern.count)
                else { return nil }
                return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    private static func starts(_ bytes: [UInt8], at: Int, with prefix: [UInt8]) -> Bool {
        guard at + prefix.count <= bytes.count else { return false }
        for i in 0..<prefix.count where bytes[at + i] != prefix[i] { return false }
        return true
    }

    /// `source` into `target`, a row at a time (never the whole file in memory): written beside
    /// `target` first, then renamed over it. The bytes written.
    @discardableResult
    package func file(_ source: URL, to target: URL) throws -> Int {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(getpid()).move")
        FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temp)
        var written = 0
        do {
            var carry = Data()
            var out = Data()
            func flush(_ force: Bool) throws {
                guard force || out.count >= Self.chunk else { return }
                try output.write(contentsOf: out)
                written += out.count
                out.removeAll(keepingCapacity: true)
            }
            // Each piece's buffers go back before the next is read (Foundation's reads are
            // autoreleased on a Mac): what's held is a piece or two, whatever the file's size.
            var more = true
            while more {
                try drained {
                    guard let piece = try input.read(upToCount: Self.chunk), !piece.isEmpty else {
                        more = false
                        return
                    }
                    carry.append(piece)
                    var start = carry.startIndex
                    while let newline = carry[start...].firstIndex(of: 0x0A) {
                        out.append(line(carry[start..<newline]))
                        out.append(0x0A)
                        start = newline + 1
                        try flush(false)
                    }
                    carry = Data(carry[start...])
                }
            }
            // A last row with no newline after it stays without one (a copy's torn row goes).
            if !carry.isEmpty, !(dropsPartial && (try? JSONSerialization.jsonObject(with: carry)) == nil) { out.append(line(carry)) }
            try flush(true)
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        if rename(temp.path, target.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return written
    }

    static let chunk = 256 * 1024

    private func drained(_ body: () throws -> Void) throws {
        #if canImport(Darwin)
        try autoreleasepool(invoking: body)
        #else
        try body()
        #endif
    }

    /// A session's files from `source` to `target` (each its root): the transcripts rewritten,
    /// the rest copied. Files already the same at `target` are left alone. The bytes written.
    /// `renamed`: each file's path at `target` (a copy's, under its new session id).
    @discardableResult
    package func files(_ files: [String], from source: URL, to target: URL, renamed: (String) -> String = { $0 }) throws -> Int {
        var written = 0
        for path in files where SessionFiles.plain(path) {
            let from = source.appendingPathComponent(path), to = target.appendingPathComponent(renamed(path))
            if SessionFiles.rewrites(path) {
                written += try file(from, to: to)
            } else {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.contentsEqual(atPath: from.path, andPath: to.path) { continue }
                try? FileManager.default.removeItem(at: to)
                try FileManager.default.copyItem(at: from, to: to)
                written += ((try? FileManager.default.attributesOfItem(atPath: to.path)[.size]) as? Int) ?? 0
            }
        }
        return written
    }
}
