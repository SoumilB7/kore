import AppKit
import HostClient
import KoreCore
import LinkProtocol
import SwiftUI

// Copy, Cut, Paste, Duplicate and drops between every explorer in every window: a folder on this
// Mac or on a box. One Kore file clipboard for the app; Mac items also go on the pasteboard as
// files (Finder pastes them, and Kore pastes Finder's). Each carry runs in `FileCarries`, its bar
// at the bottom of the explorer it goes into (`TransferBar`).

/// What ⌘C or ⌘X took, with where each item is: a path on this Mac, or an alias and a path on a
/// box. Good while the pasteboard is still what it wrote; after that, the pasteboard's files
/// (Finder's) are what pastes, as copies.
@MainActor @Observable
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var items: [FilePlace] = []
    private(set) var cut = false
    @ObservationIgnored private var stamp = -1
    @ObservationIgnored private let board: () -> NSPasteboard

    init(board: @escaping () -> NSPasteboard = { DraftClipboard.pasteboard }) { self.board = board }

    /// Mac items as files on the pasteboard; a box's as their paths, a line each (a terminal or
    /// another app takes them so).
    func put(_ items: [FilePlace], cut: Bool) {
        guard !items.isEmpty else { return }
        let board = board()
        board.clearContents()
        let mac = items.compactMap { if case .mac(let path) = $0 { URL(fileURLWithPath: path) as NSURL } else { nil } }
        if mac.count == items.count {
            board.writeObjects(mac)
        } else {
            board.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
        }
        self.items = items
        self.cut = cut
        stamp = board.changeCount
    }

    /// What ⌘V pastes now, and whether it's a cut.
    func current() -> (items: [FilePlace], cut: Bool)? {
        let board = board()
        if board.changeCount == stamp, !items.isEmpty { return (items, cut) }
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.isEmpty ? nil : (urls.map { .mac(realPath($0.path)) }, false)
    }

    var canPaste: Bool { current() != nil }

    /// Dimmed in its tree: cut, waiting for its paste.
    func isCut(_ place: FilePlace) -> Bool { cut && items.contains(place) }

    /// A cut pasted: it pastes once.
    func pasted() {
        guard cut else { return }
        items = []
        cut = false
        if board().changeCount == stamp { board().clearContents() }
    }
}

/// The carries under way, and the bar each shows in the explorer it goes into. Each keeps its
/// checkpoint (`CarryJournal`) and goes on from it: after the link drops or rsync ends (by itself
/// once the box answers again, waiting longer after each try that moved nothing), after a sleep
/// (on wake), after Kore quits (on the next launch, `restore`), and after Pause (on Resume).
@MainActor @Observable
final class FileCarries {
    static let shared = FileCarries()

