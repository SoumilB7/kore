import Foundation
import KoreCore
import LinkProtocol
import src

/// Link 1.10: a chat moving between the box and the Mac linked to it. The Mac starts every move.
/// `chat.release` hands a box chat to the Mac (prepare freezes it and names its session files,
/// which the Mac fetches with rsync; commit makes the box's copy a replica; abort un-freezes it).
/// `chat.adopt` takes one back from staging (`state/staging/<move id>/`, where the Mac's rsync
/// put it): a fast-forward while the box still holds the gen it gave, else a new chat. While the
/// Mac holds a chat, `chat.mirror` brings its new events to the replica. `sync.flush` answers
/// once the box's side of a folder's sync has said everything.
extension HostDaemon {
    var staging: URL { paths.state.appendingPathComponent("staging") }

    /// Staging folders a day old are a move that never finished: they go when the daemon starts.
    func sweepStaging() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for dir in dirs {
            let made = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(made) > 86400 { try? FileManager.default.removeItem(at: dir) }
        }
    }

    /// The folder's two spellings (as kept, and its real path): the rows' `cwd`s a move rewrites.
    static func spellings(_ folder: String) -> [String] {
        let real = SessionFiles.real(folder)
        return real == folder ? [folder] : [folder, real]
    }

    /// The session's files on this box.
    func sessionFiles(_ hc: HostChat, session: String) -> SessionFiles.Found {
        hc.record.provider == ProviderDescriptor.codex.id
            ? SessionFiles.codex(session, known: hc.record.transcript, env: sessionEnv)
            : SessionFiles.claude(session, folder: hc.record.folder, env: sessionEnv)
    }

    /// Where a session's files land on this box for `folder`.
    func sessionRoot(_ provider: String, folder: String) -> URL {
        provider == ProviderDescriptor.codex.id
            ? SessionFiles.codexSessions(sessionEnv)
            : SessionFiles.claudeProjects(sessionEnv).appendingPathComponent(ClaudeHistory.projectKey(for: URL(fileURLWithPath: folder)))
    }

    // MARK: chat.release

    func release(_ args: ControlArgs, id: String, from client: LinkClient) -> MoveResult {
        func refused(_ code: ResultCode, _ message: String) -> MoveResult { .refused(id, code, message) }
        guard let grant = client.holder, let phase = args.phase.flatMap(MovePhase.init(rawValue:)) else { return refused(.invalid, "Name the phase.") }
        guard let hc = args.chatId.flatMap(chat) else { return refused(.goneChat, "No such chat on this box.") }
        switch phase {
        case .prepare:
            if let refusal = Self.held(hc) { return refused(refusal.code, refusal.message) }
            guard args.gen == hc.gen else { return refused(.staleGen, "The chat moved since; look again.") }
            guard let session = hc.record.session else { return refused(.goneSession, "Nothing to move yet: the chat hasn't started.") }
            if !hc.idle {
                guard args.stop == true else { return refused(.busy, "The chat is working.") }
                hc.chat?.stop()
            }
            let moveId = UUID().uuidString.lowercased()
            hc.setMoving(MoveHold(moveId: moveId, grant: grant, at: Date().timeIntervalSince1970))
            moveClients[moveId] = ObjectIdentifier(client)
            // Its CLI ends: the session files hold still while they're copied.
            sleep(hc)
            let found = sessionFiles(hc, session: session)
            guard let first = found.files.first(where: { !$0.contains("/") || hc.record.provider == ProviderDescriptor.codex.id }) else {
                unfreeze(hc)
                return refused(.goneSession, "The CLI's session file isn't on this box.")
            }
            hc.setTranscript(found.root.appendingPathComponent(first).path)
            HostJournal.note("move prepare", ["chat": hc.id, "move": moveId, "grant": grant, "files": "\(found.files.count)"])
            broadcast(chats: [hc])
            let settings = hc.record
            var answer = MoveResult(
                id: id, ok: true, chatId: hc.id,
                move: MoveInfo(
                    moveId: moveId, chatId: hc.id, provider: settings.provider, sessionId: session, folders: Self.spellings(settings.folder),
                    root: found.root.path, files: found.files, gen: hc.gen, title: hc.title, modelId: settings.controls?.modelId ?? settings.modelId,
                    effort: settings.controls?.effort ?? settings.effort, mode: settings.mode))
            answer.move?.bytes = SessionFiles.bytes(found)
            return answer
        case .commit:
            guard let hold = hc.record.moving, hold.moveId == args.moveId, hold.grant == grant else { return refused(.staleGen, "That move isn't under way.") }
            let owner = ChatOwner(host: grant, gen: hc.gen + 1, since: Int64(Date().timeIntervalSince1970 * 1000), name: args.host, mirrored: 0)
            hc.setOwner(owner)
            hc.setMoving(nil)
            moveClients[hold.moveId] = nil
            HostJournal.note("move commit", ["chat": hc.id, "move": hold.moveId, "gen": "\(owner.gen)"])
            followersChanged(hc)
            broadcast(chats: [hc])
            return MoveResult(id: id, ok: true, chatId: hc.id, owner: owner)
        case .abort:
            if let hold = hc.record.moving, hold.moveId == args.moveId, hold.grant == grant { unfreeze(hc) }
            return MoveResult(id: id, ok: true, chatId: hc.id)
        }
    }

    /// The move didn't happen: the box still holds the chat, and it takes messages again.
    func unfreeze(_ hc: HostChat) {
        guard let hold = hc.record.moving else { return }
        moveClients[hold.moveId] = nil
        hc.setMoving(nil)
        HostJournal.note("move abort", ["chat": hc.id, "move": hold.moveId])
        broadcast(chats: [hc])
    }

    /// A link that ends mid-move aborts it: its chats un-freeze, its staging goes.
    func movesEnded(_ client: LinkClient) {
        let mine = ObjectIdentifier(client)
        for (moveId, owner) in moveClients where owner == mine {
            moveClients[moveId] = nil
            if let hc = chats.first(where: { $0.record.moving?.moveId == moveId }) { unfreeze(hc) }
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(moveId))
        }
    }

    // MARK: chat.adopt

    func adopt(_ args: ControlArgs, id: String, from client: LinkClient) -> MoveResult {
        func refused(_ code: ResultCode, _ message: String) -> MoveResult { .refused(id, code, message) }
        guard let grant = client.holder, let phase = args.phase.flatMap(MovePhase.init(rawValue:)), let moveId = args.moveId,
            LinkMoves.plainMoveID(moveId)
        else { return refused(.invalid, "Name the move.") }
        let dir = staging.appendingPathComponent(moveId, isDirectory: true)
        // The chat a return fast-forwards: the replica this grant holds, at the gen it holds.
        func held() -> HostChat? {
            guard let hc = args.chatId.flatMap(chat), let owner = hc.record.owner, owner.host == grant, owner.gen == args.gen,
                hc.record.session == args.sessionId, hc.record.provider == args.provider
            else { return nil }
            return hc
        }
        switch phase {
        case .prepare:
            guard let session = args.sessionId, let provider = args.provider, Registry.provider(provider) != nil else { return refused(.invalid, "No such CLI.") }
            do {
                try? FileManager.default.removeItem(at: dir)
                try HostPaths.privateFolder(staging)
                try HostPaths.privateFolder(dir)
            } catch {
                return refused(.busy, "The box couldn't make its staging folder.")
            }
            moveClients[moveId] = ObjectIdentifier(client)
            var files: [String] = []
            let target = held()
            // The box's own copy, in the Mac's folder's words: rsync then sends only what's new.
            if let hc = target, let macFolder = args.from {
                let found = sessionFiles(hc, session: session)
                let rewrite = FolderRewrite(from: Self.spellings(hc.record.folder), to: macFolder)
                files = found.files
                _ = try? rewrite.files(found.files, from: found.root, to: dir)
            }
            return MoveResult(
                id: id, ok: true, chatId: target?.id,
                move: MoveInfo(
                    moveId: moveId, chatId: target?.id, provider: provider, sessionId: session, folders: [], root: dir.path, files: files,
                    gen: target?.gen ?? 0, fastForward: target != nil))
        case .commit:
            guard let session = args.sessionId, let provider = args.provider, let folder = args.folder.map(Self.standard), serves(folder),
                !HostConfig.missing(folder)
            else { return refused(.goneFolder, "That folder isn't on this box.") }
            guard FileManager.default.fileExists(atPath: dir.path) else { return refused(.goneSession, "Nothing was staged for that move.") }
            let files = SessionFiles.tree(staging, under: moveId).map { String($0.dropFirst(moveId.count + 1)) }
            guard !files.isEmpty else { return refused(.goneSession, "Nothing was staged for that move.") }
            let root = sessionRoot(provider, folder: folder)
            let fastForward = held()
            // Not a fast-forward, while the box keeps that session for a chat of its own: placing
            // it would rewrite that chat's history. It stays where it is.
            if fastForward == nil, let other = (chats + closedChats).first(where: { $0.record.session == session }),
                sessionFiles(other, session: session).files.isEmpty == false
            {
                try? FileManager.default.removeItem(at: dir)
                moveClients[moveId] = nil
                return refused(.staleGen, "\(other.title) moved on here meanwhile; this copy stays on the Mac.")
            }
            let rewrite = FolderRewrite(from: args.folders ?? (args.from.map { [$0] } ?? []), to: SessionFiles.real(folder))
            do {
                try rewrite.files(files, from: dir, to: root)
            } catch {
                return refused(.busy, "The box couldn't place the session: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: dir)
            moveClients[moveId] = nil
            let main = files.first { provider == ProviderDescriptor.codex.id || !$0.contains("/") }.map { root.appendingPathComponent($0).path }
            let owner = ChatOwner(host: ChatOwner.box, gen: (args.gen ?? 0) + 1, since: Int64(Date().timeIntervalSince1970 * 1000))
            if let hc = fastForward {
                // A fast-forward: the box's chat again, its history the one that came back.
                let complete = hc.record.owner?.mirrored == args.seq && args.seq != nil
                hc.adopted(session: session, transcript: main, title: args.title, modelId: args.modelId, effort: args.level, mode: args.mode)
                hc.setOwner(owner)
                hc.forgetLog()
                // Everything said on the Mac is in the replica's events already: nothing is sent
                // again. Else the next start's history replaces them.
                if !complete { hc.stream.restart(with: []) }
                HostJournal.note("move adopt", ["chat": hc.id, "move": moveId, "gen": "\(owner.gen)", "mirrored": complete ? "all" : "some"])
                followersChanged(hc)
                broadcast(chats: [hc])
                return MoveResult(id: id, ok: true, chatId: hc.id, owner: owner)
            }
            // Not the gen the box gave (a copy was made meanwhile, or the box never had it): a
            // new chat, said to come from the Mac. Never merged.
            guard let hc = newChat(folder: folder, provider: provider, modelId: args.modelId, title: args.title, mode: args.mode, effort: args.level, session: session)
            else { return refused(.invalid, "The box couldn't make the chat.") }
            hc.adoptedNew(from: args.host ?? grant, transcript: main)
            HostJournal.note("move adopt", ["chat": hc.id, "move": moveId, "new": "true"])
            broadcast(chats: [hc])
            return MoveResult(id: id, ok: true, chatId: hc.id, owner: nil)
        case .abort:
            moveClients[moveId] = nil
            try? FileManager.default.removeItem(at: dir)
            return MoveResult(id: id, ok: true)
        }
    }

    // MARK: chat.mirror

    /// The holding Mac's new events, into the replica's own event log (best effort; the box never
    /// acts on them). `seq` is the first one's number in the Mac's count: a repeat is skipped, a gap
    /// is refused with what the replica holds, so the Mac sends from there.
    func mirror(_ args: ControlArgs, id: String, from client: LinkClient) -> MoveResult {
        guard let hc = args.chatId.flatMap(chat) else { return .refused(id, .goneChat, "No such chat on this box.") }
        guard var owner = hc.record.owner, !owner.onBox, owner.host == client.holder, owner.gen == args.gen else {
            return .refused(id, .staleGen, "This Mac doesn't hold that chat.")
        }
        var have = owner.mirrored ?? 0
        let start = args.seq ?? 0
        guard start <= have else { return MoveResult(id: id, ok: false, code: .invalid, message: "Send from \(have).", mirrored: have) }
        for (offset, item) in (args.events?.items ?? []).enumerated() where start + offset == have {
            if let event = item.e { hc.stream.add(event, by: nil) }
            have += 1
        }
        if have != owner.mirrored {
            owner.mirrored = have
            hc.setOwner(owner)
        }
        return MoveResult(id: id, ok: true, mirrored: have)
    }

    /// Who follows a replica changed: its meta says whether anyone does (the holder mirrors only then).
    func followersChanged(_ hc: HostChat) {
        let now = hc.isReplica && provenClients.contains { $0.streams(hc.id) || $0.follows(hc.id) }
        guard now != hc.followedByOthers else { return }
        hc.followedByOthers = now
        broadcast(chats: [hc])
    }
}
