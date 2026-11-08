import Foundation
import KoreNet
import KoreTrust
import KoreUI
import LinkProtocol

/// Another of the owner's Macs linked to this one over KoreNet, paired once by an Allow card (its
/// record: kind mac, owner, in this Mac's own book). A lean link: no feed, no snapshot, no chats.
/// It answers only a login's move (`account.import`, `account.export`, `account.fingerprints`,
/// checked by `LinkLogins`), through this Mac's `MacLoginMoves`; anything else is refused.
@MainActor
package final class MacPeerLink {
    package let id: UUID
    package private(set) var record: DeviceRecord
    package let connection: PhoneConnection
    private unowned let net: MacNet
    package private(set) var ended = false

    /// What the other Mac can ask of this one.
    package static let caps = [LinkLogins.cap]
    /// The commands it answers.
    package static let loginKinds: Set<ControlKind> = [.accountImport, .accountExport, .accountFingerprints]
    /// The answer to anything else.
    package static let refusal = "Between Macs, only a login moves."

    init(net: MacNet, record: DeviceRecord, connection: PhoneConnection) {
        self.net = net
        id = record.id
        self.record = record
        self.connection = connection
        send(LinkMessage.welcome(Self.welcome(name: net.host.macName)))
    }

    static func welcome(name: String) -> LinkMessage.Welcome {
        LinkMessage.Welcome(
            proto: LinkProto.version, epoch: LinkRun.epoch, host: .init(name: name, koreVersion: LinkHost.version), providers: [],
            policy: .init(sendMaxLevel: LinkPolicy.sendMaxLevel, control: .full), caps: caps)
    }

    /// Whether a record may hold this link: another owner Mac, not paused.
    static func admits(_ record: DeviceRecord?, as held: DeviceRecord) -> Bool {
        guard let record, record.identityKey == held.identityKey, record.kind == .mac, record.owner, !record.isPaused else { return false }
        return true
    }

    func take(_ incoming: [PhoneConnection.Incoming], record now: DeviceRecord?) {
        guard !ended else { return }
        // Read per batch: a Mac removed here (or changed) stops at its next message.
        guard Self.admits(now, as: record), let now else {
            NetAudit.line("revoke", ["device": id.uuidString.lowercased()])
            return end(LinkMessage.ByeReason.revoked.rawValue)
        }
        record = now
        for item in incoming where !ended {
            switch item {
            case .invalid:
                return end(LinkMessage.ByeReason.invalid.rawValue)
            case .link(.bye):
                return end(LinkMessage.ByeReason.quit.rawValue)
            case .link(.cmd(let id, let command)):
                perform(id, command)
            case .raise, .leave, .link:
                continue
            }
        }
    }

    private func perform(_ id: String, _ command: LinkCommand) {
        guard case .control(let kind, let args) = command, Self.loginKinds.contains(kind) else {
            return answer(.refused(id, .deniedControl, Self.refusal))
        }
        if case .deny(let code, let message) = LinkLogins.check(kind, args) { return answer(.refused(id, code, message)) }
        NetAudit.line("login", ["device": self.id.uuidString.lowercased(), "kind": kind.rawValue, "phase": args.phase])
        let moves = net.loginMoves
        Task { @MainActor [weak self] in
            let result = await moves.handle(kind, args, id: id)
            self?.answer(result)
        }
    }

    private func answer(_ result: LoginMoveResult) {
        guard !ended, let data = try? JSONEncoder().encode(result) else { return }
        let connection = connection
        connection.queue.async { connection.write(data) }
    }

    private func send(_ message: LinkMessage) {
        guard let data = try? message.encoded() else { return }
        let connection = connection
        connection.queue.async { connection.write(data) }
    }

    package func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        connection.end(reason)
        net.macGone(self)
    }

    func gone() {
        guard !ended else { return }
        ended = true
        net.macGone(self)
    }
}
