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
    /// The folder a drag is over.
    var dropTarget: String? { dropping.target }
    /// A drag over the tree: its target, badge and the folders it sprang open.
    @ObservationIgnored let dropping = TreeDropping()
    /// The box watches the open folders; false: a turn's end lists them again.
    private(set) var watching = false
    /// One plain line when the box refused something shown already (it's put back): it goes by
    /// itself after a while.
    private(set) var problem: String?
    @ObservationIgnored private var problemClear: Task<Void, Never>?

    /// The folder's entries moved or went (a rename, a move, Move to Trash): open tabs follow.
    @ObservationIgnored var onMoved: ((String, String) -> Void)?
    @ObservationIgnored var onTrashed: (([String]) -> Void)?
    /// Files in these folders changed on the box: open tabs read them again.
    @ObservationIgnored var onChanged: ((BoxChange) -> Void)?

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
        dropping.isOpen = { [weak self] in self?.isExpanded($0) ?? true }
        dropping.expand = { [weak self] in self?.expand($0) }
        dropping.collapse = { [weak self] in self?.collapse($0) }
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

    /// Opens a folder: what was listed before shows at once and is asked again behind it; a
    /// folder never listed says Loading… in place.
    func expand(_ path: String) {
        expanded.insert(path)
        let cached = children[path] != nil
        if !cached { failed[path] = nil }
        if !loading.contains(path) {
            loading.insert(path)
            Task { await load(path) }
        }
        _ = cached
        rebuild()
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
            rebuild()
        } while again
        reloading = false
    }

    /// The box said these folders changed: listed again (only those), and the open files it
    /// names read again.
    func changed(_ change: BoxChange) {
        Task {
            for folder in change.folders.sorted() where children[folder] != nil { await load(folder, rebuilding: false) }
            rebuild()
            onChanged?(change)
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
            children[folder] = listing.entries.filter { !Self.hidden.contains($0.name) && !FileCarry.isStaging($0.name) }
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

    /// A new empty file or a folder in `parent`: it shows at once, selected; the box makes it,
    /// and when it refuses, it goes again and the line says why.
    func create(_ name: String, in parent: String, folder: Bool) async -> Result<String, HostRefusal> {
        if let why = Self.refusal(name) { return .failure(HostRefusal(message: why)) }
        let name = name.trimmingCharacters(in: .whitespaces)
        if taken(name, in: parent) { return .failure(HostRefusal(message: "A file or folder named \(name) already exists here.")) }
        let path = parent + "/" + name
        place(FileEntry(name: name, kind: folder ? .dir : .file, size: folder ? nil : 0), in: parent)
        pickOnly(path)
        rebuild()
        let result = await source.create(path, folder: folder)
        switch result {
        case .success:
            if folder { expanded.insert(path) }
            await settle([parent], selecting: nil)
        case .failure(let why):
            unplace(name, in: parent)
            if selection == path { pickOnly(nil) }
            say(why.message)
            rebuild()
        }
        return result
    }

    /// Renames in place at once; open tabs follow. Put back when the box refuses.
    func rename(_ path: String, to name: String) async -> Result<String, HostRefusal> {
        if let why = Self.refusal(name) { return .failure(HostRefusal(message: why)) }
        let name = name.trimmingCharacters(in: .whitespaces)
        let folder = parent(of: path)
        let target = folder + "/" + name
        if target == path { return .success(path) }
        if target.lowercased() != path.lowercased(), taken(name, in: folder) {
            return .failure(HostRefusal(message: "A file or folder named \(name) already exists here."))
        }
        let old = (path as NSString).lastPathComponent
        guard let entry = children[folder]?.first(where: { $0.name == old }) else { return .failure(HostRefusal(message: "\(old) isn't there any more.")) }
        unplace(old, in: folder)
        var renamed = entry
        renamed.name = name
        place(renamed, in: folder)
        landed([(path, target)])
        pickOnly(target)
        rebuild()
        let result = await source.rename(path, to: target)
        switch result {
        case .success:
            await settle([folder], selecting: nil)
        case .failure(let why):
            unplace(name, in: folder)
            place(entry, in: folder)
            landed([(target, path)])
            pickOnly(path)
            say(why.message)
            rebuild()
        }
        return result
    }

    /// The entry shows in a folder this tree has listed: one a move here can place at once.
    func shows(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return children[parent(of: path)]?.contains { $0.name == name } == true
    }

    /// Moves entries into a folder (a drop, ⌘V after ⌘X): they show there at once; any the box
    /// refuses go back, and the line says why. Open tabs follow.
    func move(_ paths: [String], into folder: String) async -> String? {
        let moving = paths.filter { parent(of: $0) != folder && !LinkFiles.inside(folder, $0) }
        var shown: [(from: String, entry: FileEntry)] = []
        for path in moving {
            let name = (path as NSString).lastPathComponent
            guard !taken(name, in: folder), let entry = children[parent(of: path)]?.first(where: { $0.name == name }) else { continue }
            unplace(name, in: parent(of: path))
            place(entry, in: folder)
            shown.append((path, entry))
        }
        landed(shown.map { ($0.from, folder + "/" + $0.entry.name) })
        rebuild()
        var failure: String?
        for (from, entry) in shown {
            let target = folder + "/" + entry.name
            if case .failure(let why) = await source.rename(from, to: target) {
                failure = failure ?? why.message
                unplace(entry.name, in: folder)
                place(entry, in: parent(of: from))
                landed([(target, from)])
            }
        }
        if shown.count < moving.count { failure = failure ?? "A file or folder with that name already exists there." }
        if let failure { say(failure) }
        await settle(Set(moving.map { parent(of: $0) } + [folder]), selecting: shown.last.map { folder + "/" + $0.entry.name })
        return failure
    }

    /// Move to Trash: gone from the tree at once, into the box's trash; any the box refuses come
    /// back, and the line says why.
    func trash(_ paths: [String]) async -> String? {
        var hidden: [(path: String, entry: FileEntry)] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard let entry = children[parent(of: path)]?.first(where: { $0.name == name }) else { continue }
            unplace(name, in: parent(of: path))
            hidden.append((path, entry))
        }
        if let selection, paths.contains(where: { selection == $0 || selection.hasPrefix($0 + "/") }) { pickOnly(nil) }
        rebuild()
        var gone: [String] = []
        var failure: String?
        for (path, entry) in hidden {
            switch await source.trash(path) {
            case .success: gone.append(path)
            case .failure(let why):
                failure = failure ?? why.message
                place(entry, in: parent(of: path))
            }
        }
        if !gone.isEmpty { onTrashed?(gone) }
        if let failure { say(failure) }
        await settle(Set(paths.map { parent(of: $0) }), selecting: nil)
        return failure
    }

    /// An entry shown in a folder's listing now, in the tree's order (folders first, then names).
    private func place(_ entry: FileEntry, in folder: String) {
        guard var list = children[folder], !list.contains(where: { $0.name == entry.name }) else { return }
        list.append(entry)
        list.sort { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        children[folder] = list
    }

    private func unplace(_ name: String, in folder: String) { children[folder]?.removeAll { $0.name == name } }

    /// The line under the tree, for a while.
    func say(_ line: String) {
        problem = line
        problemClear?.cancel()
        problemClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.problem = nil
        }
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
        if let failure { say(failure) }
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
        for folder in folders.sorted() where folder == root || children[folder] != nil || expanded.contains(folder) {
            await load(folder, rebuilding: false)
        }
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
        let waiting = children[folder] == nil && loading.contains(folder) && folder != root
        switch edit {
        case .newFolder(let parent) where parent == folder:
            rows.append(Row(id: folder + "/\u{0}new", name: "", depth: depth, isFolder: true, isOpen: false, kind: .newFolder))
        case .newFile(let parent) where parent == folder:
            rows.append(Row(id: folder + "/\u{0}new", name: "", depth: depth, isFolder: false, isOpen: false, kind: .newFile))
        default: break
        }
        if waiting {
            rows.append(Row(id: folder + "/\u{0}loading", name: "Loading…", depth: depth, isFolder: false, isOpen: false, kind: .note("Loading…")))
            return
        }
        for entry in withPending(children[folder], in: folder) {
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

    /// A folder's entries and those on their way into it (`FileCarries`), in the tree's order.
    private func withPending(_ listed: [FileEntry]?, in folder: String) -> [FileEntry] {
        guard let listed else { return [] }
        let coming = FileCarries.shared.pending(in: .box(alias: alias, path: folder))
        guard !coming.isEmpty else { return listed }
        let names = Set(listed.map(\.name))
        var all = listed + coming.filter { !names.contains($0.name) }.map { FileEntry(name: $0.name, kind: $0.isFolder ? .dir : .file) }
        all.sort { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return all
    }

    /// Entries on their way came or went.
    func carriesChanged() { rebuild() }

    /// A carry landed: the open folders listed again, the last entry here chosen.
    func landed(_ outcome: CarryOutcome) async {
        await refresh()
        if let last = outcome.landed.last(where: { $0.alias == alias && LinkFiles.inside($0.path, root) }) { await reveal(last.path) }
    }

    /// The box can be reached now (a drop onto an offline box is refused).
    var reachable: Bool { (source as? HostConnection)?.isOnline ?? true }

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
