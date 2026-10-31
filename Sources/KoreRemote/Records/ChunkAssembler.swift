import Foundation

/// Puts big messages together from CHUNK records, within the limits.
package struct ChunkAssembler: Sendable {
    private var streams: [UInt32: (next: UInt32, data: Data, limit: Int)] = [:]
    private var buffered = 0

    package init() {}

    /// A chunk's header and bytes.
    package static func chunk(stream: UInt32, seq: UInt32, fin: Bool, _ bytes: Data) -> Record {
        var body = Data()
        body.append(contentsOf: withUnsafeBytes(of: stream.bigEndian) { Array($0) })
        body.append(contentsOf: withUnsafeBytes(of: seq.bigEndian) { Array($0) })
        body.append(fin ? 1 : 0)
        body.append(bytes)
        return Record(.chunk, body)
    }

    /// A message split into chunk records.
    package static func split(_ message: Data, stream: UInt32) -> [Record] {
        let room = RecordLimits.maxBody - 9
        var records: [Record] = []
        var offset = message.startIndex
        var seq: UInt32 = 0
        repeat {
            let end = min(offset + room, message.endIndex)
            records.append(chunk(stream: stream, seq: seq, fin: end == message.endIndex, Data(message[offset..<end])))
            offset = end
            seq += 1
        } while offset < message.endIndex
        return records
    }

    /// Adds a chunk; the whole message once its last piece is in.
    package mutating func add(_ record: Record, limit: Int = RecordLimits.maxApp) throws -> Data? {
        let body = record.body
        guard body.count >= 9 else { throw RecordError.malformed }
        let s = body.startIndex
        let stream = body[s..<(s + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let seq = body[(s + 4)..<(s + 8)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let fin = body[s + 8] != 0
        let bytes = body.dropFirst(9)
        var entry = streams[stream] ?? {
            (0, Data(), limit)
        }()
        if streams[stream] == nil, streams.count >= RecordLimits.maxStreams { throw RecordError.tooManyStreams }
        guard seq == entry.next else { throw RecordError.outOfOrder }
        guard entry.data.count + bytes.count <= entry.limit, buffered + bytes.count <= RecordLimits.maxBuffered else {
            throw RecordError.tooBig
        }
        entry.data.append(bytes)
        entry.next += 1
        buffered += bytes.count
        if fin {
            streams[stream] = nil
            buffered -= entry.data.count
            return entry.data
        }
        streams[stream] = entry
        return nil
    }
}
