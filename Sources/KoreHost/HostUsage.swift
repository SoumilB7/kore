import Foundation
import KoreCore
import LinkProtocol
import src

/// `usage/ledger.jsonl`: a line per model request the box's chats made, with the login it ran
/// on, and a line per plan reading the box heard (`UsageLine.plan`), a week of them, numbered
/// so the Mac asks for what follows its cursor. Append-only; nothing runs on a timer: a write
/// whose oldest line is past a week and a day rewrites the file without the lines past a week
/// (so at most about once a day), and reads skip lines past a week.
@MainActor
package final class UsageLedger {
    package let url: URL
    private let now: () -> Date
    /// The next line's number and the oldest line's time, read from the file on first use.
    private var next: Int?
    private var oldest: Date?

    package static let keep: TimeInterval = 7 * 86400
    package static let slack: TimeInterval = 86400
    package static let pageMax = 500

    package init(url: URL, now: @escaping () -> Date) {
        self.url = url
        self.now = now
    }

    /// A request, counted for `account` (the login it ran on; nil when the box doesn't know).
    package func append(chat: String, provider: String, _ usage: RequestUsage, account: String? = nil) {
        let lines = loadIfNeeded()
        let n = next ?? 1
        let line = UsageLine(
            n: n, at: Int64(usage.at.timeIntervalSince1970 * 1000), chat: chat, provider: provider, id: usage.id, model: usage.model,
            agent: usage.agent, input: usage.input, output: usage.output, cacheRead: usage.cacheRead, cacheWrite5m: usage.cacheWrite5m,
            cacheWrite1h: usage.cacheWrite1h, acct: usage.account ?? account)
        next = n + 1
        write(line, lines)
    }

    /// The plan's windows as a turn reported them (or a quiet read), for `account`: a line of their
    /// own, naming the box chat whose request the report came before (`chat`, as the request
    /// lines name it; nil for a read). A report that doesn't name its login isn't kept.
    package func appendPlan(provider: String, account: String?, chat: String? = nil, _ snapshot: PlanSnapshot) {
        guard let account, !account.hasPrefix("plan:"), !snapshot.windows.isEmpty else { return }
        let lines = loadIfNeeded()
        let n = next ?? 1
        let readings = snapshot.windows.map {
            PlanWindowWire(minutes: $0.minutes, used: $0.used, resets: $0.resetsAt.map { Int64($0.timeIntervalSince1970 * 1000) }, limit: $0.limit)
        }
        let line = UsageLine.plan(
            n: n, at: Int64(snapshot.at.timeIntervalSince1970 * 1000), provider: provider, acct: account, readings: readings, chat: chat)
        next = n + 1
        write(line, lines)
    }

    private func write(_ line: UsageLine, _ lines: [UsageLine]?) {
        let time = now()
        if let oldest, time.timeIntervalSince(oldest) > Self.keep + Self.slack {
            let kept = (lines ?? read()).filter { !old($0, at: time) } + [line]
            rewrite(kept)
            return
        }
        if oldest == nil { oldest = Date(timeIntervalSince1970: Double(line.at) / 1000) }
        guard var data = try? Self.encoder.encode(line) else { return }
        data.append(0x0A)
        do {
            try HostPaths.privateFolder(url.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: url.path) { try HostPaths.privateFile(Data(), to: url) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            HostJournal.writeFailed(url, HostJournal.code(error))
        }
    }

    /// The lines after `cursor` within the week, at most `pageMax`; plan lines only for an asker
    /// that takes them (`plan`). Reads the whole file (a week of lines, asked once per link-up
    /// and when the Mac's usage card opens): left so, a seek index would cost more than it saves.
    package func since(_ cursor: Int?, id: String, plan: Bool = false) -> UsageWire.Page {
        let time = now()
        let after = read().filter { $0.n > (cursor ?? 0) && !old($0, at: time) }
        let all = plan ? after : after.filter { !$0.isPlan }
        let page = Array(all.prefix(Self.pageMax))
        // Past the last line read, plan lines skipped included: the next ask starts after them.
        let end = page.count < all.count ? page.last?.n : after.last?.n
        return UsageWire.Page(id: id, lines: page, cursor: end ?? cursor ?? 0, more: all.count > page.count)
    }

    private func old(_ line: UsageLine, at time: Date) -> Bool { time.timeIntervalSince1970 * 1000 - Double(line.at) > Self.keep * 1000 }

    /// Reads the file once to learn the next number and the oldest time; the lines when it read them.
    private func loadIfNeeded() -> [UsageLine]? {
        guard next == nil else { return nil }
        let lines = read()
        next = (lines.last?.n ?? 0) + 1
        oldest = lines.first.map { Date(timeIntervalSince1970: Double($0.at) / 1000) }
        return lines
    }

    private func read() -> [UsageLine] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(UsageLine.self, from: Data($0)) }
    }

    private func rewrite(_ lines: [UsageLine]) {
        var data = Data()
        for line in lines {
            guard let one = try? Self.encoder.encode(line) else { continue }
            data.append(one)
            data.append(0x0A)
        }
        do {
            try HostPaths.privateFolder(url.deletingLastPathComponent())
            try HostPaths.privateFile(data, to: url)
        } catch {
            HostJournal.writeFailed(url, HostJournal.code(error))
        }
        oldest = lines.first.map { Date(timeIntervalSince1970: Double($0.at) / 1000) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}
