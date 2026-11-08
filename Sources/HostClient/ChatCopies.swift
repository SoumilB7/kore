import Foundation
import KoreCore
import LinkProtocol
import src

// Link 1.11 on the Mac: a chat copied from one place to another (a folder on this Mac, or a box
// folder), under a new session id. The Mac starts every copy and is the one place both ends are
// reached from: a box's files come to a staging folder here by rsync over its SSH alias, and go
// on to the other box the same way, never over the link. Each copy is rewritten once, where it
// lands (`SessionCopy`, in src): the folder and the session id, nothing else. A cut is a copy,
// verified, then its source leaves its history (Kore's own trash here, kore-host's on a box).

extension HostConnection {
    /// Whether the box takes 1.11's chat copies (a full grant).
    package var copiesChats: Bool { caps.contains("chatCopy") }
}

/// One end of a copy: a folder on this Mac, or a box folder (its link, ssh and staging).
@MainActor
package enum CopyEnd {
    case mac(String)
    case box(ChatMoves, folder: String)

    package var folder: String {
        switch self {
        case .mac(let folder): folder
        case .box(_, let folder): folder
        }
    }
}

/// What's copied: a chat at one end, by its History row's id (a session id on this Mac; a box
/// chat's id or a past session's id on a box).
@MainActor
package struct CopySource {
    package var end: CopyEnd
    package var id: String
    package var provider: String
    package var title: String
    /// Its transcript on this Mac, when the History listing said (a chat from before a rename).
    package var known: String?

    package init(end: CopyEnd, id: String, provider: String, title: String, known: String? = nil) {
        self.end = end
        self.id = id
        self.provider = provider
        self.title = title
        self.known = known
    }
}

/// A copy made: its new session, and on a box the chat made for it.
package struct ChatCopy: Sendable, Equatable {
    package var provider: String
    package var session: String
    package var chatId: String?
    package var title: String?
    package var modelId: String?
    package var effort: String?
    package var mode: String?
    package var cost = MoveCost()
}

