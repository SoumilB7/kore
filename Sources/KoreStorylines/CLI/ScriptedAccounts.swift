import Foundation
import KoreCore
import KoreUI

/// The scripted CLIs' logins (with `ScriptedBackend`, the storylines' default CLI): each CLI's
/// status as it answers it (Kore parses it with its own code), and sign-ins and sign-outs a
/// storyline drives. Nothing reaches a real CLI, a browser, Terminal, the owner's Keychain or
/// clipboard. Everything Kore asks is in `log`. Claude's status follows the run's own settings
/// file (Kore's real writer writes it): a platform switched on there reads `third_party`, Kore's
/// key helper `api_key_helper`, as the CLI would. Kore's Keychain is an in-memory one.
@MainActor
package final class ScriptedAccounts {
    package static let shared = ScriptedAccounts()

    package enum Call: Equatable, Sendable {
        case status(String)
        /// A sign-in started: the provider, and what Kore asked (`loginWithClaudeAi=true`,
        /// `type=chatgptDeviceCode`).
        case signIn(String, String)
        case cancel(String)
        case signOut(String)
        /// A page Kore would have opened: its host.
        case opened(String)
        /// A typed key reached the CLI (Codex) or Kore's Keychain (Claude); never the key itself.
        case key(String)
        /// A submitted OAuth input; never records its value.
        case loginInput(String)
        /// Terminal would have opened, running the CLI with these arguments.
        case terminal(String, String)
        /// The `awsAuthRefresh` script ran.
        case refresh(String)
    }

    /// How the next sign-in starts.
    package enum Start: Sendable {
        /// A page to open; the sign-in then waits for `finish` or `fail`.
        case browser
        /// A device code to enter at the page.
        case deviceCode(String)
        /// It fails to start, saying this.
        case fails(String)
    }

    package private(set) var log: [Call] = []
    /// Each CLI's status reply: Claude's `auth status --json`, Codex's `account/read`.
    package var status: [String: JSONValue] = [:]
    package var start: [String: Start] = [:]
    /// A sign-out that fails, with the CLI's words.
    package var signOutFails: [String: String] = [:]
    /// Added to each CLI's status: its policy (`forcedLoginMethod`, `allowedProviders`,
    /// `awsAuthRefresh`), as Kore reads it.
    package var policy: [String: JSONValue] = [:]
    /// The next typed key is refused, with the CLI's words.
    package var keyFails: [String: String] = [:]
    /// The key each CLI last took: for a check that it arrived (a storyline's made-up key).
    package private(set) var keys: [String: String] = [:]
    /// What an open panel picks.
    package var chosenFile: URL?
    /// CLIs whose status first looks for the binary, as the real CLIs' does (`CLIExecutable`,
    /// in a storyline's own `places`): not found, the status read fails as the real one would.
    package var lookup: Set<String> = []
    /// Kore's Keychain while storylines run.
    package let keychain = MemoryKeychain()
    /// The sign-in waiting for the browser, by provider.
    private var waiting: [String: CheckedContinuation<JSONValue?, any Error>] = [:]

    /// Kore's login calls go here from now on.
    package func install() {
        StorylineSeams.accounts = { [unowned self] provider in calls(provider) }
        StorylineSeams.opened = { [unowned self] url in log.append(.opened(url.host() ?? "")) }
        StorylineSeams.chooseFile = { [unowned self] in chosenFile }
        Keychain.store.value = keychain
    }

    /// Back to nothing asked, every CLI signed in as in `signedIn`, and nothing known in Kore.
    package func reset() {
        for wait in waiting.values { wait.resume(throwing: CancellationError()) }
        waiting = [:]
        log = []
        status = ["claude": Self.claude(), "codex": Self.codex()]
        start = [:]
        signOutFails = [:]
        policy = [:]
        keyFails = [:]
        keys = [:]
        chosenFile = nil
        lookup = []
        if CLIExecutable.places.value != nil { CLIExecutable.look(in: nil) }
        CLIInstaller.standIn.value = nil
        StorylineSeams.loginUsage = nil
        keychain.removeAll()
        // The run's Claude settings start empty for each storyline.
        try? FileManager.default.removeItem(at: ClaudeSettings.userFile())
        try? FileManager.default.removeItem(at: SettingsFile.backup(of: ClaudeSettings.userFile()))
        // Logins side by side only where a storyline gives them a folder (`SeedLogins`).
        CLIProfiles.root.value = nil
        CLIProfiles.mains.value = [:]
        CLIProfiles.reload()
        AccountStore.shared.reset()
    }

    /// The browser finished: the CLI is now signed in as `reply` says.
    package func finish(_ provider: String, as reply: JSONValue) {
        status[provider] = reply
        // Codex answers its `account/read` with the end; Claude's status is read after it.
        let answer: JSONValue? = provider == "codex" ? .some(reply) : .none
        waiting.removeValue(forKey: provider)?.resume(returning: answer)
    }

    /// The sign-in failed, the CLI saying `reason`.
    package func fail(_ provider: String, _ reason: String) {
        waiting.removeValue(forKey: provider)?.resume(throwing: Said(reason))
    }

    /// Whether a sign-in waits for the browser.
    package func isWaiting(_ provider: String) -> Bool { waiting[provider] != nil }

    private func calls(_ provider: String) -> AccountCalls {
        AccountCalls(
            status: { @MainActor [unowned self] in
                log.append(.status(provider))
                if lookup.contains(provider), await CLIExecutable.located(provider) == nil {
                    throw CLIExecutable.Failure.notFound(name: provider, searched: [])
                }
                return reply(provider)
            },
            signIn: { @MainActor [unowned self] mechanism, _ in
                log.append(.signIn(provider, Self.words(mechanism)))
                switch mechanism {
                case .terminal(let arguments):
                    log.append(.terminal(provider, arguments.joined(separator: " ")))
                    return handle(provider, url: nil, code: nil)
                case .awsRefresh:
                    log.append(.refresh(provider))
                    return handle(provider, url: nil, code: nil)
                default: break
                }
                switch start[provider] ?? .browser {
                case .fails(let reason):
                    throw Said(reason)
                case .browser:
                    if case .codexLogin(let params) = mechanism, params["type"]?.string == "chatgptDeviceCode" {
                        return handle(provider, url: Self.web("https://auth.openai.com/codex/device"), code: "DEMO-CODE")
                    }
                    // Claude's SSO opens the page itself: Kore only offers Copy link.
                    return handle(provider, url: Self.page(provider), code: nil, opensItself: mechanism == .claudeSSO)
                case .deviceCode(let code):
                    return handle(provider, url: Self.web("https://auth.openai.com/codex/device"), code: code)
                }
            },
            useKey: { @MainActor [unowned self] key in
                if let reason = keyFails.removeValue(forKey: provider) { throw Said(reason) }
                keys[provider] = key
                log.append(.key(provider))
                guard provider == "codex" else {
                    // Kore's own path: the (in-memory) Keychain, then the run's settings file.
                    try ClaudeSettingsStore.saveKey(key)
                    return nil
                }
                let account: JSONValue = ["account": ["type": "apiKey"], "requiresOpenaiAuth": true]
                status[provider] = account
                return account
            },
            signOut: { @MainActor [unowned self] in
                log.append(.signOut(provider))
                if let reason = signOutFails[provider] { throw Said(reason) }
                status[provider] = provider == "codex" ? ["account": nil, "requiresOpenaiAuth": true] : ["loggedIn": false, "authMethod": "none"]
            })
    }

    /// The CLI's status as it would answer now: Claude's from the run's settings when they turn
    /// a platform or Kore's key on, with the policy the storyline set.
    private func reply(_ provider: String) -> JSONValue {
        var reply = status[provider] ?? .null
        if provider == "claude", case .object(var fields) = reply {
            switch ClaudeSettings.saved(in: ClaudeSettingsStore.read()) {
            case .platform(let platform, _):
                fields = ["loggedIn": true, "authMethod": "third_party", "apiProvider": .string(platform.provider)]
            case .key:
                fields = ["loggedIn": true, "authMethod": "api_key_helper", "apiKeySource": "apiKeyHelper", "apiProvider": "firstParty"]
            case nil: break
            }
            reply = .object(fields)
        }
        if case .object(var fields) = reply, case .object(let extra)? = policy[provider] {
            fields.merge(extra) { $1 }
            reply = .object(fields)
        }
        return reply
    }

    private func handle(_ provider: String, url: URL?, code: String?, opensItself: Bool = false) -> SignInHandle {
        let submit: (@Sendable (String) async throws -> Void)?
        if code == nil && url != nil {
            submit = { @MainActor [unowned self] input in
                if provider == "codex" { _ = try LoginCallback.localhostURL(input, authorizationURL: Self.page(provider)) }
                else { _ = try LoginCallback.code(input, authorizationURL: Self.page(provider)) }
                log.append(.loginInput(provider))
                finish(provider, as: status[provider] ?? .null)
            }
        } else { submit = nil }
        return SignInHandle(
            url: url, code: code, opensItself: opensItself,
            wait: { @MainActor [unowned self] in
                try await withCheckedThrowingContinuation { waiting[provider] = $0 }
            },
            cancel: { @MainActor [unowned self] in
                log.append(.cancel(provider))
                waiting.removeValue(forKey: provider)?.resume(throwing: CancellationError())
            },
            manualURL: code == nil ? url : nil,
            submit: submit)
    }

    private static func page(_ provider: String) -> URL {
        web((provider == "codex" ? "https://auth.openai.com/oauth/authorize" : "https://claude.com/cai/oauth/authorize")
            + "?state=demo-state&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback")
    }

    private static func web(_ text: String) -> URL { URL(string: text) ?? URL(fileURLWithPath: "/") }

    private static func words(_ mechanism: SignInMethod.Mechanism) -> String {
        switch mechanism {
        case .claudeAuthenticate(let fields): fields.keys.sorted().map { "\($0)=\(fields[$0].map(describe) ?? "")" }.joined(separator: ",")
        case .codexLogin(let params): "type=\(params["type"]?.string ?? "")"
        case .claudeSSO: "sso"
        case .claudeKey, .codexKey: "key"
        case .platform(let platform): platform.rawValue
        case .awsRefresh: "awsRefresh"
        case .terminal(let arguments): "terminal " + arguments.joined(separator: " ")
        case .none: "none"
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        if let bool = value.bool { return "\(bool)" }
        return value.string ?? "?"
    }

    /// the claude CLI's `auth status --json` for a Claude.ai login.
    package static func claude(
        email: String = "you@example.com", org: String = "you@example.com's Organization", plan: String = "max"
    ) -> JSONValue {
        [
            "loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": .string(email), "orgId": "org-1",
            "orgName": .string(org), "subscriptionType": .string(plan),
        ]
    }

    /// Codex's `account/read` for a ChatGPT login.
    package static func codex(email: String = "you@example.com", plan: String = "prolite") -> JSONValue {
        ["account": ["type": "chatgpt", "email": .string(email), "planType": .string(plan)], "requiresOpenaiAuth": true]
    }

    private struct Said: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}
