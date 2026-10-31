import Foundation
import KoreCore
import KoreRemote
import KoreUI

/// The phone remote on the Mac: the switch, the phones connected, what each follows, and their
/// commands. Off, it costs nothing. On with no phone connected, each chat event costs one check
/// (and a turn end is kept). Pairings last for one run of Kore: nothing about a phone is saved.
@MainActor
package final class RemoteHost {
    package static let shared = RemoteHost()

    /// One phone, while it's connected.
    final class Connection {
        let session: RemoteSession
        /// The paired phone's id (nil: a test's loopback phone).
        var phoneID: String?
        var device = "a phone"
        var presence = WireMessage.Presence.foreground
        var visibleChat: String?
        /// Transcripts it follows: how many of the last entries each, and whether it has them yet.
        var subs: [String: Sub] = [:]
        /// It needs every window and chat again (a hello, or back from the background).
        var snapshotDue = false
        var sends = RateLimiter(limit: 10, per: 60)
        var actions = RateLimiter(limit: 30, per: 60)
        var tasks: [Task<Void, Never>] = []

        struct Sub {
            var last: Int
            /// Ids it was sent, so entries that come into its window are sent too.
            var known = Set<String>()
            var fresh = true
        }

        init(session: RemoteSession) { self.session = session }
        /// It's sent Kore's state: open on the phone, and unlocked (full access).
        var foreground: Bool { presence != .background && session.link.access == .full }
    }

    package private(set) var isOn = false
    /// What a paired phone may do here.
    package var grant = RemotePolicy.Grant()
    /// This run of Kore: a phone that sees another starts over.
    package let hostEpoch = String(UUID().uuidString.prefix(8)).lowercased()
    private(set) var connections: [Connection] = []
    let attention = AttentionTracker()
    let bridge = RemoteBridge()
    private var tap: UUID?
    private let log = KoreLog.named("remote")
    private let activityLog = KoreLog.named("remote-activity")

    /// What the Phone popup and the title-row button show.
    package let phone = PhoneModel()
    /// The switch, the relay and pairing.
    package private(set) lazy var service = PhoneService(host: self)

    /// Phones connected now.
    package var phones: Int { connections.count }
    /// How long each recent tick took on the main thread (the navigation budget).
    package var tickTimes: [Duration] { bridge.tickTimes }

    // MARK: On and off

    package func turnOn() {
        guard !isOn else { return }
        isOn = true
        tap = RemoteTaps.add { [weak self] chat, event in self?.noted(chat, event) }
        log.write("on", [:])
    }

    package func turnOff() {
        guard isOn else { return }
        for connection in connections { drop(connection, saying: .off) }
        if let tap { RemoteTaps.remove(tap) }
        tap = nil
        isOn = false
        bridge.stop()
        TranscriptStore.remoteTracking = false
        log.write("off", [:])
    }

    // MARK: Phones' rows

    /// The popup's rows for the paired phones, with what each connection is now.
    func rows(_ records: [PhoneRecord]) -> [PhoneModel.Row] {
        records.map { record in
            let live = connections.first { $0.phoneID == record.id }
            return PhoneModel.Row(
                id: record.id, name: record.name, connected: live != nil, access: live?.session.link.access ?? .watch, lastSeen: record.lastSeen)
        }
    }

    func refreshRows() {
        for index in phone.rows.indices {
            let live = connections.first { $0.phoneID == phone.rows[index].id }
            phone.rows[index].connected = live != nil
            phone.rows[index].access = live?.session.link.access ?? .watch
        }
    }

    private func noted(_ chat: Chat, _ event: ChatEvent) {
        if let turn = attention.noted(chat, event) { broadcast(turn) }
        guard !connections.isEmpty else { return }
        bridge.dirty(chat)
    }

    // MARK: Phones

    /// A phone on `link` (R0: a loopback; the paired, encrypted transport comes later).
    @discardableResult
    package func connect(_ link: any RemoteLink, phoneID: String? = nil) -> RemoteSession {
        turnOn()
        let session = RemoteSession(link: link)
        let connection = Connection(session: session)
        connection.phoneID = phoneID
        connections.append(connection)
        AwakeInputs.phonesConnected(connections.count)
        let sessionID = session.id
        link.observeAccess { [weak self] access in
            Task { @MainActor in
                guard let self, let connection = self.connections.first(where: { $0.session.id == sessionID }) else { return }
                self.accessChanged(connection, access)
            }
        }
        connection.tasks.append(Task.detached { await session.run() })
        connection.tasks.append(
            Task { [weak self] in
                for await data in link.incoming {
                    guard let message = await session.receive(data) else { continue }
                    self?.handle(connection, message)
                }
                self?.ended(connection)
            })
        bridge.start(self)
        return session
    }

    /// Unlocked: Kore's state goes to it. Locked: only alerts.
    private func accessChanged(_ connection: Connection, _ access: RemoteAccess) {
        if access == .full {
            connection.snapshotDue = connection.foreground
            bridge.start(self)
        } else {
            connection.subs = [:]
            connection.session.enqueue(.forget)
        }
        refreshRows()
    }

    private func ended(_ connection: Connection) {
        guard let index = connections.firstIndex(where: { $0 === connection }) else { return }
        connections.remove(at: index)
        AwakeInputs.phonesConnected(connections.count)
        refreshRows()
        connection.tasks.forEach { $0.cancel() }
        log.write("disconnected", ["phones": "\(connections.count)"])
        if connections.isEmpty {
            bridge.stop()
            TranscriptStore.remoteTracking = false
        }
    }

    private func drop(_ connection: Connection, saying reason: WireMessage.ByeReason) {
        connection.session.enqueue(.message(.bye(reason)))
        connection.session.end()
        ended(connection)
    }

    private func handle(_ connection: Connection, _ message: WireMessage) {
        let session = connection.session
        switch message {
        case .hello(let proto, let device, let mode, let attnAfter, _):
            guard proto.major == Proto.major else {
                drop(connection, saying: .replaced)
                return
            }
            connection.device = device.name
            connection.presence = mode
            session.enqueue(
                .message(
                    .welcome(
                        .init(
                            proto: Proto.version, hostEpoch: hostEpoch,
                            host: .init(name: Host.current().localizedName ?? "Mac", koreVersion: Self.version), providers: RemoteSnapshot.providers(),
                            policy: .init(sendMaxLevel: grant.sendMaxLevel), caps: ["tx", "attn"]))))
            for message in attention.look(RemoteBridge.chatsByID(), everything: true) { broadcast(message) }
            session.enqueue(.message(attention.ledger.state(after: attnAfter)))
            connection.snapshotDue = connection.foreground
            log.write("connected", ["mode": mode.rawValue])
            refreshRows()
        case .presence(let mode, let visible):
            connection.visibleChat = visible
            guard mode != connection.presence else { return }
            connection.presence = mode
            if mode == .background {
                connection.subs = [:]
                session.enqueue(.forget)
            } else {
                connection.snapshotDue = true
            }
        case .txOpen(let chatId, let last):
            guard connection.foreground else { return }
            connection.subs[chatId] = .init(last: min(max(last ?? RemoteBridge.window, 1), RemoteBridge.windowMax))
            TranscriptStore.remoteTracking = true
            bridge.dirty(id: chatId)
        case .txMore(let chatId, let count):
            guard var sub = connection.subs[chatId] else { return }
            sub.last = min(sub.last + max(count, 0), RemoteBridge.windowMax)
            connection.subs[chatId] = sub
            bridge.dirty(id: chatId)
        case .txClose(let chatId):
            connection.subs[chatId] = nil
            session.enqueue(.close(chatId: chatId))
        case .entryMore(let id, let chatId, let entryId, let field, let offset):
            guard connection.foreground else { return }
            session.enqueue(.message(RemoteBridge.chunk(id: id, chatId: chatId, entryId: entryId, field: field, offset: offset)))
        case .cmd(let id, let command):
            let outcome: RemoteActions.Outcome
            if session.link.access != .full {
                outcome = .failed(.access, "Unlock Kore on the phone first.")
            } else if !connection.actions.take() || (command.type == "chat.send" && !connection.sends.take()) {
                outcome = .failed(.rateLimited, "Too many at once; try again in a minute.")
            } else {
                outcome = RemoteActions.apply(command, grant: grant, link: session.link)
            }
            session.enqueue(.result(id: id, ok: outcome.ok, code: outcome.code, message: outcome.message))
            log.write("cmd", ["type": command.type, "ok": outcome.ok ? "yes" : "no", "code": outcome.code?.rawValue])
            act(connection, command, outcome)
            if let chatId = command.chatId { bridge.dirty(id: chatId) }
        default:
            break
        }
    }

    /// The Activity list's line for a phone's command: what was done, to which chat (by title),
    /// never what was said.
    private func act(_ connection: Connection, _ command: RemoteCommand, _ outcome: RemoteActions.Outcome) {
        let title = command.chatId.flatMap(Self.chat).map(\.title)
        let name = connection.phoneID.flatMap { id in phone.rows.first { $0.id == id }?.name } ?? connection.device
        phone.note(PhoneActivity.command(command, ok: outcome.ok, title: title), phone: name)
        activityLog.write("cmd", ["type": command.type, "ok": outcome.ok ? "yes" : "no", "chat": title, "phone": connection.phoneID])
    }

    /// To every phone, in the foreground or not (attention).
    func broadcast(_ message: WireMessage) {
        for connection in connections { connection.session.enqueue(.message(message)) }
    }

    /// An open chat by its wire id.
    static func chat(_ id: String) -> Chat? { RemoteBridge.chatsByID()[id] }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
