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
        var foreground: Bool { presence != .background }
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

    private func noted(_ chat: Chat, _ event: ChatEvent) {
        if let turn = attention.noted(chat, event) { broadcast(turn) }
        guard !connections.isEmpty else { return }
        bridge.dirty(chat)
    }

    // MARK: Phones

    /// A phone on `link` (R0: a loopback; the paired, encrypted transport comes later).
    @discardableResult
    package func connect(_ link: any RemoteLink) -> RemoteSession {
        turnOn()
        let session = RemoteSession(link: link)
        let connection = Connection(session: session)
        connections.append(connection)
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

    private func ended(_ connection: Connection) {
        guard let index = connections.firstIndex(where: { $0 === connection }) else { return }
        connections.remove(at: index)
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
            session.enqueue(.message(RemoteBridge.chunk(id: id, chatId: chatId, entryId: entryId, field: field, offset: offset)))
        case .cmd(let id, let command):
            let limited = !connection.actions.take() || (command.type == "chat.send" && !connection.sends.take())
            let outcome =
                limited ? RemoteActions.Outcome.failed(.rateLimited, "Too many at once; try again in a minute.") : RemoteActions.apply(command, grant: grant)
            session.enqueue(.result(id: id, ok: outcome.ok, code: outcome.code, message: outcome.message))
            log.write("cmd", ["type": command.type, "ok": outcome.ok ? "yes" : "no", "code": outcome.code?.rawValue])
            if let chatId = command.chatId { bridge.dirty(id: chatId) }
        default:
            break
        }
    }

    /// To every phone, in the foreground or not (attention).
    func broadcast(_ message: WireMessage) {
        for connection in connections { connection.session.enqueue(.message(message)) }
    }

    /// An open chat by its wire id.
    static func chat(_ id: String) -> Chat? { RemoteBridge.chatsByID()[id] }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
