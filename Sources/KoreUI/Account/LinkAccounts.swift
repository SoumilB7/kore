import Foundation
import src

// What the local link (the KoreLink module) may read and do with a CLI's account under full control
// (link 1.2): each is the Account popup's own action. A sign-in the link starts opens nothing on
// the Mac and shows the link only a page that hands back a code (Claude's manual page) or a
// device code (Codex). Keys and tokens never cross: there is no key path at all.

extension AccountStore {
    package struct LinkLogin: Equatable {
        /// "main" for main.
        package var id: String
        package var email: String?
        package var workspace: String?
        package var active: Bool
        package var signedOut: Bool
        package var duplicate: Bool
    }

    package struct LinkMethod: Equatable {
        package var id: String
        package var label: String
        package var hint: String?
        package var group: String?
        /// browserOAuth, deviceCode, secret, terminal, external.
        package var kind: String
        /// The link can finish it ("link"), or only the Mac can ("mac").
        package var onLink: Bool
    }

    package struct LinkFlow: Equatable {
        package var serial: Int
        package var method: String?
        package var startedByLink: Bool
        package var switching: Bool
        /// starting, page, code, refreshing, signingIn, signingOut, signedIn, switched, same, failed, timedOut.
        package var step: String
        package var url: String?
        package var code: String?
        package var takesPaste: Bool
        package var error: String?
    }

    package struct LinkAccount: Equatable {
        /// signedIn, signedOut, unknown, unreadable.
        package var status: String
        package var email: String?
        package var plan: String?
        package var workspace: String?
        package var method: String?
        package var privacy: Bool
        package var logins: [LinkLogin]
        package var methods: [LinkMethod]
        package var workingChats: Int
        package var flow: LinkFlow?
    }

    /// The account as the link sees it. Emails are masked while privacy mode is on.
    package func linkAccount(_ provider: String) -> LinkAccount {
        let privacy = AccountPrivacy.shared.on
        let shown: (String?) -> String? = { $0.map { privacy ? AccountPrivacy.mask($0) : $0 } }
        var account = LinkAccount(
            status: "unknown", privacy: privacy,
            logins: logins(provider).map {
                LinkLogin(
                    id: Self.loginKey($0.id), email: shown($0.email), workspace: $0.workspace, active: $0.active, signedOut: $0.signedOut,
                    duplicate: $0.duplicate)
            },
            methods: methods(provider).filter { $0.runs }.map {
                LinkMethod(
                    id: $0.id, label: $0.label, hint: $0.hint, group: $0.group?.title, kind: Self.linkKind($0.kind),
                    onLink: Self.linkFinishes($0))
            },
            workingChats: workingChats(provider), flow: linkFlow(provider))
        switch status(provider) {
        case .signedIn(let identity):
            account.status = "signedIn"
            account.email = shown(identity.email)
            account.plan = identity.plan
            account.workspace = identity.organization
            account.method = identity.method
        case .signedOut: account.status = "signedOut"
        case .unreadable: account.status = "unreadable"
        case .unknown: break
        }
        return account
    }

    /// A method the link can see through to the end without the Mac: Claude's sign-in with its
    /// manual code page, a device code, or the configured refresh script. The rest (SSO, a
    /// browser callback, Terminal, a typed key, a platform form) need the Mac.
    static func linkFinishes(_ method: SignInMethod) -> Bool {
        switch method.mechanism {
        case .claudeAuthenticate, .awsRefresh: true
        case .codexLogin: method.kind == .deviceCode
        default: false
        }
    }

    private static func linkKind(_ kind: SignInMethod.Kind) -> String {
        switch kind {
        case .browserOAuth: "browserOAuth"
        case .deviceCode: "deviceCode"
        case .secret: "secret"
        case .terminal: "terminal"
        case .external: "external"
        }
    }

