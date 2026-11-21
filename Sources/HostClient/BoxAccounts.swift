import Foundation
import KoreCore
import LinkProtocol
import Observation

/// Logins on the box: each CLI's, through the link's account commands, and GitHub's (`auth.gh`).
/// The box runs the login without a browser; the Mac shows the page and any code, the owner
/// approves in the Mac's browser, and the token stays on the box.
@MainActor @Observable
package final class BoxAccounts {
    package enum Step: Equatable, Sendable {
        case idle
        case starting
        /// The page to open (and the code to enter there, or to paste back from it).
        case waiting(HostWire.Page)
        case submitting(HostWire.Page)
        case failed(String)
    }

    package struct Line: Equatable, Sendable {
        /// What the box last said of the login ("Signed in as …", "… isn't signed in.").
        package var said: String?
        /// Signed in, as the box said it; nil until it says.
        package var signedIn: Bool?
        package var step = Step.idle

        package init(said: String? = nil, signedIn: Bool? = nil, step: Step = .idle) {
            self.said = said
            self.signedIn = signedIn
            self.step = step
        }
    }

    /// GitHub's line, beside the CLIs'.
    package static let gitHub = "gh"

    /// The box's Claude accounts as last listed (`account.list`, Claude only: Codex keeps one
    /// login on a box), the account each chat runs on as last said, and each folder's default.
    package private(set) var claude: [LinkAccount] = []
    package private(set) var chatLogins: [String: String] = [:]
    package private(set) var folderLogins: [String: String] = [:]
    /// The chat whose Account popup shows the accounts (nil: a chat not made on the box yet), and
    /// its folder there: a status read is that chat's account's.
    package var viewing: (chatId: String?, folder: String?) = (nil, nil)

    /// The account the chat shown runs on, as last said: "main" until the box says otherwise.
    package var viewedLogin: String { viewing.chatId.flatMap { chatLogins[$0] } ?? viewing.folder.flatMap { folderLogins[$0] } ?? LinkAccount.main }

    /// Reads the list again (one `claude auth status` per account on the box). False when the box
    /// refused or doesn't know the command (a box before this one): its one login stands.
    @discardableResult
    package func listClaude() async -> Bool {
        let (chatId, folder) = viewing
        let result = await connection.command { HostWire.accountList(id: $0, provider: "claude", chatId: chatId, folder: folder) }
        guard result.ok, let accounts = result.accounts else { return false }
        claude = accounts
        if let chatId, let login = result.login { chatLogins[chatId] = login }
        if let folder, let login = result.folderLogin { folderLogins[folder] = login }
        return true
    }

    /// The shown chat runs on `login` from now on (and its folder's new chats start on it): the
    /// box stops its work and starts its CLI again on its session. The box's reason when it refused.
    package func switchClaude(to login: String) async -> String? {
        let (chatId, folder) = viewing
        let result = await connection.command {
            HostWire.accountSwitch(id: $0, provider: "claude", login: login, chatId: chatId, folder: chatId == nil ? folder : nil)
        }
        guard result.ok else { return result.message ?? "Couldn't switch on \(NodeNames.name(alias))" }
        if let chatId { chatLogins[chatId] = result.login ?? login }
        if let folder { folderLogins[folder] = result.folderLogin ?? login }
        return nil
    }

    /// One account's plan and limits, read on the box.
    package func claudeUsage(_ login: String) async throws -> PlanReading {
        let result = await connection.command { HostWire.accountUsage(id: $0, provider: "claude", login: login) }
        guard result.ok, let reading = result.reading else {
            throw HostRefusal(message: result.message ?? "Couldn't read usage on \(NodeNames.name(alias))")
        }
        return reading
    }

    package private(set) var lines: [String: Line] = [:]
    @ObservationIgnored private unowned let connection: HostConnection

    init(connection: HostConnection) { self.connection = connection }

    package func line(_ key: String) -> Line {
        var line = lines[key] ?? Line()
        if key == Self.gitHub, let on = connection.ghSignedIn {
            line.said = on ? "Signed in" : "Not signed in"
            line.signedIn = on
            // Signed in while the page was up: done.
            if on, case .waiting = line.step { line.step = .idle }
        }
        return line
    }

    private func set(_ key: String, _ change: (inout Line) -> Void) {
        var line = lines[key] ?? Line()
        change(&line)
        lines[key] = line
    }

    private var alias: String { connection.alias }

    /// Who the CLI on the box is signed in as.
    package func refresh(_ provider: String) async {
        let result = await connection.command { HostWire.refresh(id: $0, provider: provider) }
        if result.ok, let email = result.account?.email {
            let box = alias
            Task { await KoreUsage.shared.boxLogin(box: box, cli: provider, email: email) }
        }
        set(provider) {
            $0.said = result.message ?? (result.ok ? nil : "Couldn't read the login on \(NodeNames.name(alias))")
            $0.signedIn = result.signedIn
        }
    }

    package func signIn(_ provider: String) {
        Task { _ = await signInToEnd(provider) }
    }

    /// The CLI's own sign-in on the box, to its end: its page (`open`, once, as it's known: a
    /// Mac's Move of a Claude login opens it here), the code pasted in the box's line, then what
    /// the box says. Nil when it signed in; else why not.
    /// `login`: Claude's sign-in goes to the box's added account of that name, never its default.
    package func signInToEnd(_ provider: String, login: String? = nil, open: (@MainActor (URL) -> Void)? = nil) async -> String? {
        let failed = "Couldn't sign in on \(NodeNames.name(alias))"
        guard !busy(provider) else { return "It's already signing in on \(NodeNames.name(alias))" }
        set(provider) { $0.step = .starting }
        let result = await connection.command { HostWire.signIn(id: $0, provider: provider, login: login) }
        guard result.ok else {
            set(provider) { $0.step = .failed(result.message ?? failed) }
            return result.message ?? failed
        }
        let page = HostWire.page(result.message)
        set(provider) { $0.step = .waiting(page) }
        if let url = page.url { open?(url) }
        let done = await connection.later(result.id + HostWire.doneSuffix)
        set(provider) {
            $0.said = done.message ?? $0.said
            $0.signedIn = done.signedIn ?? $0.signedIn
            $0.step = done.ok ? .idle : .failed(done.message ?? failed)
        }
        return done.ok ? nil : done.message ?? failed
    }

    /// The code the page showed, pasted back (Claude's login).
    package func submit(_ provider: String, code: String) {
        guard case .waiting(let page) = line(provider).step, !code.isEmpty else { return }
        set(provider) { $0.step = .submitting(page) }
        Task {
            let result = await connection.command { HostWire.submit(id: $0, provider: provider, input: code) }
            // On success the sign-in's end follows; a refused code leaves the page up to try again.
            if !result.ok { set(provider) { $0.step = .waiting(page) } }
        }
    }

    package func cancel(_ provider: String) {
        set(provider) { $0.step = .idle }
        guard provider != Self.gitHub else { return }
        Task { _ = await connection.command { HostWire.cancelSignIn(id: $0, provider: provider) } }
    }

    /// GitHub's CLI on the box: a device code to enter on GitHub's page; the box says when it's in.
    package func signInGitHub() {
        guard !busy(Self.gitHub) else { return }
        set(Self.gitHub) { $0.step = .starting }
        Task {
            let (result, raw) = await connection.commandRaw { HostWire.gitHub(id: $0) }
            guard result.ok, let page = HostWire.gitHubPage(raw) else {
                set(Self.gitHub) { $0.step = .failed(result.message ?? "Couldn't start GitHub's sign-in on \(NodeNames.name(alias))") }
                return
            }
            set(Self.gitHub) { $0.step = .waiting(page) }
        }
    }

    private func busy(_ key: String) -> Bool {
        switch line(key).step {
        case .starting, .waiting, .submitting: true
        case .idle, .failed: false
        }
    }
}
