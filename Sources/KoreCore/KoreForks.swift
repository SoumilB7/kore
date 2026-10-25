import Foundation

/// Forks Kore made, so each shows in the folder's history the moment it's made, titled
/// "<title> (fork)", whether or not its CLI lists it yet. Claude makes a fork's session on its
/// first message (`--fork-session`); Codex makes the thread when the fork opens (`thread/fork`)
/// but only once the fork's tab starts it. A record stands in for the CLI's entry until the CLI
/// lists the fork under the record's title, then it's dropped: one entry either way.
///
/// JSON in Kore's Application Support (`usage/forks.json`), next to `sessions.jsonl`.
public final class KoreForks: @unchecked Sendable {
    public struct Fork: Sendable, Equatable, Codable {
        public var cli: String
        public var folder: String
        /// Kore's id for the fork, fixed when it's made: Claude's session takes it (`--session-id`).
        public var key: String
        /// The id it's listed under: `key`, or the CLI's own once it says another (Codex's thread).
        public var id: String
        public var title: String
        /// The session it was forked from, and the message or turn its history runs through.
        public var from: String
        public var at: String
        /// The original chat's title, for the fork's "Forked from" line.
        public var source: String?
        public var t: Double
        /// The CLI has the fork's session: it resumes as itself, not as a fork made again.
        public var made: Bool

        public init(
            cli: String, folder: URL, key: String, title: String, from: String, at: String, source: String?,
            at time: Date = Date()
        ) {
            self.cli = cli
            self.folder = folder.standardizedFileURL.path
            self.key = key
            id = key
            self.title = title
            self.from = from
            self.at = at
            self.source = source
            t = time.timeIntervalSince1970.rounded()
            made = false
        }

        func matches(_ cli: String, _ id: String) -> Bool { self.cli == cli && (self.id == id || key == id) }
    }

    public let url: URL?
    private let queue = DispatchQueue(label: "Kore.forks", qos: .utility)
    // Touched on `queue` only.
    private var loaded: [Fork]?

    public init(url: URL?) { self.url = url }

    public static let shared = KoreForks(url: UsagePaths.current.support?.appendingPathComponent("forks.json"))

    /// A fork just made.
    public func add(_ fork: Fork) {
        change { forks in
            forks.removeAll { $0.cli == fork.cli && $0.key == fork.key }
            forks.append(fork)
            return true
        }
    }

    /// The fork's CLI named its session: listed under that id from now on. An id other than
    /// Kore's means the CLI made it (Codex's thread); Claude's takes Kore's own.
    public func identified(cli: String, key: String, as id: String) {
        change { forks in
            guard let i = forks.firstIndex(where: { $0.cli == cli && $0.key == key }), forks[i].id != id else { return false }
            forks[i].id = id
            forks[i].made = true
            return true
        }
    }

    /// A message went out in the fork: its CLI has the session now.
    public func sent(cli: String, key: String) {
        change { forks in
            guard let i = forks.firstIndex(where: { $0.cli == cli && $0.key == key }), !forks[i].made else { return false }
            forks[i].made = true
            return true
        }
    }

    public func rename(cli: String, id: String, to title: String) {
        change { forks in
            guard let i = forks.firstIndex(where: { $0.matches(cli, id) }), forks[i].title != title else { return false }
            forks[i].title = title
            return true
        }
    }

    public func forget(cli: String, id: String) {
        change { forks in
            let before = forks.count
            forks.removeAll { $0.matches(cli, id) }
            return forks.count != before
        }
    }

    /// The fork listed (or once listed) as `id`. Blocking, but from memory after the first read.
    public func find(cli: String, id: String) -> Fork? {
        queue.sync { load().last { $0.matches(cli, id) } }
    }

    /// The folder's forks Kore keeps a record of, oldest first.
    public func forks(cli: String, folder: URL) -> [Fork] {
        let path = folder.standardizedFileURL.path
        return queue.sync { load().filter { $0.cli == cli && $0.folder == path } }
    }

    /// `cli`'s list for `folder` with Kore's forks in it: each one the CLI doesn't list yet is
    /// added; one it lists under another title keeps the fork's; one it lists under the fork's
    /// title is the CLI's from now on, and its record goes.
    public func merged(_ listed: [SessionSummary], cli: String, agent: SessionSummary.Agent, folder: URL) -> [SessionSummary] {
        let forks = forks(cli: cli, folder: folder)
        guard !forks.isEmpty else { return listed }
        let (sessions, settled, made) = Self.merge(listed, forks: forks, agent: agent)
        if !settled.isEmpty || !made.isEmpty {
            change { all in
                all.removeAll { $0.cli == cli && settled.contains($0.key) }
                for i in all.indices where all[i].cli == cli && made.contains(all[i].key) { all[i].made = true }
                return true
            }
        }
        return sessions
    }

    /// The merge itself: the sessions shown, the records the CLI's list has taken over (by key),
    /// and those it lists that weren't known to be made.
    public static func merge(_ listed: [SessionSummary], forks: [Fork], agent: SessionSummary.Agent)
        -> (sessions: [SessionSummary], settled: Set<String>, made: Set<String>)
    {
        var sessions = listed
        var settled: Set<String> = []
        var made: Set<String> = []
        for fork in forks {
            if let i = sessions.firstIndex(where: { $0.id == fork.id }) {
                let own = sessions[i]
                if own.title == fork.title {
                    settled.insert(fork.key)
                } else {
                    sessions[i] = SessionSummary(
                        id: own.id, agent: own.agent, title: fork.title, updated: own.updated, archived: own.archived, file: own.file)
                    if !fork.made { made.insert(fork.key) }
                }
            } else {
                sessions.append(SessionSummary(id: fork.id, agent: agent, title: fork.title, updated: Date(timeIntervalSince1970: fork.t)))
            }
        }
        return (sessions, settled, made)
    }

    /// Waits until every change so far is written.
    public func sync() { queue.sync {} }

    // MARK: - The file

    /// `edit` says whether it changed anything: only then is the file written.
    private func change(_ edit: @escaping @Sendable (inout [Fork]) -> Bool) {
        queue.async { [self] in
            var forks = load()
            guard edit(&forks) else { return }
            // A record this old is let go: its fork was never sent, or its CLI kept another title.
            let cutoff = Date().addingTimeInterval(-Self.keep).timeIntervalSince1970
            forks.removeAll { $0.t < cutoff }
            loaded = forks
            save(forks)
        }
    }

    /// How long a record is kept.
    static let keep: TimeInterval = 90 * 24 * 3600

    private func load() -> [Fork] {
        if let loaded { return loaded }
        let forks = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Fork].self, from: $0) } ?? []
        loaded = forks
        return forks
    }

    private func save(_ forks: [Fork]) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(forks) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