    /// The flow under way. One the Mac started shows only its step; one the link started also
    /// shows its page (never a callback on this Mac) and code.
    private func linkFlow(_ provider: String) -> LinkFlow? {
        guard let flow = flow(provider) else { return nil }
        let serial = signInSerial(provider)
        let byLink = linkStarted[provider] == serial
        var out = LinkFlow(
            serial: serial, method: flow.method, startedByLink: byLink, switching: flow.switching, step: "starting", takesPaste: false)
        switch flow.step {
        case .starting: out.step = "starting"
        case .browser:
            out.step = "page"
            if byLink, let manual = manualSignInURL(provider) {
                out.url = manual.absoluteString
                out.takesPaste = acceptsSignInInput(provider)
            }
        case .code(let code, let url):
            out.step = "code"
            if byLink {
                out.url = url.absoluteString
                out.code = code
            }
        case .terminal: out.step = "starting"
        case .refreshing: out.step = "refreshing"
        case .signingIn: out.step = "signingIn"
        case .signingOut: out.step = "signingOut"
        case .signedIn, .refreshed, .saved, .signedOutOf: out.step = "signedIn"
        case .switched: out.step = "switched"
        case .same: out.step = "same"
        case .failed(let why), .keyFailed(let why), .refreshFailed(let why), .signOutFailed(let why):
            out.step = "failed"
            out.error = why
        case .timedOut: out.step = "timedOut"
        }
        return out
    }

    package enum LinkAim: Equatable {
        case active
        case new
        /// "main" or an added login's id.
        case login(String)
    }

    package enum LinkOutcome: Equatable {
        case ok
        /// A sign-in, switch or sign-out is under way for that CLI.
        case busy
        /// That method needs the Mac.
        case mac
        case goneLogin
        case goneFlow
        case staleFlow
        case invalid(String)
        case failed(String)
    }

    private var linkFolder: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Starts a sign-in the link can finish, opening nothing on the Mac.
    package func linkSignIn(_ provider: String, method id: String?, aim: LinkAim) -> LinkOutcome {
        if flow(provider)?.step.live == true { return .busy }
        let runnable = methods(provider)
        guard let method = id.map({ id in runnable.first { $0.id == id } }) ?? currentMethod(provider) else {
            return .invalid("This CLI doesn't offer that sign-in.")
        }
        guard Self.linkFinishes(method) else { return .mac }
        switch aim {
        case .new:
            guard method.ownsLogin else { return .invalid("That sign-in can't add a login of its own.") }
            addLogin(provider, method: method, in: linkFolder, quiet: true)
        case .active:
            signIn(provider, method: method, in: linkFolder, quiet: true)
        case .login(let key):
            guard let login = logins(provider).first(where: { Self.loginKey($0.id) == key }) else { return .goneLogin }
            signIn(provider, method: method, in: linkFolder, aim: login.active ? .active : .login(login.id), quiet: true)
        }
        return flow(provider)?.step.live == true ? .ok : .failed("The sign-in didn't start.")
    }

    /// The code from the manual page, for a sign-in the link started.
    package func linkSubmit(_ provider: String, serial: Int, input: String) async -> LinkOutcome {
        guard flow(provider) != nil else { return .goneFlow }
        guard signInSerial(provider) == serial, linkStarted[provider] == serial else { return .staleFlow }
        guard acceptsSignInInput(provider) else { return .staleFlow }
        do {
            try await submitSignIn(input, provider: provider, serial: serial)
            return .ok
        } catch {
            return .failed("The CLI didn't take that code.")
        }
    }

    package func linkCancel(_ provider: String) -> LinkOutcome {
        guard let flow = flow(provider) else { return .goneFlow }
        guard flow.step.cancellable else { return .busy }
        cancel(provider)
        return .ok
    }

    /// Every chat of the CLI moves to that login, as a hand pick in the popup does.
    package func linkSwitch(_ provider: String, to key: String) -> LinkOutcome {
        if flow(provider)?.step.live == true { return .busy }
        guard let login = logins(provider).first(where: { Self.loginKey($0.id) == key }) else { return .goneLogin }
        if login.active { return .ok }
        switchLogin(provider, to: login.id, LoginPick.byHandOnLink())
        return .ok
    }

    package func linkRemove(_ provider: String, _ key: String) -> LinkOutcome {
        guard let login = logins(provider).first(where: { Self.loginKey($0.id) == key }), let id = login.id else { return .goneLogin }
        guard !login.active else { return .invalid("The login in use can't be removed; switch first.") }
        removeLogin(provider, id)
        return .ok
    }

    package func linkSignOut(_ provider: String) -> LinkOutcome {
        if flow(provider)?.step.live == true { return .busy }
        guard case .signedIn = status(provider) else { return .invalid("It isn't signed in.") }
        signOut(provider)
        return .ok
    }

    package static func linkSetPrivacy(_ on: Bool) { AccountPrivacy.shared.on = on }
}
