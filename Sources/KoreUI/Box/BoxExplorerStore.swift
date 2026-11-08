import Foundation
import HostClient
import LinkProtocol
import Observation

/// A box folder's files as a box window's explorer shows them, read over the link (`fs.list`):
/// a folder is listed when it's first opened, and the open ones again on Reload, when the link
/// comes back, or when a turn in the window ends. Nothing on this Mac is read, and nothing is
/// watched or polled on the box. Read-only: no new, rename or delete here.
@MainActor @Observable
final class BoxExplorerStore {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case node
            /// Why a folder opened here couldn't be listed, under it.
            case note(String)
        }

        /// The box path the row acts on.
        let id: String
        let name: String
        let depth: Int
        let isFolder: Bool
        let isOpen: Bool
        var isLink = false
        var kind = Kind.node
    }

    /// The box's folder, absolute there.
    let root: String
    private(set) var rows: [Row] = []
    private(set) var rootLoaded = false
    /// Why the folder itself can't be listed.
    private(set) var rootError: String?
    /// The row the keys are on.
    var selection: String?

    @ObservationIgnored private let source: any BoxFileSource
    @ObservationIgnored private var children: [String: [FileEntry]] = [:]
    /// Folders the box listed only up to its cap: their last row says so.
    @ObservationIgnored private var capped: Set<String> = []
    @ObservationIgnored private var failed: [String: String] = [:]
    @ObservationIgnored private var expanded: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []
    /// A reload asked while one runs: one more pass after it.
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var again = false

    /// Hidden as in the Mac's explorer: `.git` and Finder's litter; other dotfiles show.
    static let hidden: Set<String> = [".git", ".DS_Store", ".svn", ".hg"]

    init(root: String, source: any BoxFileSource) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        self.source = source
    }

    var alias: String { source.alias }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    /// Lists the folder itself, once.
    func start() async {
        guard !rootLoaded, !loading.contains(root) else { return }
        await load(root)
    }

    func toggle(_ path: String) {
        if expanded.contains(path) { collapse(path) } else { expand(path) }
    }

    func expand(_ path: String) {
        expanded.insert(path)
        rebuild()
        // Opened again after it couldn't be listed: asked again.
        if children[path] == nil, !loading.contains(path) {
            failed[path] = nil
            Task { await load(path) }
        }
    }

    func collapse(_ path: String) {
        expanded.remove(path)
        rebuild()
    }

    func collapseAll() {
        expanded.removeAll()
        rebuild()
    }

    /// Lists the folder and its open folders again (Reload, the link back, a turn's end). Folders
    /// that went are dropped; one pass at a time.
    func refresh() async {
        if reloading {
            again = true
            return
        }
        reloading = true
        repeat {
            again = false
            // Root first, then down: a folder whose parent went isn't asked.
            let open = [root] + expanded.filter { $0 != root }.sorted { $0.count < $1.count }
            for folder in open where folder == root || isShown(folder) {
                await load(folder, rebuilding: false)
            }
            // Listings of folders no longer open are dropped: opened again, they're asked fresh.
            for folder in children.keys where folder != root && !expanded.contains(folder) { children[folder] = nil }
            rebuild()
        } while again
        reloading = false
    }

    /// Its parents are all open and listed with it in them.
    private func isShown(_ path: String) -> Bool {
        var folder = path
        while folder != root {
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent.count >= root.count, expanded.contains(parent) || parent == root,
                children[parent]?.contains(where: { parent + "/" + $0.name == folder }) == true
            else { return false }
            folder = parent
        }
        return true
    }

    private func load(_ folder: String, rebuilding: Bool = true) async {
        loading.insert(folder)
        let result = await source.list(folder, hidden: true)
        loading.remove(folder)
        switch result {
        case .success(let listing):
            failed[folder] = nil
            children[folder] = listing.entries.filter { !Self.hidden.contains($0.name) }
            if listing.more { capped.insert(folder) } else { capped.remove(folder) }
            if folder == root { rootError = nil }
        case .failure(let why):
            if folder == root {
                rootError = why.message
            } else if children[folder] == nil || expanded.contains(folder) {
                failed[folder] = why.message
            }
            children[folder] = nil
        }
        if folder == root { rootLoaded = true }
        if rebuilding { rebuild() }
    }

    // MARK: Rows

    private func rebuild() {
        var rows: [Row] = []
        append(root, depth: 0, into: &rows)
        if self.rows != rows { self.rows = rows }
    }

    private func append(_ folder: String, depth: Int, into rows: inout [Row]) {
        if let why = failed[folder], folder != root {
            rows.append(Row(id: folder + "/\u{0}note", name: why, depth: depth, isFolder: false, isOpen: false, kind: .note(why)))
            return
        }
        for entry in children[folder] ?? [] {
            let path = folder == "/" ? "/" + entry.name : folder + "/" + entry.name
            let open = entry.isFolder && expanded.contains(path)
            rows.append(Row(id: path, name: entry.name, depth: depth, isFolder: entry.isFolder, isOpen: open, isLink: entry.kind == .link))
            if open { append(path, depth: depth + 1, into: &rows) }
        }
        if capped.contains(folder) {
            let line = "First \(LinkFiles.listMax.formatted()) shown"
            rows.append(Row(id: folder + "/\u{0}more", name: line, depth: depth, isFolder: false, isOpen: false, kind: .note(line)))
        }
    }

    var isEmpty: Bool { rootLoaded && rootError == nil && rows.isEmpty }

    func relative(_ path: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    func parent(of path: String) -> String { (path as NSString).deletingLastPathComponent }
}
