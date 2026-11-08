import Foundation
import KoreCore
import Testing

@testable import KoreHost
@testable import LinkProtocol
@testable import src

/// A CLI that records each start's environment (as the real backend reads it at launch) and its
/// relaunches, on one session.
@MainActor
final class AccountStandIn: ChatBackend {
    let events: AsyncStream<ChatEvent>
    let sink: AsyncStream<ChatEvent>.Continuation
    var options: BackendOptions?
    /// Each start's `CLAUDE_CONFIG_DIR` ("" for none), in order.
    var starts: [String] = []
    var relaunches = 0
    var failures: [String] = []
    private var running = false
    var sessionId: String? { "s1" }
    init() { (events, sink) = AsyncStream.makeStream() }
    func start() async throws {
        guard !running else { return }
        do {
            let env = try options?.environment?() ?? [:]
            starts.append(env["CLAUDE_CONFIG_DIR"] ?? "")
        } catch {
            failures.append(error.localizedDescription)
            throw error
        }
        running = true
        sink.yield(.sessionIdentified("s1"))
    }
    func relaunch(reason: String) async {
        relaunches += 1
        running = false
    }
    func relaunchAfterAccountChange() async -> Bool {
        relaunches += 1
        running = false
        return true
    }
    func send(_ text: String, files: [Attachments.File], queued: String?, id: String?) async throws -> Bool { false }
    func interrupt() async {}
    func respond(to approvalID: String, _ decision: Decision) async {}
    func setMode(_ id: String) async throws {}
    func setPlanMode(_ on: Bool) async {}
    func setModel(_ id: String) async throws {}
    func setEffort(_ level: String) async {}
    func rename(_ title: String) async throws {}
    func stopAgent(_ id: String) async {}
    func agentHistory(_ id: String) async -> [ChatEvent] { [] }
    func fork(message id: String?, text: String) async throws -> ForkStart { .fresh }
    func forkAtEnd() async throws -> ForkStart { .fresh }
    func rollback(message id: String?, text: String) async throws -> (events: [ChatEvent], more: Bool) { ([], false) }
    func earlier() async -> (events: [ChatEvent], more: Bool)? { nil }
    func close() async { sink.finish() }
}

/// What the fake `claude auth status` was asked, by folder ("" for the default's).
final class StatusCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var all: [String] { lock.withLock { asked } }
    func add(_ folder: URL?) { lock.withLock { asked.append(folder?.lastPathComponent ?? "") } }
}

