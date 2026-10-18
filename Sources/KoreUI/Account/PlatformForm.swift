import Foundation
import KoreCore

/// A platform form's values that aren't secret (the credential choice, profile, region, project,
/// key file's path, resource), kept for this run of Kore so reopening a form fills it in again.
/// Secrets live in the form's view only, and are passed in as `Secrets` on Save.
struct PlatformForm: Equatable {
    typealias Platform = ClaudeSettings.Platform

    var bedrock: ClaudeSettings.BedrockCredentials = .profile
    var profile: String?
    var region = ""
    /// The region was typed: it no longer follows the profile.
    var regionEdited = false
    var accessKeyID = ""
    var vertex: ClaudeSettings.VertexCredentials = .gcloud
    var project = ""
    var projectEdited = false
    var vertexRegion = ""
    var keyFile: String?
    var resource = ""
    var profiles = AWSProfiles()
    /// The secrets the saved settings already hold, by field: an empty field keeps them.
    var savedSecrets: Set<String> = []
    /// The platforms filled in once; their values aren't reset on reopening.
    var seeded: Set<String> = []

    /// What the form's secret fields hold, on Save.
    struct Secrets {
        var bedrockKey = ""
        var accessSecret = ""
        var accessToken = ""
        var foundryKey = ""
    }

    /// The fields that are secrets, by name.
    enum Secret: String, CaseIterable {
        case bedrockKey = "apikey", accessSecret = "secret", accessToken = "token", foundryKey = "foundrykey"
    }

    // MARK: Filling in

    /// Fills `platform`'s values from the saved settings (when they set it up), else the launch
    /// environment and the CLIs' own files, the first time it opens in this run.
    mutating func seed(_ platform: Platform, settings: SettingsDocument, environment: [String: String], profiles: AWSProfiles) {
        let env = settings.object("env")
        let saved = ClaudeSettings.saved(in: settings)
        let hasSaved: Bool = if case .platform(platform, _) = saved { true } else { false }
        savedSecrets = []
        if platform == .bedrock { self.profiles = profiles }
        if hasSaved {
            switch platform {
            case .bedrock:
                for (key, secret) in [("AWS_BEARER_TOKEN_BEDROCK", Secret.bedrockKey), ("AWS_SECRET_ACCESS_KEY", .accessSecret)]
                where !(env.string(key) ?? "").isEmpty {
                    savedSecrets.insert(secret.rawValue)
                }
            case .foundry:
                if !(env.string("ANTHROPIC_FOUNDRY_API_KEY") ?? "").isEmpty { savedSecrets.insert(Secret.foundryKey.rawValue) }
            case .vertex: break
            }
        }
        guard !seeded.contains(platform.rawValue) else { return }
        seeded.insert(platform.rawValue)
        let summary = ClaudeSettings.summary(platform, env)
        switch platform {
        case .bedrock:
            if hasSaved {
                bedrock = ClaudeSettings.BedrockCredentials(rawValue: summary.credentials) ?? .environment
                profile = summary.profile
                region = summary.region ?? "us-east-1"
                accessKeyID = env.string("AWS_ACCESS_KEY_ID") ?? ""
                regionEdited = true
            } else {
                bedrock = profiles.names.isEmpty ? .apiKey : .profile
                let wanted = environment["AWS_PROFILE"].flatMap { profiles.names.contains($0) ? $0 : nil }
                profile = wanted ?? (profiles.names.contains("default") ? "default" : profiles.names.first)
                if let region = environment["AWS_REGION"], !region.isEmpty {
                    self.region = region
                    regionEdited = true
                } else {
                    region = profile.flatMap { profiles.regions[$0] } ?? "us-east-1"
                }
            }
        case .vertex:
            if hasSaved {
                vertex = ClaudeSettings.VertexCredentials(rawValue: summary.credentials) ?? .gcloud
                project = summary.project ?? ""
                vertexRegion = summary.region ?? "us-east5"
                keyFile = summary.keyFile
                projectEdited = true
            } else {
                project = environment["ANTHROPIC_VERTEX_PROJECT_ID"] ?? gcloudProject(environment: environment) ?? ""
                projectEdited = !project.isEmpty
                vertexRegion = environment["CLOUD_ML_REGION"].flatMap { $0.isEmpty ? nil : $0 } ?? "us-east5"
            }
        case .foundry:
            resource = summary.resource ?? ""
        }
    }

    /// The profile picked: the region follows it until it's typed.
    mutating func pick(profile name: String) {
        profile = name
        if !regionEdited, let region = profiles.regions[name] { self.region = region }
    }

    /// The key file picked: the project comes from it unless it was typed.
    mutating func pick(keyFile url: URL) {
        keyFile = url.path
        if !projectEdited, let project = vertexProject(keyFile: url) { self.project = project }
    }

    // MARK: Saving

