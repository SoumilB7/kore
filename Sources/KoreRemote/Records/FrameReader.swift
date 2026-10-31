import Foundation

/// Splits a byte stream into `u16 length ‖ Noise message` frames.
package struct FrameReader: Sendable {
    private var buffer = Data()
    /// The least a frame may be (an empty AEAD payload is still its tag).
    package var minimum = Noise.tagLen

    package init() {}

    package mutating func feed(_ bytes: Data) { buffer.append(bytes) }

    /// The next whole frame, if one has arrived.
    package mutating func next() throws -> Data? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer[start]) << 8 | Int(buffer[start + 1])
        guard length >= minimum else { throw RecordError.malformed }
        guard buffer.count >= 2 + length else { return nil }
        let frame = Data(buffer[(start + 2)..<(start + 2 + length)])
        buffer = Data(buffer[(start + 2 + length)...])
        return frame
    }

    /// Bytes waiting for the rest of their frame.
    package var pending: Int { buffer.count }

    package static func frame(_ message: Data) throws -> Data {
        guard message.count <= Noise.maxMessage else { throw RecordError.tooBig }
        return Data([UInt8(message.count >> 8), UInt8(message.count & 0xff)]) + message
    }
}
