import Foundation
import LinkProtocol

// What a box adds to the link (1.4): every message shape the client sends or reads beyond 1.3
// lives here, so the wire can change in one place.
//
// - `hello` goes with an empty `proof`: `kore-host attach` answers the challenge itself and fills
//   in `grant` and `proof`.
// - `welcome.host.kind` is `"box"`.
// - `chat.new` takes `folder` in place of `windowId`.
// - `folders.list {id}` is answered by a message with the same `id` and `folders: [{path, name?}]`.
// - Catch-up: `tx.open` carries `since`, the last `seq` the client holds, where a page or delta
//   carries one. A host without them sends a page, which the client merges with its copy.
// - Liveness: `ping` is sent as a command; any 1.x host answers a command, known or not, with a
//   `result`, and every frame counts as a sign of life.

/// One folder the box serves.
package struct BoxFolder: Codable, Sendable, Equatable, Hashable {
    /// As the box names it ("~/Code/app" or an absolute path): what `chat.new` and windows use.
    package var path: String
    package var name: String

    package init(path: String, name: String? = nil) {
        self.path = path
        self.name = name ?? BoxFolder.lastPart(path)
    }

    static func lastPart(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// A message read from the box: a link message, or one of the box's own.
package enum HostInbound: Sendable {
    /// `seq`: the position in the box's per-chat log that a `tx.page` or `tx.delta` brings the
    /// client to, when the box says.
    case link(LinkMessage, seq: Int?)
    case folders(id: String, [BoxFolder])
}

package enum HostWire {
    /// The link version the client speaks.
    package static let proto = LinkVersion(major: 1, minor: 4)
    /// `tx.open`'s window: what the box sends of a chat it hasn't been asked about before.
    package static let followLast = 200

    // MARK: Out

    package static func hello(build: String) -> Data {
        encode(.hello(proto: proto, client: .init(name: "Kore", build: build), proof: "", commands: nil))
    }

    package static func txOpen(chatId: String, since seq: Int?) -> Data {
        var object: [String: Any] = ["t": "tx.open", "chatId": chatId, "last": followLast]
        if let seq { object["since"] = seq }
        return json(object)
    }

    package static func txClose(chatId: String) -> Data { encode(.txClose(chatId: chatId)) }

    package static func command(id: String, _ command: LinkCommand) -> Data { encode(.cmd(id: id, command)) }

    /// A command by its fields, for those 1.3's types can't say.
    package static func command(id: String, type: String, _ fields: [String: Any]) -> Data {
        var cmd = fields
        cmd["type"] = type
        return json(["t": "cmd", "id": id, "cmd": cmd])
    }

    package static func newChat(id: String, folder: String, provider: String) -> Data {
        command(id: id, type: "chat.new", ["folder": folder, "provider": provider])
    }

    package static func ping(id: String) -> Data { command(id: id, type: "ping", [:]) }

    package static func foldersList(id: String) -> Data { json(["t": "folders.list", "id": id]) }

    package static func bye() -> Data { encode(.bye(.quit)) }

    // MARK: In

    package static func decode(_ data: Data) throws -> HostInbound {
        let message = try LinkMessage.decode(data)
        switch message {
        case .unknown:
            let peek = try JSONDecoder().decode(FoldersPeek.self, from: data)
            if let id = peek.id, let folders = peek.folders { return .folders(id: id, folders.map { BoxFolder(path: $0.path, name: $0.name) }) }
            return .link(message, seq: nil)
        case .txPage, .txDelta:
            return .link(message, seq: try? JSONDecoder().decode(SeqPeek.self, from: data).seq)
        default:
            return .link(message, seq: nil)
        }
    }

    /// The welcome's `host.kind` ("box" for kore-host); nil from a host that doesn't say.
    package static func hostKind(_ data: Data) -> String? {
        (try? JSONDecoder().decode(KindPeek.self, from: data))?.host?.kind
    }

    private struct SeqPeek: Decodable { var seq: Int? }
    private struct KindPeek: Decodable {
        struct Host: Decodable { var kind: String? }
        var host: Host?
    }
    private struct FoldersPeek: Decodable {
        struct Folder: Decodable {
            var path: String
            var name: String?
        }
        var id: String?
        var folders: [Folder]?
    }

    // MARK: Bytes

    private static func encode(_ message: LinkMessage) -> Data { (try? message.encoded()) ?? Data() }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