    /// The setup Save writes, or nil while a required field is missing (Save stays off).
    /// `saved`: the current settings' `env`, whose secrets an empty field keeps.
    func setup(_ platform: Platform, secrets: Secrets, saved env: SettingsDocument) -> ClaudeSettings.Setup? {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let kept = { (secret: Secret, typed: String, key: String) -> String? in
            let typed = trim(typed)
            if !typed.isEmpty { return typed }
            return savedSecrets.contains(secret.rawValue) ? env.string(key) : nil
        }
        switch platform {
        case .bedrock:
            let region = trim(region)
            guard !region.isEmpty else { return nil }
            switch bedrock {
            case .profile:
                guard let profile, !profile.isEmpty else { return nil }
                return .bedrock(credentials: .profile, region: region, profile: profile, apiKey: nil, accessKey: nil)
            case .apiKey:
                guard let key = kept(.bedrockKey, secrets.bedrockKey, "AWS_BEARER_TOKEN_BEDROCK") else { return nil }
                return .bedrock(credentials: .apiKey, region: region, profile: nil, apiKey: key, accessKey: nil)
            case .accessKey:
                let id = trim(accessKeyID)
                guard !id.isEmpty, let secret = kept(.accessSecret, secrets.accessSecret, "AWS_SECRET_ACCESS_KEY") else { return nil }
                let token = trim(secrets.accessToken)
                let access = ClaudeSettings.AccessKey(
                    id: id, secret: secret, token: token.isEmpty ? (savedSecrets.contains(Secret.accessSecret.rawValue) ? env.string("AWS_SESSION_TOKEN") : nil) : token)
                return .bedrock(credentials: .accessKey, region: region, profile: nil, apiKey: nil, accessKey: access)
            case .environment:
                return .bedrock(credentials: .environment, region: region, profile: nil, apiKey: nil, accessKey: nil)
            }
        case .vertex:
            let project = trim(project), region = trim(vertexRegion)
            guard !project.isEmpty, !region.isEmpty else { return nil }
            if vertex == .keyFile {
                guard let keyFile, !keyFile.isEmpty else { return nil }
                return .vertex(credentials: .keyFile, project: project, region: region, keyFile: keyFile)
            }
            return .vertex(credentials: vertex, project: project, region: region, keyFile: nil)
        case .foundry:
            guard let resource = ClaudeSettings.foundryResource(resource) else { return nil }
            return .foundry(resource: resource, apiKey: kept(.foundryKey, secrets.foundryKey, "ANTHROPIC_FOUNDRY_API_KEY"))
        }
    }

    /// The footer: where Save puts what's typed. `keyTyped`: Foundry's key field holds one.
    func caption(_ platform: Platform, keyTyped: Bool) -> String {
        switch platform {
        case .bedrock: bedrock == .apiKey || bedrock == .accessKey ? AccountText.savedPlainSecret : AccountText.savedPlain
        case .vertex: AccountText.savedPlain
        case .foundry: keyTyped || savedSecrets.contains(Secret.foundryKey.rawValue) ? AccountText.savedPlainSecret : AccountText.azure
        }
    }

    // MARK: Words

    static func label(_ credentials: ClaudeSettings.BedrockCredentials) -> String {
        switch credentials {
        case .profile: "AWS profile (SSO or named profile)"
        case .apiKey: "Bedrock API key (bearer token)"
        case .accessKey: "Access key + secret"
        case .environment: "Use credentials already in my environment"
        }
    }

    static func short(_ credentials: ClaudeSettings.BedrockCredentials) -> String {
        switch credentials {
        case .profile: "AWS profile"
        case .apiKey: "Bedrock API key"
        case .accessKey: "Access key + secret"
        case .environment: "My environment"
        }
    }

    static func label(_ credentials: ClaudeSettings.VertexCredentials) -> String {
        switch credentials {
        case .gcloud: "Application Default Credentials (gcloud auth)"
        case .keyFile: "Service account key file"
        case .environment: "Use credentials already in my environment"
        }
    }

    static func short(_ credentials: ClaudeSettings.VertexCredentials) -> String {
        switch credentials {
        case .gcloud: "gcloud auth"
        case .keyFile: "Key file"
        case .environment: "My environment"
        }
    }

    /// The form's rows as they read, for a storyline's checks: "Region: us-east-1"; a secret
    /// reads "••••" when it holds something, never what. `filled`: the secret fields with text.
    func lines(_ platform: Platform, filled: Set<String>) -> [String] {
        let secret = { (field: Secret) in
            filled.contains(field.rawValue) ? "••••" : savedSecrets.contains(field.rawValue) ? "Unchanged" : ""
        }
        switch platform {
        case .bedrock:
            var rows = ["Credentials: " + Self.short(bedrock)]
            switch bedrock {
            case .profile: rows.append("Profile: " + (profile ?? "None in ~/.aws/config"))
            case .apiKey: rows.append("API key: " + secret(.bedrockKey))
            case .accessKey: rows += ["Key ID: " + accessKeyID, "Secret: " + secret(.accessSecret), "Token: " + secret(.accessToken)]
            case .environment: break
            }
            return rows + ["Region: " + region]
        case .vertex:
            var rows = ["Credentials: " + Self.short(vertex)]
            if vertex == .keyFile { rows.append("Key file: " + (keyFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No file")) }
            return rows + ["Project: " + project, "Region: " + vertexRegion]
        case .foundry:
            return ["Resource: " + resource, "API key: " + secret(.foundryKey)]
        }
    }
}
