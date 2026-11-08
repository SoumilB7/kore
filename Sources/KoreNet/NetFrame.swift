import Foundation

/// Link 2.0's framing (phase 18 §1): `u32 len | u8 queue | u8 flags | u32 stream | payload`, big
/// endian, `len` counting the payload only. A message longer than one frame is cut into fragments
/// of at most `maxPayload` with MORE set on all but the last; fragments of different streams
/// interleave, so a large stream message never holds up an interactive one.
/// `Tests/Fixtures/link/v2/frames.json` holds worked encodings.
package struct NetFrame: Equatable, Sendable {
    package static let headerSize = 10
    package static let maxPayload = 64 << 10
    /// The largest whole message (a reassembled stream message).
    package static let maxMessage = 16 << 20
    /// Messages being reassembled at once, per connection.
    package static let maxPartialStreams = 64
    /// Before the hello is verified: one frame, header included, no fragments.
    package static let preAuthMaxFrame = 4 << 10
    /// Stream 0 is the session's own (challenge, hello, welcome, credit, bye), interactive only.
    package static let controlStream: UInt32 = 0

    package enum Queue: UInt8, Sendable, CaseIterable {
        /// Control, commands and results, nav reads, pty input, the first pty output after quiet.
        case interactive = 0
        /// Catch-up events, transcript pages, blobs, file reads, pty floods; under stream credit.
        case stream = 1
    }

    package struct Flags: OptionSet, Hashable, Sendable {
        package let rawValue: UInt8
        package init(rawValue: UInt8) { self.rawValue = rawValue }
        package static let more = Flags(rawValue: 1 << 0)
        package static let known: Flags = [.more]
    }

    package var queue: Queue
    package var flags: Flags
    package var stream: UInt32
    package var payload: Data

    package init(queue: Queue, flags: Flags = [], stream: UInt32, payload: Data) {
        self.queue = queue
        self.flags = flags
        self.stream = stream
        self.payload = payload
    }

    package var encoded: Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.appendBig(UInt32(payload.count))
        out.append(queue.rawValue)
        out.append(flags.rawValue)
        out.appendBig(stream)
        out.append(payload)
        return out
    }
}

package enum NetFrameError: Error, Equatable, CustomStringConvertible {
    case tooLong(Int)
    case badQueue(UInt8)
    case badFlags(UInt8)
    case messageTooLong
    case tooManyStreams
    case queueChanged(UInt32)
    case control(String)
    case preAuth(String)

    package var description: String {
        switch self {
        case .tooLong(let n): "frame of \(n) bytes"
        case .badQueue(let q): "unknown queue \(q)"
        case .badFlags(let f): "unknown flags \(f)"
        case .messageTooLong: "message too long"
        case .tooManyStreams: "too many partial messages"
        case .queueChanged(let s): "stream \(s) changed queue mid-message"
        case .control(let why): "control stream: \(why)"
        case .preAuth(let why): "before hello: \(why)"
        }
    }
}

/// A whole message off the wire.
package struct NetMessage: Equatable, Sendable {
    package var queue: NetFrame.Queue
    package var stream: UInt32
    package var payload: Data

    package init(queue: NetFrame.Queue, stream: UInt32, payload: Data) {
        self.queue = queue
        self.stream = stream
        self.payload = payload
    }
}

/// Bytes in, whole messages out, every limit checked as the bytes arrive: a violation is an
/// error and the connection ends.
package struct NetFrameDecoder: Sendable {
    /// Before the hello is verified (one small frame), or after.
    package var preAuth: Bool
    private var buffer = Data()
    private var partial: [UInt32: (queue: NetFrame.Queue, bytes: Data)] = [:]
    /// Frames taken while `preAuth`.
    package private(set) var preAuthFrames = 0
    /// Stream-queue payload bytes taken off the wire since the last `takeStreamBytes()`: what the
    /// receiver gives back as credit (fragments count as they land, so a message larger than the
    /// window still completes).
    private var streamBytes = 0

    package mutating func takeStreamBytes() -> Int {
        defer { streamBytes = 0 }
        return streamBytes
    }

    package init(preAuth: Bool) { self.preAuth = preAuth }

    /// Lets one more pre-auth frame in: the client's welcome after its challenge.
    package mutating func expectAnotherPreAuthFrame() { preAuthFrames = 0 }

    /// Bytes held but not yet a whole frame.
    package var pending: Int { buffer.count }

    package mutating func feed(_ bytes: Data) throws -> [NetMessage] {
        buffer.append(bytes)
        var out: [NetMessage] = []
        while buffer.count >= NetFrame.headerSize {
            let base = buffer.startIndex
            let length = Int(buffer.readBig(at: base))
            let queueByte = buffer[base + 4]
            let flagsByte = buffer[base + 5]
            let stream = buffer.readBig(at: base + 6)
            let limit = preAuth ? NetFrame.preAuthMaxFrame - NetFrame.headerSize : NetFrame.maxPayload
            guard length <= limit else { throw preAuth ? NetFrameError.preAuth("frame of \(length) bytes") : NetFrameError.tooLong(length) }
            guard let queue = NetFrame.Queue(rawValue: queueByte) else { throw NetFrameError.badQueue(queueByte) }
            let flags = NetFrame.Flags(rawValue: flagsByte)
            guard NetFrame.Flags.known.isSuperset(of: flags) else { throw NetFrameError.badFlags(flagsByte) }
            if preAuth {
                guard preAuthFrames == 0 else { throw NetFrameError.preAuth("a second frame") }
                guard !flags.contains(.more), stream == NetFrame.controlStream, queue == .interactive else {
                    throw NetFrameError.preAuth("not one control frame")
                }
            }
            if stream == NetFrame.controlStream {
                guard queue == .interactive, !flags.contains(.more) else { throw NetFrameError.control("fragmented or off the interactive queue") }
            }
            guard buffer.count >= NetFrame.headerSize + length else { break }
            let payload = Data(buffer[(base + NetFrame.headerSize)..<(base + NetFrame.headerSize + length)])
            buffer.removeFirst(NetFrame.headerSize + length)
            if preAuth { preAuthFrames += 1 }
            if queue == .stream { streamBytes += length }
            if let message = try take(queue: queue, flags: flags, stream: stream, payload: payload) { out.append(message) }
        }
        return out
    }

    private mutating func take(queue: NetFrame.Queue, flags: NetFrame.Flags, stream: UInt32, payload: Data) throws -> NetMessage? {
        if var held = partial[stream] {
            guard held.queue == queue else { throw NetFrameError.queueChanged(stream) }
            guard held.bytes.count + payload.count <= NetFrame.maxMessage else { throw NetFrameError.messageTooLong }
            held.bytes.append(payload)
            if flags.contains(.more) {
                partial[stream] = held
                return nil
            }
            partial[stream] = nil
            return NetMessage(queue: queue, stream: stream, payload: held.bytes)
        }
        if flags.contains(.more) {
            guard partial.count < NetFrame.maxPartialStreams else { throw NetFrameError.tooManyStreams }
            partial[stream] = (queue, payload)
            return nil
        }
        return NetMessage(queue: queue, stream: stream, payload: payload)
    }
}

extension Data {
    mutating func appendBig(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func readBig(at index: Index) -> UInt32 {
        (index..<(index + 4)).reduce(UInt32(0)) { $0 << 8 | UInt32(self[$1]) }
    }
}
