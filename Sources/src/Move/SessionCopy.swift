import Foundation
import KoreCore

// A chat copied (link 1.11, and between this Mac's own folders): the CLI's session files again
// under a new session id, in another folder. The rows keep every byte but the folder (`cwd`, and
// Claude's project-key folder) and the session's id where a field holds exactly it; the files
// are renamed to the new id (Claude's `<id>.jsonl` and `<id>/`, Codex's `rollout-<time>-<id>`).
// A cut is a copy, verified, then the source's files into a trash folder: never deleted.

package enum SessionCopy {
    /// A new session id, as the CLIs make them.
    package static func newId() -> String { UUID().uuidString.lowercased() }

    /// A file's path under the copy's id: each part that names the old id names the new one.
    package static func renamed(_ path: String, from old: String, to new: String) -> String {
        guard old != new else { return path }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: old, with: new) }.joined(separator: "/")
    }

    /// The copy's rewrite: `folders` (the source's, as kept and as real paths) to `folder`, the
    /// session `old` as `new`, a torn last row left out.
    package static func rewrite(folders: [String], to folder: String, session old: String, as new: String) -> FolderRewrite {
        var rewrite = FolderRewrite(from: folders, to: folder, session: old, as: new)
        rewrite.dropsPartial = true
        return rewrite
    }

    /// `files` (paths from `source`) placed at `target` as session `new`. The placed paths.
    @discardableResult
    package static func place(_ files: [String], from source: URL, to target: URL, rewrite: FolderRewrite, old: String, new: String) throws -> [String] {
        let plain = files.filter(SessionFiles.plain)
        let placed = plain.map { renamed($0, from: old, to: new) }
        // Never over another session's files.
        for path in placed where FileManager.default.fileExists(atPath: target.appendingPathComponent(path).path) {
            throw CopyError("A chat with that id is there already: \(path)")
        }
        do {
            try rewrite.files(plain, from: source, to: target) { renamed($0, from: old, to: new) }
        } catch {
            for path in placed { try? FileManager.default.removeItem(at: target.appendingPathComponent(path)) }
            throw error
        }
        return placed
    }

    /// The session's main transcript among its files: Claude's `<id>.jsonl`, Codex's rollout.
    package static func main(_ files: [String]) -> String? {
        files.first { !$0.contains("/") && $0.hasSuffix(".jsonl") } ?? files.first { $0.hasSuffix(".jsonl") && $0.contains("rollout-") }
    }

    /// A placed copy is whole: every file there, its main transcript naming the new id early on,
    /// and (`rows`, a stopped source's count) each transcript as many rows as the source's.
    package static func verified(_ placed: [String], at root: URL, session new: String, rows: [String: Int]? = nil) -> Bool {
        guard !placed.isEmpty, let main = main(placed) else { return false }
        for path in placed where !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { return false }
        guard let head = try? FileHandle(forReadingFrom: root.appendingPathComponent(main)) else { return false }
        defer { try? head.close() }
        let first = (try? head.read(upToCount: 256 * 1024)) ?? Data()
        guard first.range(of: Data(("\"" + new + "\"").utf8)) != nil else { return false }
        if let rows {
            for (path, count) in rows where Self.rows(root.appendingPathComponent(path)) != count { return false }
        }
        return true
    }

    /// A transcript's rows (its newlines, and a last row without one), read a piece at a time.
    package static func rows(_ url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return -1 }
        defer { try? handle.close() }
        var count = 0
        var last: UInt8 = 0x0A
        while let piece = try? handle.read(upToCount: 256 * 1024), !piece.isEmpty {
            count += piece.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            last = piece.last ?? last
        }
        return count + (last == 0x0A ? 0 : 1)
    }

    /// A copy on this machine: `provider`'s session `old` in folder `from` (its files found
    /// under `env`'s CLI folders, or at `known`) as session `new` in folder `to`. The placed
    /// files, from their root.
    /// `whole`: the source has stopped (a cut), so the copy must have every one of its rows.
    package static func local(
        provider: String, session old: String, from: String, to: String, as new: String, known: String? = nil, whole: Bool = false,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SessionFiles.Found {
        let found = files(provider: provider, session: old, folder: from, known: known, env: env)
        guard !found.files.isEmpty else { throw CopyError("The chat's session isn't on this Mac") }
        return try placed(found, provider: provider, folders: spellings(from), session: old, to: to, as: new, whole: whole, env: env)
    }

    /// Files found (on this machine, or staged from another) placed as session `new` in folder
    /// `to`, verified; nothing is left of a copy that didn't come out whole.
    package static func placed(
        _ found: SessionFiles.Found, provider: String, folders: [String], session old: String, to: String, as new: String, whole: Bool = false,
        env: [String: String]
    ) throws -> SessionFiles.Found {
        let root = target(provider: provider, folder: to, env: env)
        let rewrite = rewrite(folders: folders, to: SessionFiles.real(to), session: old, as: new)
        var rows: [String: Int]?
        if whole {
            rows = [:]
            for path in found.files where SessionFiles.plain(path) && SessionFiles.rewrites(path) {
                rows?[renamed(path, from: old, to: new)] = Self.rows(found.root.appendingPathComponent(path))
            }
        }
        let placed = try place(found.files, from: found.root, to: root, rewrite: rewrite, old: old, new: new)
        guard verified(placed, at: root, session: new, rows: rows) else {
            for path in placed { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
            throw CopyError("The copy didn't come out whole")
        }
        return SessionFiles.Found(root: root, files: placed)
    }

    /// A session's files on this machine: Claude's in the folder's project key (or beside a
    /// `known` transcript), Codex's rollout.
    package static func files(provider: String, session: String, folder: String, known: String? = nil, env: [String: String]) -> SessionFiles.Found {
        if provider == ProviderDescriptor.codex.id { return SessionFiles.codex(session, known: known, env: env) }
        let found = SessionFiles.claude(session, folder: folder, env: env)
        // A chat from before the folder was renamed: beside its transcript, where the listing found it.
        if found.files.isEmpty, let known, URL(fileURLWithPath: known).lastPathComponent == session + ".jsonl",
            FileManager.default.fileExists(atPath: known)
        {
            let root = URL(fileURLWithPath: known).deletingLastPathComponent()
            return SessionFiles.Found(root: root, files: [session + ".jsonl"] + SessionFiles.tree(root, under: session))
        }
        return found
    }

    /// Where a session's files go for `folder` on this machine.
    package static func target(provider: String, folder: String, env: [String: String]) -> URL {
        provider == ProviderDescriptor.codex.id
            ? SessionFiles.codexSessions(env)
            : SessionFiles.claudeProjects(env).appendingPathComponent(ClaudeHistory.projectKey(for: URL(fileURLWithPath: folder)))
    }

    /// The folder as given and as its real path: the rows' `cwd`s a copy rewrites.
    package static func spellings(_ folder: String) -> [String] {
        let real = SessionFiles.real(folder)
        return real == folder ? [folder] : [folder, real]
    }

    /// A cut's source, once its copy is verified: its files into `trash`
    /// (`<trash>/<time>-<session>/`, their paths kept), never deleted. The folder they went to.
    @discardableResult
    package static func trash(_ found: SessionFiles.Found, session: String, into trash: URL) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = trash.appendingPathComponent("\(stamp)-\(session)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for path in found.files where SessionFiles.plain(path) {
            let from = found.root.appendingPathComponent(path), to = dir.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: from, to: to)
        }
        // Claude's `<session>/` folder, its empty folders left behind (anything else in it stays).
        try? removeEmpty(found.root.appendingPathComponent(session))
        return dir
    }

    /// `dir` and the empty folders in it, bottom up; anything with a file in it stays.
    private static func removeEmpty(_ dir: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) { try? removeEmpty(dir.appendingPathComponent(name)) }
        if try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty { try FileManager.default.removeItem(at: dir) }
    }

    package struct CopyError: Error, Equatable, CustomStringConvertible {
        package var line: String
        package init(_ line: String) { self.line = line }
        package var description: String { line }
    }
}
