import Foundation
@testable import KoreNet
import Testing

/// Framing limits, reassembly, and the two-queue scheduler with stream credit.
@Suite("frames and scheduler")
struct FrameTests {
    @Test func roundTripAcrossArbitrarySplits() throws {
        let frames = [
            NetFrame(queue: .interactive, stream: 0, payload: Data("{}".utf8)),
            NetFrame(queue: .stream, flags: .more, stream: 4, payload: Data(repeating: 1, count: 70)),
            NetFrame(queue: .interactive, stream: 2, payload: Data()),
            NetFrame(queue: .stream, stream: 4, payload: Data(repeating: 2, count: 30)),
        ]
        let wire = frames.reduce(Data()) { $0 + $1.encoded }
        for split in [1, 3, 10, 11, 64, wire.count] {
            var decoder = NetFrameDecoder(preAuth: false)
            var got: [NetMessage] = []
            var at = 0
            while at < wire.count {
                got += try decoder.feed(wire.subdata(in: at..<min(at + split, wire.count)))
                at += split
            }
            #expect(got == [
                NetMessage(queue: .interactive, stream: 0, payload: Data("{}".utf8)),
                NetMessage(queue: .interactive, stream: 2, payload: Data()),
                NetMessage(queue: .stream, stream: 4, payload: Data(repeating: 1, count: 70) + Data(repeating: 2, count: 30)),
            ], "split \(split)")
            #expect(decoder.pending == 0)
        }
    }

    @Test func maxPayloadIsAllowedOneMoreIsNot() throws {
        var decoder = NetFrameDecoder(preAuth: false)
        let full = NetFrame(queue: .stream, stream: 1, payload: Data(count: NetFrame.maxPayload))
        #expect(try decoder.feed(full.encoded).count == 1)
        var header = Data()
        header.appendBig(UInt32(NetFrame.maxPayload + 1))
        header += Data([1, 0, 0, 0, 0, 1])
        #expect(throws: NetFrameError.tooLong(NetFrame.maxPayload + 1)) { try decoder.feed(header) }
    }

    @Test func partialStreamsAndMessageSizeAreBounded() throws {
        var decoder = NetFrameDecoder(preAuth: false)
        for stream in 1...UInt32(NetFrame.maxPartialStreams) {
            _ = try decoder.feed(NetFrame(queue: .stream, flags: .more, stream: stream, payload: Data([1])).encoded)
        }
        #expect(throws: NetFrameError.tooManyStreams) {
            try decoder.feed(NetFrame(queue: .stream, flags: .more, stream: 999, payload: Data([1])).encoded)
        }
        var big = NetFrameDecoder(preAuth: false)
        let chunk = NetFrame(queue: .stream, flags: .more, stream: 1, payload: Data(count: NetFrame.maxPayload)).encoded
        for _ in 0..<(NetFrame.maxMessage / NetFrame.maxPayload) { _ = try big.feed(chunk) }
        #expect(throws: NetFrameError.messageTooLong) { try big.feed(NetFrame(queue: .stream, stream: 1, payload: Data([0])).encoded) }
    }

    @Test func preAuthTakesOneSmallControlFrame() throws {
        var decoder = NetFrameDecoder(preAuth: true)
        let hello = NetFrame(queue: .interactive, stream: 0, payload: Data(count: NetFrame.preAuthMaxFrame - NetFrame.headerSize))
        #expect(try decoder.feed(hello.encoded).count == 1)
        #expect(throws: NetFrameError.preAuth("a second frame")) { try decoder.feed(hello.encoded) }
        var big = NetFrameDecoder(preAuth: true)
        let over = NetFrame(queue: .interactive, stream: 0, payload: Data(count: NetFrame.preAuthMaxFrame - NetFrame.headerSize + 1))
        #expect(throws: NetFrameError.preAuth("frame of 4087 bytes")) { try big.feed(over.encoded.prefix(NetFrame.headerSize)) }
    }

    @Test func schedulerFragmentsAtTheLimit() {
        var s = NetScheduler(credit: .max)
        s.enqueue(Data(count: NetFrame.maxPayload * 2 + 5), queue: .stream, stream: 3)
        var frames: [NetFrame] = []
        while let f = s.next() { frames.append(f) }
        #expect(frames.map(\.payload.count) == [NetFrame.maxPayload, NetFrame.maxPayload, 5])
        #expect(frames.map(\.flags) == [.more, .more, []])
        #expect(s.isEmpty)
    }

    /// An interactive message queued after a 1 MiB stream message started goes out next, not after
    /// the remaining 15 fragments.
    @Test func interactiveOvertakesAOneMebibyteStream() throws {
        var s = NetScheduler(credit: .max)
        s.enqueue(Data(repeating: 7, count: 1 << 20), queue: .stream, stream: 9)
        let taken = s.next()
        let first = try #require(taken)
        #expect(first.queue == .stream && first.flags == .more)
        s.enqueue(Data("{\"cmd\":\"stop\"}".utf8), queue: .interactive, stream: 2)
        let next = s.next()
        let second = try #require(next)
        #expect(second.queue == .interactive && second.stream == 2 && second.flags == [])
        // The rest of the stream message follows, and the receiver rebuilds both.
        var decoder = NetFrameDecoder(preAuth: false)
        var got = try decoder.feed(first.encoded + second.encoded)
        while let frame = s.next() { got += try decoder.feed(frame.encoded) }
        #expect(got.map(\.stream) == [2, 9])
        #expect(got[1].payload == Data(repeating: 7, count: 1 << 20))
    }

    @Test func streamsTakeTurnsAndKeepTheirOwnOrder() {
        var s = NetScheduler(credit: .max)
        s.enqueue(Data(count: NetFrame.maxPayload + 1), queue: .stream, stream: 1)
        s.enqueue(Data([1]), queue: .stream, stream: 1)
        s.enqueue(Data(count: NetFrame.maxPayload + 1), queue: .stream, stream: 2)
        var order: [UInt32] = []
        while let f = s.next() { order.append(f.stream) }
        #expect(order == [1, 2, 1, 2, 1])
    }

    @Test func streamFramesWaitForCreditInteractiveNever() {
        var s = NetScheduler(credit: 100)
        s.enqueue(Data(count: 250), queue: .stream, stream: 1)
        #expect(s.next()?.payload.count == 100)
        #expect(s.next() == nil)
        s.enqueue(Data(count: 10), queue: .interactive, stream: 2)
        #expect(s.next()?.queue == .interactive)
        s.grant(200)
        #expect(s.next()?.payload.count == 150)
        #expect(s.credit == 50)
        #expect(s.isEmpty)
    }
}
