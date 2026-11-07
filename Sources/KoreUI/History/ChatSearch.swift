import Foundation
import KoreCore

/// The history panel's search of what chats say. The first key starts reading the listed chats
/// (`ChatTextIndex`, newest first, off the main thread); each key searches what's read so far at
/// once, and more hits join as files finish. Closing the panel stops the reading, not what it read.
@MainActor @Observable
final class ChatSearch {
    /// Chats whose words hold the query, by id.
    private(set) var hits: [String: ChatTextIndex.Hit] = [:]
    /// Files are still being read, so more may come.
    private(set) var reading = false

    /// Shorter queries match nearly every chat's words: the titles are enough for them.
    private static let shortest = 2
    private static let refreshAfter: Duration = .milliseconds(120)

    private let index: ChatTextIndex
    private var query = ""
    private var ids: [String] = []
    private var reader: Task<Void, Never>?
    private var searcher: Task<Void, Never>?
    private var refreshing = false
    /// The chats this opening of the panel has read, so a key doesn't look at the disk again.
    private var readChats: [SessionSummary] = []

    init(index: ChatTextIndex = .shared) {
        self.index = index
    }

    func update(query text: String, chats: [SessionSummary]) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.utf8.count >= Self.shortest else {
            searcher?.cancel()
            hits = [:]
            return
        }
        let sources = chats.compactMap(Self.source)
        ids = sources.map(\.id)
        if reader == nil || chats != readChats {
            readChats = chats
            read(sources)
        }
        search()
    }

    /// The panel closed.
    func stop() {
        reader?.cancel()
        reader = nil
        reading = false
        readChats = []
    }

    private static func source(_ chat: SessionSummary) -> ChatTextIndex.Source? {
        guard let file = chat.file else { return nil }
        return ChatTextIndex.Source(id: chat.id, file: file, format: chat.agent == .codex ? .codex : .claude)
    }

    private func read(_ sources: [ChatTextIndex.Source]) {
        reader?.cancel()
        reading = true
        let index = index
        reader = Task.detached(priority: .userInitiated) { [weak self] in
            await index.index(sources) { _ in
                Task { @MainActor in self?.fileRead() }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.reading = false
                self?.search()
            }
        }
    }

    /// Files finish in bursts: the hits catch up a few times a second.
    private func fileRead() {
        guard !refreshing, reader != nil else { return }
        refreshing = true
        Task {
            try? await Task.sleep(for: Self.refreshAfter)
            refreshing = false
            search()
        }
    }

    private func search() {
        guard query.utf8.count >= Self.shortest else { return }
        searcher?.cancel()
        let (index, query, ids) = (index, query, ids)
        searcher = Task.detached(priority: .userInitiated) { [weak self] in
            let found = index.search(query, in: ids)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.query == query else { return }
                let hits = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                if hits != self.hits { self.hits = hits }
            }
        }
    }
}
