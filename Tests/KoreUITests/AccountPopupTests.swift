import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// The Account popup's words: each CLI's status as an identity, its caption, the / menu entry,
/// and the pointers to it.
@Suite("Account popup")
@MainActor
struct AccountPopupTests {
    static func claude(_ fields: JSONValue) -> AccountReading { AccountText.claude(ClaudeAuth.Status(fields)) }
    static func codex(_ fields: JSONValue) -> AccountReading { AccountText.codex(CodexAuth.Status(fields)) }

    static func identity(_ reading: AccountReading) -> AccountIdentity? {
        if case .signedIn(let identity) = reading { identity } else { nil }
    }

    @Test func claudeMethodsAndWhetherKoreCanChangeThem() {
        let sub = Self.identity(Self.claude([
            "loggedIn": true, "authMethod": "claude.ai", "email": "you@example.com", "orgName": "you@example.com's Organization",
            "subscriptionType": "max",
        ]))
        #expect(sub == AccountIdentity(
            email: "you@example.com", plan: "Claude Max", organization: "you@example.com's Organization", method: "Claude.ai",
            changeable: true, methodID: "claudeai"))
        let console = Self.identity(Self.claude(["loggedIn": true, "authMethod": "api_key", "apiKeySource": "/login managed key"]))
        #expect(console?.method == "Console" && console?.plan == "Claude Console" && console?.changeable == true)
        let rows: [(JSONValue, String)] = [
            (["loggedIn": true, "authMethod": "api_key", "apiKeySource": "ANTHROPIC_API_KEY"], "API key from env"),
            (["loggedIn": true, "authMethod": "oauth_token"], "Token from env"),
            (["loggedIn": true, "authMethod": "api_key_helper", "apiKeySource": "apiKeyHelper"], "API key helper"),
            (["loggedIn": true, "authMethod": "third_party", "apiProvider": "bedrock"], "Amazon Bedrock"),
            (["loggedIn": true, "authMethod": "third_party", "apiProvider": "vertex"], "Google Vertex AI"),
            (["loggedIn": true, "authMethod": "something_new"], "Managed settings"),
        ]
        for (status, word) in rows {
            let identity = Self.identity(Self.claude(status))
            // A platform is named in the header; its caption says where it was set.
            #expect(identity?.method == word || identity.map(AccountText.header) == word)
            #expect(identity?.changeable == false)
        }
        #expect(Self.claude(["loggedIn": false, "authMethod": "none"]) == .signedOut)
        #expect(Self.claude(.null) == .signedOut)
    }

    @Test func codexMethodsAndWhetherKoreCanChangeThem() {
        let chatgpt = Self.identity(Self.codex(["account": ["type": "chatgpt", "email": "you@example.com", "planType": "prolite"]]))
        #expect(chatgpt?.method == "ChatGPT" && chatgpt?.plan == "ChatGPT Pro Lite" && chatgpt?.changeable == true)
        let key = Self.identity(Self.codex(["account": ["type": "apiKey"]]))
        #expect(key?.method == "API key" && key?.changeable == true && key.map(AccountText.header) == "API key")
        let bedrock = Self.identity(Self.codex(["account": ["type": "amazonBedrock", "usesCodexManagedCredentials": false]]))
        #expect(bedrock?.method == "Bedrock" && bedrock?.changeable == false)
        #expect(Self.codex(["account": nil, "requiresOpenaiAuth": true]) == .signedOut)
        #expect(Self.identity(Self.codex(["account": nil, "requiresOpenaiAuth": false]))?.method == "Managed")
    }

    @Test func theCaptionLeavesOutEmptyPartsAndAPersonalOrg() {
        let caption = { (org: String?) in
            AccountText.caption(AccountIdentity(email: "you@example.com", plan: "Claude Max", organization: org, method: "Claude.ai", changeable: true))
        }
        #expect(caption(nil) == "Claude Max · Claude.ai")
        #expect(caption("you@example.com's Organization") == "Claude Max · Claude.ai")
        #expect(caption("You@Example.com\u{2019}s organization") == "Claude Max · Claude.ai")
        #expect(caption("Acme Labs") == "Claude Max · Claude.ai · Acme Labs")
        #expect(AccountText.caption(AccountIdentity(method: "API key helper", changeable: false)) == "API key helper")
    }

    @Test func aSwitchToTheSameAccountIsKnown() {
        let me = AccountIdentity(email: "You@example.com", plan: "Claude Max", method: "Claude.ai", changeable: true)
        var again = me
        again.email = "you@example.com"
        again.plan = "Claude Pro"
        #expect(me.isSameAccount(as: again))
        var other = me
        other.email = "work@acme.dev"
        #expect(!me.isSameAccount(as: other))
    }

    @Test func theFlowsWords() {
        #expect(AccountText.signOutCaption(working: 0) == "Also signs out Terminal and VS Code on this Mac.")
        #expect(AccountText.signOutCaption(working: 1) == "Also signs out Terminal and VS Code on this Mac. Stops 1 working chat.")
        #expect(AccountText.signOutCaption(working: 2) == "Also signs out Terminal and VS Code on this Mac. Stops 2 working chats.")
        #expect(AccountText.signInFailed("Login cancelled.") == "Couldn't sign in: Login cancelled.")
        #expect(AccountText.signInFailed(nil) == "Couldn't sign in.")
        #expect(AccountText.readFailed("Codex", nil) == "Couldn't read Codex's account.")
        #expect(AccountText.expired("Claude Code", signedOut: false) == "Your Claude Code sign-in expired.")
        #expect(AccountText.expired("Claude Code", signedOut: true) == "Claude Code isn't signed in.")
        #expect(AccountReason.of(ClaudeSession.Failure.controlError("Login blocked by policy")) == "Login blocked by policy")
        #expect(AccountReason.of(CodexAppServer.Failure.rpc(code: 0, message: "")) == nil)
    }

    @Test func theWelcomeLine() {
        #expect(AccountText.welcome(signedOut: []) == nil)
        #expect(AccountText.welcome(signedOut: ["Codex"]) == "Codex isn't signed in. Sign in from Account in a chat's / menu.")
        #expect(
            AccountText.welcome(signedOut: ["Claude Code", "Codex"])
                == "Claude Code and Codex aren't signed in. Sign in from Account in a chat's / menu.")
    }

    @Test func eachCLIsMethodsAsData() {
        let claude = ProviderDescriptor.claude.account.methods
        #expect(claude.first?.mechanism == .claudeAuthenticate(["loginWithClaudeAi": true]))
        let allRun = claude.allSatisfy(\.runs)
        #expect(allRun)
        let codex = ProviderDescriptor.codex.account.methods
        #expect(codex[1].mechanism == .codexLogin(["type": "chatgptDeviceCode"]))
        #expect(codex[2].mechanism == .codexKey && codex[2].label == "Provide your own API key…")
    }

    // MARK: The / menu entry

    static let compact = SlashCommand(name: "compact", description: "", hint: "", kind: .command)
    static let login = SlashCommand(name: "login", description: "", hint: "", kind: .command)
    static let logout = SlashCommand(name: "logout", description: "", hint: "", kind: .command)

    func names(_ query: String) -> [String] {
        SlashCommand.matches([Self.compact, Self.login, Self.logout], sigil: "/", query: query).map(\.label)
    }

    @Test func accountFollowsUsageInPlaceOfTheCLIsLogin() {
        #expect(names("") == ["Usage", "Account", "/compact"])
        #expect(SlashCommand.usage.glyph == "chart.bar.fill" && SlashCommand.usage.description == "Plan limits")
        #expect(SlashCommand.account.glyph == "person" && SlashCommand.account.description == "Sign in, switch or sign out")
    }

    @Test func accountIsFoundByItsOtherWords() {
        #expect(names("login") == ["Account"])
        #expect(names("logout") == ["Account"])
        #expect(names("sign") == ["Account"])
        #expect(names("switch") == ["Account"])
        #expect(names("acc") == ["Account"])
    }
}

/// A turn the CLI's login refused before it wrote anything still shows its notice, after the
/// message that started it and before the next one.
@Suite("Refused login notice")
@MainActor
struct RefusedLoginNoticeTests {
    @Test func aRefusedTurnWithNothingOfItsOwnShowsAfterItsMessage() {
        let script = Script()
        script.send("first")
        script.start("t1")
        script.finish("t1", .authFailed("Not logged in · Please run /login"))
        #expect(script.lines == ["§ first", "message first", "signin Not logged in · Please run /login"])
        script.turn("t2", "second")
        #expect(script.lines.prefix(3) == ["§ first", "message first", "signin Not logged in · Please run /login"])
        #expect(script.lines.contains("§ second"))
    }
}
