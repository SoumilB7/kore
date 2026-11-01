import AppKit
import Foundation
import KoreUI

/// A ring at the doorbell (`z-docs/link-protocol.md` §1). The first ring shows Kore's card; on
/// Allow the companion is allowed for this run and its first connection wakes. Later rings with a
/// valid proof wake a connection at once, with no card. One card at a time; while a card is up or
/// a client is connected, rings are answered `busy`; after a Deny, the same sender's rings are
/// answered `denied` for the rest of this run.
@MainActor
package enum LinkDoorbell {
    package enum Answer: Equatable, Sendable {
        /// `runSecret` only in the first Allow's reply.
        case allowed(socket: String, secret: Data, runSecret: Data?)
        case denied, busy, invalid
    }

    /// How long a ring waits for the user before it's answered `denied`.
    package static var replyWait: TimeInterval = 120
    /// Senders denied in this run, by their designated requirement's text.
    private static var refused = Set<String>()

    // MARK: The Apple Event

    /// The re-ring's proof (`'rprf'`, text) and its time (`'rgts'`, Unix seconds).
    static let proofKeyword: AEKeyword = 0x7270_7266
    static let timeKeyword: AEKeyword = 0x7267_7473

    /// `'KoRe'/'ring'`, from `AppDelegate`.
    package static func ring(_ event: NSAppleEventDescriptor, _ reply: NSAppleEventDescriptor) {
        // keySenderAuditTokenAttr ('tokn'): who sent it, as the system stamped it on delivery.
        ring(
            name: event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? "", token: event.attributeDescriptor(forKeyword: 0x746F_6B6E)?.data,
            proof: event.paramDescriptor(forKeyword: proofKeyword)?.stringValue, ts: event.paramDescriptor(forKeyword: timeKeyword).flatMap { Int($0.stringValue ?? "") },
            reply: reply)
    }

    /// A ring from the sender with this audit token, with a re-ring's proof if it has one.
    package static func ring(name: String, token: Data?, proof: String? = nil, ts: Int? = nil, reply: NSAppleEventDescriptor) {
        if let answer = rering(token: token, proof: proof, ts: ts) { return fill(reply, answer) }
        guard let identity = token.flatMap(LinkIdentity.requirement(auditToken:)) else { return fill(reply, .invalid) }
        // Answered now unless the user is asked.
        if let answer = immediate(key: identity.1) { return fill(reply, answer) }
        let manager = NSAppleEventManager.shared()
        guard let suspension = manager.suspendCurrentAppleEvent() else { return fill(reply, .invalid) }
        ask(name: name, requirement: identity.0, key: identity.1, appURL: token.flatMap(LinkRun.appURL(auditToken:))) { answer in
            fill(manager.replyAppleEvent(forSuspensionID: suspension), answer)
            manager.resume(withSuspensionID: suspension)
        }
    }

    private static func fill(_ reply: NSAppleEventDescriptor, _ answer: Answer) {
        switch answer {
        case .allowed(let socket, let secret, let runSecret):
            var body: [String: Any] = [
                "socket": socket, "secret": secret.base64EncodedString(), "proto": ["major": LinkProto.major, "minor": LinkProto.minor],
                "epoch": LinkRun.epoch,
            ]
            if let runSecret { body["runSecret"] = runSecret.base64EncodedString() }
            let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            reply.setParam(NSAppleEventDescriptor(string: String(decoding: json, as: UTF8.self)), forKeyword: keyDirectObject)
        case .denied, .busy, .invalid:
            reply.setParam(NSAppleEventDescriptor(int32: -1743), forKeyword: keyErrorNumber)
            reply.setParam(NSAppleEventDescriptor(string: "\(answer)"), forKeyword: keyErrorString)
        }
    }

    // MARK: Asking

    /// The answer without asking: a card up or a client connected, or a sender denied before.
    static func immediate(key: String) -> Answer? {
        if LinkHost.current?.linked == true || LinkPanel.cardOpen { return .busy }
        if refused.contains(key) { return .denied }
        return nil
    }

    /// The allowed companion ringing again with a valid proof: a new connection at once, no card.
    /// Nil when it isn't one (no proof, a bad, replayed or stale one): the normal flow answers.
    package static func rering(token: Data?, proof: String?, ts: Int?, directory: URL = LinkHost.defaultDirectory) -> Answer? {
        guard proof != nil, let run = LinkRun.current, !LinkPanel.cardOpen else { return nil }
        if LinkHost.current?.linked == true { return .busy }
        guard run.admits(proof: proof, ts: ts, token: token) else {
            UILog.event("link-rering-refused", [:])
            return nil
        }
        do {
            let host = try LinkHost.wake(run: run, directory: directory)
            UILog.event("link-rering", [:])
            return .allowed(socket: host.socketPath, secret: host.secret, runSecret: nil)
        } catch {
            UILog.event("link-failed", ["error": "\((error as NSError).code)"])
            return .invalid
        }
    }

    /// Shows the card for `name` and answers once: Allow wakes the link, pinned to `requirement`.
    package static func ask(
        name: String, requirement: SecRequirement, key: String, appURL: URL? = nil, directory: URL = LinkHost.defaultDirectory,
        respond: @escaping @MainActor (Answer) -> Void
    ) {
        if let answer = immediate(key: key) { return respond(answer) }
        UILog.event("link-rung", [:])
        var answered = false
        let finish: @MainActor (Answer) -> Void = { answer in
            guard !answered else { return }
            answered = true
            respond(answer)
        }
        LinkPanel.showCard(name: shown(name)) { allow in
            guard allow else {
                refused.insert(key)
                UILog.event("link-denied", [:])
                return finish(.denied)
            }
            do {
                let run = LinkRun.allow(name: shown(name), requirement: requirement, key: key, appURL: appURL)
                let host = try LinkHost.wake(run: run, directory: directory)
                finish(.allowed(socket: host.socketPath, secret: host.secret, runSecret: run.runSecret))
            } catch {
                UILog.event("link-failed", ["error": "\((error as NSError).code)"])
                finish(.invalid)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + replyWait) {
            MainActor.assumeIsolated {
                guard !answered else { return }
                LinkPanel.closeCard()
                finish(.denied)
            }
        }
    }

    /// The name as the card shows it: printable, at most 64 characters.
    static func shown(_ name: String) -> String {
        let clean = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "A companion app" : String(clean.prefix(64))
    }

    /// Forgets this run's Denies (tests).
    package static func forgetRefusals() { refused = [] }
}
