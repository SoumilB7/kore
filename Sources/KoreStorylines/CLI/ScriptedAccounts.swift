import Foundation
import KoreCore
import KoreUI

/// The scripted CLIs' logins (with `ScriptedBackend`, the storylines' default CLI): each CLI's
/// status as it answers it (Kore parses it with its own code), and sign-ins and sign-outs a
/// storyline drives. Nothing reaches a real CLI, a browser or the owner's clipboard. Everything
/// Kore asks is in `log`.
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
    /// The sign-in waiting for the browser, by provider.
    private var waiting: [String: CheckedContinuation<JSONValue?, any Error>] = [:]

    /// Kore's login calls go here from now on.
    package func install() {
        StorylineSeams.accounts = { [unowned self] provider in calls(provider) }
        StorylineSeams.opened = { [unowned self] url in log.append(.opened(url.host() ?? "")) }
    }

    /// Back to nothing asked, every CLI signed in as in `signedIn`, and nothing known in Kore.
    package func reset() {
        for wait in waiting.values { wait.resume(throwing: CancellationError()) }
        waiting = [:]
        log = []
        status = ["claude": Self.claude(), "codex": Self.codex()]
        start = [:]
        signOutFails = [:]
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
                return status[provider] ?? .null
            },
            signIn: { @MainActor [unowned self] mechanism in
                log.append(.signIn(provider, Self.words(mechanism)))
                switch start[provider] ?? .browser {
                case .fails(let reason):
                    throw Said(reason)
                case .browser:
                    return handle(provider, url: Self.page(provider), code: nil)
                case .deviceCode(let code):
                    return handle(provider, url: Self.web("https://auth.openai.com/codex/device"), code: code)
                }
            },
            signOut: { @MainActor [unowned self] in
                log.append(.signOut(provider))
                if let reason = signOutFails[provider] { throw Said(reason) }
                status[provider] = provider == "codex" ? ["account": nil, "requiresOpenaiAuth": true] : ["loggedIn": false, "authMethod": "none"]
            })
    }

    private func handle(_ provider: String, url: URL, code: String?) -> SignInHandle {
        SignInHandle(
            url: url, code: code,
            wait: { @MainActor [unowned self] in
                try await withCheckedThrowingContinuation { waiting[provider] = $0 }
            },
            cancel: { @MainActor [unowned self] in
                log.append(.cancel(provider))
                waiting.removeValue(forKey: provider)?.resume(throwing: CancellationError())
            })
    }

    private static func page(_ provider: String) -> URL {
        web(provider == "codex" ? "https://auth.openai.com/oauth/authorize" : "https://claude.com/cai/oauth/authorize")
    }

    private static func web(_ text: String) -> URL { URL(string: text) ?? URL(fileURLWithPath: "/") }

    private static func words(_ mechanism: SignInMethod.Mechanism) -> String {
        switch mechanism {
        case .claudeAuthenticate(let fields): fields.keys.sorted().map { "\($0)=\(fields[$0].map(describe) ?? "")" }.joined(separator: ",")
        case .codexLogin(let params): "type=\(params["type"]?.string ?? "")"
        case .none: "none"
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        if let bool = value.bool { return "\(bool)" }
        return value.string ?? "?"
    }

    /// Claude Code's `auth status --json` for a Claude.ai login.
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
