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

    /// One chat's events as the box sent them (1.5): the box's log id and its items in order.
    package struct Events: Sendable {
        package var log: String?
        package var items: [RelayItem] = []
    }

    private struct Header: Codable { var log: String }

    package func events(chat chatId: String) -> Events {
        guard let data = try? Data(contentsOf: log(chatId)) else { return Events() }
        var result = Events()
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            if let item = try? decoder.decode(RelayItem.self, from: line) {
                result.items.append(item)
            } else if let header = try? decoder.decode(Header.self, from: line) {
                result = Events(log: header.log)
            }
        }
        return result
    }

    /// The log starts again: the box's log `log`, from `items`.
    package func restart(log id: String, items: [RelayItem], chat chatId: String) {
        queue.async { [self] in
            make(chats)
            var data = RelayWire.encode(Header(log: id)) + Data([0x0A])
            for item in items { data += RelayWire.encode(item) + Data([0x0A]) }
            try? data.write(to: log(chatId), options: .atomic)
        }
    }

    /// Items that followed.
    package func append(_ items: [RelayItem], chat chatId: String) {
        guard !items.isEmpty else { return }
        queue.async { [self] in
            guard let handle = try? FileHandle(forWritingTo: log(chatId)) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            var data = Data()
            for item in items { data += RelayWire.encode(item) + Data([0x0A]) }
            try? handle.write(contentsOf: data)
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
