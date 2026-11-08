import Foundation
import HostClient
import KoreNet
import KoreTrust
import KoreUI
import LinkProtocol
import src

/// One phone linked to this Mac over KoreNet (phase 18 step 5b): link 2.0's bodies, as the local
/// link's companion gets them, under ask (`LinkAsk`). Its snapshot and transcripts come from the
/// shared `LinkFeed` (attention only while it's in the background); raises and risky Allows take
/// its fingerprint (`LinkRaiseGate`); a resume picks up from its cursors.
@MainActor
package final class PhoneLink {
    package let id: UUID
    package private(set) var record: DeviceRecord
    package let connection: PhoneConnection
    let peer: LinkPeer
    private let gate: LinkRaiseGate
    private unowned let net: MacNet
    private let resumed: Bool
    private var started = false
    package private(set) var ended = false

    init(net: MacNet, record: DeviceRecord, connection: PhoneConnection, binding: Data, resumed: Bool) {
        self.net = net
        id = record.id
        self.record = record
        self.connection = connection
        self.resumed = resumed
        let sink = LinkSink(queue: connection.queue) { [connection] data in connection.write(data) }
        let client = LinkFeed.Client(sink: sink, full: false, phone: true)
        client.holding = true
        peer = LinkPeer(grant: .phone, feed: net.feed, client: client)
        gate = LinkRaiseGate(binding: binding, clock: net.clock)
        let who = record.id.uuidString.lowercased()
        peer.who = who
        peer.ends = { [weak self] reason in self?.end(reason.rawValue) }
        net.feed.attach(client)
        sink.send(.welcome(Self.welcome()))
    }

    /// The link's own welcome (link 1.x's, inside the KoreNet session): ask, not full control.
    static func welcome() -> LinkMessage.Welcome {
        LinkMessage.Welcome(
            proto: LinkProto.version, epoch: LinkRun.epoch, host: .init(name: Host.current().localizedName ?? "Mac", koreVersion: LinkHost.version),
            providers: LinkSnapshot.providers(), policy: .init(sendMaxLevel: LinkPolicy.sendMaxLevel, control: .standard),
            caps: ["tx", "attn", "blob", "commands", "control", "raise", "history", "diff"])
    }

    package var client: LinkFeed.Client { peer.client }

    // MARK: Starting (and resuming)

    /// Its first batch: from the cursors when its ticket was honoured (the deltas since the rev
    /// it holds, if this Mac kept what it was sent; else a snapshot), then what needs the user.
    func begin(cursors: [String: KoreTrust.JSONValue]?) {
        guard !started, !ended else { return }
        started = true
        let rev = resumed ? LinkResume.rev(cursors) : nil
        if let rev, let kept = net.retained(id, rev: rev) {
            client.sink.adopt(kept)
            NetAudit.line("resume", ["device": id.uuidString.lowercased(), "from": "rev"])
        }
        net.feed.release(client)
        net.feed.tick()
        let aid = resumed ? net.feed.attentionResume(LinkResume.aid(cursors)) : nil
        client.sink.send(net.feed.attentionState(after: aid ?? 0))
    }

    /// Nothing more came after the welcome within a second (a resume without cursors).
    func beginIfWaiting() { begin(cursors: nil) }

    var waitsForCursors: Bool { resumed && !started }

    // MARK: In

    func take(_ incoming: [PhoneConnection.Incoming], record now: DeviceRecord?, cursorsSettled: Bool, cursors: [String: KoreTrust.JSONValue]?) {
        guard !ended else { return }
        // Read off the main actor per batch, like kore-host's per command: removed or paused ends it.
        guard let now, now.identityKey == record.identityKey else {
            NetAudit.line("revoke", ["device": id.uuidString.lowercased()])
            return end(LinkMessage.ByeReason.revoked.rawValue)
        }
        guard !now.isPaused else { return end(LinkMessage.ByeReason.paused.rawValue) }
        record = now
        if !started, cursorsSettled || !resumed { begin(cursors: cursors) }
        for item in incoming where !ended {
            switch item {
            case .invalid:
                return end(LinkMessage.ByeReason.invalid.rawValue)
            case .raise(let raise):
                self.raise(raise)
            case .link(.bye, _):
                return end(LinkMessage.ByeReason.quit.rawValue)
            case .link(let message, let proof):
                link(message, proof: proof)
            }
        }
    }

    private func link(_ message: LinkMessage, proof: LinkRaiseWire.Signed?) {
        if case .cmd(let id, let command) = message {
            let chat = command.chatId.flatMap { LinkSnapshot.chatsByID()[$0] }
            if let digest = LinkAsk.proofNeeded(command, chat.map(LinkSnapshot.facts)) {
                guard approved(id: id, digest: digest, proof: proof) else { return }
                // Signed: as the doorbell's companion would allow it.
                peer.client.sink.send(.result(peer.perform(id, command)))
                net.feed.poke()
                return
            }
            if Self.creates(command) { NetAudit.line("create", ["device": self.id.uuidString.lowercased(), "kind": command.type]) }
        }
        peer.received(message)
    }

    /// A new chat or window from the phone (§3): audited.
    static func creates(_ command: LinkCommand) -> Bool {
        switch command {
        case .new: true
        case .control(let kind, _): kind == .chatNew || kind == .windowOpen || kind == .windowReopen
        default: false
        }
    }

    /// A risky card's Allow: its signature over `approve.<digest>`, or refused.
    private func approved(id: String, digest: String, proof: LinkRaiseWire.Signed?) -> Bool {
        let who = self.id.uuidString.lowercased()
        guard let proof, proof.modeId == LinkRaiseWire.approveMode(digest) else {
            client.sink.send(.result(.init(id: id, ok: false, code: .raiseMode, message: "Allowing this takes your fingerprint.")))
            return false
        }
        if case .refused(let code, let message) = gate.verify(proof, raiseKey: record.raiseKey) {
            NetAudit.line("risky", ["device": who, "ok": "0"])
            client.sink.send(.result(.init(id: id, ok: false, code: code, message: message)))
            return false
        }
        NetAudit.line("risky", ["device": who, "ok": "1"])
        return true
    }

    // MARK: Raises

    private func raise(_ incoming: LinkRaiseWire.Incoming) {
        let who = id.uuidString.lowercased()
        switch incoming {
        case .challenge(let ask):
            client.sink.sendRaw(gate.challenge(ask))
        case .raise(let id, let signed):
            if case .refused(let code, let message) = gate.verify(signed, raiseKey: record.raiseKey) {
                NetAudit.line("raise", ["device": who, "mode": signed.modeId, "ok": "0"])
                return client.sink.send(.result(.init(id: id, ok: false, code: code, message: message)))
            }
            NetAudit.line("raise", ["device": who, "mode": signed.modeId, "ok": "1"])
            if let tier = LinkRaiseGate.arsenalTier(signed.modeId) {
                peer.performControl(id, .chatSetArsenal, ControlArgs(chatId: signed.chatId, tier: tier), raised: true)
            } else {
                // A mode up to Auto (never Bypass or Codex's Full access): the full control rule.
                client.sink.send(.result(peer.perform(id, .setMode(chatId: signed.chatId, modeId: signed.modeId), control: .full)))
                net.feed.poke()
            }
        case .key(let id, let pub):
            net.newRaiseKey(self, id: id, pub: pub)
        case .malformed(let id, let type):
            client.sink.send(.result(.init(id: type == LinkRaiseWire.raise ? id : "\(type):\(id)", ok: false, code: .invalid)))
        }
    }

    /// A result for the phone, if it's still here.
    func answer(_ result: LinkMessage.Result) {
        guard !ended else { return }
        client.sink.send(.result(result))
    }

    // MARK: Ending

    /// Ends the link (`bye <reason>`); the projector is kept a while for its resume.
    package func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        connection.end(reason)
        gone()
    }

    /// The connection went (its side, or ours).
    func gone() {
        ended = true
        net.feed.detach(client)
        let id = id
        let net = net
        client.sink.projected { projector in
            DispatchQueue.main.async { MainActor.assumeIsolated { net.retain(id, projector) } }
        }
        net.phoneGone(self)
    }
}