/// The box's Claude accounts (phase 17): listed from the default and `~/.config/claude-accounts`,
/// a chat's CLI started with its account's folder, a switch resuming the chat's session there,
/// and no sign-out ever run. No real CLI, login or token: the folders are a test's, the status a fake.
@Suite("kore-host, Claude accounts", .serialized)
@MainActor
struct HostAccountsTests {
    /// A rig whose home holds a default `.claude` and two account folders; `ajinkya` signed in.
    func rig(_ calls: StatusCalls = StatusCalls()) throws -> HostRig {
        let rig = try HostRig()
        let home = rig.root
        let files = FileManager.default
        let main = home.appendingPathComponent(".claude")
        try files.createDirectory(at: main.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: main.appendingPathComponent("settings.json"))
        try Data("main-own".utf8).write(to: main.appendingPathComponent(".credentials.json"))
        let accounts = home.appendingPathComponent(".config/claude-accounts")
        for name in ["ajinkya", "work", ".hidden", "main", "bad name"] {
            try files.createDirectory(at: accounts.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("placeholder".utf8).write(to: accounts.appendingPathComponent("ajinkya/.credentials.json"))
        try Data("{}".utf8).write(to: accounts.appendingPathComponent("ajinkya/.claude.json"))
        try Data().write(to: accounts.appendingPathComponent("loose-file"))
        rig.host.sessionEnv = ["HOME": home.path]
        rig.host.accounts.status = { folder in
            calls.add(folder)
            switch folder?.lastPathComponent {
            case nil: return ["loggedIn": true, "email": "me@example.com", "subscriptionType": "max"]
            case "ajinkya": return ["loggedIn": true, "email": "ajinkya@onfinance.in", "orgName": "OnFinance", "subscriptionType": "team"]
            default: return ["loggedIn": false]
            }
        }
        return rig
    }

    func apply(_ rig: HostRig, _ kind: ControlKind, _ args: ControlArgs, _ control: GrantControl = .full) async throws -> LinkMessage.Result {
        var later: LinkMessage.Result?
        if let now = rig.host.apply(.control(kind, args), id: kind.rawValue, control: control, reply: { later = $0 }) { return now }
        try await until { later != nil }
        return later!
    }

    var accountsRoot: (HostRig) -> URL { { $0.root.appendingPathComponent(".config/claude-accounts") } }

    @Test func listsTheDefaultAndEachAccountFolderOnDemand() async throws {
        let calls = StatusCalls()
        let rig = try rig(calls)
        defer { rig.finish() }
        #expect(calls.all.isEmpty)
        let result = try await apply(rig, .accountList, ControlArgs(provider: "claude"))
        #expect(result.ok)
        let accounts = try #require(result.accounts)
        // The default first, then each folder by name; a dotfolder, "main", a name the link can't
        // carry and a loose file aren't accounts.
        #expect(accounts.map(\.id) == ["main", "ajinkya", "work"])
        #expect(accounts[0] == LinkAccount(id: "main", email: "me@example.com", plan: "Claude Max", signedIn: true))
        #expect(accounts[1] == LinkAccount(id: "ajinkya", email: "ajinkya@onfinance.in", organization: "OnFinance", plan: "Claude Team", signedIn: true))
        #expect(accounts[2] == LinkAccount(id: "work", signedIn: false))
        #expect(Set(calls.all) == ["", "ajinkya", "work"] && calls.all.count == 3)
        // Read again within the half minute: answered as it was, no CLI run.
        _ = try await apply(rig, .accountList, ControlArgs(provider: "claude"))
        #expect(calls.all.count == 3)
        // A status that can't be read says so (nil), not signed out.
        rig.host.accounts.status = { _ in throw CocoaError(.fileReadUnknown) }
        #expect(await rig.host.accounts.list(fresh: true).allSatisfy { $0.signedIn == nil && $0.email == nil })
        // A read writes nothing in an account's folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: accountsRoot(rig).appendingPathComponent("ajinkya").path).sorted() == [".claude.json", ".credentials.json"])
        // Claude only: Codex keeps its one login on a box.
        #expect(try await apply(rig, .accountList, ControlArgs(provider: "codex")).message == LinkPolicy.boxAccountsClaudeOnly)
        // Accounts are a full grant's.
        #expect(try await apply(rig, .accountList, ControlArgs(provider: "claude"), .act).code == .deniedControl)
    }

    @Test func aChatsCLIStartsInItsAccountsFolder() async throws {
        let rig = try rig()
        defer { rig.finish() }
        let backend = AccountStandIn()
        rig.host.services.backend = { _, options in
            backend.options = options
            return backend
        }
        let folder = rig.folder.path
        // The folder's default is the default account: a new chat runs as kore-host does.
        let plain = try #require(rig.host.newChat(folder: folder, provider: "claude", modelId: nil))
        #expect(plain.record.account == nil)
        await plain.live(services: rig.host.services).start()
        #expect(backend.starts == [""])

        // The folder's default set: its new chats start on that account, in its folder.
        #expect(try await apply(rig, .accountSwitch, ControlArgs(provider: "claude", login: "ajinkya", folder: folder)).ok)
        let chat = try #require(rig.host.newChat(folder: folder, provider: "claude", modelId: nil))
        #expect(chat.record.account == "ajinkya")
        let account = accountsRoot(rig).appendingPathComponent("ajinkya")
        let env = try #require(rig.host.services.accountEnvironment)
        #expect(try env("ajinkya") == ["CLAUDE_CONFIG_DIR": account.path])
        #expect(try env(nil).isEmpty && env("main").isEmpty)
        // The default's chats and settings are linked in; its own files are never touched, and
        // the default's login isn't linked.
        let files = FileManager.default
        #expect(try files.destinationOfSymbolicLink(atPath: account.appendingPathComponent("projects").path) == rig.root.appendingPathComponent(".claude/projects").path)
        #expect(try String(contentsOf: account.appendingPathComponent(".credentials.json"), encoding: .utf8) == "placeholder")
        #expect((try? files.destinationOfSymbolicLink(atPath: account.appendingPathComponent(".credentials.json").path)) == nil)
        // Codex chats take no account.
        let codex = try #require(rig.host.newChat(folder: folder, provider: "codex", modelId: nil))
        #expect(codex.record.account == nil)
        // An account folder that's gone: the CLI doesn't start, and nothing falls back to another.
        try files.removeItem(at: account)
        #expect(throws: HostAccounts.Failure.self) { try env("ajinkya") }
        let lone = AccountStandIn()
        rig.host.services.backend = { _, options in
            lone.options = options
            return lone
        }
        _ = chat.live(services: rig.host.services).connect()
        try? await lone.start()
        #expect(lone.starts.isEmpty && lone.failures.first?.contains("“ajinkya” isn't on this machine") == true)
    }

    @Test func aSwitchResumesTheSameSessionAsTheNewAccount() async throws {
        let rig = try rig()
        defer { rig.finish() }
        try rig.host.start()
        let backend = AccountStandIn()
        var made = 0
        rig.host.services.backend = { _, options in
            made += 1
            backend.options = options
            return backend
        }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        let chat = hc.live(services: rig.host.services)
        await chat.start()
        #expect(backend.starts == [""])

        let result = try await apply(rig, .accountSwitch, ControlArgs(chatId: hc.id, provider: "claude", login: "ajinkya"))
        #expect(result.ok && result.login == "ajinkya" && result.folderLogin == "ajinkya")
        // Its CLI ended and started again: the same backend on the same session, as the new account.
        try await until { backend.starts.count == 2 }
        let account = accountsRoot(rig).appendingPathComponent("ajinkya").path
        #expect(backend.starts == ["", account] && backend.relaunches == 1 && made == 1)
        #expect(backend.sessionId == "s1" && hc.record.account == "ajinkya")
        // Its list now says so, and the folder's new chats start on it.
        let list = try await apply(rig, .accountList, ControlArgs(chatId: hc.id, provider: "claude"))
        #expect(list.login == "ajinkya" && list.folderLogin == "ajinkya")
        // The same account again does nothing; back to the default resumes there.
        _ = try await apply(rig, .accountSwitch, ControlArgs(chatId: hc.id, provider: "claude", login: "ajinkya"))
        #expect(backend.relaunches == 1)
        #expect(try await apply(rig, .accountSwitch, ControlArgs(chatId: hc.id, provider: "claude", login: "main")).ok)
        try await until { backend.starts.count == 3 }
        #expect(backend.starts.last == "" && hc.record.account == nil)
        // Kept across a restart.
        _ = try await apply(rig, .accountSwitch, ControlArgs(chatId: hc.id, provider: "claude", login: "ajinkya"))
        let id = hc.id
        rig.restart()
        rig.host.sessionEnv = ["HOME": rig.root.path]
        #expect(rig.host.chat(id)?.record.account == "ajinkya")
        #expect(rig.host.accounts.folderDefault(rig.folder.path) == "ajinkya")
        // Refused: an account that isn't there, a Codex chat.
        #expect(try await apply(rig, .accountSwitch, ControlArgs(chatId: id, provider: "claude", login: "nobody")).code == .goneLogin)
        #expect(try await apply(rig, .accountSwitch, ControlArgs(chatId: id, provider: "codex", login: "main")).code == .invalid)
    }

    @Test func aChatsStatusIsItsOwnAccounts() async throws {
        let calls = StatusCalls()
        let rig = try rig(calls)
        defer { rig.finish() }
        let hc = try #require(rig.host.newChat(folder: rig.folder.path, provider: "claude", modelId: nil))
        hc.setAccount("ajinkya")
        let said = try await apply(rig, .accountRefresh, ControlArgs(chatId: hc.id, provider: "claude"))
        #expect(said.signedIn == true && said.account?.email == "ajinkya@onfinance.in")
        #expect(calls.all == ["ajinkya"])
    }

    @Test func noSignOutEverRunsOnABox() async throws {
        let rig = try rig()
        defer { rig.finish() }
        // Refused whatever the grant and the CLI, before anything runs.
        for provider in ["claude", "codex"] {
            for control in [GrantControl.full, .act] {
                let result = try await apply(rig, .accountSignOut, ControlArgs(provider: provider), control)
                #expect(!result.ok && result.message == LinkPolicy.boxSignOutRefused)
            }
        }
        #expect(LinkPolicy.checkBox(.accountSignOut, ControlArgs(provider: "claude"), nil, control: .full) == .deny(.invalid, LinkPolicy.boxSignOutRefused))
        // Nothing in kore-host or the Mac's box client can run a CLI's sign-out or ask a box for one.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        for target in ["KoreHost", "HostClient", "kore-host"] {
            let root = sources.appendingPathComponent(target).path
            for path in try FileManager.default.subpathsOfDirectory(atPath: root) where path.hasSuffix(".swift") {
                let source = try String(contentsOfFile: root + "/" + path, encoding: .utf8)
                for banned in [".signOut()", "ClaudeAuth.logout", "CodexAuth.logout", "\"logout\"", "\"account.signOut\""] {
                    #expect(!source.contains(banned), "\(target)/\(path) has \(banned)")
                }
            }
        }
    }
}
