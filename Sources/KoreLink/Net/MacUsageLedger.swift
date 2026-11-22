import Foundation
import KoreCore
import LinkProtocol
import src

/// This Mac's own Kore usage, for the owner's other Macs (`usage.since` over `MacPeerLink`), as a
/// box keeps its own (`UsageLedger`): a line per model request this Mac's Kore chats made, with
/// the login it ran on, and a line per plan reading this Mac heard or read itself. A week of
/// them, numbered, in `usage/peer-ledger.jsonl` (0600). What came from another device (a box's,
/// another Mac's) is never kept here, so nothing goes round. A request whose login isn't known is
/// left out: on another Mac it can't be put to any login, and a wrong one would misstate it.
@MainActor
package final class MacUsageLedger {
    package static let shared = MacUsageLedger(url: KoreFolders.support.appendingPathComponent("usage/peer-ledger.jsonl"))

    package let url: URL
    package var now: () -> Date = { Date() }
    /// Each Kore chat's login over time (`KoreSessions`): the login of a request that didn't name
    /// one (Codex's reports don't).
    package var known: () -> KoreSessions.Known = { KoreSessions.shared.known() } {
        didSet { knownCache = nil }
    }

    package static let keep: TimeInterval = 7 * 86400
    package static let pageMax = 500
    /// The sources of this Mac's own readings: a turn's report, a read Kore made.
    package static let ownSources: Set<String> = ["stream", "read"]

    private var lines: [UsageLine]?
    private var ids: Set<String> = []
    private var knownCache: (at: Date, value: KoreSessions.Known)?

    package init(url: URL) {
        self.url = url
    }

    // MARK: In

    /// A request one of this Mac's Kore chats made (`session`: its CLI session or thread).
    package func request(session: String, provider: String, _ usage: RequestUsage) {
        guard !usage.id.isEmpty, !session.isEmpty else { return }
        load()
        guard !ids.contains(Self.key(provider, usage.id)) else { return }
        let account = usage.account ?? knownAccount(provider, session, at: usage.at)
        guard let account, !account.isEmpty, !account.hasPrefix("plan:") else { return }
        add(
            UsageLine(
                n: nextNumber(), at: Self.ms(usage.at), chat: session, provider: provider, id: usage.id, model: usage.model, agent: usage.agent,
                input: usage.input, output: usage.output, cacheRead: usage.cacheRead, cacheWrite5m: usage.cacheWrite5m,
                cacheWrite1h: usage.cacheWrite1h, acct: account))
    }

    /// A plan reading this Mac heard or made: kept when it names its login and is this Mac's own.
    package func plan(_ snapshot: PlanSnapshot) {
        guard Self.ownSources.contains(snapshot.source), let account = snapshot.account, !account.isEmpty, !account.hasPrefix("plan:"),
            !snapshot.windows.isEmpty
        else { return }
        load()
        let readings = snapshot.windows.map {
            PlanWindowWire(minutes: $0.minutes, used: $0.used, resets: $0.resetsAt.map(Self.ms), limit: $0.limit)
        }
        // A Claude turn's report names its session, as this ledger's request lines do.
        let chat = snapshot.cli == "claude" ? snapshot.chat : nil
        add(UsageLine.plan(n: nextNumber(), at: Self.ms(snapshot.at), provider: snapshot.cli, acct: account, readings: readings, chat: chat))
    }

    // MARK: Out

    /// The lines after `cursor` within the week, at most `pageMax`; plan lines only for an asker
    /// that takes them.
    package func since(_ cursor: Int?, id: String, plan: Bool) -> UsageWire.Page {
        load()
        let time = now()
        let after = (lines ?? []).filter { $0.n > (cursor ?? 0) && !old($0, at: time) }
        let all = plan ? after : after.filter { !$0.isPlan }
        let page = Array(all.prefix(Self.pageMax))
        let end = page.count < all.count ? page.last?.n : after.last?.n
        return UsageWire.Page(id: id, lines: page, cursor: end ?? cursor ?? 0, more: all.count > page.count)
    }

    // MARK: The file

    private static func key(_ provider: String, _ id: String) -> String { provider + "|" + id }
    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// A chat's login at `time` as Kore noted it: from what was read last, else read again (a chat
    /// started since), at most once a second.
    private func knownAccount(_ provider: String, _ session: String, at time: Date) -> String? {
        if let cache = knownCache, let found = cache.value.account(provider, session, at: time) { return found }
        let at = Date()
        if let cache = knownCache, at.timeIntervalSince(cache.at) < 1 { return nil }
        let value = known()
        knownCache = (at, value)
        return value.account(provider, session, at: time)
    }

    private func old(_ line: UsageLine, at time: Date) -> Bool { Double(Self.ms(time) - line.at) > Self.keep * 1000 }

    private func nextNumber() -> Int { (lines?.last?.n ?? 0) + 1 }

    private func load() {
        guard lines == nil else { return }
        let read = (try? Data(contentsOf: url)).map { data in
            data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(UsageLine.self, from: Data($0)) }
        } ?? []
        lines = read
        ids = Set(read.filter { !$0.isPlan }.map { Self.key($0.provider, $0.id) })
    }

    private func add(_ line: UsageLine) {
        var all = lines ?? []
        all.append(line)
        if !line.isPlan { ids.insert(Self.key(line.provider, line.id)) }
        let time = now()
        // Past a week and a day, the file is written again without what's past the week.
        if let first = all.first, Double(Self.ms(time) - first.at) > (Self.keep + 86400) * 1000 {
            all.removeAll { old($0, at: time) }
            lines = all
            ids = Set(all.filter { !$0.isPlan }.map { Self.key($0.provider, $0.id) })
            return rewrite(all)
        }
        lines = all
        guard var data = try? Self.encoder.encode(line) else { return }
        data.append(0x0A)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
    }

    private func rewrite(_ all: [UsageLine]) {
        var data = Data()
        for line in all {
            guard let one = try? Self.encoder.encode(line) else { continue }
            data.append(one)
            data.append(0x0A)
        }
        try? LoginVault.writePrivate(data, to: url)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}
