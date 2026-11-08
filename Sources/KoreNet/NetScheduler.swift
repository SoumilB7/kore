import Foundation

/// What goes on the wire next (phase 18 §1 "Two queues"): any interactive frame strictly ahead of
/// any stream frame; within a queue, streams take turns a fragment at a time and each stream's
/// messages stay in order. Stream frames spend the peer's credit and wait when it's gone;
/// interactive frames never do. One frame is taken per writable socket, so something queued later
/// on the interactive queue still overtakes a large stream message already started.
package struct NetScheduler: Sendable {
    private struct Pending: Sendable {
        var payload: Data
        var sent = 0
        var remaining: Int { payload.count - sent }
    }

    private struct Lane: Sendable {
        var stream: UInt32
        var messages: [Pending]
    }

    private var lanes: [NetFrame.Queue: [Lane]] = [.interactive: [], .stream: []]
    /// Stream-queue payload bytes the peer will still take.
    package private(set) var credit: Int
    package private(set) var queuedBytes: [NetFrame.Queue: Int] = [.interactive: 0, .stream: 0]

    package init(credit: Int) { self.credit = credit }

    package var isEmpty: Bool { lanes.values.allSatisfy(\.isEmpty) }

    /// Whether `stream` has messages waiting on the other queue (a stream lives on one queue at a
    /// time: the peer reassembles by stream id).
    package func busy(_ stream: UInt32, otherThan queue: NetFrame.Queue) -> Bool {
        lanes.contains { $0.key != queue && $0.value.contains { $0.stream == stream } }
    }

    package mutating func enqueue(_ payload: Data, queue: NetFrame.Queue, stream: UInt32) {
        precondition(!busy(stream, otherThan: queue), "stream \(stream) is on the other queue")
        queuedBytes[queue, default: 0] += payload.count
        if let i = lanes[queue]!.firstIndex(where: { $0.stream == stream }) {
            lanes[queue]![i].messages.append(Pending(payload: payload))
        } else {
            lanes[queue]!.append(Lane(stream: stream, messages: [Pending(payload: payload)]))
        }
    }

    /// The peer's `credit` message.
    package mutating func grant(_ bytes: Int) {
        credit = min(credit + max(bytes, 0), Int(Int32.max))
    }

    /// The next frame, or nil when nothing can go (empty, or only stream frames without credit).
    package mutating func next() -> NetFrame? {
        if let frame = take(.interactive, budget: .max) { return frame }
        guard credit > 0 else { return nil }
        guard let frame = take(.stream, budget: credit) else { return nil }
        credit -= frame.payload.count
        return frame
    }

    private mutating func take(_ queue: NetFrame.Queue, budget: Int) -> NetFrame? {
        guard var lane = lanes[queue]!.first else { return nil }
        lanes[queue]!.removeFirst()
        var message = lane.messages[0]
        let size = min(NetFrame.maxPayload, message.remaining, budget)
        let start = message.payload.startIndex + message.sent
        let chunk = message.payload.subdata(in: start..<(start + size))
        message.sent += size
        let done = message.remaining == 0
        if done {
            lane.messages.removeFirst()
        } else {
            lane.messages[0] = message
        }
        queuedBytes[queue, default: 0] -= size
        // Its turn is over: to the back, unless it has nothing left.
        if !lane.messages.isEmpty { lanes[queue]!.append(lane) }
        return NetFrame(queue: queue, flags: done ? [] : .more, stream: lane.stream, payload: chunk)
    }
}
