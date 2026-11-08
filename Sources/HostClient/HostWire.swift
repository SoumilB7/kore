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
// - Sign-in on the box (§11.x's account commands): `account.signIn`'s result carries the page to
//   open and any device code in `message`, space-separated ("https://… code ABCD-1234"); how it
//   ended comes later as a result whose id is the command's plus `:done`. `account.submit` takes
//   the code from Claude's page; `account.refresh` says who's signed in, in `message`.
// - GitHub on the box: `auth.gh` answers `{url, authCode}` (a device code to enter on the page); the
//   box says `ghSignedIn` on its welcome's `host` (or a snapshot's or delta's).
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

    // MARK: Sign-in on the box

    /// The id of a sign-in's ending: its command's id and this.
    package static let doneSuffix = ":done"

    package static func signIn(id: String, provider: String) -> Data { command(id: id, type: "account.signIn", ["provider": provider]) }
    package static func submit(id: String, provider: String, input: String) -> Data {
        command(id: id, type: "account.submit", ["provider": provider, "serial": 0, "input": input])
    }
    package static func cancelSignIn(id: String, provider: String) -> Data { command(id: id, type: "account.cancel", ["provider": provider]) }
    package static func refresh(id: String, provider: String) -> Data { command(id: id, type: "account.refresh", ["provider": provider]) }
    package static func gitHub(id: String) -> Data { command(id: id, type: "auth.gh", [:]) }

    /// A page to open and the code to enter there.
    package struct Page: Equatable, Sendable {
        package var url: URL?
        package var code: String?

        package init(url: URL?, code: String?) {
            self.url = url
            self.code = code
        }
    }

    /// `account.signIn`'s message: its last link (the page that shows a code to paste back, where
    /// there are two) and the word after "code".
    package static func page(_ message: String?) -> Page {
        let words = (message ?? "").split(separator: " ").map(String.init)
        let url = words.last { $0.hasPrefix("https://") || $0.hasPrefix("http://") }.flatMap(URL.init(string:))
        let code = words.firstIndex(of: "code").flatMap { $0 + 1 < words.count ? words[$0 + 1] : nil }
        return Page(url: url, code: code)
    }

    /// `auth.gh`'s result.
    package static func gitHubPage(_ raw: Data?) -> Page? {
        guard let raw, let peek = try? JSONDecoder().decode(PagePeek.self, from: raw), let url = peek.url.flatMap(URL.init(string:)) else { return nil }
        return Page(url: url, code: peek.authCode)
    }

    /// `ghSignedIn` where the box says it: the welcome's or a snapshot's or delta's `host`, or the
    /// message itself.
    package static func ghSignedIn(_ message: LinkMessage, raw: Data) -> Bool? {
        switch message {
        case .welcome, .snapshot, .delta:
            guard let peek = try? JSONDecoder().decode(GitHubPeek.self, from: raw) else { return nil }
            return peek.host?.ghSignedIn ?? peek.ghSignedIn
        default:
            return nil
        }
    }

    private struct PagePeek: Decodable {
        var url: String?
        var code: String?
        var authCode: String?
    }
    private struct GitHubPeek: Decodable {
        struct Host: Decodable { var ghSignedIn: Bool? }
        var host: Host?
        var ghSignedIn: Bool?
    }

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
