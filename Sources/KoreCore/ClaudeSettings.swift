import Foundation

/// What Kore writes into Claude Code's user settings (`settings.json` in `CLAUDE_CONFIG_DIR`, else
/// `~/.claude`): a cloud platform's `env` keys, the same ones Claude's own `/login` wizard writes,
/// and an `apiKeyHelper` that reads Kore's Keychain item. Every change keeps the file's other
/// keys as they were; the platforms' keys are the only ones it adds or removes.
package enum ClaudeSettings {
    /// The user settings file the CLI reads.
    package static func userFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The machine's managed settings, which outrank every other file.
    package static let managedFile = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")

    /// The Keychain item Kore keeps a Claude API key in, and the helper that reads it.
    package static let keyService = "dev.kore.claude.api-key"
    package static let keyHelper = "security find-generic-password -s \(keyService) -w"

    /// The `awsAuthRefresh` command the CLI would run: managed settings first, then the user's;
    /// nil when neither sets one.
    package static func awsAuthRefresh(files: [URL]) -> String? {
        for file in files {
            guard let document = try? SettingsFile.read(file), let command = document.string("awsAuthRefresh") else { continue }
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: Platforms

    package enum Platform: String, CaseIterable, Sendable {
        case bedrock, vertex, foundry

        /// What Claude's status calls it (`apiProvider`).
        package var provider: String { rawValue }

        package var name: String {
            switch self {
            case .bedrock: "Amazon Bedrock"
            case .vertex: "Google Vertex AI"
            case .foundry: "Microsoft Foundry"
            }
        }

        /// The variable that turns it on.
        package var switchKey: String {
            switch self {
            case .bedrock: "CLAUDE_CODE_USE_BEDROCK"
            case .vertex: "CLAUDE_CODE_USE_VERTEX"
            case .foundry: "CLAUDE_CODE_USE_FOUNDRY"
            }
        }

        /// Every `env` key a save for it may write, and so every key its sign-out removes.
        package var keys: [String] {
            switch self {
            case .bedrock:
                [switchKey, "AWS_REGION", "AWS_PROFILE", "AWS_BEARER_TOKEN_BEDROCK", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"]
            case .vertex: [switchKey, "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION", "GOOGLE_APPLICATION_CREDENTIALS"]
            case .foundry: [switchKey, "ANTHROPIC_FOUNDRY_RESOURCE", "ANTHROPIC_FOUNDRY_API_KEY"]
            }
        }

        package init?(provider: String?) {
            guard let provider, let platform = Platform(rawValue: provider) else { return nil }
            self = platform
        }
    }

    /// How Bedrock gets its credentials.
    package enum BedrockCredentials: String, CaseIterable, Sendable {
        case profile, apiKey, accessKey, environment
    }

    /// How Vertex gets its credentials.
    package enum VertexCredentials: String, CaseIterable, Sendable {
        case gcloud, keyFile, environment
    }

    /// One platform form's values, as saved. Secrets are here only on their way to the file.
    package enum Setup: Equatable, Sendable {
        case bedrock(credentials: BedrockCredentials, region: String, profile: String?, apiKey: String?, accessKey: AccessKey?)
        case vertex(credentials: VertexCredentials, project: String, region: String, keyFile: String?)
        case foundry(resource: String, apiKey: String?)

        package var platform: Platform {
            switch self {
            case .bedrock: .bedrock
            case .vertex: .vertex
            case .foundry: .foundry
            }
        }

        /// The `env` keys and values it writes.
        package var env: [(String, String)] {
            switch self {
            case .bedrock(let credentials, let region, let profile, let apiKey, let accessKey):
                var pairs = [("CLAUDE_CODE_USE_BEDROCK", "1"), ("AWS_REGION", region)]
                switch credentials {
                case .profile: if let profile { pairs.append(("AWS_PROFILE", profile)) }
                case .apiKey: if let apiKey { pairs.append(("AWS_BEARER_TOKEN_BEDROCK", apiKey)) }
                case .accessKey:
                    if let accessKey {
                        pairs.append(("AWS_ACCESS_KEY_ID", accessKey.id))
                        pairs.append(("AWS_SECRET_ACCESS_KEY", accessKey.secret))
                        if let token = accessKey.token, !token.isEmpty { pairs.append(("AWS_SESSION_TOKEN", token)) }
                    }
                case .environment: break
                }
                return pairs
            case .vertex(let credentials, let project, let region, let keyFile):
                var pairs = [("CLAUDE_CODE_USE_VERTEX", "1"), ("ANTHROPIC_VERTEX_PROJECT_ID", project), ("CLOUD_ML_REGION", region)]
                if credentials == .keyFile, let keyFile { pairs.append(("GOOGLE_APPLICATION_CREDENTIALS", keyFile)) }
                return pairs
            case .foundry(let resource, let apiKey):
                var pairs = [("CLAUDE_CODE_USE_FOUNDRY", "1"), ("ANTHROPIC_FOUNDRY_RESOURCE", resource)]
                if let apiKey, !apiKey.isEmpty { pairs.append(("ANTHROPIC_FOUNDRY_API_KEY", apiKey)) }
                return pairs
            }
        }
    }

    package struct AccessKey: Equatable, Sendable {
        package let id: String
        package let secret: String
        package let token: String?

        package init(id: String, secret: String, token: String?) {
            self.id = id
            self.secret = secret
            self.token = token
        }
    }

    /// Every platform key Kore may write, and any other `CLAUDE_CODE_USE_*`: a save clears them
    /// all before writing its own, so exactly one platform is on.
    static func isPlatformKey(_ key: String) -> Bool {
        key.hasPrefix("CLAUDE_CODE_USE_") || Platform.allCases.contains { $0.keys.contains(key) }
    }

    /// The document with `setup` saved: the other platforms' keys and every other
    /// `CLAUDE_CODE_USE_*` gone, the same platform's keys for the credential not chosen gone, the
    /// rest of the file kept.
    package static func saving(_ setup: Setup, in document: SettingsDocument) -> SettingsDocument {
        var document = document
        var env = document.object("env")
        env.removeAll(where: isPlatformKey)
        for (key, value) in setup.env { env.set(key, string: value) }
        document.set("env", object: env)
        return document
    }

    /// The document with `platform` signed out: its keys gone (and, for Bedrock, any default
    /// model pinned to a Bedrock id, which first-party Claude can't run); nothing else touched.
    package static func removing(_ platform: Platform, from document: SettingsDocument) -> SettingsDocument {
        var document = document
        guard document.text("env") != nil else { return document }
        var env = document.object("env")
        env.removeAll { platform.keys.contains($0) }
        if platform == .bedrock {
            for key in env.keys where key.hasPrefix("ANTHROPIC_DEFAULT_") && key.hasSuffix("_MODEL") {
                if let value = env.string(key), isBedrockModel(value) { env.remove(key) }
            }
        }
        if env.members.isEmpty { document.remove("env") } else { document.set("env", object: env) }
        return document
    }

    /// A Bedrock model id or ARN ("us.anthropic.claude-…", "anthropic.claude-…", "arn:aws:bedrock:…").
    static func isBedrockModel(_ value: String) -> Bool {
        let value = value.lowercased()
        if value.hasPrefix("arn:aws:bedrock:") || value.hasPrefix("anthropic.") { return true }
        // A cross-region prefix: "us.", "eu.", "apac.", "global." …
        guard let dot = value.firstIndex(of: "."), value[value.index(after: dot)...].hasPrefix("anthropic.") else { return false }
        return value[..<dot].allSatisfy(\.isLetter)
    }

    /// The document with Kore's key on: its helper set, every platform's keys gone (a platform
    /// would leave the key unused).
    package static func savingKey(in document: SettingsDocument) -> SettingsDocument {
        var document = document
        if document.text("env") != nil {
            var env = document.object("env")
            env.removeAll(where: isPlatformKey)
            if env.members.isEmpty { document.remove("env") } else { document.set("env", object: env) }
        }
        document.set("apiKeyHelper", string: keyHelper)
        return document
    }

    /// The document with Kore's key off: the helper gone only when it's Kore's own.
    package static func removingKey(from document: SettingsDocument) -> SettingsDocument {
        var document = document
        if document.string("apiKeyHelper") == keyHelper { document.remove("apiKeyHelper") }
        return document
    }

    // MARK: Reading back

    /// What a settings file says Kore set up there: the platform turned on in its `env`, or Kore's
    /// key. nil when neither.
    package enum Saved: Equatable, Sendable {
        case platform(Platform, Summary)
        case key
    }

    /// A saved platform's details, for the caption and to fill its form in again. No secret.
    package struct Summary: Equatable, Sendable {
        package var region: String?
        package var profile: String?
        package var project: String?
        package var keyFile: String?
        package var resource: String?
        /// Bedrock's or Vertex's credentials, by their case name; "apiKey" for Foundry's key.
        package var credentials: String

        /// "us-east-1 · profile dev", "my-gcp-project · us-east5 · key file", "my-resource · Azure sign-in".
        package func caption(_ platform: Platform) -> String {
            switch platform {
            case .bedrock:
                let credential =
                    switch BedrockCredentials(rawValue: credentials) {
                    case .profile: "profile " + (profile ?? "default")
                    case .apiKey: "API key"
                    case .accessKey: "access key"
                    case .environment, nil: "environment"
                    }
                return [region ?? "us-east-1", credential].joined(separator: " · ")
            case .vertex:
                return [project, region, keyFile == nil ? nil : "key file"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            case .foundry:
                return [resource ?? "", credentials == "apiKey" ? "API key" : "Azure sign-in"].filter { !$0.isEmpty }.joined(separator: " · ")
            }
        }
    }

    /// The platform `env` turns on, if it's one of Kore's; else Kore's key, if its helper is set.
    package static func saved(in document: SettingsDocument) -> Saved? {
        let env = document.object("env")
        for platform in Platform.allCases where isOn(env.string(platform.switchKey)) {
            return .platform(platform, summary(platform, env))
        }
        return document.string("apiKeyHelper") == keyHelper ? .key : nil
    }

    /// The saved details of `platform` (whether or not it's on).
    package static func summary(_ platform: Platform, _ env: SettingsDocument) -> Summary {
        let has = { (key: String) in !(env.string(key) ?? "").isEmpty }
        switch platform {
        case .bedrock:
            let credentials: BedrockCredentials =
                has("AWS_BEARER_TOKEN_BEDROCK") ? .apiKey : has("AWS_ACCESS_KEY_ID") ? .accessKey : has("AWS_PROFILE") ? .profile : .environment
            return Summary(region: env.string("AWS_REGION"), profile: env.string("AWS_PROFILE"), credentials: credentials.rawValue)
        case .vertex:
            let keyFile = env.string("GOOGLE_APPLICATION_CREDENTIALS").flatMap { $0.isEmpty ? nil : $0 }
            return Summary(
                region: env.string("CLOUD_ML_REGION"), project: env.string("ANTHROPIC_VERTEX_PROJECT_ID"), keyFile: keyFile,
                credentials: (keyFile == nil ? VertexCredentials.gcloud : .keyFile).rawValue)
        case .foundry:
            return Summary(resource: env.string("ANTHROPIC_FOUNDRY_RESOURCE"), credentials: has("ANTHROPIC_FOUNDRY_API_KEY") ? "apiKey" : "azure")
        }
    }

    /// How the CLI reads a `CLAUDE_CODE_USE_*` value as on.
    static func isOn(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }

    // MARK: Form checks

    /// A Foundry resource name as the CLI takes it: 2–64 letters, digits and hyphens, no hyphen at
    /// either end. A pasted URL ("https://name.services.ai.azure.com/…") is cut to its name.
    package static func foundryResource(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: name), let host = url.host(), url.scheme != nil {
            name = String(host.prefix { $0 != "." })
        }
        let allowed = name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
        guard (2...64).contains(name.count), allowed, !name.hasPrefix("-"), !name.hasSuffix("-") else { return nil }
        return name
    }
}
