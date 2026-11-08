import Foundation
import KoreCore
import LinkProtocol
import src

// Link 1.10 on the Mac: a box chat brought to this Mac, and sent back. The Mac starts every move.
// Ownership changes hands over the attach link (`chat.release`, `chat.adopt`); the CLI's own
// session files go by rsync over the pair's SSH alias, rewritten to the receiving side's folder
// by the shared helper in src (`FolderRewrite`). Each side seeds the copy with the copy it last
// had, so rsync sends only what's new; files are streamed, never read whole.

/// A box chat this Mac holds now: which box chat it was, where it runs here, and the gen it was
/// given. Kept in `<hosts>/moves.json` until it goes back.
package struct MovedChat: Codable, Sendable, Equatable {
    package var alias: String
    package var boxChat: String
    /// The chat's folder on the box, and on this Mac (the pair's, or a folder inside it).
    package var boxFolder: String
    package var macFolder: String
    package var provider: String
    package var session: String
    package var gen: Int
    package var title: String?
    /// The mirror's count when it last heard the box: what the replica holds.
    package var mirrored: Int?

    package init(alias: String, boxChat: String, boxFolder: String, macFolder: String, provider: String, session: String, gen: Int, title: String? = nil) {
        self.alias = alias
        self.boxChat = boxChat
        self.boxFolder = boxFolder
        self.macFolder = macFolder
        self.provider = provider
        self.session = session
        self.gen = gen
        self.title = title
    }
}

/// The chats this Mac holds, read once, written on each change.
@MainActor
package final class MovedChats {
    package static let shared = MovedChats()
    package private(set) var all: [MovedChat] = []
    private var url: URL
    /// The hosts' folder it's kept in (each box's moves sit under it too).
    package var root: URL { url.deletingLastPathComponent() }
    /// Told after every change (the tabs' marks, the box windows' replicas).
    package var changed: (() -> Void)?

    package init(root: URL = HostCache.root()) {
        url = root.appendingPathComponent("moves.json")
        if let data = try? Data(contentsOf: url) { all = (try? JSONDecoder().decode([MovedChat].self, from: data)) ?? [] }
    }

    /// A store elsewhere (tests).
    package func use(_ root: URL) {
        url = root.appendingPathComponent("moves.json")
        all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([MovedChat].self, from: $0) } ?? []
    }

    package func session(_ id: String) -> MovedChat? { all.first { $0.session == id } }
    package func boxChat(_ alias: String, _ id: String) -> MovedChat? { all.first { $0.alias == alias && $0.boxChat == id } }

    package func keep(_ moved: MovedChat) {
        all.removeAll { $0.session == moved.session || ($0.alias == moved.alias && $0.boxChat == moved.boxChat) }
        all.append(moved)
        save()
    }

    package func forget(session: String) {
        all.removeAll { $0.session == session }
        save()
    }

    package func noteMirrored(_ session: String, _ count: Int) {
        guard let at = all.firstIndex(where: { $0.session == session }), all[at].mirrored != count else { return }
        all[at].mirrored = count
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
        changed?()
    }
}

/// Why a move didn't happen: one line for the sheet.
package struct MoveFailure: Error, Equatable, Sendable {
    package var line: String
    package var code: ResultCode?
    package init(_ line: String, _ code: ResultCode? = nil) {
        self.line = line
        self.code = code
    }
}

/// What a move cost: bytes rsync put on the wire each way, and the link's messages.
package struct MoveCost: Sendable, Equatable {
    package var rsyncSent = 0
    package var rsyncReceived = 0
    package var linkBytes = 0
    package var files = 0
}

extension HostConnection {
    /// A 1.10 command and its `MoveResult`.
    package func move(_ kind: ControlKind, _ args: ControlArgs) async -> MoveResult {
        var size = 0
        let (result, raw) = await commandRaw { id in
            let data = HostWire.command(id: id, .control(kind, args))
            size = data.count
            return data
        }
        lastMoveBytes = size + (raw?.count ?? 0)
        if let raw, let decoded = try? JSONDecoder().decode(MoveResult.self, from: raw) { return decoded }
        return MoveResult(id: result.id, ok: result.ok, code: result.code, message: result.message)
    }

    /// Whether the box takes moves (1.10, a full grant).
    package var moves: Bool { caps.contains("move") }
}

