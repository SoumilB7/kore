import AppKit
import Foundation
import KoreUI

/// A companion allowed for this run of Kore (`z-docs/link-protocol.md` §1): from the user's Allow
/// until Disconnect or quit. It holds no socket, tap or timer of its own. Each connection is a
/// `LinkHost`, woken by a ring and gone when the client goes; while the companion is allowed but
/// not connected, only this record and its "/" entries exist.
@MainActor
package final class LinkRun {
    /// The companion allowed now; nil before the first Allow and after Disconnect.
    package private(set) static var current: LinkRun?
    /// This run of Kore, the same for every link in it: a client learns from `welcome` whether
    /// Kore restarted. Made on first use, never at launch.
    package static let epoch = UUID().uuidString
    /// How far a re-ring's time may be from Kore's clock, in seconds.
    static let skew = 30
    /// The companion's commands Kore lists in "/", and their labels' length.
    static let commandsMax = 6
    static let labelMax = 40
    /// Opens the companion's app for "Open <name>" (tests swap it for a stub).
    package static var opener: (URL) -> Void = { url in
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    package let name: String
    let requirement: SecRequirement
    /// The requirement's text: the key a Deny is remembered by.
    let key: String
    /// Proves a re-ring for this run; discarded on Disconnect.
    package let runSecret: Data
    /// The companion's app, from the audit token at Allow: what "Open <name>" opens.
    package let appURL: URL?
    /// What the companion offered in its last hello.
    package private(set) var commands: [LinkMessage.CompanionCommand] = []
    /// The title row's mark while connected; its recent actions last the whole run.
    package let mark: LinkMark
    /// Re-ring proofs already taken, by their time: none is taken twice.
    private var seen: [String: Int] = [:]

    private init(name: String, requirement: SecRequirement, key: String, appURL: URL?) {
        self.name = name
        self.requirement = requirement
        self.key = key
        self.appURL = appURL
        runSecret = Data(base64Encoded: LinkProof.random(32)) ?? Data()
        var revoke: (() -> Void)?
        mark = LinkMark(name: name) { revoke?() }
        revoke = { [weak self] in self?.revoke() }
    }

    /// The user allowed `name`: a new run, in place of any earlier one.
    package static func allow(name: String, requirement: SecRequirement, key: String, appURL: URL? = nil) -> LinkRun {
        current?.revoke()
        let run = LinkRun(name: name, requirement: requirement, key: key, appURL: appURL)
        current = run
        LinkTaps.slash = { LinkRun.current?.slashEntries() ?? [] }
        LinkTaps.slashChosen = { LinkRun.current?.chose($0) }
        LinkTaps.quit = { LinkRun.current?.revoke(.quit) }
        UILog.event("link-allowed", [:])
        return run
    }

    /// Disconnect (or quit): the connection ends, the run's secret and entries go, and the next
    /// ring needs the card again.
    package func revoke(_ reason: LinkMessage.ByeReason = .disconnected) {
        guard LinkRun.current === self else { return }
        LinkHost.current?.end(reason)
        LinkRun.current = nil
        LinkTaps.slash = nil
        LinkTaps.slashChosen = nil
        LinkTaps.quit = nil
        Workspace.showLinkMark(nil)
        LinkPanel.closePopup()
        UILog.event("link-revoked", ["reason": reason.rawValue])
    }

    // MARK: Re-rings

    /// A ring from the allowed companion, answered without the card: a valid proof over this run's
    /// epoch and a time within `skew`, not seen before, and, where the event carries an audit
    /// token, a sender that satisfies the pinned requirement.
    package func admits(proof: String?, ts: Int?, token: Data?, now: Int = Int(Date().timeIntervalSince1970)) -> Bool {
        guard let proof, let ts, abs(now - ts) <= Self.skew else { return false }
        seen = seen.filter { abs(now - $0.value) <= Self.skew }
        guard seen[proof] == nil, LinkProof.checkRing(proof, runSecret: runSecret, epoch: Self.epoch, ts: ts) else { return false }
        if let token {
            guard let code = LinkIdentity.code(auditToken: token), SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        }
        seen[proof] = ts
        return true
    }

    // MARK: Commands in "/"

    /// The commands from a hello, made safe to show: at most six, plain one-line labels.
    func offer(_ offered: [LinkMessage.CompanionCommand]?) {
        commands = (offered ?? []).prefix(Self.commandsMax).compactMap { command in
            let id = String(command.id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }.prefix(64))
            let label = LinkRun.plain(command.label, max: Self.labelMax)
            return id.isEmpty || label.isEmpty ? nil : .init(id: id, label: label)
        }
    }

    /// Printable, one line, at most `max` characters.
    static func plain(_ text: String, max: Int) -> String {
        let kept = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(max))
    }

    static let commandPrefix = "link-cmd-"
    static let openName = "link-open"
    static let disconnectName = "link-disconnect"

    /// Kore's "/" entries for the companion: its commands while connected, "Open <name>" while
    /// not, and "Disconnect <name>" either way.
    func slashEntries() -> [SlashCommand] {
        var entries: [SlashCommand] = []
        if LinkHost.current?.linked == true {
            for command in commands {
                var entry = SlashCommand(name: Self.commandPrefix + command.id, description: name, hint: "", kind: .kore, glyph: "link")
                entry.title = command.label
                entries.append(entry)
            }
        } else {
            var open = SlashCommand(name: Self.openName, description: name, hint: "", kind: .kore, glyph: "arrow.up.forward.app")
            open.title = "Open \(name)"
            open.unavailable = appURL == nil
            entries.append(open)
        }
        var disconnect = SlashCommand(name: Self.disconnectName, description: name, hint: "", kind: .kore, glyph: "link")
        disconnect.title = "Disconnect \(name)"
        entries.append(disconnect)
        return entries
    }

    /// One of the entries was chosen.
    func chose(_ entry: String) {
        switch entry {
        case Self.disconnectName:
            revoke()
        case Self.openName:
            guard let appURL else { return }
            UILog.event("link-open", [:])
            Self.opener(appURL)
        default:
            guard entry.hasPrefix(Self.commandPrefix) else { return }
            let id = String(entry.dropFirst(Self.commandPrefix.count))
            guard commands.contains(where: { $0.id == id }) else { return }
            LinkHost.current?.command(id)
        }
    }

    /// The app holding `token`'s code, for "Open <name>".
    package static func appURL(auditToken: Data) -> URL? {
        guard let code = LinkIdentity.code(auditToken: auditToken) else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return url as URL
    }
}
