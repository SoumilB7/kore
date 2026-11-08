import Foundation
import LinkProtocol

/// The local copy of one box: under `~/Library/Application Support/Kore/hosts/<alias>/`, the box's
/// last state (`state.json`: windows, chats, the CLIs, folders, when it last spoke) and one log per
/// followed chat (`chats/<id>.log`). A chat's log is append-only: a base line with the whole
/// transcript as the client holds it, then each delta exactly as it came. A page writes a new base.
/// Writes go on a queue of their own; reads happen once, when a chat or window opens.
package final class HostCache: Sendable {
    package let folder: URL
    private let queue = DispatchQueue(label: "kore.host.cache")

    package static func root() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Kore/hosts", isDirectory: true)
    }

    package init(alias: String, root: URL = HostCache.root()) {
        folder = root.appendingPathComponent(Self.safe(alias), isDirectory: true)
    }

    /// A name that stays one path part.
    static func safe(_ name: String) -> String {
        let kept = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-@".unicodeScalars.contains($0) ? Character($0) : "_" }
        let text = String(kept)
        return text.isEmpty || text.hasPrefix(".") ? "_" + text : text
    }

    private var chats: URL { folder.appendingPathComponent("chats", isDirectory: true) }
    private func log(_ chatId: String) -> URL { chats.appendingPathComponent(Self.safe(chatId) + ".log") }
    private var stateFile: URL { folder.appendingPathComponent("state.json") }

    // MARK: State

    package struct State: Codable, Sendable, Equatable {
        package var windows: [LinkWindow] = []
        package var chats: [ChatMeta] = []
        package var clis: [CLIState] = []
        package var providers: [ProviderInfo] = []
        package var folders: [BoxFolder] = []
        /// When the box last said anything, in seconds since 1970.
        package var updated: Double?

        package init() {}
    }

    package func state() -> State? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    package func save(_ state: State) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(state) else { return }
            make(folder)
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    // MARK: Chats

    /// The whole transcript as the client holds it.
    package struct Base: Codable, Sendable, Equatable {
        package var order: [String]
        /// The ids of `order` the box's window holds now; the rest came before it.
        package var window: [String]
        package var entries: [LinkEntry]
        package var turns: [LinkTurn]
        package var hasEarlier: Bool
        package var seq: Int?
    }

    /// One chat's log as written: its base, then its deltas in order.
    package struct Log: Sendable {
        package var base: Base?
        package var deltas: [(delta: LinkMessage.TxDelta, seq: Int?)]
    }

    package func read(chat chatId: String) -> Log {
        guard let data = try? Data(contentsOf: log(chatId)) else { return Log(base: nil, deltas: []) }
        var result = Log(base: nil, deltas: [])
        for line in data.split(separator: 0x0A) where line.count > 2 {
            let kind = line[line.startIndex]
            let body = Data(line.dropFirst(2))
            if kind == UInt8(ascii: "B") {
                result.base = try? JSONDecoder().decode(Base.self, from: body)
                result.deltas = []
            } else if kind == UInt8(ascii: "D"), case .link(.txDelta(let delta), let seq)? = try? HostWire.decode(body) {
                result.deltas.append((delta, seq))
            }
        }
        return result
    }

    /// A new base: the log starts again from it.
    package func write(base: Base, chat chatId: String) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(base) else { return }
            make(chats)
            try? (Data("B ".utf8) + data + Data([0x0A])).write(to: log(chatId), options: .atomic)
        }
    }

    /// A delta, as its bytes came.
    package func append(delta raw: Data, chat chatId: String) {
        queue.async { [self] in
            let url = log(chatId)
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("D ".utf8) + raw + Data([0x0A]))
        }
    }

    package func forget(chat chatId: String) {
        queue.async { [self] in try? FileManager.default.removeItem(at: log(chatId)) }
    }

    /// Waits for the writes queued so far (tests, and before reading back).
    package func flush() { queue.sync {} }

    private func make(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
