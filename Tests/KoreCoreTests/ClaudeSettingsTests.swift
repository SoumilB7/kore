import Foundation
import Testing

@testable import KoreCore

/// Kore's writes into Claude's settings: only the platform's keys move, the rest of the file
/// stays as it was, the file stays 0600 and is backed up once; and the pieces the sign-in
/// methods read (the SSO page, Codex's policy, AWS profiles, the Terminal hand-off).
@Suite("Claude settings")
struct ClaudeSettingsTests {
    /// A scratch folder of its own, gone after the test.
    final class Scratch {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kore-settings-\(UUID().uuidString)", isDirectory: true)
        var file: URL { folder.appendingPathComponent("settings.json") }
        init() { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: folder) }

        func mode(_ url: URL) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
    }

    static let original = """
        {
          "theme": "dark",
          "permissions": {"allow": ["Bash(ls:*)"]},
          "env": {"FOO": "1", "CLAUDE_CODE_USE_VERTEX": "1", "ANTHROPIC_VERTEX_PROJECT_ID": "old", "CLAUDE_CODE_USE_MANTLE": "1"},
          "model": "opus"
        }

        """

    @Test func aBedrockSaveMovesOnlyThePlatformsKeys() throws {
        let scratch = Scratch()
        try Self.original.write(to: scratch.file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratch.file.path)
        let setup = ClaudeSettings.Setup.bedrock(credentials: .profile, region: "us-west-2", profile: "dev", apiKey: nil, accessKey: nil)
        try SettingsFile.write(ClaudeSettings.saving(setup, in: try SettingsFile.read(scratch.file)), to: scratch.file)

        let saved = try SettingsFile.read(scratch.file)
        #expect(saved.keys == ["theme", "permissions", "env", "model"])
        #expect(saved.text("permissions") == #"{"allow": ["Bash(ls:*)"]}"#)
        #expect(saved.string("model") == "opus")
        let env = saved.object("env")
        #expect(env.keys == ["FOO", "CLAUDE_CODE_USE_BEDROCK", "AWS_REGION", "AWS_PROFILE"])
        #expect(env.string("AWS_PROFILE") == "dev" && env.string("AWS_REGION") == "us-west-2")
        #expect(scratch.mode(scratch.file) == 0o600)
        // One backup, of the file as it was before Kore first wrote it.
        let backup = SettingsFile.backup(of: scratch.file)
        #expect(try String(contentsOf: backup, encoding: .utf8) == Self.original)
        #expect(scratch.mode(backup) == 0o600)
        try SettingsFile.write(saved, to: scratch.file)
        #expect(try String(contentsOf: backup, encoding: .utf8) == Self.original)
        // Valid JSON, and nothing else left in the folder.
        #expect((try? JSONSerialization.jsonObject(with: Data(contentsOf: scratch.file))) is [String: Any])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.folder.path).sorted() == ["settings.json", "settings.json.kore-backup"])
    }

    @Test func signingOutRemovesExactlyWhatTheSaveWrote() {
        var document = SettingsDocument()
        document.set("theme", string: "dark")
        var env = SettingsDocument()
        env.set("FOO", string: "1")
        env.set("ANTHROPIC_DEFAULT_SONNET_MODEL", string: "us.anthropic.claude-sonnet-4-5-v1:0")
        env.set("ANTHROPIC_DEFAULT_OPUS_MODEL", string: "claude-opus-4-1")
        document.set("env", object: env)
        let saved = ClaudeSettings.saving(
            .bedrock(credentials: .apiKey, region: "us-east-1", profile: nil, apiKey: "k", accessKey: nil), in: document)
        #expect(saved.object("env").string("AWS_BEARER_TOKEN_BEDROCK") == "k")
        let out = ClaudeSettings.removing(.bedrock, from: saved)
        #expect(out.keys == ["theme", "env"])
        #expect(out.object("env").keys == ["FOO", "ANTHROPIC_DEFAULT_OPUS_MODEL"])
        // A platform alone in env leaves no empty env behind.
        let vertex = ClaudeSettings.saving(.vertex(credentials: .gcloud, project: "p", region: "us-east5", keyFile: nil), in: SettingsDocument())
        #expect(ClaudeSettings.removing(.vertex, from: vertex).keys == [])
    }

    @Test func eachChoiceWritesItsKeysAndNoOthers() {
        let env = { (setup: ClaudeSettings.Setup) in ClaudeSettings.saving(setup, in: SettingsDocument()).object("env").keys }
        #expect(env(.bedrock(credentials: .environment, region: "eu-west-1", profile: "x", apiKey: "y", accessKey: nil))
            == ["CLAUDE_CODE_USE_BEDROCK", "AWS_REGION"])
        let access = ClaudeSettings.AccessKey(id: "AKIA1", secret: "s", token: nil)
        #expect(env(.bedrock(credentials: .accessKey, region: "us-east-1", profile: nil, apiKey: nil, accessKey: access))
            == ["CLAUDE_CODE_USE_BEDROCK", "AWS_REGION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"])
        #expect(env(.vertex(credentials: .keyFile, project: "p", region: "us-east5", keyFile: "/k.json"))
            == ["CLAUDE_CODE_USE_VERTEX", "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION", "GOOGLE_APPLICATION_CREDENTIALS"])
        #expect(env(.foundry(resource: "r1", apiKey: nil)) == ["CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_FOUNDRY_RESOURCE"])
        #expect(env(.foundry(resource: "r1", apiKey: "k")) == ["CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_FOUNDRY_RESOURCE", "ANTHROPIC_FOUNDRY_API_KEY"])
    }

    @Test func koresKeyHelperComesAndGoesOnlyAsKores() {
        var document = SettingsDocument()
        var env = SettingsDocument()
        env.set("CLAUDE_CODE_USE_FOUNDRY", string: "1")
        env.set("FOO", string: "1")
        document.set("env", object: env)
        let on = ClaudeSettings.savingKey(in: document)
        #expect(on.string("apiKeyHelper") == "security find-generic-password -s dev.kore.claude.api-key -w")
        #expect(on.object("env").keys == ["FOO"])
        #expect(ClaudeSettings.saved(in: on) == .key)
        #expect(ClaudeSettings.removingKey(from: on).text("apiKeyHelper") == nil)
        var theirs = SettingsDocument()
        theirs.set("apiKeyHelper", string: "~/bin/key.sh")
        #expect(ClaudeSettings.removingKey(from: theirs).string("apiKeyHelper") == "~/bin/key.sh")
        #expect(ClaudeSettings.saved(in: theirs) == nil)
    }

    @Test func whatASaveReadsBackAs() {
        let saved = { (setup: ClaudeSettings.Setup) -> String? in
            guard case .platform(let platform, let summary) = ClaudeSettings.saved(in: ClaudeSettings.saving(setup, in: SettingsDocument()))
            else { return nil }
            return summary.caption(platform)
        }
        #expect(saved(.bedrock(credentials: .profile, region: "us-east-1", profile: "dev", apiKey: nil, accessKey: nil)) == "us-east-1 · profile dev")
        #expect(saved(.bedrock(credentials: .apiKey, region: "us-west-2", profile: nil, apiKey: "k", accessKey: nil)) == "us-west-2 · API key")
        #expect(saved(.bedrock(credentials: .environment, region: "us-east-1", profile: nil, apiKey: nil, accessKey: nil)) == "us-east-1 · environment")
        #expect(saved(.vertex(credentials: .keyFile, project: "acme", region: "us-east5", keyFile: "/a.json")) == "acme · us-east5 · key file")
        #expect(saved(.foundry(resource: "my-resource", apiKey: nil)) == "my-resource · Azure sign-in")
        #expect(saved(.foundry(resource: "my-resource", apiKey: "k")) == "my-resource · API key")
    }

    @Test func aFileThatIsntJSONIsNeverWritten() throws {
        let scratch = Scratch()
        try "{ not json".write(to: scratch.file, atomically: true, encoding: .utf8)
        #expect(throws: SettingsDocument.Failure.invalid) { try SettingsFile.read(scratch.file) }
        #expect(throws: SettingsDocument.Failure.invalid) { try SettingsDocument(parsing: Data("[1, 2]".utf8)) }
        // Missing or empty: an empty object.
        #expect(try SettingsFile.read(scratch.folder.appendingPathComponent("none.json")).keys == [])
        #expect(try SettingsDocument(parsing: Data(" \n".utf8)).keys == [])
    }

    @Test func aDocumentRendersAsTheCLIsDo() throws {
        var document = try SettingsDocument(parsing: Data(#"{"a": 1, "b": {"c": "d/e"}}"#.utf8))
        document.set("z", string: "x/y \"q\"")
        #expect(document.rendered() == "{\n  \"a\": 1,\n  \"b\": {\"c\": \"d/e\"},\n  \"z\": \"x/y \\\"q\\\"\"\n}")
        #expect(SettingsDocument().rendered() == "{}")
    }

    @Test func foundryResourcesAsTheCLITakesThem() {
        #expect(ClaudeSettings.foundryResource("my-resource") == "my-resource")
        #expect(ClaudeSettings.foundryResource("https://acme.services.ai.azure.com/anthropic/") == "acme")
        #expect(ClaudeSettings.foundryResource("-bad") == nil)
        #expect(ClaudeSettings.foundryResource("a") == nil)
        #expect(ClaudeSettings.foundryResource("has space") == nil)
        #expect(ClaudeSettings.foundryResource(String(repeating: "a", count: 65)) == nil)
    }

    @Test func awsRefreshIsReadFromTheFirstFileThatSetsIt() throws {
        let scratch = Scratch()
        let managed = scratch.folder.appendingPathComponent("managed.json")
        try #"{"awsAuthRefresh": "aws sso login --profile dev"}"#.write(to: scratch.file, atomically: true, encoding: .utf8)
        #expect(ClaudeSettings.awsAuthRefresh(files: [managed, scratch.file]) == "aws sso login --profile dev")
        try #"{"awsAuthRefresh": "  "}"#.write(to: managed, atomically: true, encoding: .utf8)
        #expect(ClaudeSettings.awsAuthRefresh(files: [managed, scratch.file]) == "aws sso login --profile dev")
        #expect(ClaudeSettings.awsAuthRefresh(files: [managed]) == nil)
    }

    // MARK: The Keychain

    @Test func theFakeKeychainHoldsAndForgets() throws {
        let keychain = MemoryKeychain()
        try keychain.set("sk-1", service: "svc")
        #expect(keychain.contains(service: "svc") && keychain.secret("svc") == "sk-1")
        try keychain.set("sk-2", service: "svc")
        #expect(keychain.secret("svc") == "sk-2")
        try keychain.remove(service: "svc")
        #expect(!keychain.contains(service: "svc"))
        keychain.failNext = -128
        #expect(throws: Keychain.Failure.self) { try keychain.set("sk-3", service: "svc") }
        #expect(!keychain.contains(service: "svc"))
        #expect(Keychain.Failure(-128).words.isEmpty == false)
    }

    // MARK: What the methods read

    @Test func theSSOPageIsTheVisitLine() {
        let out = "Opening browser to sign in…\nIf the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&login_method=sso\nPaste code here if prompted > "
        #expect(ClaudeAuth.visitURL(out)?.host() == "claude.com")
        #expect(ClaudeAuth.visitURL(out)?.query()?.contains("login_method=sso") == true)
        // Half a line isn't a page yet.
        #expect(ClaudeAuth.visitURL("If the browser didn't open, visit: https://claude.com/cai/oa") == nil)
        // A terminal hyperlink around it is taken off.
        let link = "If the browser didn't open, visit: \u{1B}]8;;https://claude.com/x\u{07}https://claude.com/x\u{1B}]8;;\u{07}\n"
        #expect(ClaudeAuth.visitURL(link)?.absoluteString == "https://claude.com/x")
        #expect(ClaudeAuth.visitURL("visit: file:///etc/passwd\n") == nil)
        #expect(ClaudeAuth.loginReason("Login failed: The sign-in page was closed.\n") == "The sign-in page was closed.")
        #expect(ClaudeAuth.loginReason("") == nil)
    }

    @Test func codexsForcedLoginMethod() throws {
        #expect(CodexAuth.forcedLoginMethod(toml: "model = \"x\"\nforced_login_method = \"api\" # policy\n") == "api")
        #expect(CodexAuth.forcedLoginMethod(toml: "forced_login_method='chatgpt'") == "chatgpt")
        #expect(CodexAuth.forcedLoginMethod(toml: "[profiles.x]\nforced_login_method = \"api\"") == nil)
        #expect(CodexAuth.forcedLoginMethod(toml: "forced_login_method = \"other\"") == nil)
        let scratch = Scratch()
        let user = scratch.folder.appendingPathComponent("config.toml"), managed = scratch.folder.appendingPathComponent("managed.toml")
        try "forced_login_method = \"chatgpt\"".write(to: user, atomically: true, encoding: .utf8)
        try "forced_login_method = \"api\"".write(to: managed, atomically: true, encoding: .utf8)
        #expect(CodexAuth.forcedLoginMethod(files: [managed, user]) == "api")
        #expect(CodexAuth.configFiles(environment: ["CODEX_HOME": "/tmp/x"]).last?.path == "/tmp/x/config.toml")
    }

    @Test func awsProfilesNamesAndRegionsOnly() {
        let config = "[default]\nregion = us-east-1\n\n[profile dev]\nsso_session = acme\nregion=us-west-2\n[sso-session acme]\nsso_region = eu-west-1\n"
        let credentials = "[default]\naws_access_key_id = AKIA\n[ci]\naws_secret_access_key = x\n"
        let profiles = AWSProfiles.parse(config: config, credentials: credentials)
        #expect(profiles.names == ["default", "dev", "ci"])
        #expect(profiles.regions == ["default": "us-east-1", "dev": "us-west-2"])
        #expect(AWSProfiles.read(environment: ["AWS_CONFIG_FILE": "/nonexistent/c", "AWS_SHARED_CREDENTIALS_FILE": "/nonexistent/k"]).names == [])
    }

    @Test func theTerminalHandOffRunsTheCLIInTheFolder() {
        let script = TerminalLogin.script(claude: "/opt/my tools/claude", arguments: ["/login"], folder: URL(fileURLWithPath: "/w/it's here"))
        #expect(script == "#!/bin/zsh -l\nrm -f -- \"$0\"\ncd -- '/w/it'\\''s here' 2>/dev/null\nexec '/opt/my tools/claude' '/login'\n")
    }

    /// Credentials from the launch shell never reach a CLI Kore starts, a platform's switch and
    /// its key together; what only says where things are does.
    @Test func platformSwitchesAndKeysAreStrippedTogether() {
        for name in [
            "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_MANTLE", "AWS_BEARER_TOKEN_BEDROCK",
            "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_API_KEY", "CODEX_ACCESS_TOKEN",
        ] {
            #expect(CLIExecutable.isForeignAuth(name))
        }
        for name in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "AWS_PROFILE", "AWS_REGION", "AWS_CONFIG_FILE", "GOOGLE_APPLICATION_CREDENTIALS", "PATH"] {
            #expect(!CLIExecutable.isForeignAuth(name))
        }
    }
}
