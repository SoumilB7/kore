import Combine
import Foundation
import KoreCore

/// A row of the @ menu: a file or folder of the chat's folder, a model, a skill, or another tab.
struct AtItem: Identifiable, Equatable, Sendable {
    /// The groups, in this order when nothing is typed.
    enum Kind: Int, CaseIterable, Sendable {
        case file, folder, model, skill, tab

        var name: String {
            switch self {
            case .file: "file"
            case .folder: "folder"
            case .model: "model"
            case .skill: "skill"
            case .tab: "tab"
            }
        }

        var title: String {
            switch self {
            case .file: "Files"
            case .folder: "Folders"
            case .model: "Models"
            case .skill: "Skills"
            case .tab: "Tabs"
            }
        }

        /// Rows a group shows at most: the menu stays a few screens of rows on any folder.
        var cap: Int {
            switch self {
            case .file: 8
            case .folder, .model, .skill, .tab: 4
            }
        }
    }

    let kind: Kind
    /// The relative path, the model's id, the skill's name, the tab's id.
    let key: String
    let label: String
    let detail: String
    let score: Int
    var id: String { "\(kind.name):\(key)" }
}

/// What the @ menu searches, read on the main actor and ranked off it.
struct AtCandidates: Sendable {
    struct Tab: Sendable {
        let id: String
        let title: String
    }

    var files: [String] = []
    var folders: [String] = []
    /// Shown for a bare "@" in place of the folder's files.
    var recent: [String] = []
    var models: [ModelOption] = []
    var currentModel: String?
    var skills: [SlashCommand] = []
    var tabs: [Tab] = []
}

/// One fuzzy search over every kind (`FuzzyMatch`, as quick open's): each kind's best rows,
/// capped, and the kinds ordered by their best row. A bare "@" lists the recently opened files,
/// the models, the skills and the tabs.
enum AtRank {
    static func rank(_ query: String, _ candidates: AtCandidates) -> [AtItem] {
        let needle = Array(query.replacingOccurrences(of: " ", with: "").utf16)
        var groups: [[AtItem]] = []
        groups.append(best(.file, needle.isEmpty ? candidates.recent : candidates.files, needle) { fileItem(.file, $0, $1) })
        if !needle.isEmpty {
            groups.append(best(.folder, candidates.folders, needle) { fileItem(.folder, $0, $1) })
        }
        groups.append(
            best(.model, candidates.models, needle, text: { [$0.name, $0.id] }) { model, score in
                AtItem(
                    kind: .model, key: model.id, label: model.name,
                    detail: model.id == candidates.currentModel ? "current" : (model.name == model.id ? "" : model.id), score: score)
            })
        groups.append(
            best(.skill, candidates.skills, needle, text: { [$0.name] }) { skill, score in
                AtItem(kind: .skill, key: skill.name, label: skill.name, detail: skill.summary, score: score)
            })
        groups.append(
            best(.tab, candidates.tabs, needle, text: { [$0.title] }) { tab, score in
                AtItem(kind: .tab, key: tab.id, label: tab.title, detail: "", score: score)
            })
        let kept = groups.filter { !$0.isEmpty }
        guard !needle.isEmpty else { return kept.flatMap { $0 } }
        // The kind with the best row first; equal ones in the kinds' own order.
        return kept.sorted { a, b in
            a[0].score != b[0].score ? a[0].score > b[0].score : a[0].kind.rawValue < b[0].kind.rawValue
        }.flatMap { $0 }
    }

    private static func fileItem(_ kind: AtItem.Kind, _ path: String, _ score: Int) -> AtItem {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        return AtItem(kind: kind, key: path, label: kind == .folder ? name + "/" : name, detail: parent, score: score)
    }

    private static func best(
        _ kind: AtItem.Kind, _ paths: [String], _ needle: [UInt16], make: (String, Int) -> AtItem
    ) -> [AtItem] {
        best(kind, paths, needle, text: { [$0] }, make: make)
    }

    /// The `kind.cap` best by score, kept as they come (a bounded insertion, no sort of every
    /// match: a short query matches most of a big folder). Equal scores keep the list's order.
    private static func best<T>(
        _ kind: AtItem.Kind, _ list: [T], _ needle: [UInt16], text: (T) -> [String], make: (T, Int) -> AtItem
    ) -> [AtItem] {
        let cap = kind.cap
        if needle.isEmpty { return list.prefix(cap).map { make($0, 0) } }
        var top: [(score: Int, item: T)] = []
        top.reserveCapacity(cap + 1)
        for entry in list {
            guard let score = text(entry).compactMap({ FuzzyMatch.match(needle, in: $0)?.score }).max() else { continue }
            if top.count == cap, let last = top.last, score <= last.score { continue }
            let at = top.firstIndex { $0.score < score } ?? top.count
            top.insert((score, entry), at: at)
            if top.count > cap { top.removeLast() }
        }
        return top.map { make($0.item, $0.score) }
    }

    /// Every folder that holds one of `files` (relative paths), each once, in the order met.
    static func folders(of files: [String]) -> [String] {
        var seen = Set<Substring>()
        var folders: [String] = []
        for path in files {
            var end = path.endIndex
            while let slash = path[..<end].lastIndex(of: "/") {
                let folder = path[..<slash]
                guard seen.insert(folder).inserted else { break }
                folders.append(String(folder))
                end = slash
            }
        }
        return folders
    }
}

/// The @ menu's search for one composer: the chat folder's files (quick open's `FileIndex`),
/// listed when the menu opens, and the ranked rows. Typing waits a moment before ranking, and
/// ranks off the main thread, so a keystroke never waits for a big folder.
@MainActor
final class AtSearch: ObservableObject {
    @Published private(set) var results: [AtItem] = []

    private var folder: URL?
    private var files: [String] = []
    private var folders: [String] = []
    private var listing: Task<Void, Never>?
    private var ranking: Task<Void, Never>?
    private var last: (query: String, candidates: AtCandidates)?
    /// A keystroke's wait before ranking: the next one within it replaces it.
    static let debounce: Duration = .milliseconds(30)

    /// A new "@": the rows of the last one go, and the folder is listed again (it may have
    /// changed), the rows as they were found meanwhile.
    func open(_ folder: URL) {
        if !results.isEmpty { results = [] }
        if self.folder != folder {
            self.folder = folder
            files = []
            folders = []
        }
        listing?.cancel()
        listing = Task { [weak self] in
            let listed = await FileIndex.files(in: folder)
            let found = await Task.detached { AtRank.folders(of: listed) }.value
            guard let self, !Task.isCancelled, self.folder == folder else { return }
            files = listed
            folders = found
            if let last { search(last.query, last.candidates, wait: false) }
        }
    }

    func search(_ query: String, _ candidates: AtCandidates, wait: Bool = true) {
        var candidates = candidates
        candidates.files = files
        candidates.folders = folders
        last = (query, candidates)
        ranking?.cancel()
        ranking = Task { [weak self] in
            if wait { try? await Task.sleep(for: Self.debounce) }
            guard !Task.isCancelled else { return }
            let ranked = await Task.detached(priority: .userInitiated) { AtRank.rank(query, candidates) }.value
            guard let self, !Task.isCancelled else { return }
            if ranked != results { results = ranked }
        }
    }

    func close() {
        ranking?.cancel()
        listing?.cancel()
        last = nil
        if !results.isEmpty { results = [] }
    }
}
