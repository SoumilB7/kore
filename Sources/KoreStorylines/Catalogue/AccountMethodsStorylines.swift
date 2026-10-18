import AppKit
import Foundation
import KoreCore
import KoreUI

/// Every sign-in method (account-popup.html §7): the ⌄ unfolds the CLI's own login in the card
/// (its labels, order and hints, its groups disclosing in place), and a policy hides what it
/// refuses, the ⌄ going when one method is left; Esc folds them. A key goes into one masked field in the action row, is sent once and the field
/// is cleared; typing never closes the popup. Claude's platforms get Kore's forms, which write
/// Claude's settings (the run's own file) and keep everything else in it; signed in through
/// one, the card names the platform, and Sign out asks with No, go back covering Sign out's spot.
/// Esc steps back out of a field or form, and a second Esc closes the popup.
final class AccountMethods: ChatStoryline {
    override class var tags: Set<Tag> { [.chat] }

    static let claudeMenu = [
        "✓ Claude account with subscription", "Claude account with SSO",
        "Anthropic Console account/Sign in with your Console account (recommended)", "Anthropic Console account/Create an API key (legacy)",
        "—", "Anthropic Console account/Use an API key…", "3rd-party platform/Amazon Bedrock…", "3rd-party platform/Microsoft Foundry…",
        "3rd-party platform/Google Vertex AI…",
    ]
    static let codexMenu = ["✓ Sign in with ChatGPT", "Sign in with Device Code", "Provide your own API key…"]

    override func steps() -> [any Step] {
        let codex = variant == .codex
        let provider = codex ? "codex" : "claude"
        var steps: [any Step] = [
            UseScript(AccountPopup.script(provider), for: provider), OpenFolder(), StartChat(), WaitForFocus(.id(StoryID.Composer.field)),
        ]
        steps += codex ? codexSteps() : claudeSteps()
        return steps
    }

    // MARK: Pieces

    private static let popup = Locator.id(StoryID.Composer.account)
    private static func part(_ part: StoryID.Part) -> Locator { .id(StoryID.Composer.account.part(part)) }
    private static func field(_ name: String) -> Locator { .id(StoryID.Composer.accountField(name)) }
    private static var accounts: ScriptedAccounts { .shared }
    private static let open: [any Step] = [
        Press(.id(StoryID.Composer.slash)), Press(.id(StoryID.Composer.command("account"))), WaitForElement(popup),
    ]
    private static let reopen: [any Step] = [Key(.escape), ExpectElement(popup, .absent)] + open

    private static func lines(_ what: String, _ want: [String]) -> Expect {
        Expect(what, found: { $0.app.chat?.storyAccount.joined(separator: " | ") }) { $0.app.chat?.storyAccount == want }
    }

    private static func caption(_ what: String, _ want: String?) -> Expect {
        Expect(what, found: { $0.app.chat?.storyAccountCaption }) { $0.app.chat?.storyAccountCaption == want }
    }

    private static func menu(_ what: String, _ want: [String]) -> Expect {
        Expect(what, found: { $0.app.chat?.storyAccountMenu?.joined(separator: " | ") }) { $0.app.chat?.storyAccountMenu == want }
    }

    /// Unfolds the methods and presses one by its path.
    static func pick(_ path: String) -> [any Step] {
        [Press(part(.method)), Expect("the methods unfolded") { $0.app.chat?.storyAccountMenu != nil }] + press(path)
    }

    /// Presses an unfolded method by its path: its group's row first, which discloses it.
    static func press(_ path: String) -> [any Step] {
        let parts = path.split(separator: "/", maxSplits: 1)
        let group: [any Step] = parts.count == 2 ? [Press(.id(StoryID.Composer.accountMethod(String(parts[0]))))] : []
        return group + [Press(.id(StoryID.Composer.accountMethod(path)))]
    }

    private static func check(_ what: String, _ test: @escaping @MainActor () -> Bool) -> Expect { Expect(what) { _ in test() } }

