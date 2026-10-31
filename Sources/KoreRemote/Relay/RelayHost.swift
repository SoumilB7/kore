import Foundation

/// The Mac's one socket to its mailbox on the relay, for one run of Kore: dials out (Kore listens
/// on nothing), keeps the tokens phones may join with registered, and hands each phone that joins
/// on as a byte channel. Reconnects with backoff and jitter; a closed one says goodbye and the
/// relay tears the mailbox down.
package actor RelayHost {
    package enum Status: Equatable, Sendable {
        case connecting
        case connected
        /// Waiting to try again (and why).
        case offline(String)
        case stopped
    }

    package nonisolated let mailbox: Data
    private let token: Data
    private let dial: RelayDialer
    private var socket: (any RelaySocket)?
    private var allowed: Set<Data> = []
    private var slots: [UInt8: RelaySlotChannel] = [:]
    private var stopped = false
    private var attempt = 0
    private var loop: Task<Void, Never>?
    private let onPhone: @Sendable (RelaySlotChannel) -> Void
    private let onStatus: @Sendable (Status) -> Void

    /// A new mailbox: its id follows from the host's token, which never leaves the Mac but for
    /// the relay's check of it.
    package init(dial: @escaping RelayDialer, onPhone: @escaping @Sendable (RelaySlotChannel) -> Void, onStatus: @escaping @Sendable (Status) -> Void) {
        token = KoreKeys.random(32)
        mailbox = KoreKeys.mailbox(hostToken: token)
        self.dial = dial
        self.onPhone = onPhone
        self.onStatus = onStatus
    }

    /// Its socket is up.
    package var isConnected: Bool { socket != nil }

    package func start() {
        guard loop == nil, !stopped else { return }
        loop = Task { await run() }
    }

    /// Phone off or quit: goodbye to the relay, which puts every phone out.
    package func stop() {
        stopped = true
        loop?.cancel()
        socket?.close()
        socket = nil
        for slot in slots.values { slot.ended() }
        slots = [:]
        onStatus(.stopped)
    }

    /// The network changed: try again now rather than at the next backoff.
    package func nudge() {
        guard !stopped, socket == nil else { return }
        attempt = 0
        loop?.cancel()
        loop = Task { await run() }
    }

    // MARK: Tokens

    package func allow(_ hash: Data) async {
        guard allowed.insert(hash).inserted else { return }
        try? await socket?.send(RelayFrame.allow(hash).encoded(host: true))
    }

    package func revoke(_ hash: Data) async {
        guard allowed.remove(hash) != nil else { return }
        try? await socket?.send(RelayFrame.revoke(hash).encoded(host: true))
    }

    // MARK: Phones

    func send(_ slot: UInt8, _ data: Data) async throws {
        guard let socket else { throw ChannelError.closed }
        var offset = data.startIndex
        repeat {
            let end = min(offset + RelayFrame.maxPayload, data.endIndex)
            try await socket.send(RelayFrame.data(slot: slot, Data(data[offset..<end])).encoded(host: true))
            offset = end
        } while offset < data.endIndex
    }

    func close(_ slot: UInt8) async {
        guard slots.removeValue(forKey: slot) != nil else { return }
        try? await socket?.send(RelayFrame.close(slot: slot).encoded(host: true))
    }

    // MARK: The socket

    private func run() async {
        while !stopped, !Task.isCancelled {
            onStatus(.connecting)
            do {
                let socket = try await dial(mailbox, .host, token)
                self.socket = socket
                attempt = 0
                for hash in allowed { try await socket.send(RelayFrame.allow(hash).encoded(host: true)) }
                onStatus(.connected)
                try await read(socket)
            } catch let refusal as RelayJoin.Refusal {
                onStatus(.offline(refusal == .conflict ? "the mailbox is taken" : "the relay refused"))
            } catch {
                onStatus(.offline("no connection"))
            }
            socket = nil
            // Phones on the old socket are gone; they join again.
            for slot in slots.values { slot.ended() }
            slots = [:]
            guard !stopped, !Task.isCancelled else { return }
            attempt += 1
            let base = min(60.0, pow(2.0, Double(min(attempt, 6))))
            try? await Task.sleep(for: .seconds(base * Double.random(in: 0.8...1.2)))
        }
    }

    private func read(_ socket: any RelaySocket) async throws {
        while true {
            let bytes = try await socket.receive()
            guard let frame = RelayFrame(bytes, host: true) else { throw ChannelError.closed }
            switch frame {
            case .open(let slot?):
                slots[slot]?.ended()
                let channel = RelaySlotChannel(slot: slot, host: self)
                slots[slot] = channel
                onPhone(channel)
            case .data(let slot?, let payload):
                slots[slot]?.feed(payload)
            case .close(let slot?):
                slots.removeValue(forKey: slot)?.ended()
            default:
                throw ChannelError.closed
            }
        }
    }
}

/// One phone in the Mac's mailbox, as a byte channel: what the session reads and writes.
package final class RelaySlotChannel: ByteChannel, @unchecked Sendable {
    package let slot: UInt8
    private weak var host: RelayHost?
    private let inbox: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let iterator: Locked<AsyncStream<Data>.Iterator?>

    init(slot: UInt8, host: RelayHost) {
        self.slot = slot
        self.host = host
        (inbox, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        iterator = Locked(inbox.makeAsyncIterator())
    }

    package var remoteHost: String { "relay slot \(slot)" }

    func feed(_ data: Data) { continuation.yield(data) }
    func ended() { continuation.finish() }

    package func receive() async throws -> Data {
        var it = iterator.withLock { $0.take() }
        defer { iterator.withLock { $0 = it } }
        guard let data = await it?.next() else { throw ChannelError.closed }
        return data
    }

    package func send(_ data: Data) async throws {
        guard let host else { throw ChannelError.closed }
        try await host.send(slot, data)
    }

    package func close() {
        continuation.finish()
        let slot = slot
        if let host { Task { await host.close(slot) } }
    }
}
