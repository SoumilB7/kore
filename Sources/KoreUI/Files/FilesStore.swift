import AppKit
import KoreCore
import Observation

/// The folder's files as the explorer shows them: folders listed when first opened, a chain
/// of single-folder folders shown as one row, git states, and one FSEvents stream for the
/// window that keeps listings, git states and open files current while agents edit.
/// Made when the explorer first opens or a file tab first shows, not with the window.
@MainActor @Observable
final class FilesStore {
    struct Node: Equatable, Sendable {
        let path: String
        let name: String
        let isFolder: Bool
    }

    /// A visible row: one file or folder, or a chain of folders that each hold one folder.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case node, newFile, newFolder }

        /// The path the row acts on (the chain's last folder).
        let id: String
        /// The chain's names, root-most first; one name for most rows.
        let names: [String]
        let depth: Int
        let isFolder: Bool
        let isOpen: Bool
        var kind = Kind.node
    }

    enum Edit: Equatable {
        case newFile(parent: String)
        case newFolder(parent: String)
        case rename(String)
    }

    let root: String
    private(set) var rows: [Row] = []
    private(set) var git = GitStatus.empty
    private(set) var rootLoaded = false
    private(set) var rootError = false
    var selection: String?
    /// The folder a drag is over: it and its open rows fill (look §3).
    var dropTarget: String?
    var edit: Edit? {
        didSet { if edit != oldValue { rebuild() } }
    }
    /// Tells the workspace which paths changed on disk (for its open files).
    @ObservationIgnored var onChange: (([String]) -> Void)?
    /// Tells the workspace which work trees (this folder's or one nested in it) moved `HEAD`,
    /// the index or a branch: commit, checkout, reset, stash, pull. Their open files' change
    /// bars are against a `HEAD` that's gone.
    @ObservationIgnored var onGitMove: (([String]) -> Void)?

    @ObservationIgnored private var children: [String: [Node]] = [:]
    @ObservationIgnored private var expanded: Set<String> = []
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var gitRefresh: Task<Void, Never>?
    @ObservationIgnored private var moved: Set<String> = []
    @ObservationIgnored private var movedReport: Task<Void, Never>?

    /// `.git` and Finder's litter are hidden; other dotfiles show (VS Code's `files.exclude`).
    nonisolated private static let hidden: Set<String> = [".git", ".DS_Store", ".svn", ".hg"]

    init(folder: URL) {
        root = realPath(folder.path)
        watcher = FolderWatcher(URL(fileURLWithPath: root)) { [weak self] paths in self?.changed(paths) }
        Task { await load(root) }
        refreshGit()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    func state(of path: String) -> GitStatus.State? { git.state(of: path) }

    func relative(_ path: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    // MARK: - Opening folders

    func toggle(_ path: String) {
        if expanded.contains(path) { collapse(path) } else { expand(path) }
    }

    func expand(_ path: String) {
        expanded.insert(path)
        if children[path] == nil {
            Task { await load(path) }
        } else {
            rebuild()
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

    /// Opens the folders down to `path` and selects it (a file opened elsewhere, the path row).
    func reveal(_ path: String) async {
        var folder = (path as NSString).deletingLastPathComponent
        var chain: [String] = []
        while folder.count > root.count, folder.hasPrefix(root) {
            chain.insert(folder, at: 0)
            folder = (folder as NSString).deletingLastPathComponent
        }
        for folder in chain {
            expanded.insert(folder)
            if children[folder] == nil { await load(folder, rebuilding: false) }
        }
        selection = path
        rebuild()
    }

    func refresh() {
        let loaded = Array(children.keys)
        Task {
            for folder in loaded { await load(folder, rebuilding: false) }
            rebuild()
        }
        refreshGit()
    }

    /// Lists a folder off the main thread. A folder holding just one folder lists that one too,
    /// so the chain shows as one row.
    private func load(_ folder: String, rebuilding: Bool = true) async {
        let listed = await Task.detached { Self.list(folder) }.value
        if folder == root {
            rootLoaded = true
            rootError = listed == nil
        }
        guard let listed else {
            children[folder] = nil
            if rebuilding { rebuild() }
            return
        }
        children[folder] = listed
        if expanded.contains(folder), listed.count == 1, let only = listed.first, only.isFolder, children[only.path] == nil {
            expanded.insert(only.path)
            await load(only.path, rebuilding: false)
        }
        if rebuilding { rebuild() }
    }

    /// A folder's entries, folders first (the path row's menu lists them too).
    nonisolated static func list(_ folder: String) -> [Node]? {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else {
            return nil
        }
        return urls.compactMap { url -> Node? in
            let name = url.lastPathComponent
            guard !hidden.contains(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Packages (.app, .xcodeproj) are folders here, as in VS Code.
            return Node(path: folder + "/" + name, name: name, isFolder: values?.isDirectory == true)
        }
        .sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Rows

    private func rebuild() {
        var rows: [Row] = []
        append(children: root, depth: 0, into: &rows)
        if self.rows != rows { self.rows = rows }
    }

    private func append(children folder: String, depth: Int, into rows: inout [Row]) {
        switch edit {
        case .newFolder(let parent) where parent == folder:
            rows.append(Row(id: folder + "/\u{0}new", names: [""], depth: depth, isFolder: true, isOpen: false, kind: .newFolder))
        case .newFile(let parent) where parent == folder:
            rows.append(Row(id: folder + "/\u{0}new", names: [""], depth: depth, isFolder: false, isOpen: false, kind: .newFile))
        default:
            break
        }
        for node in children[folder] ?? [] {
            guard node.isFolder else {
                rows.append(Row(id: node.path, names: [node.name], depth: depth, isFolder: false, isOpen: false))
                continue
            }
            // Compact a chain of folders that each hold only one folder (not while renaming in it).
            var names = [node.name]
            var path = node.path
            while expanded.contains(path), let inner = children[path], inner.count == 1, let only = inner.first, only.isFolder,
                edit != .rename(only.path), edit != .newFile(parent: path), edit != .newFolder(parent: path)
            {
                names.append(only.name)
                path = only.path
            }
            let open = expanded.contains(path)
            rows.append(Row(id: path, names: names, depth: depth, isFolder: true, isOpen: open))
            if open { append(children: path, depth: depth + 1, into: &rows) }
        }
    }

    /// The parent folder rows show their guide brighter for (the selection's folder).
    func parent(of path: String) -> String { (path as NSString).deletingLastPathComponent }

    // MARK: - Changes on disk

    private func changed(_ paths: [String]) {
        var folders: Set<String> = []
        var gitChanged = false
        var files: [String] = []
        var trees: Set<String> = []
        for path in paths {
            if let git = path.range(of: "/.git/") ?? path.range(of: "/.git", options: [.anchored, .backwards]) {
                // Commits, staging, checkouts; not object churn.
                if path.hasSuffix("/index") || path.hasSuffix("/HEAD") || path.contains("/refs/") {
                    gitChanged = true
                    trees.insert(String(path[..<git.lowerBound]))
                }
                continue
            }
            gitChanged = true
            files.append(path)
            let parent = (path as NSString).deletingLastPathComponent
            if children[parent] != nil { folders.insert(parent) }
            if children[path] != nil { folders.insert(path) }
        }
        if !folders.isEmpty {
            Task {
                for folder in folders { await load(folder, rebuilding: false) }
                rebuild()
            }
        }
        if gitChanged { refreshGit() }
        if !trees.isEmpty { report(moved: trees) }
        if !files.isEmpty { onChange?(files) }
    }

    /// A commit writes the index, a ref and `HEAD` over a few events: one report once they stop.
    private func report(moved trees: Set<String>) {
        moved.formUnion(trees)
        movedReport?.cancel()
        movedReport = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let trees = Array(moved)
            moved = []
            movedReport = nil
            onGitMove?(trees)
        }
    }

    /// Git states, at most every half second while files keep changing.
    private func refreshGit() {
        guard gitRefresh == nil else { return }
        let root = URL(fileURLWithPath: root)
        gitRefresh = Task {
            try? await Task.sleep(for: .milliseconds(500))
            let status = await GitStatus.read(root) ?? .empty
            if status != git { git = status }
            gitRefresh = nil
        }
    }

    // MARK: - File operations

    enum Failure: Error, Equatable {
        case exists(String)
        case invalid
        case system(String)

        var message: String {
            switch self {
            case .exists(let name): "A file or folder named \(name) already exists here."
            case .invalid: "A name can't contain “/” or be empty."
            case .system(let reason): reason
            }
        }
    }

    /// Whether `name` would clash in `folder` (for the inline field's outline).
    func clash(_ name: String, in folder: String, except: String? = nil) -> Failure? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.contains("/") { return .invalid }
        let path = folder + "/" + trimmed
        if path != except, FileManager.default.fileExists(atPath: path) { return .exists(trimmed) }
        return nil
    }

    /// Creates the file or folder the inline field named; the new path on success.
    func create(_ name: String, folder: Bool, in parent: String) -> Result<String, Failure> {
        if let failure = clash(name, in: parent) { return .failure(failure) }
        let path = parent + "/" + name.trimmingCharacters(in: .whitespaces)
        do {
            if folder {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: path, contents: Data()) {
                return .failure(.system("Kore couldn't create \(name)."))
            }
        } catch {
            return .failure(.system(error.localizedDescription))
        }
        Task { await reload(parent) }
        return .success(path)
    }

    func rename(_ path: String, to name: String) -> Result<String, Failure> {
        let parent = (path as NSString).deletingLastPathComponent
        let target = parent + "/" + name.trimmingCharacters(in: .whitespaces)
        if target == path { return .success(path) }
        // A case-only rename is the same file on macOS.
        if target.lowercased() != path.lowercased(), let failure = clash(name, in: parent) { return .failure(failure) }
        do { try FileManager.default.moveItem(atPath: path, toPath: target) } catch {
            return .failure(.system(error.localizedDescription))
        }
        if expanded.remove(path) != nil { expanded.insert(target) }
        if selection == path { selection = target }
        Task { await reload(parent) }
        return .success(target)
    }

    func trash(_ path: String) -> Failure? {
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) } catch {
            return .system(error.localizedDescription)
        }
        Task { await reload((path as NSString).deletingLastPathComponent) }
        return nil
    }

    // MARK: - Moving and copying (drag in the tree)

    /// What to do when a dropped item's name is taken in the folder.
    enum Collision { case replace, keepBoth, cancel }

    /// One move or copy that was done, with what undoing it needs.
    struct Transfer: Sendable {
        let from: String
        let to: String
        let copied: Bool
        /// What was at `to` before, now in the Trash (a replace).
        let replaced: URL?
    }

    /// Whether `source` can go into `folder`: never into itself or below it; a move into its
    /// own folder does nothing (a copy there makes a "copy").
    func canDrop(_ source: String, into folder: String, copy: Bool) -> Bool {
        guard folder != source, !folder.hasPrefix(source + "/") else { return false }
        return copy || (source as NSString).deletingLastPathComponent != folder
    }

    /// Moves or copies each of `sources` into `folder`, asking `collision` when a name is
    /// taken (Cancel stops the rest). Moved folders stay open; the selection follows the last
    /// item; `moved` is told each move so open tabs follow.
    func transfer(
        _ sources: [String], into folder: String, copy: Bool, collision: (String) -> Collision,
        moved: (String, String) -> Void
    ) -> (done: [Transfer], failure: Failure?) {
        var done: [Transfer] = []
        var failure: Failure?
        let manager = FileManager.default
        items: for source in sources where canDrop(source, into: folder, copy: copy) {
            let name = (source as NSString).lastPathComponent
            var target = folder + "/" + name
            var replaced: URL?
            if target == source {
                target = Self.unusedName(for: name, in: folder)
            } else if manager.fileExists(atPath: target) {
                switch collision(name) {
                case .cancel:
                    break items
                case .keepBoth:
                    target = Self.unusedName(for: name, in: folder)
                case .replace:
                    var trashed: NSURL?
                    do { try manager.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: &trashed) } catch {
                        failure = .system(error.localizedDescription)
                        continue items
                    }
                    replaced = trashed as URL?
                }
            }
            do {
                if copy { try manager.copyItem(atPath: source, toPath: target) } else { try manager.moveItem(atPath: source, toPath: target) }
            } catch {
                failure = .system(error.localizedDescription)
                // What the replace sent to the Trash goes back where it was.
                if let replaced { try? manager.moveItem(at: replaced, to: URL(fileURLWithPath: target)) }
                continue
            }
            if !copy {
                follow(source, to: target)
                moved(source, target)
            }
            done.append(Transfer(from: source, to: target, copied: copy, replaced: replaced))
        }
        if let last = done.last {
            if folder != root { expanded.insert(folder) }
            selection = last.to
        }
        reloadAround(done)
        return (done, failure)
    }

    /// Puts transfers back: a copy goes to the Trash, a move goes home, and what a replace sent
    /// to the Trash comes back. Last first. `moved` is told each move back.
    func undo(_ transfers: [Transfer], moved: (String, String) -> Void) -> Failure? {
        var failure: Failure?
        let manager = FileManager.default
        for transfer in transfers.reversed() {
            do {
                if transfer.copied {
                    try manager.trashItem(at: URL(fileURLWithPath: transfer.to), resultingItemURL: nil)
                } else {
                    try manager.moveItem(atPath: transfer.to, toPath: transfer.from)
                    follow(transfer.to, to: transfer.from)
                    moved(transfer.to, transfer.from)
                }
                if let replaced = transfer.replaced { try manager.moveItem(at: replaced, to: URL(fileURLWithPath: transfer.to)) }
            } catch {
                failure = .system(error.localizedDescription)
            }
        }
        if let first = transfers.first { selection = first.from }
        reloadAround(transfers)
        return failure
    }

    /// Does transfers again after an undo, the way they were done.
    func redo(_ transfers: [Transfer], moved: (String, String) -> Void) -> (done: [Transfer], failure: Failure?) {
        var done: [Transfer] = []
        var failure: Failure?
        let manager = FileManager.default
        for transfer in transfers {
            do {
                var replaced: URL?
                if manager.fileExists(atPath: transfer.to) {
                    var trashed: NSURL?
                    try manager.trashItem(at: URL(fileURLWithPath: transfer.to), resultingItemURL: &trashed)
                    replaced = trashed as URL?
                }
                if transfer.copied {
                    try manager.copyItem(atPath: transfer.from, toPath: transfer.to)
                } else {
                    try manager.moveItem(atPath: transfer.from, toPath: transfer.to)
                    follow(transfer.from, to: transfer.to)
                    moved(transfer.from, transfer.to)
                }
                done.append(Transfer(from: transfer.from, to: transfer.to, copied: transfer.copied, replaced: replaced))
            } catch {
                failure = .system(error.localizedDescription)
            }
        }
        if let last = done.last { selection = last.to }
        reloadAround(done)
        return (done, failure)
    }

    /// A moved folder keeps its open folders, at their new paths.
    private func follow(_ old: String, to new: String) {
        let moved = expanded.filter { $0 == old || $0.hasPrefix(old + "/") }
        for path in moved {
            expanded.remove(path)
            expanded.insert(new + path.dropFirst(old.count))
        }
        for key in children.keys where key == old || key.hasPrefix(old + "/") { children[key] = nil }
    }

    private func reloadAround(_ transfers: [Transfer]) {
        var folders = Set<String>()
        for transfer in transfers {
            folders.insert((transfer.from as NSString).deletingLastPathComponent)
            folders.insert((transfer.to as NSString).deletingLastPathComponent)
        }
        Task {
            for folder in folders where folder == root || children[folder] != nil || expanded.contains(folder) {
                await load(folder, rebuilding: false)
            }
            rebuild()
        }
    }

    /// "name copy.ext", then "name copy 2.ext"…, as VS Code names a kept or duplicated item.
    nonisolated static func unusedName(for name: String, in folder: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || base.isEmpty ? "" : "." + ext
        let stem = base.isEmpty ? name : base
        var n = 1
        while true {
            let candidate = stem + (n == 1 ? " copy" : " copy \(n)") + suffix
            let path = folder + "/" + candidate
            if !FileManager.default.fileExists(atPath: path) { return path }
            n += 1
        }
    }

    private func reload(_ folder: String) async {
        await load(folder, rebuilding: false)
        rebuild()
    }

    /// The folder new items go in: the selection's folder, or the root.
    func targetFolder() -> String {
        guard let selection else { return root }
        if rows.first(where: { $0.id == selection })?.isFolder == true { return selection }
        return (selection as NSString).deletingLastPathComponent
    }

    func startNew(folder isFolder: Bool) {
        let parent = targetFolder()
        if parent != root { expanded.insert(parent) }
        edit = isFolder ? .newFolder(parent: parent) : .newFile(parent: parent)
    }
}
