import Foundation
import src

// Link 1.10: a chat moves between a box and the Mac linked to it (`docs/link-1.4-box.md`, "Link
// 1.10"). One host owns a chat at a time and runs its CLI; anywhere else it's a read-only replica.
// The Mac starts every move. The CLI's own session files go by rsync over the pair's SSH alias;
// these messages hand ownership over around that copy. All of it needs a full grant.

/// Where a chat lives (`ChatMeta.owner`, and the box's `meta.json`). Absent: the box, gen 0.
package struct ChatOwner: Codable, Sendable, Equatable {
    /// `box`, or the grant of the Mac that holds it.
    package var host: String
    /// One more on every move: a stale writer is refused by number.
    package var gen: Int
    /// When it got there, ms since 1970.
    package var since: Int64
    /// The holding Mac's own name, as replicas show it ("on MacBook"); absent for the box.
    package var name: String?
    /// Events the holding Mac mirrored into the box's replica so far (`chat.mirror`).
    package var mirrored: Int?
    /// A client other than the holder follows the replica: the holder mirrors only then.
    package var followed: Bool?

    package init(host: String, gen: Int, since: Int64, name: String? = nil, mirrored: Int? = nil, followed: Bool? = nil) {
        self.host = host
        self.gen = gen
        self.since = since
        self.name = name
        self.mirrored = mirrored
        self.followed = followed
    }

    package static let box = "box"
    package var onBox: Bool { host == Self.box }
}

/// `chat.release`'s and `chat.adopt`'s phases.
package enum MovePhase: String, Sendable {
    case prepare, commit, abort
}

/// What `chat.release` (prepare) and `chat.adopt` (prepare) answer: the session's files and where
/// they are, and the chat's settings, which travel with it.
package struct MoveInfo: Codable, Sendable, Equatable {
    package var moveId: String
    package var chatId: String?
    package var provider: String
    package var sessionId: String
    /// The sending side's folder, as given and as its real path: the rows' `cwd`s to rewrite.
    package var folders: [String]
    /// The folder the files are under on the side that answered, and their paths from it.
    package var root: String
    package var files: [String]
    package var gen: Int
    package var title: String?
    package var modelId: String?
    package var effort: String?
    package var mode: String?
    /// The CLI's version there (`claude --version`), when known.
    package var cli: String?
    /// `chat.adopt` (prepare): the box still holds the chat at this gen, so a return
    /// fast-forwards it; false: it comes in as a new chat.
    package var fastForward: Bool?

    package init(
        moveId: String, chatId: String? = nil, provider: String, sessionId: String, folders: [String], root: String, files: [String], gen: Int,
        title: String? = nil, modelId: String? = nil, effort: String? = nil, mode: String? = nil, cli: String? = nil, fastForward: Bool? = nil
    ) {
        self.moveId = moveId
        self.chatId = chatId
        self.provider = provider
        self.sessionId = sessionId
        self.folders = folders
        self.root = root
        self.files = files
        self.gen = gen
        self.title = title
        self.modelId = modelId
        self.effort = effort
        self.mode = mode
        self.cli = cli
        self.fastForward = fastForward
    }
}

/// The answer to `chat.release`, `chat.adopt`, `sync.flush` and `chat.mirror` (`t: "result"`):
/// a 1.9 client's `result` reads it as `{id, ok, code, message}`.
package struct MoveResult: Codable, Sendable, Equatable {
    package var t = "result"
    package var id: String
    package var ok: Bool
    package var code: ResultCode?
    package var message: String?
    /// The chat's id (a commit, or an adopt that made a new chat) and owner after it.
    package var chatId: String?
    package var owner: ChatOwner?
    package var move: MoveInfo?
    /// `sync.flush`: both ends settled; else the changes still on their way, and whether the box
    /// watches the folder for this client at all.
    package var settled: Bool?
    package var pending: Int?
    package var watching: Bool?
    /// `chat.mirror`: the events the replica holds now.
    package var mirrored: Int?

    package init(
        id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, chatId: String? = nil, owner: ChatOwner? = nil, move: MoveInfo? = nil,
        settled: Bool? = nil, pending: Int? = nil, watching: Bool? = nil, mirrored: Int? = nil
    ) {
        self.id = id
        self.ok = ok
        self.code = code
        self.message = message
        self.chatId = chatId
        self.owner = owner
        self.move = move
        self.settled = settled
        self.pending = pending
        self.watching = watching
        self.mirrored = mirrored
    }

    package static func refused(_ id: String, _ code: ResultCode, _ message: String) -> MoveResult {
        MoveResult(id: id, ok: false, code: code, message: message)
    }
}

package enum LinkMoves {
    /// Events one `chat.mirror` carries at most, and its bytes: under the box's inbound frame.
    package static let mirrorMax = 400
    package static let mirrorBytes = 192 * 1024
    /// A move's id: letters, digits and `-`, as a staging folder's name.
    package static func plainMoveID(_ id: String?) -> Bool {
        guard let id, (8...64).contains(id.count) else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A session id: what the CLIs make (uuids), nothing that could name a path.
    package static func plainSession(_ id: String?) -> Bool {
        guard let id, (1...128).contains(id.count) else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// `chat.mirror`'s events: written as a plain array of `StreamItem`s (`s` the Mac's count), each
/// read leniently (one this side can't read is an empty item, skipped).
package struct MirrorItems: Codable, Sendable, Equatable {
    package var items: [StreamItem]
    package init(_ items: [StreamItem]) { self.items = items }
    package init(from decoder: any Decoder) throws { items = try [StreamItem](from: decoder) }
    package func encode(to encoder: any Encoder) throws { try items.encode(to: encoder) }
    package static func == (a: MirrorItems, b: MirrorItems) -> Bool { StreamWire.encode(a.items) == StreamWire.encode(b.items) }
}
