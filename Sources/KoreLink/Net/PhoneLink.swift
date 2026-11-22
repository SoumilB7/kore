import Foundation
import HostClient
import KoreNet
import KoreTrust
import KoreUI
import LinkProtocol
import src

/// One phone linked to this Mac over KoreNet (phase 18 step 5b): link 2.0's bodies, as the local
/// link's companion gets them, under ask (`LinkAsk`). Its snapshot and transcripts come from the
/// shared `LinkFeed` (attention only while it's in the background); a card's Allow is a plain tap,
/// raises take its fingerprint (`LinkRaiseGate`); a resume picks up from its cursors.
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
    /// Taken offline on this Mac: the link stays but serves nothing (no feed, no commands), so
    /// Bring online reaches the phone at once (`bye online`, and it dials straight back).
    package private(set) var parked = false
    /// What a parked phone hears when it's brought online: dial again now.
    package static let onlineReason = "online"

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
            caps: ["tx", "attn", "blob", "commands", "control", "raise", "history", "diff", "group", "board", "copyVia"])
    }

    package var client: LinkFeed.Client { peer.client }

    // MARK: Starting (and resuming)

    /// Its first batch: from the cursors when its ticket was honoured (the deltas since the rev
    /// it holds, if this Mac kept what it was sent; else a snapshot), then what needs the user.
    func begin(cursors: [String: KoreTrust.JSONValue]?) {
        guard !started, !ended else { return }
        started = true
        if record.isPaused { return park() }
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
        record = now
        if now.isPaused, started { park() } else if !now.isPaused, parked { return unpark() }
        if !started, cursorsSettled || !resumed { begin(cursors: cursors) }
        for item in incoming where !ended {
            // Parked: only its own leaving or going is heard.
            if parked {
                switch item {
                case .leave, .link(.bye): break
                default: continue
                }
            }
            switch item {
            case .invalid:
                return end(LinkMessage.ByeReason.invalid.rawValue)
            case .raise(let raise):
                self.raise(raise)
            case .leave(let id):
                return leave(id)
            case .usageSince(let ask):
                // A Mac's usage bookkeeping: never a phone's.
                NetAudit.line("denied", ["device": self.id.uuidString.lowercased(), "kind": UsageWire.since])
                tell((try? JSONEncoder().encode(UsageWire.Page(id: ask.id, lines: [], cursor: ask.cursor ?? 0, more: false))) ?? Data())
            case .link(.bye):
                return end(LinkMessage.ByeReason.quit.rawValue)
            case .link(let message):
                link(message)
            }
        }
    }

    // MARK: The phone's log (1.13)

    /// Asks waiting for their next `logs.chunk`, by id.
    private var logWaits: [String: CheckedContinuation<(offset: Int, total: Int, text: String)?, Never>] = [:]

    /// The phone's own content-free log, read piece by piece (`logs.get` / `logs.chunk`); nil when
    /// it didn't answer within `wait` a piece, or the pieces didn't add up. Offsets count UTF-16
    /// units, as the phone's strings do.
    package func logs(wait: Duration = .seconds(15)) async -> String? {
        let id = UUID().uuidString.lowercased()
        var text = ""
        while !ended {
            let at = text.utf16.count
            let piece: (offset: Int, total: Int, text: String)? = await withCheckedContinuation { waiting in
                logWaits[id] = waiting
                peer.client.sink.send(.logsGet(id: id, offset: at))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: wait)
                    self?.logWaits.removeValue(forKey: id)?.resume(returning: nil)
                }
            }
            guard let piece, piece.offset == at else { return nil }
            text += piece.text
            if text.utf16.count >= piece.total || piece.text.isEmpty { return text }
        }
        return nil
    }

    private func link(_ message: LinkMessage) {
        if case .logsChunk(let id, let offset, let total, let text) = message {
            logWaits.removeValue(forKey: id)?.resume(returning: (offset, total, text))
            return
        }
        // A login moves only between the owner's Macs: never at a phone's word, whatever it may do.
        if case .cmd(let id, .control(let kind, _)) = message, MacPeerLink.loginKinds.contains(kind) {
            peer.client.sink.send(.result(.init(id: id, ok: false, code: .deniedControl, message: LinkLogins.ownerOnly)))
            return
        }
        if case .cmd(_, let command) = message, Self.creates(command) {
            NetAudit.line("create", ["device": self.id.uuidString.lowercased(), "kind": command.type])
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

    /// A message of the Mac's own for the phone (its directory), if it's still here.
    func tell(_ data: Data) {
        guard !ended else { return }
        client.sink.sendRaw(data)
    }

    /// A result for the phone, if it's still here.
    func answer(_ result: LinkMessage.Result) {
        guard !ended else { return }
        client.sink.send(.result(result))
    }

    // MARK: Taken offline

    /// Taken offline: nothing more is sent or served; the phone hears `paused` and shows it.
    func park() {
        guard !parked, !ended else { return }
        parked = true
        net.feed.detach(client)
        client.sink.sendRaw(Data(#"{"t":"paused"}"#.utf8))
        NetAudit.line("park", ["device": id.uuidString.lowercased()])
        net.phoneParked()
    }

    /// Brought online: the parked link ends with `bye online`, and the phone dials straight back.
    func unpark() {
        guard parked else { return }
        end(Self.onlineReason)
    }

    // MARK: Leaving

    /// The phone leaves KoreNet (ID3 a): its record goes now, the boxes hear, and it hears that
    /// before it signs out (`leave:<id>`).
    private func leave(_ resultId: String) {
        let who = id
        do {
            try net.host.book.update { $0.removeAll { $0.id == who } }
        } catch {
            return answer(.init(id: "leave:\(resultId)", ok: false))
        }
        NetAudit.line("leave", ["device": who.uuidString.lowercased()])
        answer(.init(id: "leave:\(resultId)", ok: true))
        end(LinkMessage.ByeReason.quit.rawValue)
        net.phonesChanged()
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
        if !parked { net.feed.detach(client) }
        let id = id
        let net = net
        client.sink.projected { projector in
            DispatchQueue.main.async { MainActor.assumeIsolated { net.retain(id, projector) } }
        }
        net.phoneGone(self)
    }
}
