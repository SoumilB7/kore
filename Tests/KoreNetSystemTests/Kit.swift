import Darwin
import Foundation
import HostClient
import KoreCore
import KoreHost
@testable import KoreLink
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
import src

@testable import KoreUI

/// Things that happen, awaited as they happen: each `next` takes the first one that matches.
final class Feed<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var waiters: [(match: (T) -> Bool, wake: CheckedContinuation<T, Never>)] = []

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

/// The world's heartbeat: anything that happens anywhere (a dial, a journal line, an audit line,
/// a link up or down, a phone's state) beats it. `quiet` returns true once nothing has beaten
/// for `window`: the only wall-clock wait in the suite, and it ends early on any beat.
final class Pulse: Sendable {
    private let state = Mutex<(beats: Int, waiter: CheckedContinuation<Void, Never>?)>((0, nil))

    func beat() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.beats += 1
            let w = s.waiter
            s.waiter = nil
            return w
        }
        waiter?.resume()
    }

    var beats: Int { state.withLock { $0.beats } }

    /// Work handed off the main actor and not back yet (a listener's bind, a WhoIs): the world
    /// isn't settled while any is under way.
    private let inflight = Mutex(0)
    var busy: Bool { inflight.withLock { $0 > 0 } }
    func began() { inflight.withLock { $0 += 1 } }
    func ended() {
        inflight.withLock { $0 -= 1 }
        beat()
    }

    /// Whether `window` went by without a beat.
    func quiet(_ window: Duration) async -> Bool {
        let before = beats
        let timer = Task {
            try? await Task.sleep(for: window)
            let w = state.withLock { s -> CheckedContinuation<Void, Never>? in
                let w = s.waiter
                s.waiter = nil
                return w
            }
            w?.resume()
        }
        await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if s.beats != before { return true }
                s.waiter?.resume()
                s.waiter = wake
                return false
            }
            if now { wake.resume() }
        }
        timer.cancel()
        return beats == before
    }
}

/// Virtual time: every timer in the world (link backoffs, pings, a phone's retries, its Join
/// knocking) sleeps on it, and only `advance` moves it.
final class VirtualClock: Sendable {
    private struct Sleeper {
        var id: Int
        var end: Duration
        var wake: CheckedContinuation<Void, Never>
    }

    private let held = Mutex<(now: Duration, next: Int, sleepers: [Sleeper])>((.zero, 0, []))
    let pulse: Pulse

    init(pulse: Pulse) { self.pulse = pulse }

    var now: Duration { held.withLock { $0.now } }
    var nowMS: Int64 { let n = now.components; return n.seconds * 1000 + n.attoseconds / 1_000_000_000_000_000 }
    var waiting: Int { held.withLock { $0.sleepers.count } }

    var sleep: @Sendable (Duration) async -> Void { { [self] d in await self.wait(d) } }

    func wait(_ duration: Duration) async {
        let id = held.withLock { h -> Int in
            h.next += 1
            return h.next
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
                let now = held.withLock { h -> Bool in
                    guard !Task.isCancelled else { return true }
                    h.sleepers.append(Sleeper(id: id, end: h.now + duration, wake: wake))
                    return false
                }
                if now { wake.resume() }
            }
        } onCancel: {
            let woken = held.withLock { h -> Sleeper? in
                guard let i = h.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return h.sleepers.remove(at: i)
            }
            woken?.wake.resume()
        }
    }

    /// Moves time on to the next timer's end (at most `limit` ahead); what ends then wakes. Nil
    /// when nothing waits within it.
    @discardableResult
    func advanceToNext(limit: Duration) -> Duration? {
        let (due, step) = held.withLock { h -> ([CheckedContinuation<Void, Never>], Duration?) in
            guard let first = h.sleepers.map(\.end).min(), first - h.now <= limit else { return ([], nil) }
            let step = max(.zero, first - h.now)
            h.now = max(h.now, first)
            let ready = h.sleepers.filter { $0.end <= h.now }
            h.sleepers.removeAll { $0.end <= h.now }
            return (ready.map(\.wake), step)
        }
        for wake in due { wake.resume() }
        if step != nil { pulse.beat() }
        return step
    }

    func advance(_ by: Duration) {
        let due = held.withLock { h -> [CheckedContinuation<Void, Never>] in
            h.now += by
            let ready = h.sleepers.filter { $0.end <= h.now }
            h.sleepers.removeAll { $0.end <= h.now }
            return ready.map(\.wake)
        }
        for wake in due { wake.resume() }
        pulse.beat()
    }
}

