import Foundation
import LinkProtocol

// What a box adds to the link (1.4, `docs/link-1.4-box.md`): every message shape the client sends
// or reads beyond 1.3 lives here, so the wire can change in one place.
//
// - `hello` goes with an empty `proof`: `kore-host attach` answers the challenge itself and fills
//   in `grant` and `proof`.
// - `welcome.host.kind` is `"box"`.
// - `chat.new` takes `folder` (an absolute path the box serves) in place of `windowId`.
// - `folders.list` is a command; its `result` carries `folders: [{windowId, path}]`. A folder's
//   window (its chats) is the one with that `windowId`.
// - Catch-up: `tx.open` answers from the chat's log with a page, which the client merges with its
//   copy; a resumed CLI replaces the log (`tx.reset`, then a page with new ids).
// - Liveness: the box has no ping. One is sent as a command of a type the box doesn't know, which
//   any 1.x host answers with a `result` (`invalid`); every frame counts as a sign of life.

/// One folder the box serves.
package struct BoxFolder: Codable, Sendable, Equatable, Hashable {
    /// Absolute, on the box: what `chat.new` takes.
    package var path: String
    /// Its window in the box's state, whose tabs are its chats.
    package var windowId: String?
    package var name: String

    package init(path: String, windowId: String? = nil) {
        self.path = path
        self.windowId = windowId
        name = BoxFolder.lastPart(path)
    }

    static func lastPart(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// A message read from the box: a link message, or one of the box's own.
package enum HostInbound: Sendable {
    /// `seq`: the position in the box's log a page or delta brings the client to; the box doesn't
    /// say one yet, so it's nil.
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

    package static func txOpen(chatId: String) -> Data { encode(.txOpen(chatId: chatId, last: followLast)) }

    package static func txClose(chatId: String) -> Data { encode(.txClose(chatId: chatId)) }

    package static func command(id: String, _ command: LinkCommand) -> Data { encode(.cmd(id: id, command)) }

    /// A command by its fields, for those 1.3's types can't say.
    package static func command(id: String, type: String, _ fields: [String: Any]) -> Data {
        var cmd = fields
        cmd["type"] = type
        return json(["t": "cmd", "id": id, "cmd": cmd])
    }

    package static func newChat(id: String, folder: String, provider: String, model: String? = nil) -> Data {
        var fields: [String: Any] = ["folder": folder, "provider": provider]
        if let model { fields["modelId"] = model }
        return command(id: id, type: "chat.new", fields)
    }

    package static func ping(id: String) -> Data { command(id: id, type: "ping", [:]) }

    package static func foldersList(id: String) -> Data { command(id: id, type: "folders.list", [:]) }

    package static func bye() -> Data { encode(.bye(.quit)) }

    // MARK: In

    package static func decode(_ data: Data) throws -> HostInbound {
        let message = try LinkMessage.decode(data)
        if case .result(let result) = message, result.ok, let folders = try? JSONDecoder().decode(FoldersPeek.self, from: data).folders {
            return .folders(id: result.id, folders.map { BoxFolder(path: $0.path, windowId: $0.windowId) })
        }
        return .link(message, seq: nil)
    }

    /// The welcome's `host.kind` ("box" for kore-host); nil from a host that doesn't say.
    package static func hostKind(_ data: Data) -> String? {
        (try? JSONDecoder().decode(KindPeek.self, from: data))?.host?.kind
    }

    private struct KindPeek: Decodable {
        struct Host: Decodable { var kind: String? }
        var host: Host?
    }
    private struct FoldersPeek: Decodable {
        struct Folder: Decodable {
            var windowId: String?
            var path: String
        }
        var folders: [Folder]?
    }

    // MARK: Bytes

    private static func encode(_ message: LinkMessage) -> Data { (try? message.encoded()) ?? Data() }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
