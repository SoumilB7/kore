import Foundation
import KoreCore

/// One way a CLI's login signs in, as data: what the ⌄ menu lists and what Kore asks the CLI.
/// Only the browser and device-code kinds run from Kore; the rest are listed, off, for what
/// they say (a terminal command, a secret Kore never takes, a sign-in done elsewhere).
package struct SignInMethod: Identifiable, Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        /// The CLI's OAuth in the browser, which Kore opens.
        case browserOAuth
        /// A code to enter on a page Kore opens.
        case deviceCode
        /// It would hand Kore a secret (an API key, a token).
        case secret
        /// Run in Terminal.
        case terminal
        /// Set up outside the CLI's login (a cloud platform, managed settings).
        case external
    }

    /// What Kore asks the CLI to start it.
    package enum Mechanism: Hashable, Sendable {
        /// Claude's `claude_authenticate` control request, with these fields.
        case claudeAuthenticate([String: JSONValue])
        /// Codex's `account/login/start`, with these params.
        case codexLogin(JSONValue)
        /// Nothing Kore runs.
        case none
    }

    package let id: String
    package let label: String
    package let kind: Kind
    package let mechanism: Mechanism

    package init(id: String, label: String, kind: Kind, mechanism: Mechanism) {
        self.id = id
        self.label = label
        self.kind = kind
        self.mechanism = mechanism
    }

    /// Kore can run it.
    package var runs: Bool { (kind == .browserOAuth || kind == .deviceCode) && mechanism != .none }
}

/// Who a CLI is signed in as, in Kore's words.
package struct AccountIdentity: Equatable, Sendable {
    package var email: String?
    /// "Claude Max", "ChatGPT Pro Lite", "Claude Console".
    package var plan: String?
    package var organization: String?
    /// How it signed in, for the caption: "Claude.ai", "Console", "ChatGPT", "API key helper".
    package var method: String
    /// Kore can switch it or sign it out; false for a login set outside the CLI's own (the
    /// env, an API key helper, a cloud platform, managed settings).
    package var changeable: Bool
    /// The menu method it came from, for the ⌄ menu's ✓; nil when none.
    package var methodID: String?

    package init(
        email: String? = nil, plan: String? = nil, organization: String? = nil, method: String, changeable: Bool, methodID: String? = nil
    ) {
        self.email = email
        self.plan = plan
        self.organization = organization
        self.method = method
        self.changeable = changeable
        self.methodID = methodID
    }

    /// The same person and organisation: a switch that lands here changed nothing.
    func isSameAccount(as other: AccountIdentity) -> Bool {
        email?.lowercased() == other.email?.lowercased() && organization == other.organization && method == other.method
    }
}

/// What a status read says.
package enum AccountReading: Equatable, Sendable {
    case signedIn(AccountIdentity)
    case signedOut
}

/// A sign-in under way in the CLI: the page Kore opened (and, for a device code, the code), its
/// end and a way to stop it. `wait` answers the CLI's status reply when it has one (Codex's
/// `account/read`), else nil, and Kore reads the status itself.
package struct SignInHandle: Sendable {
    package let url: URL
    package let code: String?
    package let wait: @Sendable () async throws -> JSONValue?
    package let cancel: @Sendable () async -> Void

    package init(
        url: URL, code: String? = nil, wait: @escaping @Sendable () async throws -> JSONValue?, cancel: @escaping @Sendable () async -> Void
    ) {
        self.url = url
        self.code = code
        self.wait = wait
        self.cancel = cancel
    }
}

/// What Kore asks a CLI about its login: the status, a sign-in, a sign-out. The real CLIs'
/// are in each descriptor; a storyline host swaps in scripted ones (`StorylineSeams.accounts`).
package struct AccountCalls: Sendable {
    package var status: @Sendable () async throws -> JSONValue
    package var signIn: @Sendable (SignInMethod.Mechanism) async throws -> SignInHandle
    package var signOut: @Sendable () async throws -> Void

    package init(
        status: @escaping @Sendable () async throws -> JSONValue,
        signIn: @escaping @Sendable (SignInMethod.Mechanism) async throws -> SignInHandle,
        signOut: @escaping @Sendable () async throws -> Void
    ) {
        self.status = status
        self.signIn = signIn
        self.signOut = signOut
    }
}

/// One CLI's login, for the Account popup: its methods, how its status reads, and the file it
/// keeps its login in (watched for changes made outside Kore).
struct AccountOps: Sendable {
    let methods: [SignInMethod]
    let parse: @Sendable (JSONValue) -> AccountReading
    let calls: AccountCalls
    let loginFile: @Sendable () -> URL
    /// What in that file names the account (Claude's `oauthAccount`); nil: the file is never
    /// read (Codex's holds tokens), and any change to it costs a status read.
    let stamp: (@Sendable (Data) -> String?)?
}

