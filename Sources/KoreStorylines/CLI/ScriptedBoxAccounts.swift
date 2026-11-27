import Foundation
import KoreCore
import KoreUI
import LinkProtocol
import src

/// A box's logins for a storyline (`BoxAccountPopup`): the Account popup's store made as a box
/// chat's is (`BoxAccountStores`: the box's sign-in methods, its status words, its account list),
/// answered here as kore-host answers `account.*`. A sign-in waits until the storyline finishes
/// it; an account named that the box doesn't have is made, as `HostAccounts.signInFolder` does.
@MainActor
final class ScriptedBoxAccounts: StoryFinishing {
    /// Each account's usage, as its row shows it.
    static let bars = ["Session · 52%", "Weekly · 18%"]

    private(set) var accounts = [LinkAccount(id: LinkAccount.main, email: "you@box.dev", plan: "Claude Max", signedIn: true)]
    private(set) var viewed = LinkAccount.main
    /// The account each sign-in named (nil: none, as Codex's one login).
    private(set) var asked: [String?] = []
    private(set) var switched: [String?] = []
    private(set) var signOuts = 0
    private var waiting: CheckedContinuation<JSONValue?, Never>?
    private var signingIn: String?
    private var stores: [String: AccountStore] = [:]

    var isWaiting: Bool { waiting != nil }

    func install() { StorylineSeams.accountStore = { [weak self] provider in self?.store(provider) } }

    func finish() {
        StorylineSeams.accountStore = nil
        waiting?.resume(returning: nil)
        waiting = nil
    }

    /// The code typed back: the box's login lands on `email`.
    func finish(as email: String) {
        if let login = signingIn, let i = accounts.firstIndex(where: { $0.id == login }) {
            accounts[i].email = email
            accounts[i].signedIn = true
        }
        waiting?.resume(returning: Self.status(email))
        waiting = nil
    }

    private static func status(_ email: String) -> JSONValue {
        BoxAccountStores.status(LinkMessage.Result(
            id: "", ok: true, signedIn: true,
            account: LinkIdentity(AccountIdentity(email: email, plan: "Claude Max", method: "Claude.ai", changeable: true))))
    }

    private func store(_ provider: String) -> AccountStore {
        if let store = stores[provider] { return store }
        let methods = (Registry.provider(provider)?.account.methods ?? []).filter { LinkPolicy.boxSignIns.contains($0.id) }
        let calls = AccountCalls(
            status: { @MainActor [weak self] in
                guard let self else { return .null }
                let login = provider == "claude" ? self.viewed : LinkAccount.main
                return Self.status(self.accounts.first { $0.id == login }?.email ?? "you@box.dev")
            },
            signIn: { @MainActor [weak self] _, context in
                guard let self else { throw UsageUnavailable() }
                let login = provider == "claude" ? context.login : nil
                self.asked.append(login)
                if let login, !self.accounts.contains(where: { $0.id == login }) {
                    self.accounts.append(LinkAccount(id: login, signedIn: false))
                }
                self.signingIn = login
                return SignInHandle(
                    url: URL(string: "https://claude.ai/oauth/code"), code: nil,
                    wait: { @MainActor [weak self] in await withCheckedContinuation { self?.waiting = $0 } },
                    cancel: { @MainActor [weak self] in self?.finish() }, submit: { _ in })
            },
            useKey: { _ in throw UsageUnavailable() },
            signOut: { @MainActor [weak self] in self?.signOuts += 1 })
        let store = AccountStore(calls: { _ in
            AccountOps(methods: methods, parse: BoxAccountStores.reading, calls: calls, loginFile: { _ in URL(fileURLWithPath: "/dev/null") }, stamp: nil)
        })
        store.box = AccountStore.BoxLogins(
            list: { [weak self] provider in
                guard let self, provider == "claude" else { return nil }
                return BoxAccountStores.rows(self.accounts, active: self.viewed)
            },
            switchTo: { [weak self] _, login in
                self?.switched.append(login ?? LinkAccount.main)
                self?.viewed = login ?? LinkAccount.main
                return nil
            },
            usage: { [weak self] _, login in
                // Read for that account: its own email, as a box's reading says it.
                let email = self?.accounts.first { $0.id == (login ?? LinkAccount.main) }?.email
                return PlanReading(account: .init(plan: "Claude Max", email: email, access: .plan), limits: .init(bars: [
                    PlanLimit(title: "Session (5hr)", used: 52, resetsAt: Date().addingTimeInterval(2 * 3600)),
                    PlanLimit(title: "Weekly (7 day)", used: 18, resetsAt: Date().addingTimeInterval(3 * 86400)),
                ]))
            },
            viewedIsMain: { [weak self] in self?.viewed == LinkAccount.main },
            viewed: { [weak self] in self?.viewed ?? LinkAccount.main })
        stores[provider] = store
        return store
    }
}
