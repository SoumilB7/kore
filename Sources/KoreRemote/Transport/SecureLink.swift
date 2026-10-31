import Foundation

/// An encrypted session on a byte channel, on either side: JSON messages in and out as records,
/// big ones in chunks, pings, rekeys, and BYE. Any failure ends it. The link's own messages go
/// to `control`; the rest to `incoming`, for the sync layer.
package final class SecureLink: RemoteLink, @unchecked Sendable {
    package let incoming: AsyncStream<Data>
    private let inbox: AsyncStream<Data>.Continuation
    private let channel: any ByteChannel
    private let reader: ChannelReader
    private let state: Locked<State>
    private let outbox: AsyncStream<Record>.Continuation
    private let outgoing: AsyncStream<Record>
    /// The handshake hash: what signatures over this session are bound to.
    package let handshakeHash: Data
    package let remoteHost: String
    private var tasks: [Task<Void, Never>] = []

    struct State {
        var channel: SecureChannel
        var assembler = ChunkAssembler()
        var nextStream: UInt32 = 1
        var closed = false
        var lastInbound = Date()
        var byeReason: Record.ByeReason?
        var control: (@Sendable (LinkControl) -> Void)?
        var ended: [@Sendable (Record.ByeReason?) -> Void] = []
        var access = RemoteAccess.watch
        var accessChanged: [@Sendable (RemoteAccess) -> Void] = []
        var authorize: (@Sendable (ApprovalProof) -> Bool)?
        var inbound: (@Sendable (String) -> Void)?
    }

    package init(channel: any ByteChannel, reader: ChannelReader, secure: SecureChannel) {
        self.channel = channel
        self.reader = reader
        handshakeHash = secure.handshakeHash
        remoteHost = channel.remoteHost
        state = Locked(State(channel: secure))
        (incoming, inbox) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (outgoing, outbox) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts reading and writing. `first`: a record already read (the one that made it live).
    package func start(first: Record? = nil) {
        if let first { take(first) }
        tasks.append(
            Task.detached { [self] in
                for await record in outgoing {
                    guard let bytes = try? state.withLock({ try $0.channel.seal(record) }) else {
                        end(nil)
                        return
                    }
                    do { try await channel.send(bytes) } catch {
                        end(nil)
                        return
                    }
                    if record.kind == .bye {
                        end(nil)
                        return
                    }
                }
            })
        tasks.append(
            Task.detached { [self] in
                while !isClosed {
                    guard let frame = try? await reader.frame(within: nil) else { break }
                    guard let record = try? state.withLock({ try $0.channel.open(frame) }) else { break }
                    take(record)
                }
                end(nil)
            })
    }

    private func take(_ record: Record) {
        state.withLock { $0.lastInbound = Date() }
        switch record.kind {
        case .app: deliver(record.body)
        case .chunk:
            do {
                if let whole = try state.withLock({ try $0.assembler.add(record) }) { deliver(whole) }
            } catch {
                end(nil)
            }
        case .ping: outbox.yield(Record(.pong, record.body))
        case .pong, .rekey: break
        case .bye:
            let reason = record.body.first.flatMap(Record.ByeReason.init(rawValue:)) ?? .unknown
            state.withLock { $0.byeReason = reason }
            end(reason)
        }
    }

    private func deliver(_ body: Data) {
        guard let type = messageType(body) else {
            end(nil)
            return
        }
        if LinkControl.isControl(type) {
            if let control = LinkControl.decode(body), let handler = state.withLock({ $0.control }) { handler(control) }
        } else {
            state.withLock { $0.inbound }?(type)
            inbox.yield(body)
        }
    }

    // MARK: RemoteLink

    package func send(_ data: Data) {
        guard !isClosed else { return }
        if data.count <= RecordLimits.maxBody {
            outbox.yield(Record(.app, data))
        } else {
            let stream = state.withLock { s -> UInt32 in
                defer { s.nextStream &+= 1 }
                return s.nextStream
            }
            for record in ChunkAssembler.split(data, stream: stream) { outbox.yield(record) }
        }
    }

    package func sendControl(_ control: LinkControl) { send(control.data) }

    package func ping(_ value: UInt64) {
        outbox.yield(Record(.ping, withUnsafeBytes(of: value.bigEndian) { Data($0) }))
    }

    /// Says why, then closes.
    package func bye(_ reason: Record.ByeReason) {
        guard !isClosed else { return }
        outbox.yield(.bye(reason))
        outbox.finish()
    }

    package func close() { bye(.quit) }

    /// Closes at once, without a BYE (a failure).
    private func end(_ reason: Record.ByeReason?) {
        let handlers: [@Sendable (Record.ByeReason?) -> Void]? = state.withLock { s in
            guard !s.closed else { return nil }
            s.closed = true
            return s.ended
        }
        guard let handlers else { return }
        outbox.finish()
        inbox.finish()
        channel.close()
        for task in tasks { task.cancel() }
        for handler in handlers { handler(reason) }
    }

    package var isClosed: Bool { state.withLock { $0.closed } }
    package var lastInbound: Date { state.withLock { $0.lastInbound } }

    package func onControl(_ handler: @escaping @Sendable (LinkControl) -> Void) { state.withLock { $0.control = handler } }
    package func onEnd(_ handler: @escaping @Sendable (Record.ByeReason?) -> Void) { state.withLock { $0.ended.append(handler) } }
    /// Each sync message's type as it arrives (activity for the idle timer).
    package func onInbound(_ handler: @escaping @Sendable (String) -> Void) { state.withLock { $0.inbound = handler } }

    // MARK: Access

    package var access: RemoteAccess { state.withLock { $0.access } }

    package func setAccess(_ access: RemoteAccess) {
        let handlers: [@Sendable (RemoteAccess) -> Void] = state.withLock { s in
            guard s.access != access else { return [] }
            s.access = access
            return s.accessChanged
        }
        for handler in handlers { handler(access) }
    }

    package func observeAccess(_ handler: @escaping @Sendable (RemoteAccess) -> Void) { state.withLock { $0.accessChanged.append(handler) } }

    package func setAuthorizer(_ check: @escaping @Sendable (ApprovalProof) -> Bool) { state.withLock { $0.authorize = check } }

    package func authorizes(_ proof: ApprovalProof) -> Bool { state.withLock { $0.authorize }?(proof) ?? false }
}
