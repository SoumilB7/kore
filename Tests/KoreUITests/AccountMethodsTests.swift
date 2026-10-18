import Foundation
import KoreCore
import Testing

@testable import KoreUI

/// Every sign-in method (account-popup.html §7.6): each CLI's menu as data, what a policy hides,
/// the submenus as drawn, a platform's status in Kore's words, and the forms' Save.
@Suite("Account methods")
@MainActor
struct AccountMethodsTests {
    static func paths(_ methods: [SignInMethod], _ policy: LoginPolicy = LoginPolicy(), current: String? = nil) -> [String] {
        MethodMenuItem.paths(MethodMenuItem.build(methods, policy: policy, current: current)).flatMap { path, item in
            (item.separated ? ["—"] : []) + [(item.checked ? "✓ " : "") + path]
        }
    }

    @Test func claudesMenuIsItsLoginsInOrderWithItsHints() {
        let methods = SignInMethod.claude
        #expect(Self.paths(methods, current: "claudeai") == [
            "✓ Claude account with subscription", "Claude account with SSO",
            "Anthropic Console account/Sign in with your Console account (recommended)", "Anthropic Console account/Create an API key (legacy)",
            "—", "Anthropic Console account/Use an API key…", "3rd-party platform/Amazon Bedrock…", "3rd-party platform/Microsoft Foundry…",
            "3rd-party platform/Google Vertex AI…",
        ])
        let top = MethodMenuItem.build(methods, policy: LoginPolicy(), current: nil)
        #expect(top.map(\.title) == ["Claude account with subscription", "Claude account with SSO", "Anthropic Console account", "3rd-party platform"])
        #expect(top.map(\.hint) == ["Pro, Max, Team, or Enterprise", nil, "API usage billing", nil])
        #expect(top[2].children.map(\.hint) == ["Opens Terminal", "Adds a key to your Console workspace", "Stored in your Keychain"])
        let byID = Dictionary(uniqueKeysWithValues: methods.map { ($0.id, $0.mechanism) })
        #expect(byID["sso"] == .claudeSSO && byID["consoleTerminal"] == .terminal(["/login"]) && byID["claudeKey"] == .claudeKey)
        #expect(byID["bedrock"] == .platform(.bedrock) && byID["awsRefresh"] == .awsRefresh)
        // "…" means a field or form comes next; the rest start at once.
        let dotted = methods.filter(\.opensEditor).allSatisfy { $0.label.hasSuffix("…") }
        #expect(dotted)
    }

    @Test func codexsMenuHasNoBedrock() {
        #expect(Self.paths(SignInMethod.codex, current: "chatgpt") == ["✓ Sign in with ChatGPT", "Sign in with Device Code", "Provide your own API key…"])
        #expect(SignInMethod.codex.map(\.hint) == [
            "Usage included with Plus, Pro, Business, and Enterprise plans", "Sign in from another device with a one-time code",
            "Pay for what you use",
        ])
        let bedrock = SignInMethod.codex.contains { $0.label.contains("Bedrock") }
        #expect(!bedrock)
    }

    @Test func policiesHideWhatTheyRefuse() {
        let claude = SignInMethod.claude
        #expect(Self.paths(claude, LoginPolicy(forcedLoginMethod: "claudeai")) == ["Claude account with subscription", "Claude account with SSO"])
        #expect(Self.paths(claude, LoginPolicy(forcedLoginMethod: "console")) == [
            "Anthropic Console account/Sign in with your Console account (recommended)", "Anthropic Console account/Create an API key (legacy)",
            "—", "Anthropic Console account/Use an API key…",
        ])
        // Gateway: one item, the Terminal hand-off.
        #expect(Self.paths(claude, LoginPolicy(forcedLoginMethod: "gateway")) == ["Cloud gateway"])
        // A submenu left with one item comes up a level.
        #expect(Self.paths(claude, LoginPolicy(allowedProviders: ["vertex"])) == ["Google Vertex AI…"])
        #expect(Self.paths(claude, LoginPolicy(allowedProviders: ["bedrock", "foundry"])) == [
            "3rd-party platform/Amazon Bedrock…", "3rd-party platform/Microsoft Foundry…",
        ])
        // Claude Platform on AWS only with a refresh command.
        #expect(Self.paths(claude, LoginPolicy(awsAuthRefresh: "aws sso login")).contains("3rd-party platform/Claude Platform on AWS"))
        let aws = Self.paths(claude, LoginPolicy(allowedProviders: ["firstParty"], awsAuthRefresh: "x")).contains { $0.contains("AWS") }
        #expect(!aws)
        let codex = SignInMethod.codex
        #expect(Self.paths(codex, LoginPolicy(forcedLoginMethod: "api")) == ["Provide your own API key…"])
        #expect(Self.paths(codex, LoginPolicy(forcedLoginMethod: "chatgpt")) == ["Sign in with ChatGPT", "Sign in with Device Code"])
    }

    @Test func thePolicyIsReadFromTheStatus() {
        let policy = LoginPolicy(["forcedLoginMethod": "console", "allowedProviders": ["firstParty"], "awsAuthRefresh": "x", "loggedIn": true])
        #expect(policy == LoginPolicy(forcedLoginMethod: "console", allowedProviders: ["firstParty"], awsAuthRefresh: "x"))
        #expect(LoginPolicy(["forcedLoginMethod": ""]) == LoginPolicy())
    }

    // MARK: Signed in through Kore's settings

    static func claude(_ status: JSONValue, _ settings: SettingsDocument) -> AccountIdentity? {
        if case .signedIn(let identity) = AccountText.claude(ClaudeAuth.Status(status), settings: settings) { identity } else { nil }
    }

    @Test func aPlatformKoreSavedIsNamedAndChangeable() {
        let saved = ClaudeSettings.saving(
            .bedrock(credentials: .profile, region: "us-east-1", profile: "dev", apiKey: nil, accessKey: nil), in: SettingsDocument())
        let bedrock = Self.claude(["loggedIn": true, "authMethod": "third_party", "apiProvider": "bedrock"], saved)
        #expect(bedrock.map(AccountText.header) == "Amazon Bedrock")
        #expect(bedrock.map(AccountText.caption) == "us-east-1 · profile dev")
        #expect(bedrock?.changeable == true && bedrock?.methodID == "bedrock" && bedrock?.isKoreSetting == true)
        // Set somewhere Kore didn't write: named, and can't change.
        let elsewhere = Self.claude(["loggedIn": true, "authMethod": "third_party", "apiProvider": "vertex"], saved)
        #expect(elsewhere.map(AccountText.header) == "Google Vertex AI" && elsewhere?.changeable == false)
        // Kore's key: "API key", "Claude Console · Keychain".
        let key = Self.claude(
            ["loggedIn": true, "authMethod": "api_key_helper", "apiKeySource": "apiKeyHelper"], ClaudeSettings.savingKey(in: SettingsDocument()))
        #expect(key.map(AccountText.header) == "API key" && key.map(AccountText.caption) == "Claude Console · Keychain")
        #expect(key?.changeable == true && key?.methodID == "claudeKey")
        #expect(AccountText.signOutCaption(working: 1, setting: true) == "Removes it from Claude's settings everywhere. Stops 1 working chat.")
    }

    // MARK: The forms

    @Test func bedrocksFormFillsInAndSaves() {
        var form = PlatformForm()
        let profiles = AWSProfiles(names: ["default", "dev"], regions: ["default": "us-east-1", "dev": "us-west-2"])
        form.seed(.bedrock, settings: SettingsDocument(), environment: [:], profiles: profiles)
        #expect(form.bedrock == .profile && form.profile == "default" && form.region == "us-east-1")
        form.pick(profile: "dev")
        #expect(form.region == "us-west-2")
        let none = PlatformForm.Secrets()
        #expect(form.setup(.bedrock, secrets: none, saved: SettingsDocument())
            == .bedrock(credentials: .profile, region: "us-west-2", profile: "dev", apiKey: nil, accessKey: nil))
        form.bedrock = .apiKey
        #expect(form.setup(.bedrock, secrets: none, saved: SettingsDocument()) == nil)
        var typed = none
        typed.bedrockKey = "  key\n"
        #expect(form.setup(.bedrock, secrets: typed, saved: SettingsDocument())
            == .bedrock(credentials: .apiKey, region: "us-west-2", profile: nil, apiKey: "key", accessKey: nil))
        #expect(form.caption(.bedrock, keyTyped: false) == "Saved to Claude's settings, in plain text.")
        // No profiles: the API key is the default.
        var empty = PlatformForm()
        empty.seed(.bedrock, settings: SettingsDocument(), environment: [:], profiles: AWSProfiles())
        #expect(empty.bedrock == .apiKey && empty.region == "us-east-1")
    }

    @Test func aSavedSecretIsKeptWhenItsFieldIsLeftEmpty() {
        let settings = ClaudeSettings.saving(.foundry(resource: "acme", apiKey: "saved-key"), in: SettingsDocument())
        var form = PlatformForm()
        form.seed(.foundry, settings: settings, environment: [:], profiles: AWSProfiles())
        #expect(form.resource == "acme" && form.lines(.foundry, filled: []) == ["Resource: acme", "API key: Unchanged"])
        #expect(form.setup(.foundry, secrets: PlatformForm.Secrets(), saved: settings.object("env")) == .foundry(resource: "acme", apiKey: "saved-key"))
        #expect(form.caption(.foundry, keyTyped: false) == "Saved to Claude's settings, in plain text.")
        var fresh = PlatformForm()
        fresh.seed(.foundry, settings: SettingsDocument(), environment: [:], profiles: AWSProfiles())
        fresh.resource = "x"
        #expect(fresh.setup(.foundry, secrets: PlatformForm.Secrets(), saved: SettingsDocument()) == nil)
        #expect(fresh.caption(.foundry, keyTyped: false) == "Uses your Azure sign-in (az login).")
    }

    @Test func vertexNeedsItsKeyFileWhenItsChosen() {
        var form = PlatformForm()
        form.seed(.vertex, settings: SettingsDocument(), environment: ["ANTHROPIC_VERTEX_PROJECT_ID": "proj", "CLOUDSDK_CONFIG": "/nonexistent"], profiles: AWSProfiles())
        #expect(form.project == "proj" && form.vertexRegion == "us-east5" && form.vertex == .gcloud)
        #expect(form.setup(.vertex, secrets: PlatformForm.Secrets(), saved: SettingsDocument())
            == .vertex(credentials: .gcloud, project: "proj", region: "us-east5", keyFile: nil))
        form.vertex = .keyFile
        #expect(form.setup(.vertex, secrets: PlatformForm.Secrets(), saved: SettingsDocument()) == nil)
        form.keyFile = "/keys/sa.json"
        #expect(form.lines(.vertex, filled: []) == ["Credentials: Key file", "Key file: sa.json", "Project: proj", "Region: us-east5"])
    }
}
