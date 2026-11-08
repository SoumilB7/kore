import Foundation
import KoreCore
import LinkProtocol
import Observation

/// A box folder's git as its window shows it (link 1.8, `LinkGit.swift`): the explorer's colours,
/// the editor's change bars and the diffs, read over the link. Asleep until shown:
///
/// - `visible` (the explorer is on screen) asks for the states once and has the box push what
///   changes; hidden, the box stops. A link that comes back asks again, once.
/// - `status` changes only when a state does, so rows never redraw for nothing.
/// - A file's text at HEAD is asked when its editor diffs, and kept until git says the file
///   changed; the diff itself runs here, so the bars follow typing with no further asks.
@MainActor @Observable
package final class BoxGitStatus {
    package let root: String
    /// The work tree's states, by absolute box path, as `FilesStore.state(of:)` reads them here.
    package private(set) var status = GitStatus.empty
    /// The folder isn't in a git work tree (or the box can't run git): no colours.
    package private(set) var none = false
    @ObservationIgnored private let connection: HostConnection
    /// The map as the box sent it, by path relative to `root`.
    @ObservationIgnored private var held: [String: GitWireState] = [:]
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var askAgain = false
    @ObservationIgnored private var bases: [String: String?] = [:]
    /// Files whose state moved (absolute box paths; nil: any may have): open editors diff again.
    @ObservationIgnored package var moved: (@MainActor ([String]?) -> Void)?

    package init(root: String, connection: HostConnection) {
        self.root = LinkFiles.normalised(root)
        self.connection = connection
    }

    /// The explorer is on screen: the box sends the states and what changes; off, it stops.
    package var visible = false {
        didSet {
            guard visible != oldValue else { return }
            if visible {
                connection.boxReaders[BoxStreams.git(root)] = { [weak self] data in self?.pushed(data) }
                connection.onSnapshot(BoxStreams.git(root)) { [weak self] in self?.linkedAgain() }
                ask()
            } else {
                connection.onSnapshot(BoxStreams.git(root), nil)
                connection.boxReaders[BoxStreams.git(root)] = nil
                connection.post(StreamWire.encode(GitUnwatch(root: root)))
            }
        }
    }

    /// A state for a file or folder under `root`; nil when clean.
    package func state(of path: String) -> GitStatus.State? { status.state(of: path) }

    /// The box can serve git to this grant now.
    private var offered: Bool { connection.isOnline && connection.caps.contains("git") }

    private func ask() {
        guard visible, offered else { return }
        guard !asking else {
            askAgain = true
            return
        }
        asking = true
        let root = root
        Task {
            let (result, raw) = await connection.commandRaw { StreamWire.encode(GitStatusAsk(id: $0, root: root, watch: true)) }
            asking = false
            if result.ok, let answer = raw.flatMap({ try? JSONDecoder().decode(GitStatusResult.self, from: $0) }), let states = answer.states {
                apply(states)
            }
            if askAgain {
                askAgain = false
                ask()
            }
        }
    }

    private func linkedAgain() {
        // A new link: the box sends the whole map again.
        ask()
    }

    private func pushed(_ data: Data) {
        guard let changed = try? JSONDecoder().decode(GitChanged.self, from: data) else { return }
        apply(changed.states)
    }

    /// Takes a change: the map, then the lookups once, only when a state moved.
    package func apply(_ states: GitStates) {
        let whole = states.full == true || states.none == true
        if whole {
            bases = [:]
            if none != (states.none == true) { none = states.none == true }
            if !held.isEmpty || states.none != true { moved?(nil) }
        } else {
            let paths = ((states.gone ?? []) + Array((states.set ?? [:]).keys)).map { root + "/" + ($0.hasSuffix("/") ? String($0.dropLast()) : $0) }
            for path in paths { bases[path] = nil }
            if !paths.isEmpty { moved?(paths) }
        }
        let next = states.applied(to: held)
        guard next != held else { return }
        held = next
        let built = GitStatus(states: next.mapValues(\.state), root: root)
        if built != status { status = built }
    }

    // MARK: Diffs

    /// The file's text at HEAD (nil: no bars), kept until git says it changed.
    package func base(of path: String) async -> String? {
        if let kept = bases[path] { return kept }
        guard offered else { return nil }
        let (result, raw) = await connection.commandRaw { StreamWire.encode(GitLineChangesAsk(id: $0, path: path)) }
        guard result.ok, let answer = raw.flatMap({ try? JSONDecoder().decode(GitTextResult.self, from: $0) }) else { return nil }
        bases[path] = .some(answer.base)
        return answer.base
    }

    /// `text` against the file at HEAD, for the gutter: the diff runs here.
    package func lineChanges(of path: String, text: String) async -> LineChanges {
        guard let base = await base(of: path) else { return LineChanges() }
        return await GitBaseline.changes(from: base, to: text)
    }

    /// The work tree's changes under the root (one path's, or all), with absolute box paths.
    package func diff(_ path: String? = nil, staged: Bool = false) async -> Result<[FileChange], HostRefusal> {
        guard offered else { return .failure(HostRefusal(message: "\(NodeNames.name(connection.alias)) can't show changes now")) }
        let root = root
        let (result, raw) = await connection.commandRaw { StreamWire.encode(GitDiffAsk(id: $0, root: root, path: path, staged: staged ? true : nil)) }
        guard result.ok, let text = raw.flatMap({ try? JSONDecoder().decode(GitTextResult.self, from: $0) })?.diff else {
            return .failure(HostRefusal(message: result.message ?? "\(NodeNames.name(connection.alias)) couldn't read the changes"))
        }
        return .success(UnifiedDiff.files(text, root: URL(fileURLWithPath: root)))
    }
}

extension GitWireState {
    package var state: GitStatus.State {
        switch self {
        case .ignored: .ignored
        case .untracked: .untracked
        case .added: .added
        case .renamed: .renamed
        case .modified: .modified
        case .deleted: .deleted
        case .conflicted: .conflicted
        }
    }
}
