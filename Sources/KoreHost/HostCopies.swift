import Foundation
import KoreCore
import LinkProtocol
import src

/// Link 1.11: a chat copied to another place (another folder here, another box, the Mac). The Mac
/// starts every copy. `chat.copy` names a chat's (or a past session's) files, which the Mac fetches
/// with rsync, as they are: nothing here changes, a working chat is copied as far as it has got.
/// A cut's `chat.copy` commit, once the copy is placed elsewhere, takes the source out of the box's
/// history: its session files into kore-host's own trash, never deleted. `chat.adoptCopy` takes a
/// copy from staging (`state/staging/<move id>/`, where the Mac's rsync put it) and places it under
/// its new session id as a new chat, the folder and the id rewritten (`SessionCopy`, in src).
extension HostDaemon {
    /// Where a cut's session files go: `state/trash/chats/<time>-<session>/`.
    package var chatTrash: URL { paths.state.appendingPathComponent("trash/chats", isDirectory: true) }

    // MARK: chat.copy

    func copyOut(_ args: ControlArgs, id: String, from client: LinkClient) -> MoveResult {
        func refused(_ code: ResultCode, _ message: String) -> MoveResult { .refused(id, code, message) }
        guard client.holder != nil, let phase = args.phase.flatMap(MovePhase.init(rawValue:)), let source = args.sourceId else {
            return refused(.invalid, "Name the chat and the phase.")
        }
        // A box chat (open or closed) by its id or its session's; else a past session of the folder's CLI.
        let hc = boxChat(source)
        if let hc, let refusal = Self.held(hc) { return refused(refusal.code, refusal.message) }
        let past: (provider: String, folder: String)?
        if hc == nil {
            guard let provider = args.provider, Registry.provider(provider) != nil, let folder = args.folder.map(Self.standard), serves(folder) else {
                return refused(.goneSession, "That chat isn't on this box.")
            }
            past = (provider, folder)
        } else {
            past = nil
        }
        let session = hc?.record.session ?? source
        let found =
            if let hc { hc.record.session.map { sessionFiles(hc, session: $0) } ?? SessionFiles.Found(root: chatTrash, files: []) } else {
                SessionCopy.files(provider: past!.provider, session: source, folder: past!.folder, env: sessionEnv)
            }
        switch phase {
        case .prepare:
            if let hc, !hc.idle {
                // A cut stops it first; a copy takes it as far as it has got.
                if args.stop == true { sleep(hc) }
            }
            guard !found.files.isEmpty else { return refused(.goneSession, "Nothing to copy yet: the chat hasn't started.") }
            let provider = hc?.record.provider ?? past!.provider
            let folder = hc?.record.folder ?? past!.folder
            let settings = hc?.record
            var answer = MoveResult(
                id: id, ok: true, chatId: hc?.id,
                move: MoveInfo(
                    moveId: UUID().uuidString.lowercased(), chatId: hc?.id, provider: provider, sessionId: session, folders: Self.spellings(folder),
                    root: found.root.path, files: found.files, gen: hc?.gen ?? 0, title: hc?.title ?? args.title,
                    modelId: settings?.controls?.modelId ?? settings?.modelId, effort: settings?.controls?.effort ?? settings?.effort, mode: settings?.mode))
            answer.move?.bytes = SessionFiles.bytes(found)
            return answer
        case .commit:
            // A cut's copy is placed elsewhere: the source leaves. Its CLI ends first.
            if let hc { sleep(hc) }
            do {
                if !found.files.isEmpty {
                    try HostPaths.privateFolder(chatTrash.deletingLastPathComponent())
                    try HostPaths.privateFolder(chatTrash)
                    try SessionCopy.trash(found, session: session, into: chatTrash)
                }
            } catch {
                return refused(.busy, "The box couldn't put the chat's files aside: \(error.localizedDescription)")
            }
            if let hc { forget(hc) }
            HostJournal.note("copy cut", ["chat": hc?.id ?? "-", "session": session, "files": "\(found.files.count)"])
            return MoveResult(id: id, ok: true, chatId: hc?.id)
        case .abort:
            return MoveResult(id: id, ok: true)
        }
    }

    // MARK: chat.adoptCopy

    func adoptCopy(_ args: ControlArgs, id: String, from client: LinkClient) -> MoveResult {
        func refused(_ code: ResultCode, _ message: String) -> MoveResult { .refused(id, code, message) }
        guard client.holder != nil, let phase = args.phase.flatMap(MovePhase.init(rawValue:)), let moveId = args.moveId, LinkMoves.plainMoveID(moveId)
        else { return refused(.invalid, "Name the move.") }
        let dir = staging.appendingPathComponent(moveId, isDirectory: true)
        switch phase {
        case .prepare:
            do {
                try? FileManager.default.removeItem(at: dir)
                try HostPaths.privateFolder(staging)
                try HostPaths.privateFolder(dir)
            } catch {
                return refused(.busy, "The box couldn't make its staging folder.")
            }
            moveClients[moveId] = ObjectIdentifier(client)
            return MoveResult(
                id: id, ok: true,
                move: MoveInfo(moveId: moveId, provider: args.provider ?? "", sessionId: args.sessionId ?? "", folders: [], root: dir.path, files: [], gen: 0))
        case .commit:
            defer {
                try? FileManager.default.removeItem(at: dir)
                moveClients[moveId] = nil
            }
            guard let new = args.sessionId, let old = args.sourceId, let provider = args.provider, Registry.provider(provider) != nil,
                let folder = args.folder.map(Self.standard), serves(folder), !HostConfig.missing(folder)
            else { return refused(.goneFolder, "That folder isn't on this box.") }
            let files = SessionFiles.tree(staging, under: moveId).map { String($0.dropFirst(moveId.count + 1)) }
            guard !files.isEmpty else { return refused(.goneSession, "Nothing was staged for that copy.") }
            // A new id is never one the box has: a chat of its own keeps its history.
            if boxChat(new) != nil { return refused(.staleGen, "A chat with that id is on this box already.") }
            let root = sessionRoot(provider, folder: folder)
            let rewrite = SessionCopy.rewrite(folders: args.folders ?? [], to: SessionFiles.real(folder), session: old, as: new)
            let placed: [String]
            do {
                placed = try SessionCopy.place(files, from: dir, to: root, rewrite: rewrite, old: old, new: new)
            } catch {
                return refused(.busy, "The box couldn't place the copy: \(error)")
            }
            guard SessionCopy.verified(placed, at: root, session: new) else {
                for path in placed { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
                return refused(.busy, "The copy didn't come out whole on this box.")
            }
            let main = SessionCopy.main(placed).map { root.appendingPathComponent($0).path }
            guard let hc = newChat(folder: folder, provider: provider, modelId: args.modelId, title: args.title, mode: args.mode, effort: args.level, session: new)
            else {
                for path in placed { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
                return refused(.invalid, "The box couldn't make the chat.")
            }
            hc.adoptedCopy(transcript: main, line: args.copiedFrom)
            HostJournal.note("copy adopt", ["chat": hc.id, "move": moveId, "files": "\(placed.count)"])
            broadcast(chats: [hc])
            return MoveResult(id: id, ok: true, chatId: hc.id)
        case .abort:
            moveClients[moveId] = nil
            try? FileManager.default.removeItem(at: dir)
            return MoveResult(id: id, ok: true)
        }
    }
}
