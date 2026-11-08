import Foundation
import HostClient
import LinkProtocol
import src

/// The box's end of a link, scripted by a test: frames over a pair of pipes, as `kore-host attach`
/// would carry them over SSH.
@MainActor
final class FakeHost {
    let transport: PipeTransport
    private var inbox: [[String: Any]] = []
    private var pump: Task<Void, Never>?
    private(set) var closed = false

    init(transport: PipeTransport) {
        self.transport = transport
        try? transport.start()
        pump = Task { [weak self] in
            for await event in transport.events {
                switch event {
                case .frame(let data):
                    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                    self?.inbox.append(object)
                case .closed:
                    self?.closed = true
                }
            }
        }
    }

    /// A client transport and the host on its other end.
    static func pair() -> (client: PipeTransport, host: FakeHost) {
        let toHost = Pipe(), toClient = Pipe()
        let client = PipeTransport(input: toClient.fileHandleForReading, output: toHost.fileHandleForWriting)
        let host = PipeTransport(input: toHost.fileHandleForReading, output: toClient.fileHandleForWriting)
        return (client, FakeHost(transport: host))
    }

    func send(_ message: LinkMessage) { transport.send((try? message.encoded()) ?? Data()) }

    func send(json object: [String: Any]) {
        transport.send((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }

    /// The next message of that type the client sent, waiting for it.
    func next(_ type: String, within seconds: Double = 3) async -> [String: Any]? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let i = inbox.firstIndex(where: { $0["t"] as? String == type }) { return inbox.remove(at: i) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Everything the client sent that wasn't taken yet.
    var pending: [[String: Any]] { inbox }

    func close() { transport.close() }

    /// Challenge, hello, welcome and snapshot.
    func handshake(windows: [LinkWindow], chats: [ChatMeta]) async -> [String: Any]? {
        send(.challenge(nonce: "bm9uY2U="))
        guard let hello = await next("hello") else { return nil }
        send(json: [
            "t": "welcome", "proto": ["major": 1, "minor": 6], "epoch": "e1",
            "host": ["name": "mybox", "koreVersion": "1", "kind": "box"], "providers": [],
            "policy": ["sendMaxLevel": 4, "control": "full"], "caps": ["tx", "control", "stream"],
        ])
        send(.snapshot(rev: 1, windows: windows, chats: chats, extras: nil))
        return hello
    }
}

/// Waits for a condition on the main actor.
@MainActor
func until(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// What a backend said, collected as it says it.
@MainActor
final class EventLog {
    private(set) var events: [ChatEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<ChatEvent>) {
        task = Task { [weak self] in
            for await event in stream { self?.events.append(event) }
        }
    }

    var texts: [String] {
        flat.compactMap {
            if case .text(_, _, let text, _) = $0 { return text }
            return nil
        }
    }

    /// Replays opened up, in order.
    var flat: [ChatEvent] {
        events.flatMap { event -> [ChatEvent] in
            switch event {
            case .replayed(let inner), .historyReplaced(let inner): inner
            default: [event]
            }
        }
    }
}

enum Fixture {
    static let folder = "~/app"

    static func window(_ chats: [String]) -> LinkWindow {
        LinkWindow(
            id: "w1", name: "app", path: folder, tabs: chats.enumerated().map { LinkTab(id: "t\($0.offset)", kind: .chat, title: "", chatId: $0.element) },
            activeTabId: "t0")
    }

    static func meta(_ id: String, title: String = "Totals", mode: String = "default", running: Bool = false, cards: [LinkCard] = []) -> ChatMeta {
        ChatMeta(
            id: id, provider: "claude", title: title, state: running ? .working : .idle, mode: .init(id: mode, level: .manual),
            modeIds: ["default", "plan"], allowedModeIds: ["default", "plan"], model: "Haiku", queued: 0, running: running, cards: cards,
            can: .init(send: true, stop: running))
    }

    static func user(_ id: String, _ text: String) -> LinkEntry { LinkEntry(id: id, kind: .user, text: text, textLen: text.count, done: true) }

    static func answer(_ id: String, _ text: String, turn: String, done: Bool = true) -> LinkEntry {
        LinkEntry(id: id, kind: .answer, turn: turn, text: text, textLen: text.count, done: done)
    }

    static func turn(_ id: String, finished: Bool) -> LinkTurn {
        LinkTurn(id: id, startedAt: 1_700_000_000_000, duration: finished ? 2 : nil, finished: finished, outcome: .completed)
    }

    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hostclient-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
