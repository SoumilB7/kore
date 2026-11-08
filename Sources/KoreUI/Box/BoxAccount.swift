import AppKit
import HostClient
import KoreCore
import LinkProtocol
import src
import SwiftUI

/// A box chat's Account popup is Kore's own, the same design and words; only its logins are the
/// box's. Each box has an `AccountStore` whose calls go to the box (`account.*`): a sign-in runs
/// there without a browser (Codex's device code, Claude's page whose code is typed back here),
/// its page opens in this Mac's browser, and the token stays on the box. A box keeps one login
/// per CLI; nothing of this Mac's logins is read or written for it.
@MainActor
enum BoxAccountStores {
    private static var stores: [String: AccountStore] = [:]

    static func store(_ connection: HostConnection) -> AccountStore {
        if let store = stores[connection.alias] { return store }
        let store = AccountStore(calls: { provider in ops(provider, connection) })
        stores[connection.alias] = store
        return store
    }

    /// The CLI's login as the box runs it: the methods a box takes (no key, no platform), and the
    /// box's own words for who's signed in.
    static func ops(_ provider: String, _ connection: HostConnection) -> AccountOps? {
        guard let base = Registry.provider(provider)?.account else { return nil }
        let methods = base.methods.filter { LinkPolicy.boxSignIns.contains($0.id) }
        return AccountOps(methods: methods, parse: reading, calls: calls(provider, connection), loginFile: base.loginFile, stamp: nil)
    }

    /// A status as the box said it, in the form `reading` parses.
    nonisolated static func status(_ result: LinkMessage.Result) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let signedIn = result.signedIn { fields["signedIn"] = .bool(signedIn) }
        if let account = result.account, let data = try? JSONEncoder().encode(account),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            fields["account"] = value
        } else if result.signedIn == true, let message = result.message, message.hasPrefix("Signed in as ") {
            // A box before 1.7 says only the email.
            let email = String(message.dropFirst("Signed in as ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            fields["account"] = .object(["email": .string(email), "method": .string(""), "changeable": .bool(true)])
        }
        return .object(fields)
    }

    nonisolated static func reading(_ status: JSONValue) -> AccountReading {
        guard status["signedIn"] == .bool(true) else { return .signedOut }
        guard let account = status["account"], let data = try? JSONEncoder().encode(account),
            let identity = try? JSONDecoder().decode(LinkIdentity.self, from: data)
        else { return .signedIn(AccountIdentity(method: "", changeable: true)) }
        return .signedIn(identity.identity)
    }

    private static func calls(_ provider: String, _ connection: HostConnection) -> AccountCalls {
        let alias = connection.alias
        let status: @MainActor @Sendable () async throws -> JSONValue = {
            let result = await connection.command { HostWire.refresh(id: $0, provider: provider) }
            guard result.ok else { throw HostRefusal(message: result.message ?? "Couldn't read the login on \(NodeNames.name(alias))") }
            return Self.status(result)
        }
        let signIn: @MainActor @Sendable (SignInMethod.Mechanism, SignInContext) async throws -> SignInHandle = { _, _ in
            // The box picks its own way in (`HostDaemon.boxMethod`).
            let result = await connection.command { HostWire.signIn(id: $0, provider: provider) }
            guard result.ok else { throw HostRefusal(message: result.message ?? "Couldn't sign in on \(NodeNames.name(alias))") }
            return handle(HostWire.page(result.message), done: result.id + HostWire.doneSuffix, provider: provider, connection)
        }
        let signOut: @MainActor @Sendable () async throws -> Void = {
            let result = await connection.command { HostWire.signOut(id: $0, provider: provider) }
            guard result.ok else { throw HostRefusal(message: result.message ?? "Couldn't sign out on \(NodeNames.name(alias))") }
        }
        return AccountCalls(
            status: status, signIn: signIn, useKey: { _ in throw HostRefusal(message: "Keys aren't sent to a box") }, signOut: signOut)
    }

    /// A sign-in under way on the box: its page (and device code), its end (`<id>:done`), Cancel,
    /// and, for a page that shows a code to type back (Claude's), the way to send it.
    private static func handle(_ page: HostWire.Page, done: String, provider: String, _ connection: HostConnection) -> SignInHandle {
        let alias = connection.alias
        let wait: @MainActor @Sendable () async throws -> JSONValue? = {
            let end = await connection.later(done)
            guard end.ok else { throw HostRefusal(message: end.message ?? "Couldn't sign in on \(NodeNames.name(alias))") }
            return Self.status(end)
        }
        let cancel: @MainActor @Sendable () async -> Void = {
            _ = await connection.command { HostWire.cancelSignIn(id: $0, provider: provider) }
        }
        let submit: @MainActor @Sendable (String) async throws -> Void = { input in
            let result = await connection.command { HostWire.submit(id: $0, provider: provider, input: input) }
            guard result.ok else { throw HostRefusal(message: result.message ?? "\(NodeNames.name(alias)) didn't take that code") }
        }
        // Codex's device code needs nothing typed back.
        var typedBack: (@Sendable (String) async throws -> Void)?
        if page.code == nil { typedBack = submit }
        return SignInHandle(url: page.url, code: page.code, wait: wait, cancel: cancel, submit: typedBack)
    }
}