/// A Mac's side of moves with one box: the pair's rsync, this Mac's CLI folders, and where it
/// stages. Tests stand in each.
@MainActor
package struct ChatMoves {
    package let connection: HostConnection
    package let box: SyncBox
    /// This Mac's environment for the CLIs' folders (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `HOME`).
    package var env: [String: String] = ProcessInfo.processInfo.environment
    /// Where copies wait before they're placed: `<hosts>/<alias>/moves/<move id>/`.
    package var staging: URL
    /// This Mac's name, as the box's replica says it ("on MacBook").
    package var name: String
    package var store: MovedChats
    /// Told as a move's or copy's files cross: the bytes so far, and (once known) all of them,
    /// a few times a second (the transfer bar). Nil: nothing is metered.
    package var progress: (@MainActor (_ bytes: Int64, _ total: Int64?) -> Void)?
    /// Stops a running rsync (the bar's Cancel): the move fails before its commit, nothing changes.
    package var stopper: Spawn?
    /// How often a pull's staged bytes are measured while rsync runs (it prints no progress
    /// into a pipe on macOS).
    package var pollEvery: Duration = .seconds(2)

    package init(connection: HostConnection, box: SyncBox, staging: URL? = nil, name: String? = nil, store: MovedChats? = nil) {
        self.connection = connection
        self.box = box
        self.staging = staging ?? connection.cache.folder.appendingPathComponent("moves", isDirectory: true)
        self.name = name ?? Host.current().localizedName ?? "this Mac"
        self.store = store ?? .shared
    }

    /// The Mac folder for a box folder through the pair: the pair's own, or the same folder inside it.
    package static func macFolder(_ boxFolder: String, pair: SyncPair) -> String? {
        guard SyncPairs.within(boxFolder, pair.box) else { return nil }
        let rest = boxFolder.dropFirst(pair.box.count)
        return pair.mac + rest
    }

    package static func boxFolder(_ macFolder: String, pair: SyncPair) -> String? {
        guard SyncPairs.within(macFolder, pair.mac) else { return nil }
        return pair.box + macFolder.dropFirst(pair.mac.count)
    }

    /// This Mac's copy of a session: where its files sit and which they are.
    func local(_ provider: String, session: String, folder: String, known: String? = nil) -> SessionFiles.Found {
        provider == ProviderDescriptor.codex.id
            ? SessionFiles.codex(session, known: known, env: env)
            : SessionFiles.claude(session, folder: folder, env: env)
    }

    func localRoot(_ provider: String, folder: String) -> URL {
        provider == ProviderDescriptor.codex.id
            ? SessionFiles.codexSessions(env)
            : SessionFiles.claudeProjects(env).appendingPathComponent(ClaudeHistory.projectKey(for: URL(fileURLWithPath: folder)))
    }

    // MARK: The folder in sync

    /// Waits for the folder's sync to settle on both ends: the box says what it gathered (its
    /// `sync.changed` comes first), then this Mac's rounds carry it. `progress` hears how many
    /// changes are still on their way ("3 changes still syncing…"). True once settled; false
    /// after `wait` seconds, or when the folder isn't syncing (`sync` nil: the box window is closed).
    package func flush(folder: String, sync: HostSync?, wait: TimeInterval = 30, progress: (@MainActor (Int) -> Void)? = nil) async -> Bool {
        guard let sync else { return false }
        let end = Date().addingTimeInterval(wait)
        let box = await connection.move(.syncFlush, ControlArgs(folder: folder))
        if box.watching == false { return false }
        var left = (box.pending ?? 0) + sync.unsettled
        while left > 0 || box.settled != true, Date() < end {
            progress?(left)
            try? await Task.sleep(for: .milliseconds(100))
            left = sync.unsettled
            if left == 0 { break }
        }
        progress?(left)
        return left == 0 && box.settled == true
    }

    // MARK: Bring to this Mac

    /// What a chat brought here is, to resume it in its local window.
    package struct Brought: Sendable, Equatable {
        package var moved: MovedChat
        package var title: String?
        package var modelId: String?
        package var effort: String?
        package var mode: String?
        package var cost: MoveCost
    }

    /// Brings box chat `chatId` (in box folder `boxFolder`) to this Mac. `stop`: a working chat
    /// stops first ("Stop and move"). The folder's sync should have settled first (`flush`).
    package func bring(chatId: String, gen: Int, boxFolder: String, pair: SyncPair, stop: Bool = false) async -> Result<Brought, MoveFailure> {
        guard let mac = Self.macFolder(boxFolder, pair: pair) else { return .failure(MoveFailure("No folder pair")) }
        return await bring(chatId: chatId, gen: gen, boxFolder: boxFolder, macFolder: mac, stop: stop)
    }

    /// The same, into any folder on this Mac (a chat cut from a box and pasted in a Mac window, 1.11).
    package func bring(chatId: String, gen: Int, boxFolder: String, macFolder mac: String, stop: Bool = false) async -> Result<Brought, MoveFailure> {
        var cost = MoveCost()
        let prepared = await connection.move(.chatRelease, ControlArgs(chatId: chatId, phase: MovePhase.prepare.rawValue, gen: gen, stop: stop ? true : nil))
        cost.linkBytes += connection.lastMoveBytes
        guard prepared.ok, let info = prepared.move else { return .failure(MoveFailure(prepared.message ?? "Couldn't move it", prepared.code)) }
        func abort(_ line: String) async -> Result<Brought, MoveFailure> {
            _ = await connection.move(.chatRelease, ControlArgs(chatId: chatId, phase: MovePhase.abort.rawValue, gen: gen, moveId: info.moveId))
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(info.moveId))
            return .failure(MoveFailure(line))
        }
        let files = info.files.filter(SessionFiles.plain)
        guard !files.isEmpty else { return await abort("Nothing to move") }
        progress?(0, info.bytes)
        let stage = staging.appendingPathComponent(info.moveId, isDirectory: true)
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        // This Mac's last copy, in the box's words: rsync sends only what's new.
        let before = local(info.provider, session: info.sessionId, folder: mac)
        if !before.files.isEmpty, let boxWords = info.folders.first {
            _ = try? FolderRewrite(from: Self.spellings(mac), to: boxWords).files(before.files, from: before.root, to: stage)
        }
        let pulled = await rsync(files: files, from: box.spec(info.root + "/"), to: stage.path + "/", landing: Self.bytes(stage))
        cost.rsyncSent += pulled.sent
        cost.rsyncReceived += pulled.received
        guard pulled.ok else { return await abort("Couldn't copy the session: \(pulled.said)") }
        let root = localRoot(info.provider, folder: mac)
        do {
            try FolderRewrite(from: info.folders, to: SessionFiles.real(mac)).files(files, from: stage, to: root)
        } catch {
            return await abort("Couldn't place the session here")
        }
        cost.files = files.count
        let committed = await connection.move(.chatRelease, ControlArgs(chatId: chatId, phase: MovePhase.commit.rawValue, gen: gen, moveId: info.moveId, host: name))
        cost.linkBytes += connection.lastMoveBytes
        guard committed.ok, let owner = committed.owner else { return .failure(MoveFailure(committed.message ?? "\(connection.alias) didn't hand it over", committed.code)) }
        var moved = MovedChat(
            alias: connection.alias, boxChat: chatId, boxFolder: boxFolder, macFolder: mac, provider: info.provider, session: info.sessionId, gen: owner.gen,
            title: info.title)
        moved.mirrored = 0
        store.keep(moved)
        HostLog.note(connection.alias, "move here", "chat \(chatId) gen \(owner.gen) files \(files.count) rsync \(cost.rsyncReceived)B")
        return .success(Brought(moved: moved, title: info.title, modelId: info.modelId, effort: info.effort, mode: info.mode, cost: cost))
    }

    static func spellings(_ folder: String) -> [String] {
        let real = SessionFiles.real(folder)
        return real == folder ? [folder] : [folder, real]
    }

    // MARK: Send back

    /// Sends a chat this Mac holds back to its box. Its CLI here must have stopped. The box takes
    /// it as the same chat when it still holds the gen it gave; else as a new chat. The box chat's
    /// id after it.
    package func sendBack(_ moved: MovedChat, title: String?, modelId: String?, effort: String?, mode: String?, mirrored: Int?) async -> Result<(chatId: String, cost: MoveCost), MoveFailure> {
        var cost = MoveCost()
        let moveId = UUID().uuidString.lowercased()
        let base = ControlArgs(chatId: moved.boxChat, provider: moved.provider, sessionId: moved.session, gen: moved.gen, moveId: moveId, host: name)
        var prepare = base
        prepare.phase = MovePhase.prepare.rawValue
        prepare.from = moved.macFolder
        let prepared = await connection.move(.chatAdopt, prepare)
        cost.linkBytes += connection.lastMoveBytes
        guard prepared.ok, let info = prepared.move else { return .failure(MoveFailure(prepared.message ?? "Couldn't send it back", prepared.code)) }
        func abort(_ line: String) async -> Result<(chatId: String, cost: MoveCost), MoveFailure> {
            var args = base
            args.phase = MovePhase.abort.rawValue
            _ = await connection.move(.chatAdopt, args)
            return .failure(MoveFailure(line))
        }
        let found = local(moved.provider, session: moved.session, folder: moved.macFolder)
        guard !found.files.isEmpty else { return await abort("The session isn't on this Mac") }
        progress?(0, SessionFiles.bytes(found))
        let pushed = await rsync(files: found.files, from: found.root.path + "/", to: box.spec(info.root + "/"))
        cost.rsyncSent += pushed.sent
        cost.rsyncReceived += pushed.received
        cost.files = found.files.count
        guard pushed.ok else { return await abort("Couldn't copy the session: \(pushed.said)") }
        var commit = base
        commit.phase = MovePhase.commit.rawValue
        commit.folder = moved.boxFolder
        commit.folders = Self.spellings(moved.macFolder)
        commit.title = title
        commit.modelId = modelId.flatMap { LinkPolicy.plainID($0) ? $0 : nil }
        commit.level = effort.flatMap { LinkPolicy.plainID($0) ? $0 : nil }
        commit.mode = mode
        commit.seq = mirrored
        let adopted = await connection.move(.chatAdopt, commit)
        cost.linkBytes += connection.lastMoveBytes
        guard adopted.ok, let chatId = adopted.chatId else { return .failure(MoveFailure(adopted.message ?? "\(connection.alias) didn't take it", adopted.code)) }
        store.forget(session: moved.session)
        ChatMirrors.shared.ended(session: moved.session)
        HostLog.note(connection.alias, "move back", "chat \(chatId) files \(found.files.count) rsync \(cost.rsyncSent)B")
        return .success((chatId, cost))
    }

    /// A chat of this Mac's (never on a box) to box folder `boxFolder`: 1.10's `chat.adopt`, as a
    /// new chat there under the same session. The Mac's copy stays until the caller puts it aside.
    package func send(
        session: String, provider: String, from macFolder: String, to boxFolder: String, title: String?, modelId: String?, effort: String?, mode: String?
    ) async -> Result<(chatId: String, cost: MoveCost), MoveFailure> {
        let moved = MovedChat(alias: connection.alias, boxChat: "", boxFolder: boxFolder, macFolder: macFolder, provider: provider, session: session, gen: 0, title: title)
        return await sendBack(moved, title: title, modelId: modelId, effort: effort, mode: mode, mirrored: nil)
    }

    // MARK: rsync

    /// The bytes under a folder on this Mac, measured off the main thread.
    static func bytes(_ folder: URL) -> @MainActor () async -> Int64? {
        let path = folder.path
        return { await Task.detached(priority: .utility) { CarryCount.mac(path)?.bytes }.value }
    }

    struct Copied {
        var ok: Bool
        var said: String
        var sent = 0
        var received = 0
    }

    /// `files` (paths from `from`) to `to`, compressed, with rsync's own delta against what's
    /// there already; what it put on the wire, from `--stats`.
    /// `landing`: measures the bytes at `to` while it runs (a pull's stage on this Mac).
    func rsync(files: [String], from: String, to: String, landing: (@MainActor () async -> Int64?)? = nil) async -> Copied {
        let list = staging.appendingPathComponent("list-\(UUID().uuidString).txt")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: list.path, contents: Data(files.map { $0 + "\n" }.joined().utf8))
        defer { try? FileManager.default.removeItem(at: list) }
        let arguments = ["-az", "--stats", "--files-from=" + list.path] + box.rsyncOptions(false) + [from, to]
        var copied: Copied
        var out: String
        if progress != nil || stopper != nil {
            // Metered (and stoppable): its `--progress` lines read as they come, the bytes told every 250 ms.
            let (spawn, reader, meter, tail) = (stopper ?? Spawn(), RsyncReader(), CarryMeter(), OutputTail())
            let progress = progress
            let ticker = Task { @MainActor in
                var last: Int64 = -1
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    let now = meter.value
                    if now != last, !Task.isCancelled {
                        last = now
                        progress?(now, nil)
                    }
                }
            }
            let poll = landing.map { LandedPoll.start(every: pollEvery, into: meter, measure: $0) }
            let said = await spawn.run(
                [["/usr/bin/rsync", "--progress"] + arguments],
                output: {
                    meter.set(reader.feed($0))
                    tail.append($0)
                })
            ticker.cancel()
            poll?.cancel()
            progress?(meter.value, nil)
            copied = Copied(ok: said == nil, said: said ?? "")
            out = tail.text
        } else {
            let output = await SyncProcess.run("/usr/bin/rsync", arguments)
            copied = Copied(ok: [0, 24].contains(output.status), said: output.said)
            out = output.out
        }
        // Both rsyncs end with "sent N bytes  received M bytes  …" (this side's view).
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("sent ") {
            let words = line.split(separator: " ").map { $0.replacingOccurrences(of: ",", with: "") }
            if words.count > 4 {
                copied.sent = Int(words[1]) ?? 0
                copied.received = Int(words[4]) ?? 0
            }
        }
        return copied
    }
}

/// The last few KiB of a process's output (rsync's `--stats` lines come at its end).
final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ piece: Data) {
        lock.withLock {
            data.append(piece)
            if data.count > 16 * 1024 { data = Data(data.suffix(8 * 1024)) }
        }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