/// Every error as one plain line for "Couldn't …: <reason>", never raw JSON; nil when there's
/// nothing readable.
enum AccountReason {
    static func of(_ error: any Error) -> String? {
        let line: String? =
            if case ClaudeSession.Failure.controlError(let text) = error { PlanReading.reason(of: Said(text)) } else {
                PlanReading.reason(of: error)
            }
        guard let line = line?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return line
    }

    private struct Said: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}

// MARK: - Claude Code

extension AccountOps {
    static let claude = AccountOps(
        methods: [
            SignInMethod(
                id: "claudeai", label: "Claude account with subscription", kind: .browserOAuth,
                mechanism: .claudeAuthenticate(["loginWithClaudeAi": true])),
            SignInMethod(
                id: "console", label: "Anthropic Console account", kind: .browserOAuth,
                mechanism: .claudeAuthenticate(["loginWithClaudeAi": false])),
        ],
        parse: { AccountText.claude(ClaudeAuth.Status($0)) },
        calls: AccountCalls(
            status: { try await ClaudeAuth.statusReply() },
            signIn: { mechanism in
                guard case .claudeAuthenticate(let fields) = mechanism else { throw AccountUnavailable() }
                let login = try await ClaudeAuth.Login.start()
                do {
                    let url = try await login.begin(fields)
                    return SignInHandle(
                        url: url,
                        wait: {
                            defer { Task { await login.cancel() } }
                            _ = try await login.wait()
                            return JSONValue?.none
                        },
                        cancel: { await login.cancel() })
                } catch {
                    await login.cancel()
                    throw error
                }
            },
            signOut: { try await ClaudeAuth.logout() }),
        loginFile: { ClaudeAuth.configFile() },
        stamp: { ClaudeAuth.accountStamp($0) })
}

// MARK: - Codex

extension AccountOps {
    static let codex = AccountOps(
        methods: [
            SignInMethod(id: "chatgpt", label: "Sign in with ChatGPT", kind: .browserOAuth, mechanism: .codexLogin(["type": "chatgpt"])),
            SignInMethod(
                id: "chatgptDeviceCode", label: "Sign in with Device Code", kind: .deviceCode,
                mechanism: .codexLogin(["type": "chatgptDeviceCode"])),
            SignInMethod(id: "apiKey", label: "API key: run codex login --with-api-key in Terminal", kind: .terminal, mechanism: .none),
        ],
        parse: { AccountText.codex(CodexAuth.Status($0)) },
        calls: AccountCalls(
            status: { try await CodexAuth.statusReply() },
            signIn: { mechanism in
                guard case .codexLogin(let params) = mechanism else { throw AccountUnavailable() }
                let login = try await CodexAuth.Login.start()
                do {
                    let prompt = try await login.begin(params)
                    return SignInHandle(
                        url: prompt.url, code: prompt.userCode,
                        wait: {
                            defer { Task { await login.close() } }
                            return try await login.wait()
                        },
                        cancel: { await login.cancel() })
                } catch {
                    await login.close()
                    throw error
                }
            },
            signOut: { try await CodexAuth.logout() }),
        loginFile: { CodexAuth.authFile() },
        stamp: nil)
}

struct AccountUnavailable: LocalizedError {
    var errorDescription: String? { "Kore can't run this sign-in" }
}

// MARK: - Wording

/// The Account popup's words, and each CLI's status in them.
enum AccountText {
    /// `claude auth status --json`, as an identity.
    static func claude(_ status: ClaudeAuth.Status) -> AccountReading {
        guard status.loggedIn else { return .signedOut }
        let org = status.orgName.flatMap { $0.isEmpty ? nil : $0 }
        let email = status.email.flatMap { $0.isEmpty ? nil : $0 }
        let plan = PlanReading.claudePlan(status.subscriptionType)
        switch status.authMethod {
        case "claude.ai":
            return .signedIn(
                AccountIdentity(email: email, plan: plan, organization: org, method: "Claude.ai", changeable: true, methodID: "claudeai"))
        case "api_key" where status.apiKeySource == "/login managed key":
            return .signedIn(
                AccountIdentity(
                    email: email, plan: "Claude Console", organization: org, method: "Console", changeable: true, methodID: "console"))
        case "api_key":
            return .signedIn(AccountIdentity(email: email, plan: "Claude Console", method: "API key from env", changeable: false))
        case "oauth_token":
            return .signedIn(AccountIdentity(email: email, plan: plan, method: "Token from env", changeable: false))
        case "api_key_helper":
            return .signedIn(AccountIdentity(email: email, plan: "Claude Console", method: "API key helper", changeable: false))
        case "third_party":
            return .signedIn(AccountIdentity(email: email, method: platform(status.apiProvider), changeable: false))
        default:
            return .signedIn(AccountIdentity(email: email, plan: plan, organization: org, method: "Managed settings", changeable: false))
        }
    }

