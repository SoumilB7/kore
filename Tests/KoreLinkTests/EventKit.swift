import Darwin
import Foundation
import KoreNet
import KoreTrust
import Synchronization
import Tailnet

/// Things that happen, awaited as they happen: each `next` takes the first one that matches,
/// already here or still to come. No polling, no wall clock; a suite's time limit bounds a hang.
final class Feed<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var waiters: [(match: (T) -> Bool, wake: CheckedContinuation<T, Never>)] = []

    init() {}

    func send(_ item: T) {
        lock.lock()
        if let i = waiters.firstIndex(where: { $0.match(item) }) {
            let waiter = waiters.remove(at: i)
            lock.unlock()
            waiter.wake.resume(returning: item)
            return
        }
        items.append(item)
        lock.unlock()
    }

    @discardableResult
    func next(_ match: @escaping @Sendable (T) -> Bool = { _ in true }) async -> T {
        await withCheckedContinuation { wake in
            lock.lock()
            if let i = items.firstIndex(where: match) {
                let item = items.remove(at: i)
                lock.unlock()
                wake.resume(returning: item)
                return
            }
            waiters.append((match, wake))
            lock.unlock()
        }
    }
}

/// Returns once everything already queued on the main queue has run (an Observation callback's
/// hop, a connection's event): an ordering point, never a wait for time.
@MainActor
func drainMain() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
}

/// A JSON object handed across queues.
struct Object: @unchecked Sendable {
    var fields: [String: Any]
    var type: String? { fields["t"] as? String }
    var id: String? { fields["id"] as? String }
    subscript(_ key: String) -> Any? { fields[key] }
}

/// One end of a KoreNet session driven by its socket on a queue of its own (as a phone's is):
/// what arrives is fed to `events`, as it arrives.
final class LiveEnd: @unchecked Sendable {
    enum Event: Sendable {
        case up
        case message(Object)
        case pong(Int)
        case closed(String)
    }

    let events = Feed<Event>()
    private let queue = DispatchQueue(label: "test.live-end")
    private let session: NetSession
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var toldUp = false
    private var toldClosed = false
    private var lastPong: Int?
    private let seen = Mutex<[String]>([])

    init(_ session: NetSession) {
        self.session = session
        queue.async { [self] in
            let fd = Darwin.dup(self.session.descriptor)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.pump() }
            source.setCancelHandler { Darwin.close(fd) }
            reader = source
            source.resume()
            pump()
        }
    }

    deinit {
        reader?.cancel()
        writer?.cancel()
    }

    /// The types that came, in order.
    var types: [String] { seen.withLock { $0 } }

    func send(_ json: String) {
        queue.async { [self] in
            try? session.send(Data(json.utf8), queue: .interactive, stream: 1)
            pump()
        }
    }

    func ping() -> Int? {
        let n = queue.sync { session.ping() }
        queue.async { [self] in pump() }
        return n
    }

    func close(_ reason: String) {
        queue.async { [self] in
            session.close(reason)
            pump()
        }
    }

    var binding: Data? { queue.sync { session.bindingDigest } }
    var peer: NetPeer? { queue.sync { if case .established(let p) = session.state { p } else { nil } } }
    var directory: [DeviceRecord]? { queue.sync { session.directory } }

    // MARK: Awaiting

    func up() async { await events.next { if case .up = $0 { true } else { false } } }

    /// The next message of type `t` (and `id`, when given).
    @discardableResult
    func next(_ t: String, id: String? = nil) async -> Object {
        let event = await events.next {
            if case .message(let o) = $0 { o.type == t && (id == nil || o.id == id) } else { false }
        }
        if case .message(let o) = event { return o }
        return Object(fields: [:])
    }

    /// Why the session ended.
    func closed() async -> String {
        if case .closed(let why) = await events.next({ if case .closed = $0 { true } else { false } }) { return why }
        return ""
    }

    func pong(_ n: Int) async { await events.next { if case .pong(n) = $0 { true } else { false } } }

    private func pump() {
        guard !toldClosed else { return }
        let messages = session.pump()
        if case .established = session.state, !toldUp {
            toldUp = true
            events.send(.up)
        }
        for message in messages {
            guard let fields = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any] else { continue }
            let object = Object(fields: fields)
            seen.withLock { $0.append(object.type ?? "?") }
            events.send(.message(object))
        }
        if let pong = session.lastPong, pong != lastPong {
            lastPong = pong
            events.send(.pong(pong))
        }
        if case .closed(let why) = session.state {
            toldClosed = true
            reader?.cancel()
            writer?.cancel()
            events.send(.closed(why))
            return
        }
        if session.wantsWrite, writer == nil {
            let fd = Darwin.dup(session.descriptor)
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.writer?.cancel()
                self.writer = nil
                self.pump()
            }
            source.setCancelHandler { Darwin.close(fd) }
            writer = source
            source.resume()
        }
    }
}
