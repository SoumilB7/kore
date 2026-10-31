import Foundation

/// Bytes both ways on one connection, before any crypto: TCP from the listener, or an in-memory
/// pipe in tests.
package protocol ByteChannel: AnyObject, Sendable {
    /// The caller's address, as text.
    var remoteHost: String { get }
    /// Some bytes, or an error once the connection is gone.
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close()
}

package enum ChannelError: Error, Equatable {
    case closed
    case timedOut
}

/// Reads exact amounts and whole frames off a channel, each within a deadline.
package final class ChannelReader: @unchecked Sendable {
    package let channel: any ByteChannel
    private var buffer = Data()
    private var frames = FrameReader()

    package init(_ channel: any ByteChannel) { self.channel = channel }

    package func exactly(_ count: Int, within seconds: Double) async throws -> Data {
        try await withDeadline(seconds) { [self] in
            while buffer.count < count { buffer.append(try await channel.receive()) }
            let out = Data(buffer.prefix(count))
            buffer = Data(buffer.dropFirst(count))
            return out
        }
    }

    /// The next `u16 ‖ message` frame; refuses a length outside `range` before reading it.
    package func frame(within seconds: Double?, size range: ClosedRange<Int> = Noise.tagLen...Noise.maxMessage) async throws -> Data {
        let read: @Sendable () async throws -> Data = { [self] in
            while buffer.count < 2 { buffer.append(try await channel.receive()) }
            let length = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
            guard range.contains(length) else { throw RecordError.malformed }
            while buffer.count < 2 + length { buffer.append(try await channel.receive()) }
            let out = Data(buffer[(buffer.startIndex + 2)..<(buffer.startIndex + 2 + length)])
            buffer = Data(buffer.dropFirst(2 + length))
            return out
        }
        guard let seconds else { return try await read() }
        return try await withDeadline(seconds, read)
    }
}

/// `body`, or `ChannelError.timedOut` after `seconds`.
package func withDeadline<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ChannelError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
