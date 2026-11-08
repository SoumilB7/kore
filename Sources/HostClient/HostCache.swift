import Foundation
import LinkProtocol
import src

/// The local copy of one box: under `~/Library/Application Support/Kore/hosts/<alias>/`, the box's
/// last state (`state.json`: windows, chats, the CLIs, folders, when it last spoke) and one log per
/// followed chat (`chats/<id>.log`): the box's log id, then each event item as it came (1.5). A
/// reset from the box writes it again.
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

    /// A folder's open chats as this copy last had them (`HostConnection.chats(in:)` offline).
    package func chats(in folder: String) -> [ChatMeta] {
        guard let state = state() else { return [] }
        let byId = Dictionary(state.chats.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        return HostConnection.chats(in: folder, windows: state.windows, folders: state.folders) { byId[$0] }
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

    // MARK: Sends waiting for the box

    /// A forwarded call not answered yet, as its bytes went.
    package struct Pending: Codable, Sendable {
        package var id: String
        package var payload: Data
        /// When it was first asked; one older than `HostCache.sendLifetime` isn't sent.
        package var at: Date?
        /// The chat it's for, to say so there when it's dropped.
        package var chatId: String?
        package init(id: String, payload: Data, at: Date, chatId: String?) {
            self.id = id
            self.payload = payload
            self.at = at
            self.chatId = chatId
        }
    }

    /// How long a message waits for its box across a quit of Kore.
    package static let sendLifetime: TimeInterval = 24 * 3600

    private var outboxFile: URL { folder.appendingPathComponent("outbox.json") }

    package func outbox() -> [Pending] {
        guard let data = try? Data(contentsOf: outboxFile) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    package func saveOutbox(_ pending: [Pending]) {
        queue.async { [self] in
            guard !pending.isEmpty else {
                try? FileManager.default.removeItem(at: outboxFile)
                return
            }
            guard let data = try? JSONEncoder().encode(pending) else { return }
            make(folder)
            try? data.write(to: outboxFile, options: .atomic)
        }
    }

    // MARK: Chats

    /// One chat's events as the box sent them (1.5): the box's log id and its items in order.
    package struct Events: Sendable {
        package var log: String?
        package var items: [StreamItem] = []
    }

    private struct Header: Codable { var log: String }

    package func events(chat chatId: String) -> Events {
        guard let data = try? Data(contentsOf: log(chatId)) else { return Events() }
        var result = Events()
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            if let item = try? decoder.decode(StreamItem.self, from: line) {
                result.items.append(item)
            } else if let header = try? decoder.decode(Header.self, from: line) {
                result = Events(log: header.log)
            }
        }
        return result
    }

    /// The log starts again: the box's log `log`, from `items`.
    package func restart(log id: String, items: [StreamItem], chat chatId: String) {
        queue.async { [self] in
            make(chats)
            var data = StreamWire.encode(Header(log: id)) + Data([0x0A])
            for item in items { data += StreamWire.encode(item) + Data([0x0A]) }
            try? data.write(to: log(chatId), options: .atomic)
        }
    }

    /// Items that followed.
    package func append(_ items: [StreamItem], chat chatId: String) {
        guard !items.isEmpty else { return }
        queue.async { [self] in
            guard let handle = try? FileHandle(forUpdating: log(chatId)) else { return }
            defer { try? handle.close() }
            Self.endOnNewline(handle)
            _ = try? handle.seekToEnd()
            var data = Data()
            for item in items { data += StreamWire.encode(item) + Data([0x0A]) }
            try? handle.write(contentsOf: data)
        }
    }

    /// A torn last line (Kore stopped mid-write) is cut off, so the next isn't glued onto it.
    static func endOnNewline(_ handle: FileHandle) {
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        var at = size
        while at > 0 {
            let from = at > 65536 ? at - 65536 : 0
            try? handle.seek(toOffset: from)
            guard let data = try? handle.read(upToCount: Int(at - from)) else { return }
            if at == size, data.last == 0x0A { return }
            if let newline = data.lastIndex(of: 0x0A) {
                try? handle.truncate(atOffset: from + UInt64(newline - data.startIndex) + 1)
                return
            }
            at = from
        }
        try? handle.truncate(atOffset: 0)
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