/// One login on the box: its name and what the box says, Sign in; while it runs, the page to
/// open, its code, and (Claude) the field for the code the page shows. GitHub's, on the Welcome's
/// box view, and each agent's in Set up agents.
struct BoxAccountLine: View {
    let title: String
    let key: String
    let accounts: BoxAccounts
    let takesPaste: Bool
    let signIn: () -> Void
    @StateObject private var code = Local("")
    @StateObject private var copied = Local(false)
    @FocusState private var typing: Bool

    var body: some View {
        let line = accounts.line(key)
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Text(title).font(TextStyle.labelMedium).foregroundStyle(Theme.text).lineLimit(1)
                Text(status(line)).font(TextStyle.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Space.sm)
                switch line.step {
                // Signed in already: nothing to press.
                case .idle where line.signedIn == true: EmptyView()
                case .idle, .failed: Button("Sign in", action: signIn).smallButton()
                case .starting: ProgressView().controlSize(.small)
                case .waiting, .submitting: Button("Cancel") { accounts.cancel(key) }.smallButton()
                }
            }
            if let page = page(line.step) {
                HStack(spacing: Space.sm) {
                    if let url = page.url { Button("Open page") { NSWorkspace.shared.open(url) }.smallButton(prominent: true) }
                    if let device = page.code {
                        Text(device).font(TextStyle.code).foregroundStyle(Theme.text).textSelection(.enabled)
                        Button(copied.value ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(device, forType: .string)
                            copied.value = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied.value = false
                            }
                        }
                        .smallButton()
                    }
                    if takesPaste {
                        TextField("", text: $code.value, prompt: Text("Code from the page").foregroundStyle(Theme.tertiary))
                            .textFieldStyle(.plain)
                            .focused($typing)
                            .fieldWell(focused: typing)
                            .onSubmit(submit)
                            .onAppear { typing = true }
                        Button("Sign in", action: submit).smallButton(prominent: true).disabled(code.value.isEmpty)
                    }
                }
            }
        }
    }

    private func submit() {
        accounts.submit(key, code: code.value.trimmingCharacters(in: .whitespacesAndNewlines))
        code.value = ""
    }

    private func page(_ step: BoxAccounts.Step) -> HostWire.Page? {
        switch step {
        case .waiting(let page), .submitting(let page): page
        default: nil
        }
    }

    private func status(_ line: BoxAccounts.Line) -> String {
        if case .failed(let why) = line.step { return why }
        return line.said ?? ""
    }
}
