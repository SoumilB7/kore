import Foundation
import KoreNet
import KoreTrust
import LinkProtocol
import Tailnet

/// One phone's KoreNet connection to this Mac, from its first byte: the session (handshake, then
/// link bodies on stream 1, interactive queue) lives on the connection's own serial queue, woken
/// by its socket only. Reading, parsing, the per-message read of the device's record, and every
/// write happen there, never on the main actor; what the link must act on is handed to it.
package final class PhoneConnection: @unchecked Sendable {
    /// What the main actor hears.
    package enum Event: Sendable {
        /// A stranger's proven hello waits for the owner (the Allow card).
        case held(DeviceRecord)
        /// The handshake held: the device, B, and whether its hello's ticket was honoured.
        case established(NetPeer, binding: Data)
        /// Messages, with the device's record as the book says now (nil: gone).
        case messages([Incoming], record: DeviceRecord?, cursorsSettled: Bool, cursors: [String: KoreTrust.JSONValue]?)
        case closed(String)
    }

    package enum Incoming: Sendable {
        case raise(LinkRaiseWire.Incoming)
        /// A link message, with a risky card's signature when its `chat.answer` carried one.
        case link(LinkMessage, proof: LinkRaiseWire.Signed?)
        case invalid
    }

    /// Bytes waiting for a phone before it's dropped as too slow (as the local link's).
    package static let backlogMax = 8 << 20
    static let stream: UInt32 = 1

    package let queue: DispatchQueue
    package let remote: String
    package let whois: TailnetWhoIs
    /// When this node key first knocked (the card shows it).
    package let firstSeen: Date
    /// The session: touched on `queue` only.
    private let session: NetSession
    private let book: DeviceBook
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var timer: DispatchSourceTimer?
    private var device: UUID?
    private var told = Told()
    private let events: @Sendable (Event) -> Void
    private let clock: @Sendable () -> Date

    private struct Told {
        var held = false
        var established = false
        var closed = false
        var settled = false
    }

    /// Takes `fd` (a connected socket); `events` is called on the queue.
    package init(
        fd: Int32, setup: NetSession.Server, remote: String, whois: TailnetWhoIs, firstSeen: Date, clock: @escaping @Sendable () -> Date,
        events: @escaping @Sendable (Event) -> Void
    ) {
        queue = DispatchQueue(label: "dev.kore.phone")
        self.remote = remote
        self.whois = whois
        self.firstSeen = firstSeen
        self.clock = clock
        self.events = events
        book = setup.book
        session = NetSession(fd: fd, role: .server(setup), clock: clock)
    }

    /// The challenge goes; the proof has its 2 s.
    package func start() {
        queue.async { [self] in
            guard let watched = Self.dup(session.descriptor) else { return close(NetControl.Reason.limit) }
            let source = DispatchSource.makeReadSource(fileDescriptor: watched, queue: queue)
            source.setCancelHandler { Darwin.close(watched) }
            source.setEventHandler { [weak self] in self?.pump() }
            reader = source
            session.start()
            source.resume()
            arm()
        }
    }

    /// The owner's answer to a held stranger: its record as kept, or nil (`reason` goes as `bye`).
    package func admit(_ record: DeviceRecord?, reason: String = NetControl.Reason.refused) {
        queue.async { [self] in
            session.admit(record, reason: reason)
            pump()
        }
    }

    /// Sends a link body (on the queue: the sink's writes come here).
    package func write(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !told.closed else { return }
        do {
            try session.send(data, queue: .interactive, stream: Self.stream)
        } catch {
            return finish()
        }
        guard session.backlog <= Self.backlogMax else { return close(NetControl.Reason.limit) }
        arm()
    }

    /// Ends it with `bye <reason>` (any thread).
    package func end(_ reason: String) { queue.async { [self] in close(reason) } }

    private func close(_ reason: String) {
        guard !told.closed else { return }
        session.close(reason)
        finish()
    }

    private func pump() {
        guard !told.closed else { return }
        let messages = session.pump()
        switch session.state {
        case .handshaking:
            if !told.held, let record = session.heldRecord {
                told.held = true
                events(.held(record))
            }
        case .established(let peer):
            if !told.established {
                told.established = true
                device = peer.record.id
                events(.established(peer, binding: session.bindingDigest ?? Data()))
            }
            var incoming: [Incoming] = []
            for message in messages {
                if let raise = LinkRaiseWire.incoming(message.payload) {
                    incoming.append(.raise(raise))
                } else if let decoded = try? LinkMessage.decode(message.payload) {
                    incoming.append(.link(decoded, proof: LinkRaiseWire.answerProof(message.payload)))
                } else {
                    incoming.append(.invalid)
                }
            }
            let settled = !session.awaitingCursors
            if !incoming.isEmpty || (settled && !told.settled) {
                told.settled = told.settled || settled
                // The record as it is now, read here: a revoked or paused phone stops at its next message.
                let record = device.flatMap { try? book.record($0) }
                events(.messages(incoming, record: record, cursorsSettled: settled, cursors: session.cursors))
            }
        case .closed:
            break
        }
        if case .closed(let reason) = session.state { return finish(reason) }
        arm()
    }

    /// A write source while frames wait; a timer for the handshake's deadline.
    private func arm() {
        guard !told.closed else { return }
        if session.wantsWrite {
            if writer == nil, let watched = Self.dup(session.descriptor) {
                let source = DispatchSource.makeWriteSource(fileDescriptor: watched, queue: queue)
                source.setCancelHandler { Darwin.close(watched) }
                source.setEventHandler { [weak self] in self?.pump() }
                writer = source
                source.resume()
            }
        } else {
            writer?.cancel()
            writer = nil
        }
        timer?.cancel()
        timer = nil
        if let deadline = session.deadline {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + max(0, deadline.timeIntervalSince(clock())) + 0.05)
            source.setEventHandler { [weak self] in self?.pump() }
            timer = source
            source.resume()
        }
    }

    private func finish(_ reason: String? = nil) {
        guard !told.closed else { return }
        told.closed = true
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        timer?.cancel()
        timer = nil
        let why: String
        if let reason {
            why = reason
        } else if case .closed(let reason) = session.state {
            why = reason
        } else {
            why = "closed"
        }
        events(.closed(why))
    }

    private static func dup(_ fd: Int32) -> Int32? {
        let copy = Darwin.dup(fd)
        return copy >= 0 ? copy : nil
    }

    // MARK: Tests

    /// Pumps now (tests drive sessions without waiting on sources).
    package func pumpNow() { queue.sync { pump() } }
}