/// `kore-host attach --proto 2` in this process: the real `NetAttach` relay between the Mac's
/// socket and the daemon's `net.sock`, as ssh would carry it.
final class InProcessAttach: Sendable {
    let socket: URL
    let grant: Grant
    private let held = Mutex<[NetAttach]>([])
    let reachable = Mutex(true)

    init(socket: URL, grant: Grant) {
        self.socket = socket
        self.grant = grant
    }

    func dial() throws -> (fd: Int32, onClose: @Sendable () -> Void) {
        guard reachable.withLock({ $0 }) else { throw SocketError.failed("ssh", ECONNREFUSED) }
        let (mine, theirs) = try Sockets.pair()
        let attach: NetAttach
        do {
            attach = try NetAttach(grant: grant, socket: socket, input: theirs, output: theirs) { _ in Sockets.closeFD(theirs) }
        } catch {
            Sockets.closeFD(mine)
            Sockets.closeFD(theirs)
            throw error
        }
        attach.start()
        held.withLock { $0.append(attach) }
        return (mine, {})
    }
}

/// `ssh <alias> kore-host attach --as <grant>` (link 1.x, the legacy SSH link): a socket to the
/// in-process daemon, the hello's proof filled in as `kore-host attach` fills it.
final class DaemonTransport: HostTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let path: String
    private let grant: Grant
    private var socket: HostSocket?
    private var nonce: String?
    private var helloSent = false

    init(path: String, grant: Grant) {
        self.path = path
        self.grant = grant
        (events, continuation) = AsyncStream.makeStream()
    }

    func start() throws {
        try MainActor.assumeIsolated {
            let socket = try HostListener.connect(to: path)
            self.socket = socket
            socket.start(
                max: LinkFrame.outboundMax,
                frame: { [weak self] data in
                    if case .challenge(let n)? = try? LinkMessage.decode(data) { self?.nonce = n }
                    self?.continuation.yield(.frame(data))
                },
                ended: { [weak self] in
                    self?.continuation.yield(.closed("gone"))
                    self?.continuation.finish()
                })
        }
    }

    func send(_ payload: Data) {
        MainActor.assumeIsolated {
            guard !helloSent, case .hello(let proto, let client, _, let commands, _)? = try? LinkMessage.decode(payload) else {
                socket?.send(payload)
                return
            }
            helloSent = true
            let proof = LinkProof.proof(secret: Data(base64Encoded: grant.secret) ?? Data(), nonce: nonce ?? "")
            socket?.send(.hello(proto: proto, client: client, proof: proof, commands: commands, grant: grant.name))
        }
    }

    func close() {
        MainActor.assumeIsolated {
            socket?.close()
            continuation.yield(.closed(nil))
            continuation.finish()
        }
    }
}

/// What a phone's feed on the Mac reads: no chats (the suite is about the net, not the chats).
@MainActor
final class EmptySource: LinkFeedSource {
    func chats() -> [String: Chat] { [:] }
    func windows(view: LinkFeed.View) -> [LinkWindow] { [] }
    func meta(_ chat: Chat, view: LinkFeed.View) -> ChatMeta { LinkSnapshot.meta(chat, view: view) }
    func extras(_ chats: [Chat]) -> LinkExtras { LinkExtras(mac: nil, clis: nil) }
}

/// A scratch folder short enough for Unix socket paths.
func scratch(_ tag: String) -> URL {
    let url = URL(fileURLWithPath: "/tmp/kns-\(tag)-\(UUID().uuidString.prefix(6).lowercased())")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
