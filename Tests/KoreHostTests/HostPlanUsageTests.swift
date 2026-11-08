import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol

/// What a box reads of reading counts, by login ("main", a folder's name, "codex").
@MainActor
final class UsageReads {
    var counts: [String: Int] = [:]
    func add(_ login: String) { counts[login, default: 0] += 1 }
}

/// The box's logins' usage (link 1.14 `clis[].usage`): pushed to a phone's grant as it changes,
/// read again only when asked and at most once a minute each, Claude's accounts and Codex's one
/// login alike; emails masked. No real CLI, login or token: the folders are a test's, the readings fakes.
@Suite("kore-host, logins' usage", .serialized)
@MainActor
struct HostPlanUsageTests {
    nonisolated static let five = Date(timeIntervalSince1970: 1_795_161_600)
    nonisolated static let week = Date(timeIntervalSince1970: 1_795_507_200)

    nonisolated static func reading(_ email: String, plan: String, five: Double, week: Double) -> PlanReading {
        PlanReading(
            account: PlanAccount(plan: plan, email: email, access: .plan),
            limits: PlanLimits(bars: [
                PlanLimit(title: "Session (5hr)", used: five, resetsAt: Self.five, window: 5 * 3600),
                PlanLimit(title: "Weekly (7 day)", used: week, resetsAt: Self.week, window: 7 * 24 * 3600),
                // A model's own week stays in Usage on the Mac: never pushed.
                PlanLimit(title: "Weekly Sonnet", used: 99, resetsAt: Self.week, window: 7 * 24 * 3600, scope: "Sonnet"),
            ]))
    }

    /// A box with both CLIs listed (their models kept from before), a default Claude account and
    /// one added ("ajinkya"); every reading a fake, counted. `now` moves only when a test says.
    func rig(_ reads: UsageReads, now: @escaping () -> Date) throws -> HostRig {
        let rig = try HostRig()
        let models = [CLIState(provider: "claude", models: [], effortScale: []), CLIState(provider: "codex", models: [], effortScale: [])]
        try FileManager.default.createDirectory(at: rig.paths.models.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(models).write(to: rig.paths.models)
        rig.restart()
        try FileManager.default.createDirectory(at: rig.root.appendingPathComponent(".config/claude-accounts/ajinkya"), withIntermediateDirectories: true)
        // The scratch home before anything reads the accounts.
        rig.host.sessionEnv = ["HOME": rig.root.path]
        rig.host.accounts.usage = { folder in
            let login = folder?.lastPathComponent ?? "main"
            await MainActor.run { reads.add(login) }
            return login == "ajinkya"
                ? Self.reading("ajinkya@onfinance.in", plan: "Claude Team", five: 100, week: 93)
                : Self.reading("me@example.com", plan: "Claude Max", five: 42.4, week: 81)
        }
        rig.host.codexUsage = {
            await MainActor.run { reads.add("codex") }
            return Self.reading("me@example.com", plan: "ChatGPT Pro", five: 18, week: 44)
        }
        rig.host.planUsage.now = now
        return rig
    }

    func connect(_ rig: HostRig, _ control: GrantControl) async throws -> Client {
        try rig.host.start()
        let grant = try GrantStore(rig.paths.grants).allow("phone", control: control, socket: rig.paths.socket)
        let client = try Client(rig.paths.socket)
        try await until { !client.got.isEmpty }
        client.hello(grant: grant)
        try await until { client.got.contains { if case .snapshot = $0 { true } else { false } } }
        return client
    }

    /// The last usage the client was sent, by "cli/login".
    func usage(_ client: Client) -> [String: AccountUsage] {
        var out: [String: AccountUsage] = [:]
        for message in client.got {
            let extras: LinkExtras? =
                switch message {
                case .snapshot(_, _, _, let extras), .delta(_, _, _, _, let extras): extras
                default: nil
                }
            for cli in extras?.clis ?? [] { for login in cli.usage ?? [] { out[cli.provider + "/" + login.login] = login } }
        }
        return out
    }

    func result(_ client: Client, _ id: String) -> LinkMessage.Result? {
        for message in client.got.reversed() { if case .result(let r) = message, r.id == id { return r } }
        return nil
    }

    @Test func aPhonesAskReadsEachLoginOnceAMinuteAndPushesItMasked() async throws {
        let reads = UsageReads()
        var clock = Date(timeIntervalSince1970: 1_795_150_000)
        let rig = try rig(reads, now: { clock })
        defer { rig.finish() }
        let started = ContinuousClock.now
        let phone = try await connect(rig, .act)
        // The first snapshot: nothing known yet, and no CLI ran to make it.
        #expect(usage(phone).isEmpty)
        #expect(reads.counts.isEmpty)

        phone.socket.send(.cmd(id: "u1", .control(.accountUsage, ControlArgs(provider: "claude"))))
        try await until { usage(phone)["claude/ajinkya"]?.limits.isEmpty == false && usage(phone)["claude/main"]?.limits.isEmpty == false }
        #expect(result(phone, "u1")?.ok == true)
        let main = try #require(usage(phone)["claude/main"])
        // Masked always, the plan's short name, whole percents, resets to the second; no model's own week.
        #expect(main == AccountUsage(
            login: "main", email: "me••••@••le.com", active: true, plan: "Max",
            limits: [.init(kind: "5h", used: 42, resetsAt: 1_795_161_600_000), .init(kind: "7d", used: 81, resetsAt: 1_795_507_200_000)]))
        #expect(usage(phone)["claude/ajinkya"]?.limits.first == .init(kind: "5h", used: 100, resetsAt: 1_795_161_600_000))
        #expect(usage(phone)["claude/ajinkya"]?.plan == "Team")
        #expect(reads.counts == ["main": 1, "ajinkya": 1])
        // No email or token on the wire in clear.
        #expect(!phone.raws.contains { String(decoding: $0, as: UTF8.self).contains("example.com") })

