import Foundation
import HostClient
import LinkProtocol
import Observation

/// A box folder's files as a box window's explorer shows them, over the link: a folder is listed
/// when it's first opened (`fs.list`), and the open ones are watched while they show (`fs.watch`;
/// a turn's end lists them again where the box can't watch). New, rename, move and Move to Trash
/// go to the box (`fs.create`, `fs.rename`, `fs.delete`); the box's trash keeps what's deleted.
/// Nothing on this Mac is read or written for it.
@MainActor @Observable
final class BoxExplorerStore {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case node
            /// A name field for a new file or folder.
            case newFile, newFolder
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

    enum Edit: Equatable {
        case newFile(parent: String)
        case newFolder(parent: String)
        case rename(String)
    }

    /// The box's folder, absolute there.
    let root: String
    private(set) var rows: [Row] = []
    private(set) var rootLoaded = false
    /// Why the folder itself can't be listed.
    private(set) var rootError: String?
    /// The row the keys are on. With one item chosen, also the choice.
    var selection: String? {
        didSet { if !picked.isEmpty, selection.map(picked.contains) != true { picked = [] } }
    }
    /// The rows chosen with ⌘ or ⇧, the selection among them; empty while one row is chosen.
    private(set) var picked: Set<String> = []
    /// A name field open: a new file or folder, or a rename.
    var edit: Edit? {
        didSet { if edit != oldValue { rebuild() } }
    }
    /// ⌘X: what ⌘V moves.
    var cut: [String] = []
    /// The folder a drag is over.
    var dropTarget: String?
    /// The box watches the open folders; false: a turn's end lists them again.
    private(set) var watching = false

    /// The folder's entries moved or went (a rename, a move, Move to Trash): open tabs follow.
    @ObservationIgnored var onMoved: ((String, String) -> Void)?
    @ObservationIgnored var onTrashed: (([String]) -> Void)?
    /// Files in these folders changed on the box: open tabs read them again.
    @ObservationIgnored var onChanged: ((Set<String>) -> Void)?

    @ObservationIgnored let source: any BoxFileSource
    @ObservationIgnored private var children: [String: [FileEntry]] = [:]
    /// Folders the box listed only up to its cap: their last row says so.
    @ObservationIgnored private var capped: Set<String> = []
    @ObservationIgnored private var failed: [String: String] = [:]
    @ObservationIgnored private var expanded: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private(set) var anchor: String?
    /// A reload asked while one runs: one more pass after it.
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var again = false
    /// The folders last sent to `fs.watch`, and this window's key there.
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private let watchKey = UUID().uuidString
    @ObservationIgnored private var watchTask: Task<Void, Never>?

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