    private static func setPolicy(_ provider: String, _ policy: JSONValue?) -> Expect {
        Expect("the CLI's policy: \(policy?.compact ?? "none")") { _ in
            accounts.policy[provider] = policy
            return true
        }
    }

    /// A form's picker pressed, its choices unfolded in the card, and one pressed.
    private static func choose(_ picker: String, _ value: String) -> [any Step] {
        let id = StoryID.Composer.accountChoice(picker, value)
        return [Press(picker == "credentials" ? part(.credentials) : field(picker)), WaitForElement(.id(id)), Press(.id(id))]
    }

    /// Claude's user settings as the run's file holds them.
    @MainActor private static var settings: SettingsDocument { (try? SettingsFile.read(ClaudeSettings.userFile())) ?? SettingsDocument() }
    @MainActor private static var env: SettingsDocument { settings.object("env") }

    private static func write(_ text: String, to path: String?) -> Expect {
        Expect("a file written at \(path ?? "?")") { _ in
            guard let path else { return false }
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        }
    }

    private static let me = ["you@example.com", "Claude Max · Claude.ai"]

    // MARK: Claude Code

    private func claudeSteps() -> [any Step] {
        let accounts = Self.accounts
        var steps: [any Step] = Self.open + [Self.lines("the Claude.ai account", Self.me)]
        // 1 · The ⌄ beside Switch account: the CLI's /login, in its order, with its hints.
        steps += [
            Press(Self.part(.method)),
            Self.menu("every method, the account's checked", Self.claudeMenu),
            Expect("the top level with the CLI's hints", found: { $0.app.chat?.storyAccountMenuTop?.joined(separator: " | ") }) {
                $0.app.chat?.storyAccountMenuTop == [
                    "Claude account with subscription · Pro, Max, Team, or Enterprise", "Claude account with SSO",
                    "Anthropic Console account ▸ · API usage billing", "3rd-party platform ▸",
                ]
            },
            // A group discloses its methods in place.
            Press(.id(StoryID.Composer.accountMethod("Anthropic Console account"))),
            WaitForElement(.id(StoryID.Composer.accountMethod("Anthropic Console account/Use an API key…"))),
            FadesEnd(),
            Snapshot("methods-menu"),
            Key(.escape),
            Expect("Esc: the methods folded, the popup still open") {
                $0.app.chat?.storyAccountMenu == nil && $0.app.chat?.isAccountOpen == true
            },
            ExpectElement(.id(StoryID.Composer.accountMethod("Claude account with SSO")), .absent),
        ]
        // 2 · Policies hide what they refuse; a submenu left with one item comes up a level; one
        // method left and the ⌄ goes.
        steps += [Self.setPolicy("claude", ["forcedLoginMethod": "console"])] + Self.reopen + [
            Press(Self.part(.method)),
            Self.menu("Console only", [
                "✓ Anthropic Console account/Sign in with your Console account (recommended)",
                "Anthropic Console account/Create an API key (legacy)", "—", "Anthropic Console account/Use an API key…",
            ]),
            Key(.escape),
            Self.setPolicy("claude", ["allowedProviders": ["firstParty", "vertex"], "awsAuthRefresh": "aws sso login --profile dev"]),
        ] + Self.reopen + [
            Press(Self.part(.method)),
            Self.menu("first party and Vertex, its submenu gone", [
                "✓ Claude account with subscription", "Claude account with SSO",
                "Anthropic Console account/Sign in with your Console account (recommended)",
                "Anthropic Console account/Create an API key (legacy)", "—", "Anthropic Console account/Use an API key…",
                "Google Vertex AI…",
            ]),
            Key(.escape),
            Self.setPolicy("claude", ["awsAuthRefresh": "aws sso login --profile dev"]),
        ] + Self.reopen + [
            Press(Self.part(.method)),
            Expect("Claude Platform on AWS listed once a refresh is set") {
                $0.app.chat?.storyAccountMenu?.contains("3rd-party platform/Claude Platform on AWS") == true
            },
            Key(.escape),
            Self.setPolicy("claude", ["forcedLoginMethod": "gateway"]),
        ] + Self.reopen + [
            Expect("one method: no ⌄") { $0.app.chat?.storyAccountHasMenu == false },
            ExpectElement(Self.part(.method), .absent),
            Self.setPolicy("claude", nil),
        ] + Self.reopen
        // 3 · SSO: the CLI opens the page itself; Kore waits with Copy link and Cancel.
        steps += Self.pick("Claude account with SSO") + [
            Self.lines("waiting for the browser", Self.me + ["Waiting for the browser…"]),
            Self.check("SSO asked for, no page opened by Kore") {
                accounts.log.contains(.signIn("claude", "sso")) && !accounts.log.contains(.opened("claude.com"))
            },
            Press(Self.part(.cancel)),
            Self.lines("cancelled", Self.me),
        ]
        // 4 · The Console's recommended sign-in goes to Terminal, and ends when the account changes.
        steps += Self.pick("Anthropic Console account/Sign in with your Console account (recommended)") + [
            Self.lines("finishing in Terminal", Self.me + ["Finish in Terminal…"]),
            Self.caption("what to do there", "Pick Console account, then Sign in with your Console account."),
            Self.check("claude /login handed to Terminal") { accounts.log.contains(.terminal("claude", "/login")) },
            Press(Self.part(.cancel)),
            Self.lines("cancelled", Self.me),
        ]
        // 5 · Use an API key…: the masked field; typing keeps the popup; the key goes to the
        // (in-memory) Keychain and Claude's helper reads it; the field is cleared.
        steps += Self.pick("Anthropic Console account/Use an API key…") + [
            Self.lines("the key field, empty", Self.me + ["API key: "]),
            Self.caption("where the key goes", "Stored in your Keychain."),
            WaitForFocus(Self.field("key")),
            TypeText("sk-ant-kore-test-0001"),
            Self.lines("the key masked", Self.me + ["API key: ••••"]),
            Expect("typing kept the popup open, the field the keys") { $0.app.chat?.isAccountOpen == true && $0.app.chat?.storyAccountEditing == true },
            FadesEnd(),
            Snapshot("methods-key-row"),
            Key(.returnKey),
            Self.lines("signed in with Kore's key", ["API key", "Claude Console · Keychain", "Switched accounts."]),
            Self.check("the key in the Keychain, Claude's helper reading it") {
                accounts.keychain.secret(ClaudeSettings.keyService) == "sk-ant-kore-test-0001"
                    && Self.settings.string("apiKeyHelper") == ClaudeSettings.keyHelper && accounts.log.contains(.key("claude"))
            },
            Self.check("the settings file is 0600") { Self.mode(ClaudeSettings.userFile()) == 0o600 },
        ]
        // Signing Kore's key out: its helper and item go, the Claude.ai login underneath shows.
        steps += Self.reopen + [
            Press(Self.part(.signOut)),
            Self.caption("a setting's reach", "Removes it from Claude's settings everywhere."),
            Expect("a double click's time gone by", timeout: .seconds(6)) { $0.app.chat?.storyAccountConfirmable == true },
            Press(Self.part(.allow)),
            Self.lines("back on Claude.ai", Self.me + ["Signed out of API key."]),
            Self.check("the helper and the item gone") {
                Self.settings.text("apiKeyHelper") == nil && !accounts.keychain.contains(service: ClaudeSettings.keyService)
            },
        ]
        // 6 · Amazon Bedrock, with the run's AWS config: the profiles listed, the region follows
        // the profile; Save writes Claude's settings and keeps the rest of the file.
        let awsConfig = ProcessInfo.processInfo.environment["AWS_CONFIG_FILE"]
        steps += [
            Self.write("[default]\nregion = us-east-1\n\n[profile dev]\nregion = us-west-2\nsso_session = acme\n", to: awsConfig),
            Self.write(
                "{\n  \"theme\": \"dark\",\n  \"env\": {\"FOO\": \"1\", \"CLAUDE_CODE_USE_MANTLE\": \"1\"}\n}\n",
                to: ClaudeSettings.userFile().path),
        ] + Self.reopen + Self.pick("3rd-party platform/Amazon Bedrock…") + [
            Self.lines("the Bedrock form, from the AWS config", [
                "Amazon Bedrock", "Credentials: AWS profile", "Profile: default", "Region: us-east-1", "Saved to Claude's settings.",
            ]),
        ] + Self.choose("profile", "dev") + [
            Self.lines("the region follows the profile", [
                "Amazon Bedrock", "Credentials: AWS profile", "Profile: dev", "Region: us-west-2", "Saved to Claude's settings.",
            ]),
        ] + Self.choose("credentials", "apiKey") + [
            WaitForFocus(Self.field("apikey")),
            TypeText("bedrock-kore-test"),
            Self.lines("a Bedrock API key, masked, saved in plain text", [
                "Amazon Bedrock", "Credentials: Bedrock API key", "API key: ••••", "Region: us-west-2",
                "Saved to Claude's settings, in plain text.",
            ]),
            Expect("typing in a form kept the popup open") { $0.app.chat?.isAccountOpen == true && $0.app.chat?.storyAccountEditing == true },
            Key(.tab),
            WaitForFocus(Self.field("region")),
            FadesEnd(),
            Snapshot("methods-bedrock-form"),
            // The choices unfold under the picker; Esc folds them, the form staying.
            Press(Self.part(.credentials)),
            WaitForElement(.id(StoryID.Composer.accountChoice("credentials", "accessKey"))),
            FadesEnd(),
            Snapshot("methods-form-picker"),
            Key(.escape),
            ExpectElement(.id(StoryID.Composer.accountChoice("credentials", "accessKey")), .absent),
            Expect("the form still open") { $0.app.chat?.storyAccount.first == "Amazon Bedrock" },
        ] + Self.choose("credentials", "profile") + [
            Press(Self.part(.save)),
            Self.lines("saved: the platform, its region and profile", ["Amazon Bedrock", "us-west-2 · profile dev", "Saved."]),
            Self.check("exactly Bedrock's keys, the rest kept") {
                let env = Self.env
                return env.keys == ["FOO", "CLAUDE_CODE_USE_BEDROCK", "AWS_REGION", "AWS_PROFILE"] && env.string("AWS_REGION") == "us-west-2"
                    && env.string("AWS_PROFILE") == "dev" && Self.settings.string("theme") == "dark"
            },
            Self.check("a backup of the file as it was, and 0600") {
                FileManager.default.fileExists(atPath: SettingsFile.backup(of: ClaudeSettings.userFile()).path)
                    && Self.mode(ClaudeSettings.userFile()) == 0o600
            },
        ] + Self.reopen + [
            Self.lines("signed in through Bedrock", ["Amazon Bedrock", "us-west-2 · profile dev"]),
            ExpectElement(Self.part(.switch)),
            FadesEnd(),
            Snapshot("methods-bedrock-signed-in"),
        ]
        // 7 · Sign out of Bedrock: "No, go back" covers Sign out's spot; Yes removes exactly the
        // keys Bedrock's save wrote.
        steps += [
            Expect("Sign out's frame at rest kept") { story in
                let rest = story.stash(SignOutFrame.self) { SignOutFrame() }
                rest.frame = StoryRegistry.entry(StoryID.Composer.account.part(.signOut).raw)?.frame
                return rest.frame != nil
            },
            Press(Self.part(.signOut)),
            WaitForElement(Self.part(.allow)),
            Self.lines("the question names the platform", ["Amazon Bedrock", "us-west-2 · profile dev", "Sign out of Amazon Bedrock?"]),
            Self.caption("its reach", "Removes it from Claude's settings everywhere."),
            Expect("No, go back covers Sign out's spot", found: { story in
                let no = StoryRegistry.entry(StoryID.Composer.account.part(.cancel).raw)?.frame
                let rest = story.stash(SignOutFrame.self) { SignOutFrame() }.frame
                return "No \(no.map { "\($0)" } ?? "none"), Sign out \(rest.map { "\($0)" } ?? "none")"
            }) { story in
                guard let rest = story.stash(SignOutFrame.self, make: { SignOutFrame() }).frame,
                    let no = StoryRegistry.entry(StoryID.Composer.account.part(.cancel).raw)?.frame
                else { return false }
                return no.insetBy(dx: -0.5, dy: -0.5).contains(rest)
            },
            FadesEnd(),
            Snapshot("methods-sign-out-confirm"),
            Expect("a double click's time gone by", timeout: .seconds(6)) { $0.app.chat?.storyAccountConfirmable == true },
            Press(Self.part(.allow)),
            Self.lines("the Claude.ai login underneath", Self.me + ["Signed out of Amazon Bedrock."]),
            Self.check("Bedrock's keys gone, the rest kept") { Self.env.keys == ["FOO"] && Self.settings.string("theme") == "dark" },
        ]
        // 8 · Google Vertex AI with a key file: its project comes from the file.
        let keyFile = { (story: StoryContext) in story.folder.appendingPathComponent("vertex-sa.json") }
        steps += Self.reopen + [
            Expect("a key file to pick") { story in
                try Data(#"{"type": "service_account", "project_id": "acme-ml-prod"}"#.utf8).write(to: keyFile(story))
                Self.accounts.chosenFile = keyFile(story)
                return true
            },
        ] + Self.pick("3rd-party platform/Google Vertex AI…") + [
        ] + Self.choose("credentials", "keyFile") + [
            Press(Self.part(.choose)),
            Self.lines("the key file, its project", [
                "Google Vertex AI", "Credentials: Key file", "Key file: vertex-sa.json", "Project: acme-ml-prod", "Region: us-east5",
                "Saved to Claude's settings.",
            ]),
            Press(Self.part(.save)),
            Self.lines("saved", ["Google Vertex AI", "acme-ml-prod · us-east5 · key file", "Saved."]),
            Expect("Vertex's four keys") { story in
                let env = Self.env
                return env.keys == ["FOO", "CLAUDE_CODE_USE_VERTEX", "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION", "GOOGLE_APPLICATION_CREDENTIALS"]
                    && env.string("GOOGLE_APPLICATION_CREDENTIALS") == keyFile(story).path
            },
        ]
        // 9 · Microsoft Foundry: a pasted URL cut to its resource; no key, Azure sign-in; Return saves.
        steps += Self.reopen + Self.pick("3rd-party platform/Microsoft Foundry…") + [
            WaitForFocus(Self.field("resource")),
            TypeText("https://acme-foundry.services.ai.azure.com/anthropic/"),
            Self.lines("the Foundry form", [
                "Microsoft Foundry", "Resource: https://acme-foundry.services.ai.azure.com/anthropic/", "API key: ",
                "Uses your Azure sign-in (az login).",
            ]),
            Key(.returnKey),
            Self.lines("saved, Vertex replaced", ["Microsoft Foundry", "acme-foundry · Azure sign-in", "Saved."]),
            Self.check("Foundry's keys only") {
                Self.env.keys == ["FOO", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_FOUNDRY_RESOURCE"]
                    && Self.env.string("ANTHROPIC_FOUNDRY_RESOURCE") == "acme-foundry"
            },
        ]
        // 10 · Esc steps back out of a form, then closes the popup.
        steps += Self.reopen + Self.pick("3rd-party platform/Amazon Bedrock…") + [
            Expect("the form open") { $0.app.chat?.storyAccount.first == "Amazon Bedrock" && $0.app.chat?.storyAccountEditing == true },
            Key(.escape),
            Self.lines("Esc: back to the account", ["Microsoft Foundry", "acme-foundry · Azure sign-in"]),
            ExpectElement(Self.popup),
            Key(.escape),
            ExpectElement(Self.popup, .absent),
            WaitForFocus(.id(StoryID.Composer.field)),
        ]
        return steps
    }

    // MARK: Codex

    private func codexSteps() -> [any Step] {
        let accounts = Self.accounts
        let me = ["you@example.com", "ChatGPT Pro Lite · ChatGPT"]
        var steps: [any Step] = Self.open + [Self.lines("the ChatGPT account", me)]
        // 1 · The ⌄: Codex's three, with their hints; Bedrock never listed.
        steps += [
            Press(Self.part(.method)),
            Self.menu("Codex's methods", Self.codexMenu),
            Expect("with Codex's hints", found: { $0.app.chat?.storyAccountMenuTop?.joined(separator: " | ") }) {
                $0.app.chat?.storyAccountMenuTop == [
                    "Sign in with ChatGPT · Usage included with Plus, Pro, Business, and Enterprise plans",
                    "Sign in with Device Code · Sign in from another device with a one-time code",
                    "Provide your own API key… · Pay for what you use",
                ]
            },
            FadesEnd(),
            Snapshot("methods-menu"),
            Key(.escape),
        ]
        // 2 · forced_login_method = "chatgpt" hides the key; "api" leaves one method, no ⌄, and
        // Switch account opens the key field.
        steps += [Self.setPolicy("codex", ["forcedLoginMethod": "chatgpt"])] + Self.reopen + [
            Press(Self.part(.method)),
            Self.menu("ChatGPT only", ["✓ Sign in with ChatGPT", "Sign in with Device Code"]),
            Key(.escape),
            Self.setPolicy("codex", ["forcedLoginMethod": "api"]),
        ] + Self.reopen + [
            Expect("one method: no ⌄") { $0.app.chat?.storyAccountHasMenu == false },
            ExpectElement(Self.part(.method), .absent),
            Press(Self.part(.switch)),
            Self.lines("the key field", me + ["API key: "]),
            Self.caption("where the key goes", "Stored by Codex."),
        ]
        // 3 · A refused key: the field comes back cleared, saying why; the next one lands.
        steps += [
            WaitForFocus(Self.field("key")),
            Expect("the next key refused") { _ in
                accounts.keyFails["codex"] = "Incorrect API key provided."
                return true
            },
            TypeText("sk-kore-test-bad"),
            Self.lines("masked", me + ["API key: ••••"]),
            Key(.returnKey),
            Self.lines("refused: the field back, empty", me + ["API key: ", "Couldn't sign in: Incorrect API key provided."]),
            Self.check("the refused key went nowhere") { accounts.keys["codex"] == nil },
            WaitForFocus(Self.field("key")),
            TypeText("sk-kore-test-0002"),
            Self.lines("typing again: the words give way", me + ["API key: ••••"]),
            Self.caption("the caption back", "Stored by Codex."),
            FadesEnd(),
            Snapshot("methods-key-row"),
            Press(Self.part(.signIn)),
            Self.lines("signed in with the key", ["API key", "API key", "Switched accounts."]),
            Self.check("Codex took the key once: account/login/start apiKey") {
                accounts.keys["codex"] == "sk-kore-test-0002" && accounts.log.filter { $0 == .key("codex") }.count == 1
            },
            Expect("the field gone and nothing kept") { $0.app.chat?.storyAccountEditing == false },
            Self.setPolicy("codex", nil),
        ]
        // 4 · Esc steps back out of the field, typing never closing the popup; a second Esc closes.
        steps += Self.reopen + Self.pick("Provide your own API key…") + [
            WaitForFocus(Self.field("key")),
            TypeText("abc"),
            Expect("typing kept the popup open") { $0.app.chat?.isAccountOpen == true && $0.app.chat?.storyAccount.last == "API key: ••••" },
            Key(.escape),
            Self.lines("Esc: back to rest", ["API key", "API key"]),
            ExpectElement(Self.popup),
            Key(.escape),
            ExpectElement(Self.popup, .absent),
            WaitForFocus(.id(StoryID.Composer.field)),
        ]
        return steps
    }

    private static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}

/// Sign out's frame at rest, kept for the question's check.
private final class SignOutFrame {
    var frame: CGRect?
}

/// Waits out the row's fade (`Motion.fade`), so a snapshot shows where it ends.
private struct FadesEnd: Step {
    var label: String { "Wait for the fades to end" }

    func run(_ story: StoryContext) async throws {
        let end = ContinuousClock.now + .milliseconds(400)
        try await story.until("the fades to end") { ContinuousClock.now >= end }
    }
}
