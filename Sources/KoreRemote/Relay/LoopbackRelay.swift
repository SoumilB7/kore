import CryptoKit
import Foundation

/// The relay in-process, for tests and storylines: the same joins, refusals, slots, signals and
/// limits as `relay/src`, on memory sockets. `tamper` stands in for a hostile relay: it gets each
/// payload on its way and returns what to deliver instead (nothing, it, twice, another).
package actor LoopbackRelay {
    package typealias Tamper = @Sendable (_ toHost: Bool, _ payload: Data) -> [Data]

    private struct Mailbox {
        var host: MemorySocket?
        var hostToken: Data?
        var allowed: Set<Data> = []
        var phones: [UInt8: (socket: MemorySocket, token: Data)] = [:]
        var hostGoneAt: Date?
    }

    private var mailboxes: [Data: Mailbox] = [:]
    private let tamper: Tamper?
    private let now: @Sendable () -> Date
    /// How long phones stay once the host is gone.
    package static let hostGrace: TimeInterval = 600

    package init(tamper: Tamper? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.tamper = tamper
        self.now = now
    }

    /// A dialer onto this relay.
    package nonisolated var dialer: RelayDialer { { [self] mailbox, role, token in try await join(mailbox, role, token) } }

    package func join(_ mailbox: Data, _ role: RelayJoin.Role, _ token: Data) throws -> any RelaySocket {
        let hash = Data(SHA256.hash(data: token))
        var box = mailboxes[mailbox] ?? Mailbox()
        switch role {
        case .host:
            guard KoreKeys.mailbox(hostToken: token) == mailbox else { throw RelayJoin.Refusal.unauthorized }
            if box.host != nil, box.hostToken != hash { throw RelayJoin.Refusal.conflict }
            let (mine, theirs) = MemorySocket.pair()
            let wasAbsent = box.host == nil
            let old = box.host
            box.host = mine
            box.hostToken = hash
            box.hostGoneAt = nil
            mailboxes[mailbox] = box
            old?.end()
            listen(mine, mailbox: mailbox, slot: nil)
            for slot in box.phones.keys.sorted() {
                mine.deliver(RelayFrame.open(slot: slot).encoded(host: true))
            }
            if wasAbsent { for (_, phone) in box.phones { phone.socket.deliver(RelayFrame.open(slot: nil).encoded(host: false)) } }
            return theirs
        case .phone:
            guard box.host != nil else {
                if let gone = box.hostGoneAt, now().timeIntervalSince(gone) > Self.hostGrace { mailboxes[mailbox] = nil }
                throw RelayJoin.Refusal.notFound
            }
            guard box.allowed.contains(hash) else { throw RelayJoin.Refusal.unauthorized }
            guard let slot = (0..<UInt8(RelayFrame.maxPhones)).first(where: { box.phones[$0] == nil }) else { throw RelayJoin.Refusal.full }
            let (mine, theirs) = MemorySocket.pair()
            box.phones[slot] = (mine, hash)
            mailboxes[mailbox] = box
            listen(mine, mailbox: mailbox, slot: slot)
            box.host?.deliver(RelayFrame.open(slot: slot).encoded(host: true))
            mine.deliver(RelayFrame.open(slot: nil).encoded(host: false))
            return theirs
        }
    }

    private nonisolated func listen(_ socket: MemorySocket, mailbox: Data, slot: UInt8?) {
        Task {
            var recent: [Date] = []
            while let bytes = await socket.next() {
                let t = Date()
                recent = recent.filter { t.timeIntervalSince($0) < 1 } + [t]
                guard recent.count <= RelayLimits.framesPerSecond else { break }
                guard await take(bytes, mailbox: mailbox, slot: slot, from: socket) else { break }
            }
            await gone(socket, mailbox: mailbox, slot: slot)
        }
    }

    /// One frame from a socket; false ends that socket.
    private func take(_ bytes: Data, mailbox: Data, slot: UInt8?, from socket: MemorySocket) -> Bool {
        guard var box = mailboxes[mailbox] else { return false }
        let host = slot == nil
        guard let frame = RelayFrame(bytes, host: host) else { return false }
        if host {
            guard box.host === socket else { return false }
            switch frame {
            case .data(let s?, let payload):
                for out in tamper?(false, payload) ?? [payload] {
                    box.phones[s]?.socket.deliver(RelayFrame.data(slot: nil, out).encoded(host: false))
                }
            case .close(let s?):
                box.phones.removeValue(forKey: s)?.socket.end()
                mailboxes[mailbox] = box
            case .allow(let hash):
                box.allowed.insert(hash)
                mailboxes[mailbox] = box
            case .revoke(let hash):
                box.allowed.remove(hash)
                for (s, phone) in box.phones where phone.token == hash {
                    box.phones[s] = nil
                    phone.socket.end()
                    socket.deliver(RelayFrame.close(slot: s).encoded(host: true))
                }
                mailboxes[mailbox] = box
            default:
                return false
            }
        } else {
            guard let slot, box.phones[slot]?.socket === socket else { return false }
            if box.host == nil {
                // The host is gone; past the grace, the mailbox goes too.
                if let gone = box.hostGoneAt, now().timeIntervalSince(gone) > Self.hostGrace { return false }
                return true
            }
            guard case .data(nil, let payload) = frame else { return false }
            for out in tamper?(true, payload) ?? [payload] {
                box.host?.deliver(RelayFrame.data(slot: slot, out).encoded(host: true))
            }
        }
        return true
    }

    private func gone(_ socket: MemorySocket, mailbox: Data, slot: UInt8?) {
        guard var box = mailboxes[mailbox] else { return }
        socket.end()
        if let slot {
            guard box.phones[slot]?.socket === socket else { return }
            box.phones[slot] = nil
            box.host?.deliver(RelayFrame.close(slot: slot).encoded(host: true))
            mailboxes[mailbox] = box
            return
        }
        guard box.host === socket else { return }
        box.host = nil
        box.allowed = []
        if socket.endedByPeer == .normal {
            // The host said goodbye: the mailbox is torn down.
            for (_, phone) in box.phones { phone.socket.end() }
            mailboxes[mailbox] = nil
        } else {
            box.hostGoneAt = now()
            for (_, phone) in box.phones { phone.socket.deliver(RelayFrame.close(slot: nil).encoded(host: false)) }
            mailboxes[mailbox] = box
        }
    }

    /// Mailboxes with anything in them (tests: nothing outlives a torn-down mailbox).
    package var count: Int { mailboxes.count }
}

package enum RelayLimits {
    /// Frames one socket may send in a second.
    package static let framesPerSecond = 400
}
