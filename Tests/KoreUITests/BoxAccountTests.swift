import Foundation
import HostClient
import KoreCore
import LinkProtocol
import src
import Testing

@testable import KoreUI

/// A box chat's Account popup is Kore's own over a box's `AccountStore`: one login per CLI, the
/// box's sign-ins only, nothing of this Mac's logins touched.
@MainActor
struct BoxAccountTests {
    @Test func theBoxsWordsReadAsKoresIdentity() {
        let identity = AccountIdentity(email: "me@example.com", plan: "Claude Max", method: "Claude.ai", changeable: true, methodID: "claudeai")
        let said = LinkMessage.Result(id: "1", ok: true, message: "Signed in as me@example.com.", signedIn: true, account: LinkIdentity(identity))
        #expect(BoxAccountStores.reading(BoxAccountStores.status(said)) == .signedIn(identity))
        // A box before 1.7: the email from its words.
        let older = LinkMessage.Result(id: "2", ok: true, message: "Signed in as me@example.com.", signedIn: true)
        guard case .signedIn(let read) = BoxAccountStores.reading(BoxAccountStores.status(older)) else {
            Issue.record("not signed in")
            return
        }
        #expect(read.email == "me@example.com")
        let out = LinkMessage.Result(id: "3", ok: true, message: "claude isn't signed in.", signedIn: false)
        #expect(BoxAccountStores.reading(BoxAccountStores.status(out)) == .signedOut)
    }

    @Test func theLinkCarriesTheIdentity() throws {
        let identity = AccountIdentity(email: "a@b.c", plan: "Pro", method: "ChatGPT", changeable: true)
        let data = try LinkMessage.result(.init(id: "x", ok: true, signedIn: true, account: LinkIdentity(identity))).encoded()
        guard case .result(let result) = try LinkMessage.decode(data) else {
            Issue.record("not a result")
            return
        }
        #expect(result.account?.identity == identity)
    }

    @Test func aBoxStoreHasOneLoginAndOnlyTheBoxsSignIns() async {
        let methods = Registry.provider("codex")?.account.methods ?? []
        let calls = AccountCalls(
            status: { .object(["signedIn": .bool(true), "account": .object(["email": .string("box@x.y"), "method": .string("ChatGPT"), "changeable": .bool(true)])]) },
            signIn: { _, _ in SignInHandle(url: URL(string: "https://example.com/device"), code: "AB-12", wait: { nil }, cancel: {}) },
            useKey: { _ in nil }, signOut: {})
        let store = AccountStore(calls: { _ in
            AccountOps(methods: methods.filter { LinkPolicy.boxSignIns.contains($0.id) }, parse: BoxAccountStores.reading, calls: calls,
                loginFile: { _ in URL(fileURLWithPath: "/dev/null") }, stamp: nil)
        })
        await store.refresh("codex")
        guard case .signedIn(let identity) = store.status("codex") else {
            Issue.record("not signed in")
            return
        }
        #expect(identity.email == "box@x.y")
        #expect(store.logins("codex").isEmpty)
        #expect(store.methods("codex").allSatisfy { LinkPolicy.boxSignIns.contains($0.id) })
        #expect(!store.methods("codex").contains(where: { (m: SignInMethod) in m.opensEditor }))
    }
}