    /// The window closed: the box stops watching its folders.
    func stop() {
        watchTask?.cancel()
        let source = source, key = watchKey
        watched = []
        Task { _ = await source.watch(key, [], changed: nil) }
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

    /// Opens the folders down to `path` and selects it.
    func reveal(_ path: String) async {
        var folder = parent(of: path)
        var chain: [String] = []
        while folder.count > root.count, folder.hasPrefix(root) {
            chain.insert(folder, at: 0)
            folder = parent(of: folder)
        }
        for folder in chain {
            expanded.insert(folder)
            if children[folder] == nil { await load(folder, rebuilding: false) }
        }
        selection = path
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

    /// The box said these folders changed: listed again, and their open files read again.
    func changed(_ folders: Set<String>) {
        Task {
            for folder in folders.sorted() where children[folder] != nil { await load(folder, rebuilding: false) }
            rebuild()
            onChanged?(folders)
        }
    }

    /// Its parents are all open and listed with it in them.
    private func isShown(_ path: String) -> Bool {
        var folder = path
        while folder != root {
            let parent = parent(of: folder)
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

    // MARK: Choosing (VS Code's tree)

    func pickOnly(_ path: String?) {
        picked = []
        selection = path
        anchor = path
    }

    /// ⌘-click: adds or drops the row.
    func pickToggle(_ path: String) {
        var next = picked.isEmpty ? Set(selection.map { [$0] } ?? []) : picked
        if next.contains(path) { next.remove(path) } else { next.insert(path) }
        picked = next.count > 1 ? next : []
        selection = next.contains(path) ? path : next.first
        anchor = path
    }

    /// ⇧-click: the rows from the anchor.
    func pickRange(to path: String) {
        let order = rows.filter { $0.kind == .node }.map(\.id)
        guard let from = (anchor ?? selection).flatMap(order.firstIndex), let to = order.firstIndex(of: path) else { return pickOnly(path) }
        let range = Set(order[min(from, to)...max(from, to)])
        picked = range.count > 1 ? range : []
        selection = path
    }

    func isChosen(_ path: String) -> Bool { picked.isEmpty ? selection == path : picked.contains(path) }

    /// The chosen rows in the tree's order, none inside another.
    var chosenTops: [String] {
        let chosen = picked.isEmpty ? Set(selection.map { [$0] } ?? []) : picked
        let order = rows.map(\.id).filter(chosen.contains)
        return order.filter { path in !order.contains { path.hasPrefix($0 + "/") } }
    }

    /// Where New File… and ⌘V go: the selected folder, else the selected file's folder.
    func targetFolder() -> String {
        guard let selection, let row = rows.first(where: { $0.id == selection }) else { return root }
        return row.isFolder ? row.id : parent(of: row.id)
    }

    /// New File… / New Folder…: the field in the target folder, opened.
    func startNew(folder: Bool) {
        let parent = targetFolder()
        if parent != root, !expanded.contains(parent) { expand(parent) }
        edit = folder ? .newFolder(parent: parent) : .newFile(parent: parent)
    }

    // MARK: Changing the box's files

    /// A name a box takes: one part, not `.` or `..`.
    static func refusal(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "A file or folder name must be provided." }
        if trimmed.contains("/") || trimmed == "." || trimmed == ".." { return "The name \(trimmed) isn't valid as a file or folder name." }
        return nil
    }

    private func taken(_ name: String, in folder: String, except: String? = nil) -> Bool {
        children[folder]?.contains { $0.name.lowercased() == name.lowercased() && folder + "/" + $0.name != except } == true
    }

    /// A new empty file or a folder in `parent`, selected.
    func create(_ name: String, in parent: String, folder: Bool) async -> Result<String, HostRefusal> {
        if let why = Self.refusal(name) { return .failure(HostRefusal(message: why)) }
        let name = name.trimmingCharacters(in: .whitespaces)
        if taken(name, in: parent) { return .failure(HostRefusal(message: "A file or folder named \(name) already exists here.")) }
        let result = await source.create(parent + "/" + name, folder: folder)
        if case .success(let path) = result {
            await load(parent, rebuilding: false)
            pickOnly(path)
            if folder { expanded.insert(path) }
            rebuild()
        }
        return result
    }

    /// Renames in place; open tabs follow.
    func rename(_ path: String, to name: String) async -> Result<String, HostRefusal> {
        if let why = Self.refusal(name) { return .failure(HostRefusal(message: why)) }
        let name = name.trimmingCharacters(in: .whitespaces)
        let folder = parent(of: path)
        let target = folder + "/" + name
        if target == path { return .success(path) }
        if target.lowercased() != path.lowercased(), taken(name, in: folder) {
            return .failure(HostRefusal(message: "A file or folder named \(name) already exists here."))
        }
        let result = await source.rename(path, to: target)
        if case .success(let moved) = result {
            landed([(path, moved)])
            await settle([folder], selecting: moved)
        }
        return result
    }

    /// Moves entries into a folder (a drop, ⌘V after ⌘X): each that can go, the first failure
    /// said. Open tabs follow.
    func move(_ paths: [String], into folder: String) async -> String? {
        var done: [(String, String)] = []
        var failure: String?
        for path in paths where parent(of: path) != folder && !LinkFiles.inside(folder, path) {
            switch await source.rename(path, to: folder + "/" + (path as NSString).lastPathComponent) {
            case .success(let moved): done.append((path, moved))
            case .failure(let why): failure = failure ?? why.message
            }
        }
        landed(done)
        await settle(Set(done.map { parent(of: $0.0) } + [folder]), selecting: done.last?.1)
        return failure
    }

    /// Move to Trash: the box's trash. The first failure said.
    func trash(_ paths: [String]) async -> String? {
        var gone: [String] = []
        var failure: String?
        for path in paths {
            switch await source.trash(path) {
            case .success: gone.append(path)
            case .failure(let why): failure = failure ?? why.message
            }
        }
        if !gone.isEmpty { onTrashed?(gone) }
        if let selection, gone.contains(where: { selection == $0 || selection.hasPrefix($0 + "/") }) { pickOnly(nil) }
        await settle(Set(gone.map { parent(of: $0) }), selecting: nil)
        return failure
    }

    /// Writes files dropped from this Mac into `folder` (each as one upload): a taken name is
    /// asked about by `collision` (replace, keep both, or stop).
    func upload(_ files: [(name: String, data: Data)], into folder: String, collision: (String) -> BoxCollision) async -> String? {
        var failure: String?
        var last: String?
        for file in files {
            var name = file.name
            if taken(name, in: folder) {
                switch collision(name) {
                case .replace: break
                case .keepBoth: name = free(name, in: folder)
                case .cancel: return failure
                }
            }
            guard file.data.count <= LinkUploads.maxSize else {
                failure = failure ?? "\(file.name) is over 12 MB."
                continue
            }
            switch await source.write(folder + "/" + name, file.data, base: nil) {
            case .success: last = folder + "/" + name
            case .failure(.refused(let why)): failure = failure ?? why
            case .failure(.conflict): failure = failure ?? "\(name) changed on \(alias) meanwhile."
            }
        }
        await settle([folder], selecting: last)
        return failure
    }

    /// "name copy.ext", "name copy 2.ext"… not taken in the folder.
    private func free(_ name: String, in folder: String) -> String {
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = stem + (n == 1 ? " copy" : " copy \(n)") + (ext.isEmpty ? "" : "." + ext)
            if !taken(candidate, in: folder) { return candidate }
            n += 1
        }
    }

    private func landed(_ moves: [(String, String)]) {
        for (old, new) in moves {
            onMoved?(old, new)
            // An open folder that moved stays open where it went.
            for open in expanded where open == old || open.hasPrefix(old + "/") {
                expanded.remove(open)
                expanded.insert(new + open.dropFirst(old.count))
            }
        }
    }

    /// The folders listed again, and the rows once.
    private func settle(_ folders: Set<String>, selecting: String?) async {
        for folder in folders.sorted() where folder == root || children[folder] != nil { await load(folder, rebuilding: false) }
        if let selecting { pickOnly(selecting) }
        rebuild()
    }

    // MARK: Rows

    private func rebuild() {
        var rows: [Row] = []
        append(root, depth: 0, into: &rows)
        if self.rows != rows { self.rows = rows }
        watchOpenFolders()
    }

    private func append(_ folder: String, depth: Int, into rows: inout [Row]) {
        if let why = failed[folder], folder != root {
            rows.append(Row(id: folder + "/\u{0}note", name: why, depth: depth, isFolder: false, isOpen: false, kind: .note(why)))
            return
        }
        switch edit {
        case .newFolder(let parent) where parent == folder:
            rows.append(Row(id: folder + "/\u{0}new", name: "", depth: depth, isFolder: true, isOpen: false, kind: .newFolder))
        case .newFile(let parent) where parent == folder:
            rows.append(Row(id: folder + "/\u{0}new", name: "", depth: depth, isFolder: false, isOpen: false, kind: .newFile))
        default: break
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

    // MARK: Watching

    /// The folders showing now: the root and each open folder listed.
    var openFolders: Set<String> {
        Set([root] + expanded.filter { children[$0] != nil && isShown($0) })
    }

    /// The box watches what shows, and nothing else: sent again when that changes.
    private func watchOpenFolders() {
        guard rootLoaded, rootError == nil else { return }
        let open = openFolders
        guard open != watched else { return }
        watched = open
        watchTask?.cancel()
        let source = source, key = watchKey
        watchTask = Task { [weak self] in
            let watching = await source.watch(key, open) { [weak self] folders in self?.changed(folders) }
            guard !Task.isCancelled else { return }
            self?.watching = watching
        }
    }

    var isEmpty: Bool { rootLoaded && rootError == nil && rows.isEmpty }

    func relative(_ path: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    func parent(of path: String) -> String { (path as NSString).deletingLastPathComponent }

    func row(_ path: String) -> Row? { rows.first { $0.id == path } }
}

/// A dropped file whose name is taken: replace it, keep both, or stop.
enum BoxCollision { case replace, keepBoth, cancel }