        // Asked again within the minute: nothing runs.
        phone.socket.send(.cmd(id: "u2", .control(.accountUsage, ControlArgs(provider: "claude"))))
        try await until { result(phone, "u2") != nil }
        await rig.host.planUsage.settled()
        #expect(reads.counts == ["main": 1, "ajinkya": 1])
        // A minute on: read again.
        clock += 61
        phone.socket.send(.cmd(id: "u3", .control(.accountUsage, ControlArgs(provider: "claude"))))
        try await until { reads.counts == ["main": 2, "ajinkya": 2] }

        // Codex's one login, the same way.
        phone.socket.send(.cmd(id: "u4", .control(.accountUsage, ControlArgs(provider: "codex"))))
        try await until { usage(phone)["codex/main"]?.limits.isEmpty == false }
        #expect(usage(phone)["codex/main"]?.plan == "Pro")
        #expect(usage(phone)["codex/main"]?.limits.map(\.used) == [18, 44])
        // Read-only: a phone names no login; a login's own reading is a full grant's.
        phone.socket.send(.cmd(id: "u5", .control(.accountUsage, ControlArgs(provider: "claude", login: "main"))))
        try await until { result(phone, "u5") != nil }
        #expect(result(phone, "u5")?.code == .deniedControl)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func offScreenItWaitsAndAWatchGrantIsRefused() async throws {
        let reads = UsageReads()
        let rig = try rig(reads, now: { Date(timeIntervalSince1970: 1_795_150_000) })
        defer { rig.finish() }
        let phone = try await connect(rig, .act)
        phone.socket.send(.presence(onScreen: false, chatId: nil))
        try await until { rig.host.provenClients.contains { !$0.onScreen } }
        let before = phone.got.count
        rig.host.planUsage.take("codex", login: "main", reading: Self.reading("me@example.com", plan: "ChatGPT Pro", five: 60, week: 70))
        #expect(phone.got.count == before)
        // Back on screen: what it missed comes whole.
        phone.socket.send(.presence(onScreen: true, chatId: nil))
        try await until { usage(phone)["codex/main"]?.limits.map(\.used) == [60, 70] }

