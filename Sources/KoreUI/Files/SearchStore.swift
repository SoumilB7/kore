import Foundation
import KoreCore
import Observation

/// The Search view's state for one window (VS Code's Search): the query and its options, and
/// the results grouped by file as they stream in. A change runs a new search after a short
/// pause, cancelling the one before.
@MainActor @Observable
final class SearchStore {
    struct FileResult: Identifiable, Equatable {
        let path: String
        var hits: [SearchHit]
        var id: String { path }
        var matchCount: Int { hits.reduce(0) { $0 + $1.matches.count } }
    }

    enum Outcome: Equatable {
        case idle
        case running
        case done
        case capped
        case failed(String)
    }

    var text = "" { didSet { if text != oldValue { schedule() } } }
    var caseSensitive = false { didSet { if caseSensitive != oldValue { schedule(now: true) } } }
    var wholeWord = false { didSet { if wholeWord != oldValue { schedule(now: true) } } }
    var regex = false { didSet { if regex != oldValue { schedule(now: true) } } }
    var include = "" { didSet { if include != oldValue { schedule() } } }
    var exclude = "" { didSet { if exclude != oldValue { schedule() } } }
    /// The include / exclude fields are shown.
    var showsDetails = false

    private(set) var results: [FileResult] = []
    private(set) var outcome = Outcome.idle
    private(set) var matchCount = 0
    /// Files whose matches are folded away.
    var collapsed: Set<String> = []
    /// The selected row: a file group or one hit (path + line).
    var selection: Row?
    /// Bumped to put the caret in the query field (⇧⌘F).
    private(set) var focusRequest = 0
    /// The query the results are for, once its search has started.
    @ObservationIgnored private(set) var searched: String?

    enum Row: Hashable {
        case file(String)
        case hit(String, line: Int)
    }

    let root: String
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Hits arriving within one frame are added together.
    @ObservationIgnored private var pending: [SearchHit] = []
    @ObservationIgnored private var flushQueued = false

    init(folder: URL) {
        root = realPath(folder.path)
    }

    func focus() { focusRequest += 1 }

    var fileCount: Int { results.count }

    func relative(_ path: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    // MARK: - Running

    private func schedule(now: Bool = false) {
        running?.cancel()
        running = Task { [weak self] in
            if !now { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await self?.search()
        }
    }

    func rerun() { schedule(now: true) }

    private func search() async {
        pending = []
        results = []
        matchCount = 0
        collapsed = []
        selection = nil
        let text = self.text
        searched = text
        guard !text.isEmpty else {
            outcome = .idle
            return
        }
        var query = SearchQuery(text: text)
        query.caseSensitive = caseSensitive
        query.wholeWord = wholeWord
        query.regex = regex
        query.include = Self.globs(include)
        query.exclude = Self.globs(exclude)
        outcome = .running
        for await event in TextSearch.run(query, in: URL(fileURLWithPath: root)) {
            if Task.isCancelled { return }
            switch event {
            case .hit(let hit):
                pending.append(hit)
                queueFlush()
            case .capped:
                flush()
                outcome = .capped
            case .done:
                flush()
                outcome = .done
            case .failed(let message):
                flush()
                outcome = .failed(message)
            }
        }
        if !Task.isCancelled, outcome == .running {
            flush()
            outcome = .done
        }
    }

    private func queueFlush() {
        guard !flushQueued else { return }
        flushQueued = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            self?.flush()
        }
    }

    private func flush() {
        flushQueued = false
        guard !pending.isEmpty else { return }
        var next = results
        for hit in pending {
            if let last = next.indices.last, next[last].path == hit.path {
                next[last].hits.append(hit)
            } else if let index = next.firstIndex(where: { $0.path == hit.path }) {
                next[index].hits.append(hit)
            } else {
                // The first files open; later ones start closed (look §3).
                if next.count >= Layout.Search.openFiles { collapsed.insert(hit.path) }
                next.append(FileResult(path: hit.path, hits: [hit]))
            }
            matchCount += hit.matches.count
        }
        pending = []
        results = next
    }

    /// "*.swift, Sources/**" → ["*.swift", "Sources/**"].
    static func globs(_ field: String) -> [String] {
        field.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Moving through the results

    /// The rows as shown, in order.
    var visibleRows: [Row] {
        results.flatMap { file -> [Row] in
            [.file(file.path)] + (collapsed.contains(file.path) ? [] : file.hits.map { .hit(file.path, line: $0.line) })
        }
    }

    var hasFilters: Bool { !include.trimmingCharacters(in: .whitespaces).isEmpty || !exclude.trimmingCharacters(in: .whitespaces).isEmpty }

    func clearFilters() {
        include = ""
        exclude = ""
    }

    func clear() {
        text = ""
        results = []
        matchCount = 0
        outcome = .idle
        selection = nil
    }

    var allCollapsed: Bool { !results.isEmpty && results.allSatisfy { collapsed.contains($0.path) } }

    func collapseOrExpandAll() {
        collapsed = allCollapsed ? [] : Set(results.map(\.path))
    }

    func toggle(_ path: String) {
        if collapsed.remove(path) == nil { collapsed.insert(path) }
    }

    func hit(_ path: String, line: Int) -> SearchHit? {
        results.first { $0.path == path }?.hits.first { $0.line == line }
    }
}