@MainActor
package struct ChatCopies {
    /// This Mac's environment for the CLIs' folders (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `HOME`).
    package var env: [String: String]
    /// Where a box's files wait on this Mac on their way: `<staging>/<move id>/`.
    package var staging: URL
    /// Where a cut's source goes on this Mac: Kore's own trash for chats.
    package var trash: URL
    /// Told as the files cross: bytes so far and all of them (a box to box copy crosses twice),
    /// a few times a second (the transfer bar).
    package var progress: (@MainActor (_ bytes: Int64, _ total: Int64) -> Void)?
    /// Stops a running rsync (the bar's Cancel): the copy fails before anything is placed.
    package var stopper: Spawn?

    package init(env: [String: String] = ProcessInfo.processInfo.environment, staging: URL, trash: URL) {
        self.env = env
        self.staging = staging
        self.trash = trash
    }

    // MARK: Copy

    /// `moves` telling this copy's progress: its own bytes after `base`, of `total`.
    func metered(_ moves: ChatMoves, base: Int64, total: Int64) -> ChatMoves {
        var moves = moves
        moves.stopper = stopper
        if let progress { moves.progress = { bytes, _ in progress(min(base + bytes, total), total) } }
        return moves
    }

    /// `source` copied to `target` as session `new`. `line`: the copy's line above its history
    /// ("copied from “Repos” · mybox"); `stop`: a working box chat stops first (a cut); `whole`:
    /// the source has stopped, so the copy must have every row (a cut, checked before it goes).
    package func copy(
        _ source: CopySource, to target: CopyEnd, as new: String = SessionCopy.newId(), title: String? = nil, line: String? = nil, stop: Bool = false,
        whole: Bool = false
    ) async -> Result<ChatCopy, MoveFailure> {
        let title = title ?? source.title
        switch source.end {
        case .mac(let from):
            let found = SessionCopy.files(provider: source.provider, session: source.id, folder: from, known: source.known, env: env)
            guard !found.files.isEmpty else { return .failure(MoveFailure("The chat's session isn't on this Mac")) }
            let total = SessionFiles.bytes(found)
            progress?(0, total)
            switch target {
            case .mac(let to):
                let (env, provider, old) = (env, source.provider, source.id)
                let placed = await Task.detached(priority: .userInitiated) { () -> Result<SessionFiles.Found, MoveFailure> in
                    do {
                        return .success(
                            try SessionCopy.placed(
                                found, provider: provider, folders: SessionCopy.spellings(from), session: old, to: to, as: new, whole: whole, env: env))
                    } catch {
                        return .failure(MoveFailure(Self.line(error)))
                    }
                }.value
                if case .success = placed { progress?(total, total) }
                return placed.map { _ in ChatCopy(provider: provider, session: new, title: title) }
            case .box(let moves, let folder):
                return await push(
                    found, provider: source.provider, old: source.id, folders: SessionCopy.spellings(from), to: metered(moves, base: 0, total: total), folder: folder, as: new,
                    settings: ChatCopy(provider: source.provider, session: new, title: title), line: line)
            }
        case .box(let moves, let folder):
            guard moves.connection.copiesChats else { return .failure(MoveFailure("Update kore-host on \(NodeNames.name(moves.connection.alias)) to copy chats")) }
            var cost = MoveCost()
            let said = await moves.connection.move(
                .chatCopy,
                ControlArgs(title: source.title, sourceId: source.id, provider: source.provider, folder: folder, phase: MovePhase.prepare.rawValue, stop: stop ? true : nil))
            cost.linkBytes += moves.connection.lastMoveBytes
            guard said.ok, let info = said.move else { return .failure(MoveFailure(said.message ?? "Couldn't copy it", said.code)) }
            let files = info.files.filter(SessionFiles.plain)
            guard !files.isEmpty else { return .failure(MoveFailure("Nothing to copy")) }
            let stage = staging.appendingPathComponent(LinkMoves.plainMoveID(info.moveId) ? info.moveId : UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            let size = info.bytes ?? 0
            let total: Int64 = if case .box = target { size * 2 } else { size }
            progress?(0, total)
            let pulled = await metered(moves, base: 0, total: total).rsync(
                files: files, from: moves.box.spec(info.root + "/"), to: stage.path + "/", landing: ChatMoves.bytes(stage))
            cost.rsyncReceived += pulled.received
            cost.rsyncSent += pulled.sent
            guard pulled.ok else { return .failure(MoveFailure("Couldn't copy the session: \(pulled.said)")) }
            let found = SessionFiles.Found(root: stage, files: files)
            var made = ChatCopy(
                provider: info.provider, session: new, title: title, modelId: info.modelId, effort: info.effort, mode: info.mode, cost: cost)
            switch target {
            case .mac(let to):
                let (env, old, folders) = (env, info.sessionId, info.folders)
                let placed = await Task.detached(priority: .userInitiated) { () -> Result<SessionFiles.Found, MoveFailure> in
                    do {
                        return .success(try SessionCopy.placed(found, provider: info.provider, folders: folders, session: old, to: to, as: new, whole: whole, env: env))
                    } catch {
                        return .failure(MoveFailure(Self.line(error)))
                    }
                }.value
                made.cost.files = files.count
                if case .success = placed { progress?(total, total) }
                return placed.map { _ in made }
            case .box(let other, let folder):
                return await push(
                    found, provider: info.provider, old: info.sessionId, folders: info.folders, to: metered(other, base: size, total: total), folder: folder, as: new,
                    settings: made, line: line)
            }
        }
    }

    /// Files on this Mac (a chat's own, or staged from a box) to a box as a new chat there:
    /// `chat.adoptCopy` prepare, rsync into its staging, commit. Any failure before the commit aborts.
    func push(
        _ found: SessionFiles.Found, provider: String, old: String, folders: [String], to moves: ChatMoves, folder: String, as new: String,
        settings: ChatCopy, line: String?
    ) async -> Result<ChatCopy, MoveFailure> {
        let connection = moves.connection
        guard connection.copiesChats else { return .failure(MoveFailure("Update kore-host on \(NodeNames.name(connection.alias)) to copy chats")) }
        var made = settings
        let moveId = UUID().uuidString.lowercased()
        let prepared = await connection.move(.chatAdoptCopy, ControlArgs(provider: provider, sessionId: new, phase: MovePhase.prepare.rawValue, moveId: moveId))
        made.cost.linkBytes += connection.lastMoveBytes
        guard prepared.ok, let info = prepared.move else { return .failure(MoveFailure(prepared.message ?? "Couldn't copy it there", prepared.code)) }
        func abort(_ line: String) async -> Result<ChatCopy, MoveFailure> {
            _ = await connection.move(.chatAdoptCopy, ControlArgs(phase: MovePhase.abort.rawValue, moveId: moveId))
            return .failure(MoveFailure(line))
        }
        let pushed = await moves.rsync(files: found.files, from: found.root.path + "/", to: moves.box.spec(info.root + "/"))
        made.cost.rsyncSent += pushed.sent
        made.cost.rsyncReceived += pushed.received
        made.cost.files = found.files.count
        guard pushed.ok else { return await abort("Couldn't copy the session: \(pushed.said)") }
        let commit = ControlArgs(
            title: settings.title.map { String($0.prefix(LinkPolicy.maxTitle)) }, modelId: settings.modelId.flatMap { LinkPolicy.plainID($0) ? $0 : nil },
            level: settings.effort.flatMap { LinkPolicy.plainID($0) ? $0 : nil }, sourceId: old, provider: provider, sessionId: new, mode: settings.mode,
            folder: folder, folders: folders, phase: MovePhase.commit.rawValue, moveId: moveId, copiedFrom: line)
        let adopted = await connection.move(.chatAdoptCopy, commit)
        made.cost.linkBytes += connection.lastMoveBytes
        guard adopted.ok, let chatId = adopted.chatId else { return .failure(MoveFailure(adopted.message ?? "\(NodeNames.name(connection.alias)) didn't take it", adopted.code)) }
        made.chatId = chatId
        HostLog.note(connection.alias, "copy there", "chat \(chatId) files \(found.files.count) rsync \(made.cost.rsyncSent)B")
        return .success(made)
    }

    // MARK: Cut

    /// A cut where 1.10's moves don't reach (folder to folder on this Mac, box to box, a box's
    /// past session): a copy of the stopped source, checked whole, and only then the source out
    /// of its history. A copy that fails leaves the source as it was. `kept`: the copy is made
    /// but the source couldn't be put aside (it stays; the line says so).
    package func cut(_ source: CopySource, to target: CopyEnd, as new: String = SessionCopy.newId()) async -> (copy: Result<ChatCopy, MoveFailure>, kept: MoveFailure?) {
        let made = await copy(source, to: target, as: new, stop: true, whole: true)
        guard case .success = made else { return (made, nil) }
        if case .failure(let failure) = await removeSource(source) { return (made, failure) }
        return (made, nil)
    }

    // MARK: A cut's source

    /// After a cut's copy is placed and verified: the source leaves its folder's history. On this
    /// Mac its files go to Kore's trash; on a box, kore-host's (`chat.copy` commit).
    package func removeSource(_ source: CopySource) async -> Result<Void, MoveFailure> {
        switch source.end {
        case .mac(let folder):
            let found = SessionCopy.files(provider: source.provider, session: source.id, folder: folder, known: source.known, env: env)
            guard !found.files.isEmpty else { return .success(()) }
            do {
                try SessionCopy.trash(found, session: source.id, into: trash)
                return .success(())
            } catch {
                return .failure(MoveFailure("The copy is made; the original stays: \(Self.line(error))"))
            }
        case .box(let moves, let folder):
            let said = await moves.connection.move(
                .chatCopy, ControlArgs(sourceId: source.id, provider: source.provider, folder: folder, phase: MovePhase.commit.rawValue))
            return said.ok ? .success(()) : .failure(MoveFailure("The copy is made; the original stays on \(NodeNames.name(moves.connection.alias))", said.code))
        }
    }

    nonisolated static func line(_ error: any Error) -> String {
        if let copy = error as? SessionCopy.CopyError { return copy.line }
        return "Couldn't copy the session: \(error.localizedDescription)"
    }
}
