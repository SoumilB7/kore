import Foundation
import KoreCore
import LinkProtocol
import src

/// A chat's transcript on the box: the log only, no rows. Every change marks where the entries
/// changed from; the chat sends them on as deltas once the change is done.
@MainActor
package final class HostTranscript: ChatTranscript, TranscriptLogView {
    package let log = TranscriptLog()
    /// Told once per burst of changes (the next turn of the main queue), with the lowest entry
    /// that changed, or `reset` when the whole history was read in again.
    package var onChange: ((_ from: Int, _ reset: Bool) -> Void)?
    private var dirtyFrom: Int?
    private var reset = false
    private var scheduled = false
    package private(set) var earlierAvailable = false
    package private(set) var loadingEarlier = false

    package init() { log.view = self }

    // MARK: What the chat asks

    package var entries: [TranscriptLog.Entry] { log.entries }
    package var providerName: String {
        get { log.providerName }
        set { log.providerName = newValue }
    }
    package var chatID: (() -> String?)? = nil
    package var provider: ProviderDescriptor? {
        get { log.provider }
        set { log.provider = newValue }
    }
    package var pendingSendSince: Date? { log.pendingSendSince }
    package var retryableTurn: String? { log.retryableTurn }
    package var workRunning: Bool { log.workRunning }
    package var mayHaveLeft: Bool { false }
    package var userTurns: Int { log.entries.count { $0.kind == .user } }
    package var runningAgents: [String] { log.agentOrder.filter { log.agent($0)?.status == .running } }

    package func apply(_ event: ChatEvent) { log.apply(event) }
    package func apply(_ event: ChatEvent, preserving observed: Set<String>) { log.apply(event, preserving: observed) }
    package func drawNow() { flush() }
    package func compacting(_ on: Bool, at point: Int?) { log.compacting(on, at: point) }
    package func connected(_ state: Connection) { log.connected(state) }
    package func forkedFrom(_ title: String) { log.forkedFrom(title) }
    package func continued(_ text: String, help: String) { log.continued(text, help: help) }
    package func carriedFrom(_ text: String, help: String) { log.carriedFrom(text, help: help) }
    package func compactionSummary(_ text: String, title: String?) { log.compactionSummary(text, title: title) }
    package func continues(turn: String?, at: Date?, sends: String?) {}
    package func actionDenied() { log.actionDenied() }
    package func approvalSettled(_ approval: String) { log.approvalSettled(approval) }
    package func agent(_ id: String) -> TranscriptLog.AgentInfo? { log.agent(id) }
    package func keepLane(of id: String) { log.keepLane(of: id) }
    package func needsHistory(_ id: String) -> Bool { log.needsHistory(id) }
    package func prompt(of turn: String) -> String? { log.prompt(of: turn) }
    package func chips(_ entry: TranscriptLog.Entry) -> [Attachment] { Self.files(entry) }
    package func startLoadingEarlier() { loadingEarlier = true }
    package func prepend(_ events: [ChatEvent], more: Bool) {
        loadingEarlier = false
        earlierAvailable = more
    }
    package func earlierMessages(_ messages: [EarlierMessage]) {}
    /// Nothing leaves memory on the box: a chat's whole history is what its log holds.
    package func unloadPoint(opening: Bool) -> TranscriptLog.Entry? { nil }
    package func unload(before id: UUID, earlier marks: [EarlierMessage]) {}

    package func replaceLane(of id: String, with events: [ChatEvent]) {
        log.loadedAgents.insert(id)
        log.lanes[id] = []
        for (tool, ref) in log.laneTools where ref.agent == id { log.laneTools[tool] = nil }
        log.loadingHistory = true
        batch { events.forEach(log.apply) }
        log.loadingHistory = false
    }

    /// A message's files as the projector reads them: by name and kind, no pictures.
    package static func files(_ entry: TranscriptLog.Entry) -> [Attachment] {
        entry.attachments.map { Attachment(name: $0.name, kind: $0.kind, url: $0.url, imageData: nil, look: nil) }
    }

    // MARK: What the log tells

    package func changed(at index: Int?) {
        mark(index)
        guard !log.batching, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    package func mark(_ index: Int?) {
        let i = max(index ?? 0, 0)
        dirtyFrom = min(dirtyFrom ?? i, i)
    }

    package func rebuild() { flush() }
    package func invalidateAll() { dirtyFrom = 0 }
    package func countHidden() {}
    package func announceFold(_ turn: String) {}
    package func agentsChanged() {}
    package func earlierHistory(_ available: Bool) { earlierAvailable = available }
    package func chips(_ files: [SentAttachment], for entry: UUID, from earlier: UUID?) {}
    package func dropChips(_ entry: UUID) {}

    package func sending(_ on: Bool, at date: Date) {
        guard !log.batching, on != (log.pendingSendSince != nil) else { return }
        log.pendingSendSince = on ? date : nil
    }

    /// A past session's history, read in whole: it replaces what the chat showed.
    package func replay(_ events: [ChatEvent]) {
        batch {
            events.forEach(log.apply)
            // A past compaction that never finished isn't still running.
            log.compactingSince = nil
            log.compactingAt = nil
            log.endUnfinishedAgents()
        }
        reset = true
        flush()
    }

    private func batch(_ changes: () -> Void) {
        log.batching = true
        changes()
        log.batching = false
        // Replayed thinking has no timing, and replayed text isn't streaming; both are finished.
        for i in log.entries.indices where log.entries[i].startedAt == nil && (log.entries[i].kind == .thinking || log.entries[i].kind == .answer) {
            log.entries[i].done = true
        }
        dirtyFrom = 0
    }

    private func flush() {
        scheduled = false
        guard let from = dirtyFrom else { return }
        dirtyFrom = nil
        let wasReset = reset
        reset = false
        onChange?(from, wasReset)
    }
}

/// The projector's reads on the box: a message's files by name, and no rendering (`blocks` is
/// nil), so the client renders the text.
package struct HostReading: LinkReading {
    package init() {}
    package func chips(_ entry: TranscriptLog.Entry) -> [Attachment] { HostTranscript.files(entry) }
    package func blocks(_ markdown: String) -> [Block]? { nil }
}
