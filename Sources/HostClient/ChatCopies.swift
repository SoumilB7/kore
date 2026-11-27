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
    /// Whether this Mac may put the box's chats in Full access (owner, 2026-11-22): a grant with
    /// full control, on a kore-host that says it takes it (`LinkPolicy.fullAccessCap`).
    package var takesFullAccess: Bool { control == .full && caps.contains(LinkPolicy.fullAccessCap) }
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
    /// A chat on this Mac: its settings as its tab (or what Kore keeps for its session) has them.
    /// A box's come from the box.
    package var settings: ChatSettings?

    package init(end: CopyEnd, id: String, provider: String, title: String, known: String? = nil, settings: ChatSettings? = nil) {
        self.end = end
        self.id = id
        self.provider = provider
        self.title = title
        self.known = known
        self.settings = settings
    }
}

/// A copy made: its new session, and on a box the chat made for it, with the settings it carried
/// (no draft for a copy: the original keeps it) and what gave way where it landed, a line each.
package struct ChatCopy: Sendable, Equatable {
    package var provider: String
    package var session: String
    package var chatId: String?
    package var title: String?
    package var settings = ChatSettings()
    /// The settings came whole (this Mac's, or a box's that says them): an Arsenal tier absent is
    /// off. False: a box from before them said only model, effort and mode.
    package var whole = true
    package var notes: [String] = []
    package var cost = MoveCost()

    package var modelId: String? { settings.modelId }
    package var effort: String? { settings.effort }
    package var mode: String? { settings.mode }
}

extension ChatSettings {
    /// As said to box `connection`: a tier it doesn't take is the one below (Act device to an
    /// older box is Act unlimited), and none while this Mac's chats can't use Arsenal
    /// (`arsenal` false); a mode above Auto is Auto unless this Mac may put the box's chats in Full
    /// access (`takesFullAccess`), each said in `notes`.
    @MainActor package func said(to connection: HostConnection, provider: String, arsenal allowed: Bool = true, notes: inout [String]) -> ChatSettings {
        var said = self
        if let mode, case let capped = LinkPolicy.cappedMode(mode, provider: provider, fullAccess: connection.takesFullAccess), capped != mode {
            said.mode = capped
            notes.append(LinkPolicy.boxCappedLine(provider, to: capped))
        }
        said.arsenal = allowed ? BoxTools.said(arsenal, caps: connection.caps) : nil
        if let asked = arsenal, said.arsenal != asked {
            notes.append(
                allowed
                    ? "Arsenal \(Self.tierName(asked)) isn't on \(NodeNames.name(connection.alias)) · \(said.arsenal.map(Self.tierName) ?? "off")"
                    : "Arsenal \(Self.tierName(asked)) is off · chats can't use Arsenal here")
        }
        return said
    }
}

extension ChatSettings {
    /// As a copy a phone asked for takes them (`chat.copyVia`): the mode no higher than a phone's
    /// new chat starts in (`LinkPolicy.askedMode`), Arsenal and Plan's allow switch off. A new chat
    /// never has by copying what a phone needs a fingerprint for, or can't set at all.
    func asked(provider: String) -> ChatSettings {
        var said = self
        said.mode = LinkPolicy.askedMode(mode, provider: provider)
        // Its history may end higher: its CLI never goes there by itself.
        said.modeCeiling = min(modeCeiling ?? .max, LinkPolicy.leavePlanMaxLevel.rawValue)
        said.arsenal = nil
        said.planAllow = false
        return said
    }
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
    /// This Mac lets chats use Arsenal: a tier goes with a copy to a box only then.
    package var arsenalAllowed = true
    /// A phone asked for it (`chat.copyVia`): the copy's settings are capped (`ChatSettings.asked`).
    package var asked = false
    /// The phone that asked: each box says whether it's allowed there (`ControlArgs.phone`).
    package var phone: UUID?
    /// How long a copy waits for a box whose link went partway, before it says so.
    package var patience: Duration = .seconds(60)

    package init(env: [String: String] = ProcessInfo.processInfo.environment, staging: URL, trash: URL) {
        self.env = env
        self.staging = staging
        self.trash = trash
    }

    /// `args` naming the phone a copy is made for.
    func told(_ args: ControlArgs) -> ControlArgs {
        var args = args
        args.phone = phone?.uuidString.lowercased()
        return args
    }

    /// A box that can't check the phone that asked is never copied to or from for it.
    func unchecked(_ connection: HostConnection) -> MoveFailure? {
        phone == nil || connection.caps.contains(LinkPolicy.copyForCap) ? nil : MoveFailure("Update kore-host on \(NodeNames.name(connection.alias)) to copy from a phone")
    }

    // MARK: A link that goes