    /// What's on its way: each new entry's place, its transfer, and whether it's a folder. Trees
    /// show them at once, dimmed, with the transfer's bar.
    private(set) var pending: [FilePlace: (id: UUID, isFolder: Bool)] = [:]
    /// Goes up as `pending` changes: trees rebuild their rows.
    private(set) var revision = 0
    @ObservationIgnored let journals: CarryJournals
    @ObservationIgnored let transfers: TransferProgress
    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    /// Waits before going on after an interruption, longer each time nothing moved; the last repeats.
    @ObservationIgnored var backoff: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120)]
    /// Interruptions in a row with no new bytes before it's said failed (Retry goes on).
    @ObservationIgnored var giveUpAfter = 8
    /// Makes the boxes a carry reaches (tests: their own).
    @ObservationIgnored var reach: (String) -> (connection: HostConnection, box: CarryBox) = { alias in
        let connection = BoxBinding.connection(alias)
        return (connection, CarryBox(alias: alias, files: connection, ssh: SyncBox.ssh(alias)))
    }
    @ObservationIgnored private var sleepWatch: [NSObjectProtocol] = []

    /// One carry across its runs.
    @MainActor
    final class Job {
        var journal: CarryJournal
        var carry: FileCarry?
        var held: [HostConnection] = []
        var boxes: [String: CarryBox] = [:]
        let done: (@MainActor (CarryOutcome) async -> Void)?
        /// Interruptions in a row with no new bytes, and the bytes at the last.
        var tries = 0
        var bytes: Int64
        var wait: Task<Void, Never>?
        var waiting = false

        init(_ journal: CarryJournal, done: (@MainActor (CarryOutcome) async -> Void)?) {
            self.journal = journal
            self.done = done
            self.bytes = journal.bytes
        }
    }

    init(journals: CarryJournals = .standard, transfers: TransferProgress = .shared) {
        self.journals = journals
        self.transfers = transfers
    }

    /// The entries on their way into `folder`.
    func pending(in folder: FilePlace) -> [(name: String, isFolder: Bool)] {
        pending.filter { $0.key.parent == folder }.map { ($0.key.name, $0.value.isFolder) }.sorted { $0.name < $1.name }
    }

    /// How far the entry at `place` is, when it's on its way.
    func progress(of place: FilePlace) -> Double? {
        guard let id = pending[place]?.id else { return nil }
        return transfers.items.first { $0.id == id }?.fraction ?? 0
    }

    /// Carries going or waiting to go on (not paused, not failed): what a quit pauses.
    var active: Int { jobs.values.filter { $0.carry != nil || $0.waiting }.count }

    /// The one with this id (tests).
    func journal(_ id: UUID) -> CarryJournal? { jobs[id].map { $0.carry?.journal ?? $0.journal } }

    private func setPending(_ change: () -> Void) {
        change()
        revision += 1
    }

    /// Starts a carry, its bar in `TransferProgress`; `done` after it ends (and after each Retry).
    func start(_ items: [CarryItem], into folder: FilePlace, move: Bool, done: @escaping @MainActor (CarryOutcome) async -> Void) {
        guard !items.isEmpty else { return }
        // The first carry holds the folder too: another Kore launched meanwhile leaves it be.
        _ = journals.claim()
        launch(Job(CarryJournal(items: items, into: folder, move: move), done: done), restored: false)
    }

    /// The carries a quit, a crash or a restart left: running ones go on at once ("Resuming…"),
    /// paused ones wait for Resume, failed ones for Retry. Only the Kore holding the folder's lock
    /// does this (another copy of Kore leaves them be).
    func restore() {
        let left = journals.all()
        guard !left.isEmpty, journals.claim() else { return }
        for journal in left where jobs[journal.id] == nil {
            guard journal.state != .done else {
                journals.remove(journal.id)
                continue
            }
            launch(Job(journal, done: nil), restored: true)
        }
    }

    private func launch(_ job: Job, restored: Bool) {
        let journal = job.journal
        let id = journal.id
        let items = journal.items.map(\.carry)
        let folder = journal.folder
        jobs[id] = job
        watchSleep()
        transfers.begin(
            Self.text(items, into: folder, move: journal.move), done: Self.doneText(items, into: folder, move: journal.move), id: id, place: folder,
            peer: (folder.alias ?? items.lazy.compactMap(\.source.alias).first).map(NodeNames.name), shown: restored, resuming: restored && journal.state == .running,
            cancel: { [weak self] in self?.cancel(id) }, retry: { [weak self] in self?.resume(id) },
            pause: { [weak self] in self?.pause(id) }, resume: { [weak self] in self?.resume(id) })
        transfers.update(id, bytes: journal.bytes, total: journal.total)
        switch journal.state {
        case .paused:
            showPending(job)
            transfers.paused(id)
        case .failed: transfers.finish(id, failure: journal.failure ?? "It stopped.", resumable: true)
        case .running, .done: run(job, resuming: restored)
        }
    }

    /// Its entries still on their way, dimmed in their trees.
    private func showPending(_ job: Job) {
        let journal = job.journal
        setPending {
            for (index, entry) in journal.items.enumerated() where index >= journal.done {
                var isFolder: ObjCBool = false
                let folderHere = entry.source.alias == nil && FileManager.default.fileExists(atPath: entry.source.path, isDirectory: &isFolder) && isFolder.boolValue
                pending[journal.folder.child(entry.name)] = (journal.id, entry.count?.dir ?? folderHere)
            }
        }
    }

    private func hidePending(_ id: UUID) { setPending { pending = pending.filter { $0.value.id != id } } }

    /// One run, each box it reaches held linked meanwhile; a dropped link stops it (it goes on
    /// once the box is back).
    private func run(_ job: Job, resuming: Bool) {
        let id = job.journal.id
        job.wait?.cancel()
        job.wait = nil
        job.waiting = false
        hold(job)
        let carry = FileCarry(journal: job.journal, boxes: job.boxes, journals: journals, resuming: resuming)
        job.carry = carry
        transfers.running(id)
        showPending(job)
        let items = job.journal.items.map(\.carry)
        let folder = job.journal.folder
        let transfers = transfers
        carry.onProgress = { [weak self, weak carry] in
            guard let self, let carry else { return }
            transfers.update(id, bytes: carry.bytes, total: carry.total)
            // Once counted: which are folders.
            let kinds = zip(items, carry.counts).filter { $0.1 != nil && pending[folder.child($0.0.name)]?.isFolder != $0.1?.dir }
            if !kinds.isEmpty { setPending { for (item, count) in kinds { pending[folder.child(item.name)] = (id, count?.dir == true) } } }
        }
        Task { [weak self] in
            let outcome = await carry.run()
            job.carry = nil
            job.journal = self?.renamed(carry.journal) ?? carry.journal
            await self?.ended(job, outcome, bytes: carry.bytes)
        }
    }

    private func ended(_ job: Job, _ outcome: CarryOutcome, bytes: Int64) async {
        let id = job.journal.id
        if outcome.paused {
            letGo(job)
            return transfers.paused(id)
        }
        if outcome.interrupted {
            if bytes > job.bytes {
                job.tries = 0
                job.bytes = bytes
            }
            job.tries += 1
            if job.tries <= giveUpAfter {
                job.waiting = true
                transfers.waiting(id)
                return later(job)
            }
            job.journal.state = .failed
            journals.save(job.journal)
        }
        if outcome.failure != nil, !outcome.cancelled {
            // Kept: Retry goes on from it, Cancel removes it.
            letGo(job)
            await job.done?(outcome)
            hidePending(id)
            return transfers.finish(id, failure: outcome.failure, resumable: true)
        }
        await close(job, outcome)
    }

    /// Done or cancelled: the boxes let go, the trees list what landed, its bar says so.
    private func close(_ job: Job, _ outcome: CarryOutcome) async {
        let id = job.journal.id
        letGo(job)
        jobs[id] = nil
        // The trees list what landed before the stand-ins go, so nothing blinks.
        await job.done?(outcome)
        hidePending(id)
        transfers.finish(id, failure: outcome.failure, cancelled: outcome.cancelled)
    }

    /// Goes on after the next wait, if its boxes are linked then; if not, when they link.
    private func later(_ job: Job) {
        job.wait?.cancel()
        let delay = backoff[min(max(0, job.tries - 1), backoff.count - 1)]
        job.wait = Task { [weak self, weak job] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let job else { return }
            job.wait = nil
            if job.held.allSatisfy(\.isOnline) { self.run(job, resuming: true) }
        }
    }

    /// A box's link came or went: one going stops the runs over it; one back lets waiting ones
    /// go on (after their wait).
    private func linked(_ id: UUID, _ up: Bool) {
        guard let job = jobs[id] else { return }
        if !up {
            job.carry?.interrupt()
        } else if job.waiting, job.wait == nil, job.held.allSatisfy(\.isOnline) {
            run(job, resuming: true)
        }
    }

    func pause(_ id: UUID) {
        guard let job = jobs[id] else { return }
        if let carry = job.carry { return carry.pause() }
        job.wait?.cancel()
        job.wait = nil
        job.waiting = false
        job.journal.state = .paused
        journals.save(job.journal)
        letGo(job)
        transfers.paused(id)
    }

    func resume(_ id: UUID) {
        guard let job = jobs[id], job.carry == nil else { return }
        job.tries = 0
        run(job, resuming: true)
    }

    /// Cancel: the run stops and its partial copy goes; one not running has it removed now.
    func cancel(_ id: UUID) {
        guard let job = jobs[id] else { return }
        if let carry = job.carry { return carry.cancel() }
        job.wait?.cancel()
        job.waiting = false
        hold(job)
        let carry = FileCarry(journal: job.journal, boxes: job.boxes, journals: journals, resuming: true)
        Task { [weak self] in
            await carry.discard()
            await self?.close(job, CarryOutcome(landed: job.journal.landed, failure: "Cancelled", cancelled: true))
        }
    }

    /// Kore quits: each run stops where it is, its checkpoint saying running (the next launch
    /// goes on from it).
    func quit() {
        for job in jobs.values {
            job.wait?.cancel()
            job.carry?.interrupt()
        }
    }

    /// The boxes it reaches, held linked, their link watched.
    private func hold(_ job: Job) {
        guard job.held.isEmpty else { return }
        let id = job.journal.id
        let aliases = Set(job.journal.items.compactMap(\.source.alias) + [job.journal.folder.alias].compactMap { $0 })
        for alias in aliases.sorted() {
            let (connection, box) = reach(alias)
            connection.retain()
            connection.onLink("carry-" + id.uuidString) { [weak self] up in self?.linked(id, up) }
            job.held.append(connection)
            job.boxes[alias] = box
        }
    }

    private func letGo(_ job: Job) {
        for connection in job.held {
            connection.onLink("carry-" + job.journal.id.uuidString, nil)
            connection.release()
        }
        job.held = []
    }

    /// Asleep: runs stop where they are; awake: waiting ones go on soon, from the first wait.
    private func watchSleep() {
        guard sleepWatch.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepWatch.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FileCarries.shared.slept() }
        })
        sleepWatch.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FileCarries.shared.woke() }
        })
    }

    // MARK: A box rekeyed to its KoreNet id

    /// Aliases whose stores moved to a KoreNet id: a run that ends after the move keeps the id.
    @ObservationIgnored private var renames: [String: String] = [:]

    private func renamed(_ journal: CarryJournal) -> CarryJournal {
        renames.reduce(journal) { $0.rekeyed($1.key, $1.value) }
    }

    private func mentions(_ job: Job, _ alias: String) -> Bool { job.journal.rekeyed(alias, "\u{0}") != job.journal }

    /// The box's stores are about to move: its carries stop where they are (their checkpoints,
    /// written now, move with the rest).
    func rekeying(_ alias: String) {
        for job in jobs.values where mentions(job, alias) {
            job.wait?.cancel()
            job.carry?.interrupt()
        }
    }

    /// They moved (`old` == `new`: they didn't): each carry reaching the box goes on under the
    /// box's id, holding its link by that key.
    func rekeyed(_ old: String, _ new: String) {
        if old != new { renames[old] = new }
        for job in jobs.values where mentions(job, old) {
            letGo(job)
            job.boxes = [:]
            job.journal = job.journal.rekeyed(old, new)
            if job.carry == nil, !job.waiting, job.journal.state == .running { later(job) }
        }
    }

    func slept() {
        for job in jobs.values { job.carry?.interrupt() }
    }

    func woke() {
        for job in jobs.values where job.waiting {
            job.tries = 0
            later(job)
        }
    }

    /// "Copied to mybox", "Moved to Downloads".
    static func doneText(_ items: [CarryItem], into folder: FilePlace, move: Bool) -> String {
        let across = items.contains { !$0.source.sameDevice(folder) }
        return "\(move ? "Moved" : "Copied") to \(across ? folder.device : folder.name)"
    }

    /// "Copying 3 items to mybox", "Moving notes.md to Downloads".
    static func text(_ items: [CarryItem], into folder: FilePlace, move: Bool) -> String {
        let what = items.count == 1 ? items[0].name : "\(items.count) items"
        let across = items.contains { !$0.source.sameDevice(folder) }
        return "\(move ? "Moving" : "Copying") \(what) to \(across ? folder.device : folder.name)"
    }
}