        let other = try self.rig(reads, now: { Date() })
        defer { other.finish() }
        let watch = try await connect(other, .watch)
        watch.socket.send(.cmd(id: "w1", .control(.accountUsage, ControlArgs(provider: "claude"))))
        try await until { result(watch, "w1") != nil }
        #expect(result(watch, "w1")?.code == .deniedControl)
        // A watch grant gets no CLIs at all.
        #expect(usage(watch).isEmpty)
    }

    @Test func theMacReadsCodexsOneLoginToo() async throws {
        let reads = UsageReads()
        let rig = try rig(reads, now: { Date(timeIntervalSince1970: 1_795_150_000) })
        defer { rig.finish() }
        func apply(_ args: ControlArgs, _ control: GrantControl = .full) async throws -> LinkMessage.Result {
            var later: LinkMessage.Result?
            if let now = rig.host.apply(.control(.accountUsage, args), id: "r", control: control, reply: { later = $0 }) { return now }
            try await until { later != nil }
            return later!
        }
        let codex = try await apply(ControlArgs(provider: "codex", login: "main"))
        #expect(codex.ok)
        #expect(codex.reading?.account.plan == "ChatGPT Pro")
        // Kept for what the link pushes as well.
        #expect(rig.host.planUsage.pushed["codex"]?.first?.limits.map(\.used) == [18, 44])
        #expect(try await apply(ControlArgs(provider: "codex", login: "work")).ok == false)
        let claude = try await apply(ControlArgs(provider: "claude", login: "ajinkya"))
        #expect(claude.reading?.account.email == "ajinkya@onfinance.in")
        #expect(rig.host.planUsage.pushed["claude"]?.first { $0.login == "ajinkya" }?.limits.first?.used == 100)
        #expect(try await apply(ControlArgs(provider: "codex", login: "main"), .act).code == .deniedControl)
        #expect(reads.counts == ["codex": 1, "ajinkya": 1])
    }

    @Test func aTurnsWindowsReachTheirLoginWithNoRead() async throws {
        let reads = UsageReads()
        let rig = try rig(reads, now: { Date(timeIntervalSince1970: 1_795_150_000) })
        defer { rig.finish() }
        let usage = rig.host.planUsage
        // Who "ajinkya" is, from the box's account list.
        usage.listed([LinkAccount(id: "ajinkya", email: "ajinkya@onfinance.in", plan: "Claude Team", signedIn: true)])
        let windows = [PlanSnapshot.Window(minutes: 300, used: 87.4, resetsAt: Self.five), PlanSnapshot.Window(minutes: 10080, used: 40, resetsAt: Self.week)]
        rig.host.services.planWindows(
            "claude", PlanSnapshot(at: Date(), cli: "claude", account: PlanSnapshot.account(email: "ajinkya@onfinance.in"), source: "stream", windows: windows))
        rig.host.services.planWindows("codex", PlanSnapshot(at: Date(), cli: "codex", account: nil, source: "stream", windows: windows))
        let pushed = usage.pushed
        #expect(pushed["claude"]?.first { $0.login == "ajinkya" }?.limits.map(\.used) == [87, 40])
        #expect(pushed["claude"]?.first { $0.login == "ajinkya" }?.email == "aj••••@••ce.in")
        // A login nobody has named or read isn't shown.
        #expect(pushed["claude"]?.contains { $0.login == "main" } == false)
        #expect(pushed["codex"]?.first?.limits.map(\.used) == [87, 40])
        // A lower reading in the same window is rounding, not a fall.
        rig.host.services.planWindows("codex", PlanSnapshot(at: Date(), cli: "codex", account: nil, source: "stream", windows: [PlanSnapshot.Window(minutes: 300, used: 86, resetsAt: Self.five)]))
        #expect(usage.pushed["codex"]?.first?.limits.first?.used == 87)
        #expect(reads.counts.isEmpty)
    }
}
