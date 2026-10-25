import AppKit
import Foundation
import KoreCore

/// One way a CLI's login signs in, as data: what the ⌄ menu lists (the CLI's own label, hint
/// and submenu, in its order), what Kore runs for it, and the policies that hide it
/// (account-popup.html §7.6).
package struct SignInMethod: Identifiable, Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        /// The CLI's OAuth in the browser.
        case browserOAuth
        /// A code to enter on a page Kore opens.
        case deviceCode
        /// A key typed into Kore's masked field.
        case secret
        /// Handed to Terminal.
        case terminal
        /// Set up outside the CLI's login: a cloud platform's settings, a refresh script.
        case external
    }

    /// What Kore runs for it.
    package enum Mechanism: Hashable, Sendable {
        /// Claude's `claude_authenticate` control request, with these fields.
        case claudeAuthenticate([String: JSONValue])
        /// Codex's `account/login/start`, with these params.
        case codexLogin(JSONValue)
        /// `claude auth login --sso` over pipes.
        case claudeSSO
        /// Kore's key field: a Keychain item and Claude's `apiKeyHelper`.
        case claudeKey
        /// Kore's key field: Codex's `account/login/start {type: "apiKey"}`.
        case codexKey
        /// Kore's form for a cloud platform, saved into Claude's settings.
        case platform(ClaudeSettings.Platform)
        /// The configured `awsAuthRefresh`, in a login shell in the chat's folder.
        case awsRefresh
        /// `claude` with these arguments, in Terminal.
        case terminal([String])
        /// Nothing Kore runs.
        case none
    }

    /// A submenu: its title and hint.
    package struct Group: Hashable, Sendable {
        package let id: String
        package let title: String
        package let hint: String?
    }

    package let id: String
    package let label: String
    /// The CLI's hint, the menu item's subtitle.
    package let hint: String?
    /// The submenu it's in; nil at the top level.
    package let group: Group?
    package let kind: Kind
    package let mechanism: Mechanism
    /// A separator goes before it.
    package let separated: Bool
    /// The login policies (`forceLoginMethod`, Codex's `forced_login_method`) it shows under:
    /// "" for none set.
    let forced: Set<String>
    /// Providers that admit it (`allowedProviders`); nil: any.
    let providers: [String]?
    /// Listed only when an `awsAuthRefresh` is configured.
    let needsAwsRefresh: Bool

    init(
        id: String, label: String, hint: String? = nil, group: Group? = nil, kind: Kind, mechanism: Mechanism, separated: Bool = false,
        forced: Set<String> = [""], providers: [String]? = nil, needsAwsRefresh: Bool = false
    ) {
        self.id = id
        self.label = label
        self.hint = hint
        self.group = group
        self.kind = kind
        self.mechanism = mechanism
        self.separated = separated
        self.forced = forced
        self.providers = providers
        self.needsAwsRefresh = needsAwsRefresh
    }

    /// Kore can run it.
    package var runs: Bool { mechanism != .none }

    /// It opens a field or a form in the popup rather than starting at once.
    package var opensEditor: Bool {
        switch mechanism {
        case .claudeKey, .codexKey, .platform: true
        default: false
        }
    }

    /// It's a key typed into Kore's field.
    package var isKey: Bool { mechanism == .claudeKey || mechanism == .codexKey }

    /// What it signs in is kept in the login's own folder, so it can make a login of its own:
    /// not Claude's key or platforms, which live in the settings every login shares.
    package var ownsLogin: Bool {
        switch mechanism {
        case .claudeAuthenticate, .codexLogin, .claudeSSO, .codexKey, .terminal: true
        default: false
        }
    }

    /// Its place in the menu: "3rd-party platform/Amazon Bedrock…".
    package var path: String { (group.map { $0.title + "/" } ?? "") + label }

    /// Whether `policy` lets it be listed.
    func allowed(by policy: LoginPolicy) -> Bool {
        guard runs, forced.contains(policy.forcedLoginMethod ?? "") else { return false }
        if needsAwsRefresh, policy.awsAuthRefresh == nil { return false }
        if let providers, let allowed = policy.allowedProviders, !providers.contains(where: allowed.contains) { return false }
        return true
    }
}

