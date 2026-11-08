#if canImport(CryptoKit)
import CryptoKit
#endif
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
// - A chat (1.5, box parity, `LinkRelay.swift`): `chat.follow` from where the copy stands, its
//   `chat.events` back; every backend call as one `chat.call`. Full grants only.
// - Sign-in on the box (§11.x's account commands): `account.signIn`'s result carries the page to
//   open and any device code in `message`, space-separated ("https://… code ABCD-1234"); how it
//   ended comes later as a result whose id is the command's plus `:done`. `account.submit` takes
//   the code from Claude's page; `account.refresh` says who's signed in, in `message`.
// - GitHub on the box: `auth.gh` answers `{url, authCode}` (a device code to enter on the page); the
//   box says `ghSignedIn` on its welcome's `host` (or a snapshot's or delta's).
// - Two-way sync: `sync.watch` / `sync.unwatch {folder}`; the box pushes `sync.changed`.
// - Liveness is SSH's own (`ServerAliveInterval`): nothing is sent to wake the box.

/// One folder the box serves.
package struct BoxFolder: Codable, Sendable, Equatable, Hashable {
    /// Absolute, on the box: what `chat.new` takes.
    package var path: String
    /// Its window in the box's state, whose tabs are its chats.
    package var windowId: String?
    package var name: String
    /// The box serves it, but it isn't there any more.
    package var missing: Bool?

    package init(path: String, windowId: String? = nil, missing: Bool? = nil) {
        self.path = path
        self.windowId = windowId
        self.missing = missing
        name = BoxFolder.lastPart(path)
    }

    package static func lastPart(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// A message read from the box: a link message, or one of the box's own.
package enum HostInbound: Sendable {
    case link(LinkMessage)
    case folders(id: String, [BoxFolder])
    /// 1.5: a chat's events.
    case events(ChatEvents)
}

package enum HostWire {
    /// The link version the client speaks.
    package static let proto = LinkVersion(major: 1, minor: 7)

    // MARK: Out

    package static func hello(build: String) -> Data {
        encode(.hello(proto: proto, client: .init(name: "Kore", build: build), proof: "", commands: nil))
    }

    package static func command(id: String, _ command: LinkCommand) -> Data { encode(.cmd(id: id, command)) }

    /// A command by its fields, for those 1.3's types can't say.
    package static func command(id: String, type: String, _ fields: [String: Any]) -> Data {
        var cmd = fields
        cmd["type"] = type
        return json(["t": "cmd", "id": id, "cmd": cmd])
    }

    /// `chat.new` in a folder; a fork (1.5) names the session and message it starts from
    /// (`sessionId`, `entryId`), its title, mode and effort.
    package static func newChat(
        id: String, folder: String, provider: String, model: String? = nil, fork: (from: String, at: String)? = nil, title: String? = nil,
        mode: String? = nil, effort: String? = nil
    ) -> Data {
        var fields: [String: Any] = ["folder": folder, "provider": provider]
        if let model { fields["modelId"] = model }
        if let fork { (fields["sessionId"], fields["entryId"]) = (fork.from, fork.at) }
        if let title { fields["title"] = title }
        if let mode { fields["mode"] = mode }
        if let effort { fields["level"] = effort }
        return command(id: id, type: "chat.new", fields)
    }


    package static func foldersList(id: String) -> Data { command(id: id, type: "folders.list", [:]) }

    /// `folder.add {path}`: an absolute path to a folder already on the box; its result lists the
    /// folders again (`gone.folder` when there's no such folder).
    package static func addFolder(id: String, path: String) -> Data { command(id: id, type: "folder.add", ["path": path]) }

    /// The `folders` a result carries (`folders.list`, `folder.add`).
    package static func folders(_ raw: Data?) -> [BoxFolder]? {
        guard let raw, let peek = try? JSONDecoder().decode(FoldersPeek.self, from: raw), let list = peek.folders else { return nil }
        return list.map { BoxFolder(path: $0.path, windowId: $0.windowId, missing: $0.missing) }
    }

    package static func bye() -> Data { encode(.bye(.quit)) }

    // MARK: Two-way sync

    /// `sync.watch {folder}`: the box sends the folder's whole list, then its changes, as
    /// `sync.changed`, while this link lasts. `sync.unwatch {folder}` ends it.
    package static func syncWatch(id: String, folder: String) -> Data { command(id: id, type: "sync.watch", ["folder": folder]) }
    package static func syncUnwatch(id: String, folder: String) -> Data { command(id: id, type: "sync.unwatch", ["folder": folder]) }

    package static let syncChanged = "sync.changed"

    /// `sync.changed`'s folder, to find its reader.
    package static func syncFolder(_ raw: Data) -> String? { (try? JSONDecoder().decode(SyncPeek.self, from: raw))?.folder }

    /// `sync.changed {folder, paths, all?, more?, watching?, limit?}`.
    package struct SyncChanged: Decodable, Sendable {
        package struct Path: Decodable, Sendable {
            package var p: String
            package var s: Int64?
            package var m: Int64?
            package var gone: Bool?
        }
        package var folder: String
        package var paths: [Path]
        /// The folder's whole list (in pieces while `more`), not changes.
        package var all: Bool?
        package var more: Bool?
        /// With the whole list: false when the box can't watch the folder (too many folders for
        /// inotify's `limit`); it lists again when asked.
        package var watching: Bool?
        package var limit: Int?
        package var folders: Int?
        /// With the whole list: the folder has more files than this, and no list was sent.
        package var capped: Int?
        /// With the whole list: the folder isn't there on the box (no list was sent).
        package var missing: Bool?
    }

    package static func syncChanged(_ raw: Data) -> SyncChanged? { try? JSONDecoder().decode(SyncChanged.self, from: raw) }

    private struct SyncPeek: Decodable { var folder: String? }

    // MARK: Sign-in on the box

    /// The id of a sign-in's ending: its command's id and this.
    package static let doneSuffix = ":done"

    package static func signIn(id: String, provider: String) -> Data { command(id: id, type: "account.signIn", ["provider": provider]) }
    package static func submit(id: String, provider: String, input: String) -> Data {
        command(id: id, type: "account.submit", ["provider": provider, "serial": 0, "input": input])
    }
    package static func cancelSignIn(id: String, provider: String) -> Data { command(id: id, type: "account.cancel", ["provider": provider]) }
    package static func signOut(id: String, provider: String) -> Data { command(id: id, type: "account.signOut", ["provider": provider]) }
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
        if StreamWire.type(data) == "chat.events" { return .events(try JSONDecoder().decode(ChatEvents.self, from: data)) }
        let message = try LinkMessage.decode(data)
        if case .result(let result) = message, result.ok, let folders = try? JSONDecoder().decode(FoldersPeek.self, from: data).folders {
            return .folders(id: result.id, folders.map { BoxFolder(path: $0.path, windowId: $0.windowId, missing: $0.missing) })
        }
        return .link(message)
    }

    /// Whether the box's kore-host is older than this Kore: a lower link minor than the one this
    /// client speaks, or a lower `koreVersion` than `mine` (this app's version; a dev build has none
    /// and compares the link only).
    package static func older(_ welcome: LinkMessage.Welcome, mine: String? = appVersion) -> Bool {
        if welcome.proto.major == proto.major, welcome.proto.minor < proto.minor { return true }
        guard let mine else { return false }
        let box = versionParts(welcome.host.koreVersion), ours = versionParts(mine)
        guard !box.isEmpty, !ours.isEmpty else { return false }
        return box.lexicographicallyPrecedes(ours)
    }

    /// This app's version (`CFBundleShortVersionString`); nil outside Kore.app.
    package static var appVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    /// "0.2.3" as [0, 2, 3]; empty when it isn't one.
    static func versionParts(_ text: String) -> [Int] {
        let parts = text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }


    private struct FoldersPeek: Decodable {
        struct Folder: Decodable {
            var windowId: String?
            var path: String
            var missing: Bool?
        }
        var folders: [Folder]?
    }

    // MARK: Bytes

    package static func encode(_ message: LinkMessage) -> Data { (try? message.encoded()) ?? Data() }

    package static func sha256(_ data: Data) -> String { LinkUploads.hex(SHA256.hash(data: data)) }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