    /// A cloud platform Claude Code runs through, by name.
    static func platform(_ provider: String?) -> String {
        switch provider {
        case "bedrock": "Amazon Bedrock"
        case "vertex": "Google Vertex AI"
        case "foundry": "Microsoft Foundry"
        case "anthropicAws": "Anthropic on AWS"
        case "anthropicGoogleCloud": "Anthropic on Google Cloud"
        case "gateway": "Gateway"
        case let other?: other.prefix(1).uppercased() + other.dropFirst()
        case nil: "Cloud platform"
        }
    }

    /// `account/read`'s answer, as an identity.
    static func codex(_ status: CodexAuth.Status) -> AccountReading {
        guard status.loggedIn else {
            // A provider that signs in its own way (its headers, in Codex's config).
            return status.requiresOpenaiAuth ? .signedOut : .signedIn(AccountIdentity(method: "Managed", changeable: false))
        }
        let email = status.email.flatMap { $0.isEmpty ? nil : $0 }
        switch status.type {
        case "chatgpt":
            return .signedIn(
                AccountIdentity(email: email, plan: PlanReading.codexPlan(status.planType), method: "ChatGPT", changeable: true, methodID: "chatgpt"))
        case "apiKey":
            return .signedIn(AccountIdentity(email: email, method: "API key", changeable: true, methodID: "apiKey"))
        case let type? where type.lowercased().contains("bedrock"):
            return .signedIn(AccountIdentity(email: email, method: "Bedrock", changeable: false))
        default:
            return .signedIn(AccountIdentity(email: email, method: "Managed", changeable: false))
        }
    }

    /// The header: the email, or "API key" without one.
    static func header(_ identity: AccountIdentity) -> String { identity.email ?? "API key" }

    /// "Claude Max · Claude.ai", "ChatGPT Business · ChatGPT · Acme Labs": empty parts left
    /// out, and an organisation only when it says more than the address.
    static func caption(_ identity: AccountIdentity) -> String {
        let org = identity.organization.flatMap { UsageText.distinct($0, from: identity.email ?? "") ? $0 : nil }
        return [identity.plan, identity.method, org].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func signedOut(_ product: String) -> String { "\(product) isn't signed in." }
    static func readFailed(_ product: String, _ reason: String?) -> String {
        "Couldn't read \(product)'s account" + (reason.map { ": " + $0 } ?? ".")
    }
    static func signInFailed(_ reason: String?) -> String { reason.map { "Couldn't sign in: \($0)" } ?? "Couldn't sign in." }
    static func signOutFailed(_ reason: String?) -> String { reason.map { "Couldn't sign out: \($0)" } ?? "Couldn't sign out." }
    static let cantChange = "Set outside Kore, so Kore can't change it."
    static let starting = "Starting sign-in…"
    static let browser = "Waiting for the browser…"
    static let signingOut = "Signing out…"
    static let signedIn = "Signed in."
    static let switched = "Switched accounts."
    static let same = "Still the same account."
    static let sameHelp = "The browser continued as the same account. Pick another on the sign-in page, then try again."
    static let timedOut = "Sign-in timed out."
    static let moving = "Open chats move to the new account after their current turn."
    static let deviceHelp = "Enter the code at auth.openai.com/codex/device"

    static func askSignOut(_ product: String) -> String { "Sign out of \(product)?" }

    /// The question's caption: always the reach of a sign-out, and the chats it stops.
    static func signOutCaption(working: Int) -> String {
        let reach = "Also signs out Terminal and VS Code on this Mac."
        guard working > 0 else { return reach }
        return reach + " Stops \(working) working chat\(working == 1 ? "" : "s")."
    }

    /// A failed turn's notice: the login lapsed, or there was none.
    static func expired(_ product: String, signedOut: Bool) -> String {
        signedOut ? "\(product) isn't signed in." : "Your \(product) sign-in expired."
    }

    /// The Welcome's line for the CLIs that aren't signed in; nil when none.
    static func welcome(signedOut products: [String]) -> String? {
        guard !products.isEmpty else { return nil }
        let names = products.count == 1 ? products[0] : products.dropLast().joined(separator: ", ") + " and " + products[products.count - 1]
        return "\(names) \(products.count == 1 ? "isn't" : "aren't") signed in. Sign in from Account in a chat's / menu."
    }
}