    /// The box is linked now, or comes back within `patience` (a stopped copy waits no longer).
    func back(_ connection: HostConnection) async -> Bool {
        let end = ContinuousClock.now + patience
        while !connection.isOnline {
            if case .refused = connection.phase { return false }
            guard connection.inUse, stopper?.isStopped != true, ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// The copy's last step on a box, never left waiting on a dead link and never run twice: one
    /// whose answer was lost with the link is asked again once it's back, and the box says the
    /// chat it made the first time.
    func commit(_ args: ControlArgs, on connection: HostConnection) async -> MoveResult {
        let box = NodeNames.name(connection.alias)
        // A box drops a lost link's staging, so nothing was made there and nothing will be.
        let nothing = "Lost \(box) partway · nothing changed"
        let unsure = "Lost \(box) at the end · look there before copying again"
        guard await back(connection) else { return .refused("", .unknown, nothing) }
        var said = await connection.move(.chatAdoptCopy, args)
        if !said.ok, said.message == connection.lostLine {
            guard await back(connection) else { return .refused("", .unknown, unsure) }
            said = await connection.move(.chatAdoptCopy, args)
            if !said.ok, said.message == connection.lostLine { return .refused("", .unknown, unsure) }
        }
        return !said.ok && said.code == .goneSession ? .refused(said.id, .goneSession, nothing) : said
    }

    // MARK: Copy

    /// A source's rollback point, as a copy takes it: a Claude cut its file doesn't say yet (Codex
    /// keeps its own in the rollout). The copy resumes there.
    static func rollbackPoint(_ provider: String, _ at: String?) -> String? {
        provider == ProviderDescriptor.claude.id ? LinkMoves.rollbackPoint(at) : nil
    }

    static func keepRollbackPoint(_ at: String?, provider: String, session: String) {
        guard let at = rollbackPoint(provider, at) else { return }
        RollbackPoints.set(at, for: session)
    }

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
    /// `draft`: the copy takes the source's draft too (a cut; a copy leaves it with its original).
    package func copy(
        _ source: CopySource, to target: CopyEnd, as new: String = SessionCopy.newId(), title: String? = nil, line: String? = nil, stop: Bool = false,
        whole: Bool = false, draft: Bool = false
    ) async -> Result<ChatCopy, MoveFailure> {
        let title = title ?? source.title
        func carried(_ settings: ChatSettings?, _ provider: String) -> ChatSettings {
            var settings = settings?.linkable ?? ChatSettings()
            if asked { settings = settings.asked(provider: provider) }
            if !draft { settings.draft = nil }
            settings.at = nil
            settings.changed = nil
            return settings
        }
        switch source.end {
        case .mac(let from):
            let found = SessionCopy.files(provider: source.provider, session: source.id, folder: from, known: source.known, env: env)
            guard !found.files.isEmpty else { return .failure(MoveFailure("The chat's session isn't on this Mac")) }
            let cut = Self.rollbackPoint(source.provider, RollbackPoints.at(source.id))
            let total = SessionFiles.bytes(found)
            progress?(0, total)
            switch target {
            case .mac(let to):
                let (env, provider, old) = (env, source.provider, source.id)
                let settings = carried(source.settings, source.provider)
                ModeCeilings.put(settings.modeCeiling, for: new)
                let placed = await Task.detached(priority: .userInitiated) { () -> Result<SessionFiles.Found, MoveFailure> in
                    do {
                        return .success(
                            try SessionCopy.placed(
                                found, provider: provider, folders: SessionCopy.spellings(from), session: old, to: to, as: new, whole: whole, env: env))
                    } catch {
                        return .failure(MoveFailure(Self.line(error)))
                    }
                }.value
                if case .success = placed {
                    progress?(total, total)
                    Self.keepRollbackPoint(cut, provider: provider, session: new)
                } else {
                    ModeCeilings.put(nil, for: new)
                }
                return placed.map { _ in ChatCopy(provider: provider, session: new, title: title, settings: settings) }
            case .box(let moves, let folder):
                return await push(
                    found, provider: source.provider, old: source.id, folders: SessionCopy.spellings(from), to: metered(moves, base: 0, total: total), folder: folder, as: new,
                    settings: ChatCopy(provider: source.provider, session: new, title: title, settings: carried(source.settings, source.provider)), line: line, rollbackAt: cut)
            }
        case .box(let moves, let folder):
            guard moves.connection.copiesChats else { return .failure(MoveFailure("Update kore-host on \(NodeNames.name(moves.connection.alias)) to copy chats")) }
            if let failure = unchecked(moves.connection) { return .failure(failure) }
            if case .box(let other, _) = target, let failure = unchecked(other.connection) { return .failure(failure) }
            var cost = MoveCost()
            let said = await moves.connection.move(
                .chatCopy,
                told(ControlArgs(title: source.title, sourceId: source.id, provider: source.provider, folder: folder, phase: MovePhase.prepare.rawValue, stop: stop ? true : nil)))
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
            // A box from before `settings` says the four it knows.
            let settings = carried(info.settings ?? ChatSettings(modelId: info.modelId, effort: info.effort, mode: info.mode), info.provider)
            var made = ChatCopy(provider: info.provider, session: new, title: title, settings: settings, whole: info.settings != nil, cost: cost)
            switch target {
            case .mac(let to):
                let (env, old, folders) = (env, info.sessionId, info.folders)
                ModeCeilings.put(settings.modeCeiling, for: new)
                let placed = await Task.detached(priority: .userInitiated) { () -> Result<SessionFiles.Found, MoveFailure> in
                    do {
                        return .success(try SessionCopy.placed(found, provider: info.provider, folders: folders, session: old, to: to, as: new, whole: whole, env: env))
                    } catch {
                        return .failure(MoveFailure(Self.line(error)))
                    }
                }.value
                made.cost.files = files.count
                if case .success = placed {
                    progress?(total, total)
                    Self.keepRollbackPoint(info.rollbackAt, provider: info.provider, session: new)
                } else {
                    ModeCeilings.put(nil, for: new)
                }
                return placed.map { _ in made }
            case .box(let other, let folder):
                return await push(
                    found, provider: info.provider, old: info.sessionId, folders: info.folders, to: metered(other, base: size, total: total), folder: folder, as: new,
                    settings: made, line: line, rollbackAt: Self.rollbackPoint(info.provider, info.rollbackAt))
            }
        }
    }

    /// Files on this Mac (a chat's own, or staged from a box) to a box as a new chat there:
    /// `chat.adoptCopy` prepare, rsync into its staging, commit. Any failure before the commit aborts.
    func push(
        _ found: SessionFiles.Found, provider: String, old: String, folders: [String], to moves: ChatMoves, folder: String, as new: String,
        settings: ChatCopy, line: String?, rollbackAt: String? = nil
    ) async -> Result<ChatCopy, MoveFailure> {
        let connection = moves.connection
        guard connection.copiesChats else { return .failure(MoveFailure("Update kore-host on \(NodeNames.name(connection.alias)) to copy chats")) }
        if let failure = unchecked(connection) { return .failure(failure) }
        var made = settings
        let moveId = UUID().uuidString.lowercased()
        let prepared = await connection.move(.chatAdoptCopy, told(ControlArgs(provider: provider, sessionId: new, phase: MovePhase.prepare.rawValue, moveId: moveId)))
        made.cost.linkBytes += connection.lastMoveBytes
        guard prepared.ok, let info = prepared.move else { return .failure(MoveFailure(prepared.message ?? "Couldn't copy it there", prepared.code)) }
        // Told only while linked, and not waited for: a box whose link went clears its own staging.
        func abort(_ line: String) -> Result<ChatCopy, MoveFailure> {
            if connection.isOnline { Task { _ = await connection.move(.chatAdoptCopy, ControlArgs(phase: MovePhase.abort.rawValue, moveId: moveId)) } }
            return .failure(MoveFailure(line))
        }
        let pushed = await moves.rsync(files: found.files, from: found.root.path + "/", to: moves.box.spec(info.root + "/"))
        made.cost.rsyncSent += pushed.sent
        made.cost.rsyncReceived += pushed.received
        made.cost.files = found.files.count
        guard pushed.ok else { return abort("Couldn't copy the session: \(pushed.said)") }
        made.settings = settings.settings.said(to: connection, provider: provider, arsenal: arsenalAllowed, notes: &made.notes).linkable
        var commit = ControlArgs(
            title: settings.title.map { String($0.prefix(LinkPolicy.maxTitle)) }, modelId: made.settings.modelId, level: made.settings.effort, sourceId: old,
            provider: provider, sessionId: new, mode: made.settings.mode, folder: folder, folders: folders, phase: MovePhase.commit.rawValue, moveId: moveId,
            copiedFrom: line, settings: made.settings)
        commit.rollbackAt = rollbackAt
        let adopted = await self.commit(told(commit), on: connection)
        made.cost.linkBytes += connection.lastMoveBytes
        guard adopted.ok, let chatId = adopted.chatId else { return .failure(MoveFailure(adopted.message ?? "\(NodeNames.name(connection.alias)) didn't take it", adopted.code)) }
        made.chatId = chatId
        if let note = adopted.message { made.notes.append(note) }
        // What the box made of them (a box from before says nothing: they stand as sent).
        if let landed = adopted.settings?.linkable { made.settings = landed }
        HostLog.event(connection.alias, "copy there", ["chat": chatId, "files": String(found.files.count), "bytes": String(made.cost.rsyncSent)])
        return .success(made)
    }

    // MARK: Cut

    /// A cut where 1.10's moves don't reach (folder to folder on this Mac, box to box, a box's
    /// past session): a copy of the stopped source, checked whole, and only then the source out
    /// of its history. A copy that fails leaves the source as it was. `kept`: the copy is made
    /// but the source couldn't be put aside (it stays; the line says so).
    package func cut(_ source: CopySource, to target: CopyEnd, as new: String = SessionCopy.newId()) async -> (copy: Result<ChatCopy, MoveFailure>, kept: MoveFailure?) {
        let made = await copy(source, to: target, as: new, stop: true, whole: true, draft: true)
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
