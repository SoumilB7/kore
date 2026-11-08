import Foundation

// Link 1.8, git on a box (`docs/link-1.4-box.md`, "Git"): what a box window's explorer colours,
// its editor's change bars and its diffs read. Full grants only, inside served folders only, and
// read-only. The box runs git with no optional locks (it never fights a chat's own git), one run
// per repository at a time, and keeps the last status: a client is sent what changed since what
// it was sent, never the whole map again.

/// A path's state in `git.status`, one letter on the wire.
package enum GitWireState: String, Codable, Sendable, CaseIterable {
    case ignored = "i", untracked = "u", added = "a", renamed = "r", modified = "m", deleted = "d", conflicted = "c"
}

/// Client to box: the work tree's states under `root` (a served folder, or one inside it).
/// `watch`: the box also pushes `git.changed` while this link lasts, once a change it notices
/// (a turn's end, a file written over the link, a command run in a terminal, the repository's
/// own index or HEAD) has settled; `git.unwatch` ends it. The first answer on a link is the
/// whole map (`full`); later ones, and every push, are what changed since.
package struct GitStatusAsk: Codable, Sendable, Equatable {
    package static let type = "git.status"
    package var t = GitStatusAsk.type
    package var id: String
    package var root: String
    package var watch: Bool?

    package init(id: String, root: String, watch: Bool? = nil) {
        self.id = id
        self.root = root
        self.watch = watch
    }
}

/// Client to box: no more `git.changed` for `root`. No answer.
package struct GitUnwatch: Codable, Sendable, Equatable {
    package static let type = "git.unwatch"
    package var t = GitUnwatch.type
    package var root: String

    package init(root: String) { self.root = root }
}

/// The states under a root as a change: paths relative to it, a whole folder's with a trailing
/// `/`. `full`: replaces what the client holds; else `set` and `gone` change it.
package struct GitStates: Codable, Sendable, Equatable {
    package var full: Bool?
    package var set: [String: GitWireState]?
    package var gone: [String]?
    /// Not a git work tree (or git isn't on the box): no states.
    package var none: Bool?
    /// Cut at `GitWire.statusMax` paths.
    package var more: Bool?

    package init(full: Bool? = nil, set: [String: GitWireState]? = nil, gone: [String]? = nil, none: Bool? = nil, more: Bool? = nil) {
        self.full = full
        self.set = set
        self.gone = gone
        self.none = none
        self.more = more
    }

    /// From what was sent to what is: nil when nothing changed.
    package static func delta(from old: [String: GitWireState]?, to new: [String: GitWireState]) -> GitStates? {
        guard let old else { return GitStates(full: true, set: new) }
        var set: [String: GitWireState] = [:]
        for (path, state) in new where old[path] != state { set[path] = state }
        let gone = old.keys.filter { new[$0] == nil }.sorted()
        guard !set.isEmpty || !gone.isEmpty else { return nil }
        return GitStates(set: set.isEmpty ? nil : set, gone: gone.isEmpty ? nil : gone)
    }

    /// `held` with this applied.
    package func applied(to held: [String: GitWireState]) -> [String: GitWireState] {
        var next = full == true || none == true ? [:] : held
        for path in gone ?? [] { next[path] = nil }
        for (path, state) in set ?? [:] { next[path] = state }
        return next
    }
}

/// Box to client: `git.status`'s answer.
package struct GitStatusResult: Codable, Sendable, Equatable {
    package var t = "result"
    package var id: String
    package var ok: Bool
    package var code: ResultCode?
    package var message: String?
    package var root: String?
    package var states: GitStates?

    package init(id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, root: String? = nil, states: GitStates? = nil) {
        self.id = id
        self.ok = ok
        self.code = code
        self.message = message
        self.root = root
        self.states = states
    }
}

/// Box to client, while watched: what changed under `root` since the last answer or push.
package struct GitChanged: Codable, Sendable, Equatable {
    package static let type = "git.changed"
    package var t = GitChanged.type
    package var root: String
    package var states: GitStates

    package init(root: String, states: GitStates) {
        self.root = root
        self.states = states
    }
}

/// Client to box: the work tree's diff under `root` (`git diff`, paths relative to `root`), of
/// one `path` in it or all; `staged`: the index against HEAD instead.
package struct GitDiffAsk: Codable, Sendable, Equatable {
    package static let type = "git.diff"
    package var t = GitDiffAsk.type
    package var id: String
    package var root: String
    package var path: String?
    package var staged: Bool?

    package init(id: String, root: String, path: String? = nil, staged: Bool? = nil) {
        self.id = id
        self.root = root
        self.path = path
        self.staged = staged
    }
}

/// Client to box: what a file's change bars are measured against: its text at HEAD. The client
/// diffs its own text with it, so the bars follow typing with no further asks.
package struct GitLineChangesAsk: Codable, Sendable, Equatable {
    package static let type = "git.lineChanges"
    package var t = GitLineChangesAsk.type
    package var id: String
    package var path: String

    package init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}

/// Box to client: `git.diff`'s or `git.lineChanges`'s answer. `diff`: unified, no colour;
/// `base`: the file at HEAD, absent for one HEAD doesn't have (new, untracked, outside a work
/// tree: no bars); `truncated`: cut at `GitWire.textMax`.
package struct GitTextResult: Codable, Sendable, Equatable {
    package var t = "result"
    package var id: String
    package var ok: Bool
    package var code: ResultCode?
    package var message: String?
    package var diff: String?
    package var base: String?
    package var truncated: Bool?

    package init(
        id: String, ok: Bool, code: ResultCode? = nil, message: String? = nil, diff: String? = nil, base: String? = nil, truncated: Bool? = nil
    ) {
        self.id = id
        self.ok = ok
        self.code = code
        self.message = message
        self.diff = diff
        self.base = base
        self.truncated = truncated
    }

    package static func refused(_ id: String, _ code: ResultCode, _ message: String) -> GitTextResult {
        GitTextResult(id: id, ok: false, code: code, message: message)
    }
}

package enum GitWire {
    /// Paths one status carries at most.
    package static let statusMax = 20_000
    /// A diff's or a base's most text.
    package static let textMax = 768 * 1024
    /// A change settles this long before the box runs status again.
    package static let settle: TimeInterval = 0.4
}
