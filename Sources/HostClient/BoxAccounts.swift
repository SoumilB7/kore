import Foundation
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
        set(provider) {
            $0.said = result.message ?? (result.ok ? nil : "Couldn't read the login on \(alias)")
            $0.signedIn = result.signedIn
        }
    }

    package func signIn(_ provider: String) {
        guard !busy(provider) else { return }
        set(provider) { $0.step = .starting }
        Task {
            let result = await connection.command { HostWire.signIn(id: $0, provider: provider) }
            guard result.ok else {
                set(provider) { $0.step = .failed(result.message ?? "Couldn't sign in on \(alias)") }
                return
            }
            set(provider) { $0.step = .waiting(HostWire.page(result.message)) }
            let done = await connection.later(result.id + HostWire.doneSuffix)
            set(provider) {
                $0.said = done.message ?? $0.said
                $0.signedIn = done.signedIn ?? $0.signedIn
                $0.step = done.ok ? .idle : .failed(done.message ?? "Couldn't sign in on \(alias)")
            }
        }
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
                set(Self.gitHub) { $0.step = .failed(result.message ?? "Couldn't start GitHub's sign-in on \(alias)") }
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
