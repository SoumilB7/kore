import Foundation
import KoreCore
import LinkProtocol
@testable import src
import Testing

@testable import KoreUI

/// How many times a fake CLI was asked to sign out.
final class SignOuts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

extension HostOverrideTests {
/// A box's Claude accounts in a box chat's Account popup, and this Mac's logins moved to a box:
/// listed and switched on the box alone, shown as on the box here, and never signed out. Fakes
/// for the CLI and the box; a test's own accounts folder.
@MainActor @Suite("Box logins")
struct BoxLoginsTests {
    private func calls(_ signOuts: SignOuts, signedIn: Bool) -> AccountCalls {
        AccountCalls(
            status: { signedIn ? ["loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com"] : ["loggedIn": false] },
            signIn: { _, _ in SignInHandle(url: URL(string: "https://example.com"), wait: { nil }, cancel: {}) },
            useKey: { _ in nil }, signOut: { signOuts.add() })
    }

    private func settle(_ check: () -> Bool) async throws {
        for _ in 0..<500 where !check() { try await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func aBoxChatListsTheBoxsAccountsAndSwitchesOnlyItself() async throws {
        let signOuts = SignOuts()
        let calls = calls(signOuts, signedIn: true)
        let methods = (Registry.provider("claude")?.account.methods ?? []).filter { LinkPolicy.boxSignIns.contains($0.id) }
        let store = AccountStore(calls: { _ in
            AccountOps(methods: methods, parse: { AccountText.claude(ClaudeAuth.Status($0)) }, calls: calls,
                loginFile: { _ in URL(fileURLWithPath: "/dev/null") }, stamp: nil)
        })
        var viewed = LinkAccount.main
        var switched: [String?] = []
        let accounts = [
            LinkAccount(id: "main", email: "me@example.com", signedIn: true),
            LinkAccount(id: "ajinkya", email: "ajinkya@onfinance.in", organization: "OnFinance", signedIn: true),
            LinkAccount(id: "work", signedIn: false),
        ]
        var box = AccountStore.BoxLogins(
            list: { _ in BoxAccountStores.rows(accounts, active: viewed) },
            switchTo: { _, login in
                switched.append(login)
                viewed = login ?? LinkAccount.main
                return nil
            },
            usage: { _, _ in throw UsageUnavailable() }, viewedIsMain: { viewed == LinkAccount.main })
        var usageReread = 0
        box.switched = { usageReread += 1 }
        store.box = box

        await store.refresh("claude")
        try await settle { store.logins("claude").count == 3 }
        let rows: [AccountStore.Login] = store.logins("claude")
        #expect(rows.map { $0.id } == [nil, "ajinkya", "work"] && rows.map { $0.active } == [true, false, false])
        #expect(rows[1].workspace == "OnFinance" && rows[2].signedOut && rows[2].workspace == nil)
        // Codex keeps its one login on a box.
        #expect(store.logins("codex").isEmpty)

        let macActive = CLIProfiles.active("claude")
        store.switchLogin("claude", to: "ajinkya", LoginPick.byHandOnLink())
        try await settle { usageReread == 1 }
        #expect(switched == ["ajinkya"] && store.logins("claude").first { $0.active }?.id == "ajinkya")
        // Nothing of this Mac's logins moved.
        #expect(CLIProfiles.active("claude") == macActive)
        // On another account the box doesn't sign in: no sign-in, add, remove or method list for it.
        #expect(!store.signInOffered("claude") && store.loginMenu("claude", "ajinkya").isEmpty && !store.loginMenu("claude", nil).isEmpty)
        let state = AccountState()
        state.open(provider: "claude", folder: URL(fileURLWithPath: "/tmp"), store: store)
        #expect(!state.addsLogins)
        #expect(!state.hasLoginMenu(rows[1]) && state.hasLoginMenu(rows[0]))
        state.close()

        // Never a sign-out on a box: not offered, and refused without asking the box.
        #expect(!store.signOutOffered("claude") && !store.signOutOffered("codex"))
        store.signOut("claude")
        guard case .signOutFailed(let why)? = store.flow("claude")?.step else {
            Issue.record("a box's sign-out wasn't refused")
            return
        }
        #expect(why?.contains("doesn't sign anyone out on a box") == true)
        #expect(signOuts.value == 0)
    }

    @Test func aLoginMovedToABoxShowsOnItAndIsNeverSignedOut() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moved-\(UUID())")
        let beforeRoot = CLIProfiles.root.value, beforeMains = CLIProfiles.mains.value, beforeCalls = StorylineSeams.accounts
        CLIProfiles.root.value = folder.appendingPathComponent("accounts")
        CLIProfiles.mains.value = ["claude": folder.appendingPathComponent("main")]
        CLIProfiles.reload()
        defer {
            StorylineSeams.accounts = beforeCalls
            CLIProfiles.root.value = beforeRoot
            CLIProfiles.mains.value = beforeMains
            CLIProfiles.reload()
            try? FileManager.default.removeItem(at: folder)
        }
        let signOuts = SignOuts()
        // Its keychain item is gone on this Mac: read here, it's signed out.
        let calls = calls(signOuts, signedIn: false)
        StorylineSeams.accounts = { $0 == "claude" ? calls : nil }
        CLIProfiles.adopt("claude", "82f61c23", email: "ajinkya@onfinance.in", workspace: "OnFinance")
        CLIProfiles.adopt("claude", "aaaa1111", email: "other@example.com", workspace: "")
        CLIProfiles.activate("claude", nil)
        let store = AccountStore()

        // Kore moved it there; the box lists it signed in there (and someone this Mac doesn't have).
        CLIProfiles.markMoved("claude", email: "Ajinkya@OnFinance.in", box: "mybox")
        store.noteBox("mybox", cli: "claude", signedIn: ["Ajinkya@OnFinance.in", "stranger@example.com"])
        #expect(CLIProfiles.movedTo("claude", email: "ajinkya@onfinance.in") == "mybox")
        #expect(CLIProfiles.movedTo("claude", email: "stranger@example.com") == nil)
        let moved = try #require(store.logins("claude").first { $0.id == "82f61c23" })
        #expect(moved.onBox == "mybox" && !moved.signedOut)
        #expect(store.logins("claude").first { $0.id == "aaaa1111" }?.onBox == nil)
        // Never read here: its usage key counts as not to be read.
        #expect(LoginUsage.Key("claude", moved, generation: 0).signedOut)

        // Picking its row doesn't move this Mac's chats onto it.
        store.switchLogin("claude", to: "82f61c23", LoginPick.byHandOnLink())
        #expect(CLIProfiles.active("claude") == nil)

        // Active and moved (set some other way): no sign-out, offered or run.
        CLIProfiles.activate("claude", "82f61c23")
        #expect(!store.signOutOffered("claude"))
        store.signOut("claude")
        #expect(signOuts.value == 0)
        CLIProfiles.activate("claude", nil)

        // Removed here: forgotten, never signed out. Another login's Remove still signs its folder out.
        store.removeLogin("claude", "82f61c23")
        try await settle { CLIProfiles.added("claude").count == 1 }
        #expect(signOuts.value == 0)
        store.removeLogin("claude", "aaaa1111")
        try await settle { CLIProfiles.added("claude").isEmpty }
        #expect(signOuts.value == 1)

        // The box no longer has it signed in: no longer said to be there.
        store.noteBox("mybox", cli: "claude", signedIn: [])
        #expect(CLIProfiles.movedTo("claude", email: "ajinkya@onfinance.in") == nil)
    }

    /// A scratch accounts folder for one test (`body` gets its parent, where `login-moves.json` is).
    private func scratch(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moved-\(UUID())")
        let beforeRoot = CLIProfiles.root.value, beforeMains = CLIProfiles.mains.value, beforeCalls = StorylineSeams.accounts
        CLIProfiles.root.value = folder.appendingPathComponent("accounts")
        CLIProfiles.mains.value = ["claude": folder.appendingPathComponent("main"), "codex": folder.appendingPathComponent("main-codex")]
        CLIProfiles.reload()
        defer {
            StorylineSeams.accounts = beforeCalls
            CLIProfiles.root.value = beforeRoot
            CLIProfiles.mains.value = beforeMains
            CLIProfiles.reload()
            try? FileManager.default.removeItem(at: folder)
        }
        try await body(folder)
    }

    /// The owner signed in to the Mac's main account on the box too, by itself: each sign-in has
    /// its own tokens, so it's on both, never "On mybox", never flagged. Main isn't read yet here
    /// (inactive, never hovered): that doesn't make it moved either.
    @Test(arguments: ["claude", "codex"]) func theSameAccountSignedInOnTheBoxByItselfIsNeitherMovedNorFlagged(_ cli: String) async throws {
        try await scratch { _ in
            _ = CLIProfiles.note(cli, email: "me@example.com", workspace: "Example")
            CLIProfiles.adopt(cli, "aaaa1111", email: "work@acme.dev", workspace: "Acme")
            CLIProfiles.activate(cli, "aaaa1111")
            let store = AccountStore()
            store.noteBox("mybox", cli: cli, signedIn: ["Me@Example.com", "work@acme.dev"])
            #expect(CLIProfiles.movedTo(cli, email: "me@example.com") == nil && CLIProfiles.movedTo(cli, email: "work@acme.dev") == nil)
            #expect(store.logins(cli).allSatisfy { $0.onBox == nil })
            #expect(store.signOutOffered(cli))

            let moves = LoginMoves.shared
            let before = (moves.boxes, moves.macs, moves.held)
            defer { (moves.boxes, moves.macs, moves.held) = before; moves.reset() }
            moves.reset()
            moves.macs = { [] }
            moves.held = { $0 == cli ? [.init(id: nil, email: "me@example.com", file: nil), .init(id: "aaaa1111", email: "work@acme.dev", file: nil)] : [] }
            moves.boxes = { [LoginMoves.Box(
                key: "mybox", name: "mybox", unready: nil, device: nil, remote: { _, _, _, _ in fatalError("no move here") },
                prints: { _, _ in [LoginPrint(cli: cli, login: "main", email: "me@example.com", fingerprint: ""),
                                   LoginPrint(cli: cli, login: "work", email: "work@acme.dev", fingerprint: "")] },
                login: { _, _ in nil })] }
            await moves.check()?.value
            #expect(moves.alsoOn(cli, nil) == nil && moves.alsoOn(cli, "aaaa1111") == nil && moves.alsoOnDevices == nil)
        }
    }

    /// A move Kore made marks the login "On mybox"; Move back's end (`noteBack`) clears it, as does
    /// the box no longer listing it.
    @Test(arguments: ["claude", "codex"]) func aRealMoveIsMarkedUntilItsBack(_ cli: String) async throws {
        try await scratch { _ in
            _ = CLIProfiles.note(cli, email: "me@example.com", workspace: "Example")
            let store = AccountStore()
            CLIProfiles.markMoved(cli, email: "Me@Example.com", box: "mybox")
            store.noteBox("mybox", cli: cli, signedIn: ["me@example.com"])
            #expect(store.logins(cli).first?.onBox == "mybox")
            CLIProfiles.noteBack(cli, email: "me@example.com")
            #expect(store.logins(cli).first?.onBox == nil)
            CLIProfiles.markMoved(cli, email: "me@example.com", box: "mybox")
            store.noteBox("other", cli: cli, signedIn: [])
            #expect(CLIProfiles.movedTo(cli, email: "me@example.com") == "mybox")
            store.noteBox("mybox", cli: cli, signedIn: [])
            #expect(CLIProfiles.movedTo(cli, email: "me@example.com") == nil)
        }
    }

    /// 0.3.4 marked any login whose email a box listed: on load, a mark no move record backs goes;
    /// one with a commit still owed to its box (a real move) stays.
    @Test func anEmailOnlyMarkIsDroppedOnLoad() async throws {
        try await scratch { folder in
            let accounts = folder.appendingPathComponent("accounts")
            try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
            let saved = #"{"active":{},"added":{"claude":[{"id":"bbbb2222","email":"moved@acme.dev"}]},"mainEmail":{"claude":"me@example.com","codex":"me@example.com"},"moved":{"claude":{"me@example.com":"mybox","moved@acme.dev":"mybox"},"codex":{"me@example.com":"mybox"}}}"#
            try Data(saved.utf8).write(to: accounts.appendingPathComponent("accounts.json"))
            let owed = #"[{"box":"mybox","cli":"claude","login":"bbbb2222","pending":{"commitImport":{"moveId":"m1"}}},{"box":"mybox","cli":"codex","login":"main","pending":{"abortImport":{"moveId":"m2"}}}]"#
            try Data(owed.utf8).write(to: folder.appendingPathComponent("login-moves.json"))
            CLIProfiles.reload()
            #expect(CLIProfiles.movedTo("claude", email: "me@example.com") == nil)
            #expect(CLIProfiles.movedTo("codex", email: "me@example.com") == nil)
            #expect(CLIProfiles.movedTo("claude", email: "moved@acme.dev") == "mybox")
            #expect(AccountStore().logins("claude").first { $0.id == nil }?.onBox == nil)
            // Written back without the old marks: read again, the same.
            let text = try String(contentsOf: accounts.appendingPathComponent("accounts.json"), encoding: .utf8)
            #expect(!text.contains("\"moved\""))
            CLIProfiles.reload()
            #expect(CLIProfiles.movedTo("claude", email: "moved@acme.dev") == "mybox" && CLIProfiles.movedTo("claude", email: "me@example.com") == nil)
        }
    }
}
}
