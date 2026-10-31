import Foundation
import Testing

@testable import KoreRemote

/// Records, frames and chunk streams: their limits, and refusals.
@Suite("records")
struct RecordTests {
    @Test func unknownTypeIsRefused() throws {
        var padded = try Record(.app, Data("x".utf8)).padded()
        padded[padded.startIndex] = 99
        #expect(throws: RecordError.unknownType) { try Record(padded: padded) }
    }

    @Test func missingMarkerIsRefused() {
        #expect(throws: RecordError.malformed) { try Record(padded: Data([1, 2, 3, 0, 0])) }
    }

    @Test func tooBigABodyIsRefused() {
        #expect(throws: RecordError.tooBig) { try Record(.app, Data(count: RecordLimits.maxBody + 1)).padded() }
        #expect(throws: Never.self) { try Record(.app, Data(count: RecordLimits.maxBody)).padded() }
    }

    @Test func framesSplitAndRefuseTooShort() throws {
        var reader = FrameReader()
        let a = try FrameReader.frame(Data(count: 20))
        let b = try FrameReader.frame(Data(count: 30))
        reader.feed(a + b.prefix(5))
        #expect(try reader.next()?.count == 20)
        #expect(try reader.next() == nil)
        reader.feed(b.dropFirst(5))
        #expect(try reader.next()?.count == 30)
        var short = FrameReader()
        short.feed(Data([0, 3, 1, 2, 3]))
        #expect(throws: RecordError.malformed) { try short.next() }
    }

    @Test func chunksReassembleWithinLimits() throws {
        let message = Data((0..<200_000).map { UInt8($0 % 251) })
        var assembler = ChunkAssembler()
        var whole: Data?
        for record in ChunkAssembler.split(message, stream: 4) { whole = try assembler.add(record) ?? whole }
        #expect(whole == message)
        // Over the JSON limit.
        var big = ChunkAssembler()
        let tooBig = Data(count: RecordLimits.maxApp + 1)
        #expect(throws: RecordError.tooBig) {
            for record in ChunkAssembler.split(tooBig, stream: 1) { _ = try big.add(record) }
        }
        // Out of order, and a third stream at once.
        var order = ChunkAssembler()
        #expect(throws: RecordError.outOfOrder) { _ = try order.add(ChunkAssembler.chunk(stream: 1, seq: 1, fin: false, Data([1]))) }
        var streams = ChunkAssembler()
        _ = try streams.add(ChunkAssembler.chunk(stream: 1, seq: 0, fin: false, Data([1])))
        _ = try streams.add(ChunkAssembler.chunk(stream: 2, seq: 0, fin: false, Data([1])))
        #expect(throws: RecordError.tooManyStreams) { _ = try streams.add(ChunkAssembler.chunk(stream: 3, seq: 0, fin: false, Data([1]))) }
    }

    /// Two ends of a session: every record arrives; a flipped bit, a dropped, a repeated or a
    /// reordered record ends it; REKEY keeps both directions in step.
    @Test func secureChannelRefusesTampering() throws {
        func pair() -> (SecureChannel, SecureChannel) {
            let k1 = Data(repeating: 1, count: 32)
            let k2 = Data(repeating: 2, count: 32)
            return (
                SecureChannel(send: NoiseCipher(key: k1), receive: NoiseCipher(key: k2), handshakeHash: Data(count: 32)),
                SecureChannel(send: NoiseCipher(key: k2), receive: NoiseCipher(key: k1), handshakeHash: Data(count: 32))
            )
        }
        func frames(_ data: Data) throws -> [Data] {
            var reader = FrameReader()
            reader.feed(data)
            var out: [Data] = []
            while let f = try reader.next() { out.append(f) }
            return out
        }
        var (a, b) = pair()
        let one = try frames(try a.seal(Record(.app, Data("one".utf8))))[0]
        let two = try frames(try a.seal(Record(.app, Data("two".utf8))))[0]
        #expect(try b.open(one).body == Data("one".utf8))
        // Repeated
        var repeated = b
        #expect(throws: Noise.Failure.decrypt) { try repeated.open(one) }
        // Flipped
        var flipped = b
        var bad = two
        bad[bad.startIndex + 3] ^= 0x10
        #expect(throws: Noise.Failure.decrypt) { try flipped.open(bad) }
        // Dropped (skip two, take three)
        let three = try frames(try a.seal(Record(.app, Data("three".utf8))))[0]
        var dropped = b
        #expect(throws: Noise.Failure.decrypt) { try dropped.open(three) }
        #expect(try b.open(two).body == Data("two".utf8))
        #expect(try b.open(three).body == Data("three".utf8))

        // REKEY after the limit: both sides follow; dropping the REKEY breaks the next one.
        var (c, d) = pair()
        _ = c.forceRekey()
        let rekeyed = try frames(try c.seal(Record(.app, Data("after".utf8))))
        #expect(rekeyed.count == 2)
        var skipRekey = d
        #expect(try d.open(rekeyed[0]).kind == .rekey)
        #expect(try d.open(rekeyed[1]).body == Data("after".utf8))
        #expect(throws: Noise.Failure.decrypt) { try skipRekey.open(rekeyed[1]) }
    }

    @Test func pairingCodeIsStrict() throws {
        let code = PairingCode(macKey: Data(repeating: 1, count: 32), secret: Data(repeating: 2, count: 32), relay: "relay.example.dev", mailbox: Data(repeating: 3, count: 16))
        #expect(PairingCode(text: code.text) == code)
        // A host name only; nothing trailing; no other prefix.
        let bad = PairingCode(macKey: Data(count: 32), secret: Data(count: 32), relay: "relay/../x", mailbox: Data(count: 16))
        #expect(PairingCode(text: bad.text) == nil)
        #expect(PairingCode(text: code.text + "AA") == nil)
        #expect(PairingCode(text: "kore://" + code.text) == nil)
    }

    @Test func prefaceParsing() {
        #expect(Preface.parse(Data([0x4B, 0x52, 1, 1])) == .ok(Preface(kind: .pair)))
        #expect(Preface.parse(Data([0x4B, 0x52, 2, 1])) == .unsupported)
        #expect(Preface.parse(Data([0x4B, 0x52, 1, 9])) == .garbage)
        #expect(Preface.parse(Data("GET ".utf8)) == .garbage)
    }

    @Test func namesAreSanitized() {
        #expect(RemoteGate.sanitize("Pixel\u{202E}9\u{200B}") == "Pixel9")
        #expect(RemoteGate.sanitize(String(repeating: "a", count: 60)).count == 40)
        #expect(RemoteGate.sanitize("\u{0007}") == "A phone")
    }
}
