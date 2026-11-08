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
    /// 1.11: the files' bytes together (`chat.copy`, `chat.release` prepare), for a transfer's bar.
    package var bytes: Int64?
    /// The chat's own settings, all of them (`ChatSettings`): a peer from before them sends only
    /// the four above.
    package var settings: ChatSettings?

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
    /// A chat taken in (`chat.adopt`, `chat.adoptCopy` commit): its settings as they are now on the
    /// box, its draft left out (on a send back the box's may have been newer). `message` says
    /// what gave way. A box from before them says neither.
    package var settings: ChatSettings?

    package init(
        id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, chatId: String? = nil, owner: ChatOwner? = nil, move: MoveInfo? = nil,
        settled: Bool? = nil, pending: Int? = nil, watching: Bool? = nil, mirrored: Int? = nil, settings: ChatSettings? = nil
    ) {
        self.settings = settings
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

/// A chat's own settings, as every copy, duplicate, cut, move, send back and fork carries them,
/// Mac to Mac, Mac to box and box to box. Each is optional: absent, the place it lands keeps its own,
/// but for the Arsenal tier (absent is off) and the draft (absent is none).
package struct ChatSettings: Codable, Sendable, Equatable {
    package var modelId: String?
    package var effort: String?
    package var mode: String?
    package var fast: Bool?
    /// Codex's Plan switch (Claude's plan is a mode).
    package var plan: Bool?
    /// "Allow commands in Plan".
    package var planAllow: Bool?
    /// The chat's own auto-compact point: 0 for off; absent, none of its own.
    package var autoCompact: Int?
    /// A box's Claude chat's login ("main" for the default). A Mac's chats run on its one login.
    package var login: String?
    /// Its Arsenal tier while on (`LinkPolicy.arsenalTiers`).
    package var arsenal: String?
    /// The composer's draft: a move's and a cut's (a copy leaves it with its original).
    package var draft: String?
    /// When they last changed where they come from, ms since 1970: on a send back the newer wins.
    package var at: Int64?

    package init(
        modelId: String? = nil, effort: String? = nil, mode: String? = nil, fast: Bool? = nil, plan: Bool? = nil, planAllow: Bool? = nil,
        autoCompact: Int? = nil, login: String? = nil, arsenal: String? = nil, draft: String? = nil, at: Int64? = nil
    ) {
        self.modelId = modelId
        self.effort = effort
        self.mode = mode
        self.fast = fast
        self.plan = plan
        self.planAllow = planAllow
        self.autoCompact = autoCompact
        self.login = login
        self.arsenal = arsenal
        self.draft = draft
        self.at = at
    }

    /// The same without the draft (a copy's: the original keeps it).
    package var withoutDraft: ChatSettings {
        var copy = self
        copy.draft = nil
        return copy
    }

    /// What a link carries of them: an id that isn't plain, a point off the ring, a tier not
    /// built and a draft over the link's limit are left out.
    package var linkable: ChatSettings {
        var kept = self
        for path in [\ChatSettings.modelId, \.effort, \.mode, \.login] where kept[keyPath: path].map(LinkPolicy.plainID) == false {
            kept[keyPath: path] = nil
        }
        if let point = kept.autoCompact, point != 0, !ContextStore.snapPoints.contains(point) { kept.autoCompact = nil }
        if let tier = kept.arsenal, !LinkPolicy.arsenalTiers.contains(tier) { kept.arsenal = nil }
        if let draft = kept.draft, draft.utf8.count > LinkPolicy.maxText { kept.draft = nil }
        return kept
    }

    /// Only what a link carries (`linkable`).
    package var plain: Bool { linkable == self }

    /// The point as a chat takes it: nil for off; `.none`, none of its own.
    package var point: Int?? { autoCompact.map { $0 == 0 ? nil : $0 } }

    /// `tier` at most the highest of `allowed` at or below it (`LinkPolicy.arsenalTiers`, lowest
    /// first); nil when none is.
    package static func cap(_ tier: String?, to allowed: Set<String>) -> String? {
        let tiers = LinkPolicy.arsenalTiers
        guard let tier, let at = tiers.firstIndex(of: tier) else { return nil }
        return tiers[...at].last { allowed.contains($0) }
    }

    /// A tier's name as Kore shows it ("Act unlimited").
    package static func tierName(_ tier: String) -> String { ArsenalTier(rawValue: tier)?.title ?? tier }

    package static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

extension ChatSettings {
    /// A live chat's, as its composer has them. `draft`: a move's and a cut's carry it. `login`:
    /// a box chat's, as the box says it.
    @MainActor package init(of chat: Chat, draft: Bool, login: String? = nil) {
        let c = chat.controls
        self.init(
            modelId: c.modelId ?? chat.launchModel, effort: c.effort ?? chat.launchEffort, mode: c.mode,
            fast: chat.launchFastMode ?? (c.fastKnown ? c.fastMode : nil), plan: chat.provider.planToggle != nil ? c.planMode : nil,
            planAllow: c.planAllow, autoCompact: chat.ownsAutoCompact ? chat.context.autoCompactAt ?? 0 : nil, login: login,
            arsenal: chat.arsenal?.rawValue, draft: draft ? Self.composer(chat) : nil, at: chat.settingsChangedAt.map(Self.ms))
    }

    /// The composer as one line of text: its command, then the draft.
    @MainActor package static func composer(_ chat: Chat) -> String {
        guard let command = chat.command else { return chat.draft }
        return "/" + command.name + (chat.draft.isEmpty ? "" : " " + chat.draft)
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