/// What a CLI's settings allow: Claude's `forceLoginMethod` and `allowedProviders` (from its
/// status), Codex's `forced_login_method` (from its config), and whether an `awsAuthRefresh` is
/// set. Read from the status reply, where Kore puts what the CLI doesn't report itself.
package struct LoginPolicy: Equatable, Sendable {
    package var forcedLoginMethod: String?
    package var allowedProviders: [String]?
    package var awsAuthRefresh: String?

    package init(forcedLoginMethod: String? = nil, allowedProviders: [String]? = nil, awsAuthRefresh: String? = nil) {
        self.forcedLoginMethod = forcedLoginMethod
        self.allowedProviders = allowedProviders
        self.awsAuthRefresh = awsAuthRefresh
    }

    package init(_ status: JSONValue) {
        forcedLoginMethod = status["forcedLoginMethod"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        allowedProviders = status["allowedProviders"]?.array?.compactMap(\.string)
        awsAuthRefresh = status["awsAuthRefresh"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The ⌄ menu as drawn: top-level items and submenus, each leaf a method.
package struct MethodMenuItem: Equatable, Sendable {
    package let title: String
    package let hint: String?
    /// A leaf's method; nil for a submenu.
    package let method: SignInMethod?
    package let children: [MethodMenuItem]
    package let separated: Bool
    package var checked: Bool

    /// The methods `policy` lists, in order, as items: a submenu left with one item becomes that
    /// item at the top level, and a separator first in its menu goes.
    package static func build(_ methods: [SignInMethod], policy: LoginPolicy, current: String?) -> [MethodMenuItem] {
        let shown = methods.filter { $0.allowed(by: policy) }
        var items: [MethodMenuItem] = []
        var index = 0
        while index < shown.count {
            let method = shown[index]
            guard let group = method.group else {
                items.append(leaf(method, current: current, first: items.isEmpty))
                index += 1
                continue
            }
            var members: [SignInMethod] = []
            while index < shown.count, shown[index].group == group {
                members.append(shown[index])
                index += 1
            }
            if members.count == 1 {
                items.append(leaf(members[0], current: current, first: items.isEmpty))
            } else {
                let children = members.enumerated().map { leaf($1, current: current, first: $0 == 0) }
                items.append(
                    MethodMenuItem(
                        title: group.title, hint: group.hint, method: nil, children: children, separated: false,
                        checked: children.contains(where: \.checked)))
            }
        }
        return items
    }

    private static func leaf(_ method: SignInMethod, current: String?, first: Bool) -> MethodMenuItem {
        MethodMenuItem(
            title: method.label, hint: method.hint, method: method, children: [], separated: method.separated && !first,
            checked: method.id == current)
    }

    /// Every leaf, in menu order.
    package static func leaves(_ items: [MethodMenuItem]) -> [MethodMenuItem] {
        items.flatMap { $0.method == nil ? $0.children : [$0] }
    }

    /// Every leaf with its place as drawn: "3rd-party platform/Amazon Bedrock…", or its title
    /// alone at the top level (a submenu of one comes up a level).
    package static func paths(_ items: [MethodMenuItem]) -> [(path: String, item: MethodMenuItem)] {
        items.flatMap { item in
            item.method == nil ? item.children.map { (item.title + "/" + $0.title, $0) } : [(item.title, item)]
        }
    }
}

/// Who a CLI is signed in as, in Kore's words.
package struct AccountIdentity: Equatable, Sendable {
    package var email: String?
    /// "Claude Max", "ChatGPT Pro Lite", "Claude Console".
    package var plan: String?
    package var organization: String?
    /// How it signed in, for the caption: "Claude.ai", "Console", "ChatGPT", "API key helper";
    /// for a platform, its details ("us-east-1 · profile dev").
    package var method: String
    /// Kore can switch it or sign it out; false for a login set outside the CLI's own (the
    /// env, an API key helper, a cloud platform, managed settings) that Kore didn't set.
    package var changeable: Bool
    /// The menu method it came from, for the ⌄ menu's ✓; nil when none.
    package var methodID: String?
    /// The cloud platform it runs through ("Amazon Bedrock"), the header without an email.
    package var platform: String?

    package init(
        email: String? = nil, plan: String? = nil, organization: String? = nil, method: String, changeable: Bool, methodID: String? = nil,
        platform: String? = nil
    ) {
        self.email = email
        self.plan = plan
        self.organization = organization
        self.method = method
        self.changeable = changeable
        self.methodID = methodID
        self.platform = platform
    }

    /// What tells two logins of one email apart: the organisation, else the plan (Codex's
    /// workspaces have no organisation); "" for neither.
    var workspace: String { organization ?? plan ?? "" }

    /// The same person and organisation: a switch that lands here changed nothing.
    func isSameAccount(as other: AccountIdentity) -> Bool {
        email?.lowercased() == other.email?.lowercased() && organization == other.organization && method == other.method
            && platform == other.platform
    }

    /// Kore set it up in Claude's settings (a platform or its key): signing out removes that.
    var isKoreSetting: Bool {
        guard changeable, let methodID else { return false }
        return methodID == "claudeKey" || ClaudeSettings.Platform(rawValue: methodID) != nil
    }
}

/// What a status read says.
package enum AccountReading: Equatable, Sendable {
    case signedIn(AccountIdentity)
    case signedOut
}

/// A sign-in under way in the CLI: the page (and, for a device code, the code), its end and a
/// way to stop it. `wait` answers the CLI's status reply when it has one (Codex's
/// `account/read`), else nil, and Kore reads the status itself. A Terminal hand-off has no page,
/// and ends when the account changes.
package struct SignInHandle: Sendable {
    package let url: URL?
    package let code: String?
    /// The CLI opens the page itself (Claude's SSO); Kore need not open it again at launch.
    package let opensItself: Bool
    /// An explicit browser-login fallback, never a saved credential.
    package let manualURL: URL?
    package let submit: (@Sendable (String) async throws -> Void)?
    package let wait: @Sendable () async throws -> JSONValue?
    package let cancel: @Sendable () async -> Void

    package init(
        url: URL?, code: String? = nil, opensItself: Bool = false, wait: @escaping @Sendable () async throws -> JSONValue?,
        cancel: @escaping @Sendable () async -> Void,
        manualURL: URL? = nil, submit: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.url = url
        self.code = code
        self.opensItself = opensItself
        self.manualURL = manualURL
        self.submit = submit
        self.wait = wait
        self.cancel = cancel
    }
}

/// Where a sign-in runs: the chat's folder (a refresh script, a Terminal hand-off).
package struct SignInContext: Sendable {
    package let folder: URL

    package init(folder: URL) { self.folder = folder }
}

/// What Kore asks a CLI about its login: the status, a sign-in, a typed key, a sign-out. The
/// real CLIs' are in each descriptor; a storyline host swaps in scripted ones
/// (`StorylineSeams.accounts`).
package struct AccountCalls: Sendable {
    package var status: @Sendable () async throws -> JSONValue
    package var signIn: @Sendable (SignInMethod.Mechanism, SignInContext) async throws -> SignInHandle
    /// A typed key, sent once: the CLI's status reply after it, if it gives one.
    package var useKey: @Sendable (String) async throws -> JSONValue?
    package var signOut: @Sendable () async throws -> Void

    package init(
        status: @escaping @Sendable () async throws -> JSONValue,
        signIn: @escaping @Sendable (SignInMethod.Mechanism, SignInContext) async throws -> SignInHandle,
        useKey: @escaping @Sendable (String) async throws -> JSONValue?,
        signOut: @escaping @Sendable () async throws -> Void
    ) {
        self.status = status
        self.signIn = signIn
        self.useKey = useKey
        self.signOut = signOut
    }
}

/// One CLI's login, for the Account popup: its methods, how its status reads, and the file it
/// keeps its login in under an environment (watched for changes made outside Kore).
struct AccountOps: Sendable {
    let methods: [SignInMethod]
    let parse: @Sendable (JSONValue) -> AccountReading
    let calls: AccountCalls
    let loginFile: @Sendable ([String: String]) -> URL
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

extension SignInMethod {
    static let claudeConsole = Group(id: "console", title: "Anthropic Console account", hint: "API usage billing")
    static let claudePlatforms = Group(id: "platform", title: "3rd-party platform", hint: nil)

    /// Claude Code's `/login`, in its order (login309.js): subscription, SSO, Console ▸, 3rd-party
    /// platform ▸, and the Cloud gateway that only a policy shows.
    static let claude: [SignInMethod] = [
        SignInMethod(
            id: "claudeai", label: "Claude account with subscription", hint: "Pro, Max, Team, or Enterprise", kind: .browserOAuth,
            mechanism: .claudeAuthenticate(["loginWithClaudeAi": true]), forced: ["", "claudeai"], providers: ["firstParty"]),
        SignInMethod(
            id: "sso", label: "Claude account with SSO", kind: .browserOAuth, mechanism: .claudeSSO, forced: ["", "claudeai"],
            providers: ["firstParty"]),
        SignInMethod(
            id: "consoleTerminal", label: "Sign in with your Console account (recommended)", hint: "Opens Terminal", group: claudeConsole,
            kind: .terminal, mechanism: .terminal(["/login"]), forced: ["", "console"], providers: ["firstParty"]),
        SignInMethod(
            id: "console", label: "Create an API key (legacy)", hint: "Adds a key to your Console workspace", group: claudeConsole,
            kind: .browserOAuth, mechanism: .claudeAuthenticate(["loginWithClaudeAi": false]), forced: ["", "console"],
            providers: ["firstParty"]),
        SignInMethod(
            id: "claudeKey", label: "Use an API key…", hint: "Stored in your Keychain", group: claudeConsole, kind: .secret,
            mechanism: .claudeKey, separated: true, forced: ["", "console"], providers: ["firstParty"]),
        SignInMethod(
            id: "bedrock", label: "Amazon Bedrock…", group: claudePlatforms, kind: .external, mechanism: .platform(.bedrock),
            providers: ["bedrock"]),
        SignInMethod(
            id: "awsRefresh", label: "Claude Platform on AWS", hint: "Refresh credentials", group: claudePlatforms, kind: .external,
            mechanism: .awsRefresh, providers: ["anthropicAws", "bedrock", "mantle"], needsAwsRefresh: true),
        SignInMethod(
            id: "foundry", label: "Microsoft Foundry…", group: claudePlatforms, kind: .external, mechanism: .platform(.foundry),
            providers: ["foundry"]),
        SignInMethod(
            id: "vertex", label: "Google Vertex AI…", group: claudePlatforms, kind: .external, mechanism: .platform(.vertex),
            providers: ["vertex"]),
        SignInMethod(
            id: "gateway", label: "Cloud gateway", hint: "Opens Terminal", kind: .terminal, mechanism: .terminal(["/login"]),
            forced: ["gateway"]),
    ]

    /// Codex's login (its onboarding's order); Amazon Bedrock stays out until Codex ships it.
    static let codex: [SignInMethod] = [
        SignInMethod(
            id: "chatgpt", label: "Sign in with ChatGPT", hint: "Usage included with Plus, Pro, Business, and Enterprise plans",
            kind: .browserOAuth, mechanism: .codexLogin(["type": "chatgpt"]), forced: ["", "chatgpt"]),
        SignInMethod(
            id: "chatgptDeviceCode", label: "Sign in with Device Code", hint: "Sign in from another device with a one-time code",
            kind: .deviceCode, mechanism: .codexLogin(["type": "chatgptDeviceCode"]), forced: ["", "chatgpt"]),
        SignInMethod(
            id: "apiKey", label: "Provide your own API key…", hint: "Pay for what you use", kind: .secret, mechanism: .codexKey,
            forced: ["", "api"]),
    ]
}

extension AccountOps {
    static let claude = AccountOps(
        methods: SignInMethod.claude,
        parse: { AccountText.claude(ClaudeAuth.Status($0), settings: ClaudeSettingsStore.read()) },
        calls: AccountCalls(
            status: {
                // The CLI doesn't report an `awsAuthRefresh`; Kore adds what the settings say.
                var reply = try await ClaudeAuth.statusReply()
                if case .object(var fields) = reply,
                    let command = ClaudeSettings.awsAuthRefresh(files: [ClaudeSettings.managedFile, ClaudeSettings.userFile()])
                {
                    fields["awsAuthRefresh"] = .string(command)
                    reply = .object(fields)
                }
                return reply
            },
            signIn: { mechanism, context in try await ClaudeSignIn.start(mechanism, context) },
            useKey: { key in
                try ClaudeSettingsStore.saveKey(key)
                return nil
            },
            signOut: { try await ClaudeAuth.logout() }),
        loginFile: { ClaudeAuth.configFile(environment: $0) },
        stamp: { ClaudeAuth.accountStamp($0) })
}

/// Claude's sign-ins by mechanism.
enum ClaudeSignIn {
    static func start(_ mechanism: SignInMethod.Mechanism, _ context: SignInContext) async throws -> SignInHandle {
        switch mechanism {
        case .claudeAuthenticate(let fields):
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
                    cancel: { await login.cancel() }, manualURL: await login.manualURL, submit: { try await login.submit($0) })
            } catch {
                await login.cancel()
                throw error
            }
        case .claudeSSO:
            let (login, url) = try await ClaudeAuth.SSOLogin.start()
            return SignInHandle(
                url: url, opensItself: true,
                wait: {
                    try await login.wait()
                    return JSONValue?.none
                },
                cancel: { login.cancel() }, manualURL: url, submit: { try login.submit($0) })
        case .terminal(let arguments):
            let claude = try await CLIExecutable.resolve("claude").url.path
            let file = try TerminalLogin.write(claude: claude, arguments: arguments, folder: context.folder)
            // The login's own file (an added login's, while it's being added), so its end is
            // seen without a watch on it.
            let landing = TerminalLogin.Landing(file: ClaudeAuth.configFile())
            await MainActor.run { _ = NSWorkspace.shared.open(file) }
            return SignInHandle(
                url: nil,
                wait: {
                    try await landing.wait()
                    return JSONValue?.none
                },
                cancel: { landing.stop() })
        case .awsRefresh:
            let files = [ClaudeSettings.managedFile, ClaudeSettings.userFile()]
            guard let command = ClaudeSettings.awsAuthRefresh(files: files) else { throw AccountUnavailable() }
            let run = try ShellRun(command, in: context.folder)
            return SignInHandle(
                url: nil,
                wait: {
                    try await run.wait()
                    return JSONValue?.none
                },
                cancel: { run.cancel() })
        default:
            throw AccountUnavailable()
        }
    }
}

/// Claude's user settings as Kore reads and writes them, and Kore's Keychain item.
package enum ClaudeSettingsStore {
    package static func read() -> SettingsDocument { (try? SettingsFile.read(ClaudeSettings.userFile())) ?? SettingsDocument() }

    /// Applies `change` to the settings file; throws "Claude's settings.json isn't valid JSON."
    /// without writing when it isn't.
    static func change(_ change: (SettingsDocument) -> SettingsDocument) throws {
        let file = ClaudeSettings.userFile()
        let document: SettingsDocument
        do { document = try SettingsFile.read(file) } catch { throw NotJSON() }
        try SettingsFile.write(change(document), to: file)
    }

    /// The key in the Keychain, then Claude's helper reading it.
    package static func saveKey(_ key: String) throws {
        do { try Keychain.store.value.set(key, service: ClaudeSettings.keyService) } catch let failure as Keychain.Failure {
            throw KeychainFailed(words: failure.words)
        }
        try change(ClaudeSettings.savingKey(in:))
    }

    /// Kore's key out: the helper (only Kore's own) and the item.
    static func removeKey() throws {
        try change(ClaudeSettings.removingKey(from:))
        try? Keychain.store.value.remove(service: ClaudeSettings.keyService)
    }

    struct NotJSON: LocalizedError {
        var errorDescription: String? { "Claude's settings.json isn't valid JSON." }
    }

    struct KeychainFailed: LocalizedError {
        let words: String
        var errorDescription: String? { "Kore couldn't save to your Keychain (\(words))" }
    }
}

// MARK: - Codex

extension AccountOps {
    static let codex = AccountOps(
        methods: SignInMethod.codex,
        parse: { AccountText.codex(CodexAuth.Status($0)) },
        calls: AccountCalls(
            status: {
                // `forced_login_method` is in Codex's config, not its answer: Kore adds it.
                var reply = try await CodexAuth.statusReply()
                if case .object(var fields) = reply, let forced = CodexAuth.forcedLoginMethod(files: CodexAuth.configFiles()) {
                    fields["forcedLoginMethod"] = .string(forced)
                    reply = .object(fields)
                }
                return reply
            },
            signIn: { mechanism, _ in
                guard case .codexLogin(let params) = mechanism else { throw AccountUnavailable() }
                let login = try await CodexAuth.Login.start()
                do {
                    let prompt = try await login.begin(params)
                    let submit: (@Sendable (String) async throws -> Void)?
                    if prompt.userCode == nil { submit = { try await login.submit($0) } } else { submit = nil }
                    return SignInHandle(
                        url: prompt.url, code: prompt.userCode,
                        wait: {
                            defer { Task { await login.close() } }
                            return try await login.wait()
                        },
                        cancel: { await login.cancel() }, submit: submit)
                } catch {
                    await login.close()
                    throw error
                }
            },
            useKey: { key in try await CodexAuth.signIn(apiKey: key) },
            signOut: { try await CodexAuth.logout() }),
        loginFile: { CodexAuth.authFile(environment: $0) },
        stamp: nil)
}

struct AccountUnavailable: LocalizedError {
    var errorDescription: String? { "Kore can't run this sign-in" }
}

// MARK: - Wording

/// The Account popup's words, and each CLI's status in them.
enum AccountText {
    /// `claude auth status --json`, as an identity; `settings` (Claude's user settings) says
    /// which platform or key Kore set up, its details, and so whether Kore can change it.
    static func claude(_ status: ClaudeAuth.Status, settings: SettingsDocument = SettingsDocument()) -> AccountReading {
        guard status.loggedIn else { return .signedOut }
        let org = status.orgName.flatMap { $0.isEmpty ? nil : $0 }
        let email = status.email.flatMap { $0.isEmpty ? nil : $0 }
        let plan = PlanReading.claudePlan(status.subscriptionType)
        let saved = ClaudeSettings.saved(in: settings)
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
        case "api_key_helper" where saved == .key:
            return .signedIn(AccountIdentity(email: email, plan: "Claude Console", method: "Keychain", changeable: true, methodID: "claudeKey"))
        case "api_key_helper":
            return .signedIn(AccountIdentity(email: email, plan: "Claude Console", method: "API key helper", changeable: false))
        case "third_party":
            let name = platform(status.apiProvider)
            if case .platform(let platform, let summary) = saved, platform.provider == status.apiProvider {
                return .signedIn(
                    AccountIdentity(
                        email: email, method: summary.caption(platform), changeable: true, methodID: platform.rawValue, platform: name))
            }
            return .signedIn(AccountIdentity(email: email, method: "Set in Claude's settings", changeable: false, platform: name))
        default:
            return .signedIn(AccountIdentity(email: email, plan: plan, organization: org, method: "Managed settings", changeable: false))
        }
    }

    /// A cloud platform Claude Code runs through, by name.
    static func platform(_ provider: String?) -> String {
        if let platform = ClaudeSettings.Platform(provider: provider) { return platform.name }
        switch provider {
        case "anthropicAws": return "Claude Platform on AWS"
        case "anthropicGoogleCloud": return "Anthropic on Google Cloud"
        case "gateway": return "Gateway"
        case let other?: return other.prefix(1).uppercased() + other.dropFirst()
        case nil: return "Cloud platform"
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

    /// The header: the email, else the platform's name, else "API key".
    static func header(_ identity: AccountIdentity) -> String { identity.email ?? identity.platform ?? "API key" }

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
    static func saveFailed(_ reason: String?) -> String { reason.map { "Couldn't save: \($0)" } ?? "Couldn't save." }
    static func refreshFailed(_ reason: String?) -> String { reason.map { "Couldn't refresh: \($0)" } ?? "Couldn't refresh." }
    static let cantChange = "Set outside Kore, so Kore can't change it."
    static let starting = "Starting sign-in…"
    static let browser = "Waiting for the browser…"
    static let terminal = "Finish in Terminal…"
    static let refreshing = "Refreshing AWS credentials…"
    static let refreshed = "Refreshed."
    static let signingIn = "Signing in…"
    static let signingOut = "Signing out…"
    static let saving = "Saving…"
    static let saved = "Saved."
    static let signedIn = "Signed in."
    static let switched = "Switched accounts."
    static let same = "Still the same account."
    static let sameHelp = "The browser continued as the same account. Pick another on the sign-in page, then try again."
    static let timedOut = "Sign-in timed out."
    static let duplicate = "Duplicate"
    static let removeDuplicate = "Remove duplicate"
    static let remove = "Remove"
    static let loginSignedOut = "Signed out"
    static let deviceHelp = "Enter the code at auth.openai.com/codex/device"
    static func signedOutOf(_ name: String) -> String { "Signed out of \(name)." }

    /// Under a Terminal hand-off: what to do there.
    static func terminalCaption(_ method: String?) -> String {
        method == "gateway" ? "Sign in to your Cloud gateway there." : "Pick Console account, then Sign in with your Console account."
    }

    /// Under the key field: where the key goes; its prompt.
    static func keyCaption(_ provider: String) -> String { provider == "codex" ? "Stored by Codex." : "Stored in your Keychain." }
    static func keyPrompt(_ provider: String) -> String { provider == "codex" ? "OpenAI API key" : "Anthropic API key" }

    static func askSignOut(_ product: String) -> String { "Sign out of \(product)?" }

    /// The question's caption: always the reach of a sign-out, and the chats it stops. A setting
    /// Kore made reaches every client that reads Claude's settings.
    static func signOutCaption(working: Int, setting: Bool = false) -> String {
        let reach = setting ? "Removes it from Claude's settings everywhere." : "Also signs out Terminal and VS Code on this Mac."
        return [reach, switchCaption(working: working)].compactMap { $0 }.joined(separator: " ")
    }

    /// A switch's caption (a sign-in over the account, a login picked): the chats it stops;
    /// nil when none work.
    static func switchCaption(working: Int) -> String? {
        working > 0 ? "Stops \(working) working chat\(working == 1 ? "" : "s")." : nil
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

    static let savedPlain = "Saved to Claude's settings."
    static let savedPlainSecret = "Saved to Claude's settings, in plain text."
    static let azure = "Uses your Azure sign-in (az login)."
}