/// Paste, Duplicate and drops into a folder from anywhere: the names the folder has asked first,
/// a copy into its own folder named " copy", a taken name kept as "name 2" (one item: Replace or
/// Keep Both, asked in a Kore popup), then the carry.
@MainActor
enum FilePaste {
    /// Plans and starts it; `done` after, on the destination's side (lists it again).
    static func carry(_ places: [FilePlace], into folder: FilePlace, move: Bool, done: @escaping @MainActor (CarryOutcome) async -> Void) {
        // A move into its own folder does nothing; into itself, never.
        let places = places.filter { place in
            !folder.within(place) && !(move && place.sameDevice(folder) && place.parent == folder)
        }
        guard !places.isEmpty else { return }
        Task {
            var taken = await names(in: folder)
            var items: [CarryItem] = []
            var clash: Int?
            for place in places {
                let ownFolder = place.sameDevice(folder) && place.parent == folder
                var item = CarryItem(source: place)
                if ownFolder {
                    item.name = CopyNames.free(place.name, duplicate: true) { taken.contains($0.lowercased()) }
                } else if taken.contains(place.name.lowercased()) {
                    if places.count == 1 { clash = items.count } else { item.name = CopyNames.free(place.name, duplicate: false) { taken.contains($0.lowercased()) } }
                }
                taken.insert(item.name.lowercased())
                items.append(item)
            }
            guard let clash else { return FileCarries.shared.start(items, into: folder, move: move, done: done) }
            let name = items[clash].name
            ask(name, in: folder.name) { replace in
                if replace {
                    items[clash].replace = true
                } else {
                    items[clash].name = CopyNames.free(name, duplicate: false) { taken.contains($0.lowercased()) }
                }
                FileCarries.shared.start(items, into: folder, move: move, done: done)
            }
        }
    }

    /// The folder's names, lowercased; none when it can't be listed (nothing is replaced anyway).
    static func names(in folder: FilePlace) async -> Set<String> {
        switch folder {
        case .mac(let path):
            return Set(((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).map { $0.lowercased() })
        case .box(let alias, let path):
            let connection = BoxBinding.connection(alias)
            connection.retain()
            defer { connection.release() }
            guard case .success(let listing) = await connection.list(path, hidden: true) else { return [] }
            return Set(listing.entries.map { $0.name.lowercased() })
        }
    }

    /// One name taken: Keep Both or Replace, in a Kore popup where the pointer is. Nothing
    /// chosen (it closed): nothing happens.
    static func ask(_ name: String, in folder: String, answer: @escaping @MainActor (Bool) -> Void) {
        if let confirm = StorylineSeams.confirm { return answer(confirm("replace")) }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return answer(false) }
        OptionsMenu.shared.show(
            [
                OptionItem("“\(name)” is already in “\(folder)”", enabled: false), .rule,
                OptionItem("Keep Both") { answer(false) },
                OptionItem("Replace", destructive: true) { answer(true) },
            ], at: window.mouseLocationOutsideOfEventStream, in: window, source: "paste")
    }
}
