import AppKit
import HostClient
import KoreCore
import LinkProtocol
import SwiftUI

// Copy, Cut, Paste, Duplicate and drops between every explorer in every window: a folder on this
// Mac or on a box. One Kore file clipboard for the app; Mac items also go on the pasteboard as
// files (Finder pastes them, and Kore pastes Finder's). Each carry runs in `FileCarries`, its one
// quiet line in the explorer it goes into (`CarryLine`).

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

/// The carries running, and the line each shows in the explorer it goes into.
@MainActor @Observable
final class FileCarries {
    static let shared = FileCarries()

    struct Line: Identifiable, Equatable {
        let id: UUID
        let folder: FilePlace
        var text: String
        var fraction: Double?
        /// Running (Cancel shows), else a failure said for a while.
        var running: Bool
        var shown: Bool
    }

    private(set) var lines: [Line] = []
    /// What's on its way: each new entry's place, its carry, and whether it's a folder. Trees show
    /// them at once, dimmed, with the carry's bar.
    private(set) var pending: [FilePlace: (id: UUID, isFolder: Bool)] = [:]
    /// Goes up as `pending` changes: trees rebuild their rows.
    private(set) var revision = 0
    @ObservationIgnored private var carries: [UUID: FileCarry] = [:]

    /// The entries on their way into `folder`.
    func pending(in folder: FilePlace) -> [(name: String, isFolder: Bool)] {
        pending.filter { $0.key.parent == folder }.map { ($0.key.name, $0.value.isFolder) }.sorted { $0.name < $1.name }
    }

    /// How far the entry at `place` is, when it's on its way.
    func progress(of place: FilePlace) -> Double? {
        guard let id = pending[place]?.id else { return nil }
        return lines.first { $0.id == id }?.fraction ?? 0
    }

    private func setPending(_ change: () -> Void) {
        change()
        revision += 1
    }

    /// The line for an explorer whose folder is `root`: a carry into it or below.
    func line(under root: FilePlace) -> Line? { lines.first { $0.shown && $0.folder.within(root) } }

    func cancel(_ id: UUID) { carries[id]?.cancel() }

    /// Runs a carry, each box it reaches held linked meanwhile; `done` after.
    func start(_ items: [CarryItem], into folder: FilePlace, move: Bool, done: @escaping @MainActor (CarryOutcome) async -> Void) {
        guard !items.isEmpty else { return }
        var boxes: [String: CarryBox] = [:]
        var held: [HostConnection] = []
        for alias in Set(items.compactMap(\.source.alias) + [folder.alias].compactMap { $0 }) {
            let connection = BoxBinding.connection(alias)
            connection.retain()
            held.append(connection)
            boxes[alias] = CarryBox(alias: alias, files: connection, ssh: SyncBox.ssh(alias))
        }
        let carry = FileCarry(items: items, into: folder, move: move, boxes: boxes)
        let id = UUID()
        carries[id] = carry
        lines.append(Line(id: id, folder: folder, text: Self.text(items, into: folder, move: move), running: true, shown: false))
        setPending {
            for item in items {
                var isFolder: ObjCBool = false
                let folderHere = item.source.alias == nil && FileManager.default.fileExists(atPath: item.source.path, isDirectory: &isFolder) && isFolder.boolValue
                pending[folder.child(item.name)] = (id, folderHere)
            }
        }
        carry.onProgress = { [weak self, weak carry] in
            guard let self, let carry else { return }
            edit(id) { $0.fraction = carry.fraction }
            // Once counted: which are folders.
            let kinds = zip(items, carry.counts).filter { $0.1 != nil && pending[folder.child($0.0.name)]?.isFolder != $0.1?.dir }
            if !kinds.isEmpty { setPending { for (item, count) in kinds { pending[folder.child(item.name)] = (id, count?.dir == true) } } }
        }
        // Quick ones never show.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.edit(id) { $0.shown = true }
        }
        Task { [weak self] in
            let outcome = await carry.run()
            for connection in held { connection.release() }
            guard let self else { return await done(outcome) }
            carries[id] = nil
            // The trees list what landed before the stand-ins go, so nothing blinks.
            await done(outcome)
            setPending { pending = pending.filter { $0.value.id != id } }
            if let failure = outcome.failure, !outcome.cancelled {
                edit(id) {
                    $0.text = failure
                    $0.running = false
                    $0.shown = true
                    $0.fraction = nil
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    self?.lines.removeAll { $0.id == id }
                }
            } else {
                lines.removeAll { $0.id == id }
            }
        }
    }

    private func edit(_ id: UUID, _ change: (inout Line) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        var line = lines[index]
        change(&line)
        if line != lines[index] { lines[index] = line }
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

/// The explorer's one quiet line for a carry into its folder: what goes where and how far, with
/// Cancel; or what went wrong, for a while.
struct CarryLine: View {
    let root: FilePlace

    var body: some View {
        if let line = FileCarries.shared.line(under: root) {
            HStack(spacing: Space.sm) {
                Text(line.text + (line.fraction.map { " · \(Int($0 * 100))%" } ?? (line.running ? "…" : "")))
                    .font(Chrome.caption).foregroundStyle(Theme.secondary).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                if line.running {
                    Button("Cancel") { FileCarries.shared.cancel(line.id) }
                        .buttonStyle(.plain).font(Chrome.caption).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, Layout.Explorer.headerInset).padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }
}
