import Foundation
import KoreCore
import LinkProtocol

/// The box's logins' plan windows for the link (`clis[].usage`, 1.14): Claude's accounts by id
/// ("main", then each folder of `~/.config/claude-accounts`) and Codex's one login ("main"). It
/// keeps what the box already hears (a turn's `rate_limit_event`, Codex's pushed limits, a usage
/// read the Mac asked for) as the Mac's usage mark keeps it (`UsageCueBook`: the highest reading
/// of each window), and reads only when a client asks (`account.usage` without a login, a
/// phone's screen opening): each login at most once a minute, one CLI at a time. Emails are
/// always masked: a box has no privacy switch, and a phone needs only to tell them apart.
@MainActor
package final class HostPlanUsage {
    /// One login's reading (tests answer for it).
    package var read: @MainActor (_ cli: String, _ login: String) async throws -> PlanReading
    /// The logins a CLI has here now, "main" first; none for a CLI that isn't installed.
    package var logins: @MainActor (_ cli: String) -> [String] = { _ in [] }
    /// What the link sends changed: the daemon pushes `clis` again.
    package var changed: @MainActor () -> Void = {}
    package var now: () -> Date = { Date() }
    /// A login read this recently isn't read again.
    package static let fresh: TimeInterval = 60
    package static let clis = ["claude", "codex"]

    private var book = UsageCueBook()
    /// Who each login is, as its last reading or listing said, by CLI then login.
    private var who: [String: [String: (email: String?, plan: String?)]] = [:]
    private var readAt: [String: Date] = [:]
    /// A CLI whose logins are being read now: a second ask joins it.
    private var reading: [String: Task<Void, Never>] = [:]
    /// What goes out, by CLI, as last made.
    package private(set) var pushed: [String: [AccountUsage]] = [:]

    package init(read: @escaping @MainActor (String, String) async throws -> PlanReading) {
        self.read = read
    }

    // MARK: What the box hears

    /// A reading of `login` (a phone's ask, or the Mac's `account.usage`).
    package func take(_ cli: String, login: String, reading: PlanReading) {
        var known = who[cli]?[login] ?? (nil, nil)
        if reading.account.access != .signedOut {
            known.email = reading.account.email ?? known.email
            known.plan = AccountUsage.pill(reading) ?? known.plan
        }
        who[cli, default: [:]][login] = known
        if let key = Self.key(cli, login: login, email: known.email) { book.take(key, UsageCueBook.Reading.from(reading)) }
        update()
    }

    /// A turn's windows (`ChatServices.planWindows`): Claude's carry its account's email hash;
    /// Codex's are its one login's.
    package func take(_ cli: String, snapshot: PlanSnapshot?) {
        guard let snapshot else { return }
        let key: String? =
            switch cli {
            case "codex": "codex"
            case "claude": snapshot.account.flatMap { $0.hasPrefix("plan:") ? nil : "claude:" + $0 }
            default: nil
            }
        guard let key else { return }
        book.take(key, UsageCueBook.Reading.from(snapshot))
        update()
    }

    /// The box's Claude accounts as last listed (`account.list`): who each one is.
    package func listed(_ accounts: [LinkAccount]) {
        for account in accounts where account.signedIn == true {
            var known = who["claude"]?[account.id] ?? (nil, nil)
            known.email = account.email ?? known.email
            known.plan = AccountUsage.pill(plan: account.plan, perToken: false) ?? known.plan
            who["claude", default: [:]][account.id] = known
        }
        update()
    }

    /// Where a login's windows are kept: Claude's by its email's hash (a turn names only that),
    /// Codex's one login as "codex".
    static func key(_ cli: String, login: String, email: String?) -> String? {
        switch cli {
        case "codex": "codex"
        case "claude": PlanSnapshot.account(email: email).map { "claude:" + $0 }
        default: nil
        }
    }

    // MARK: Reads

    /// A client asked (`account.usage` without a login): each of the CLI's logins not read in
    /// the last minute is read, one at a time; one under way is joined.
    package func refresh(_ cli: String) {
        guard Self.clis.contains(cli), reading[cli] == nil else { return }
        let due = logins(cli).filter { login in readAt[cli + "/" + login].map { now().timeIntervalSince($0) >= Self.fresh } ?? true }
        guard !due.isEmpty else { return }
        reading[cli] = Task { [weak self] in
            for login in due {
                guard let self, !Task.isCancelled else { return }
                self.readAt[cli + "/" + login] = self.now()
                HostJournal.note("usage read", ["cli": cli, "login": login])
                if let reading = try? await self.read(cli, login) { self.take(cli, login: login, reading: reading) }
            }
            self?.reading[cli] = nil
        }
    }

    /// The reads under way, for a test to wait on.
    package func settled() async {
        for task in reading.values { await task.value }
    }

    // MARK: What goes out

    /// Each CLI's logins, made again: the daemon pushes when they changed.
    package func update() {
        made = true
        let now = current()
        guard now != pushed else { return }
        pushed = now
        changed()
    }

    /// Whether `pushed` was made yet (a first snapshot makes it, without a push).
    private var made = false

    private func current() -> [String: [AccountUsage]] {
        var out: [String: [AccountUsage]] = [:]
        for cli in Self.clis {
            // Nothing heard of this CLI's logins yet: none to show, and its accounts aren't listed
            // (a daemon that just started reads no folder for it).
            guard who[cli]?.isEmpty == false || book.tracks.keys.contains(where: { $0 == cli || $0.hasPrefix(cli + ":") }) else { continue }
            // A login nobody has named yet (not read, or signed out) isn't one to show.
            let entries = logins(cli).map { entry(cli, login: $0) }.filter { $0.email != nil || !$0.limits.isEmpty }
            if !entries.isEmpty { out[cli] = entries }
        }
        return out
    }

    private func entry(_ cli: String, login: String) -> AccountUsage {
        let known = who[cli]?[login]
        let tracks = Self.key(cli, login: login, email: known?.email).flatMap { book.tracks[$0] } ?? [:]
        return AccountUsage(
            login: login, email: (known?.email).map(AccountUsage.mask), active: login == LinkAccount.main, plan: known?.plan ?? nil,
            limits: AccountUsage.limits(tracks))
    }

    /// The CLIs as the link carries them: their models (`clis`), each with its logins' usage; a
    /// CLI with usage and no models yet is listed for its usage alone.
    package func carried(_ clis: [CLIState]) -> [CLIState] {
        if !made {
            made = true
            pushed = current()
        }
        var out = clis.map { cli in
            var cli = cli
            cli.usage = pushed[cli.provider]
            return cli
        }
        for (provider, usage) in pushed.sorted(by: { $0.key < $1.key }) where !clis.contains(where: { $0.provider == provider }) {
            out.append(CLIState(provider: provider, models: [], effortScale: [], usage: usage))
        }
        return out.sorted { $0.provider < $1.provider }
    }
}
