import Foundation
import KoreCore
import LinkProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A Mac's files coming in for an update (`from: mac`): the three, one at a time, each in order.
struct UpdateReceive {
    var id: String
    var client: LinkClient
    var by: String
    var names: [String]
    var index = 0
    var offset = 0
}

/// The daemon's side of updates (phase 19): `chats.state` for `kore-host update` to see an idle
/// box, a Mac's "Keep boxes updated" (`host.keep`) kept for `status`, and a Mac's `host.update`
/// run as `kore-host update --by <Mac>` in its own session, so the restart it ends with doesn't
/// take it down halfway.
extension HostDaemon {
    /// `<working> <open>` into `chats.state`, only when it changed.
    func noteChats() {
        let now = [chats.filter(\.running).count, chats.filter(\.cliRunning).count]
        guard now != chatsNoted else { return }
        chatsNoted = now
        try? HostPaths.privateFile(Data("\(now[0]) \(now[1])\n".utf8), to: paths.chatsState)
    }

    /// `host.keep{on, by}`: the Mac whose setting keeps this box current, or none.
    func updateKeep(_ data: Data, from client: LinkClient) {
        guard let keep = try? JSONDecoder().decode(UpdateWire.Keep.self, from: data) else { return }
        guard client.current() == .full else { return client.denied(UpdateWire.keep) }
        var state = UpdateState.load(paths)
        if keep.on {
            state.keptBy = Self.oneLine(keep.by)
            state.keptAt = now()
        } else if state.keptBy == Self.oneLine(keep.by) {
            state.keptBy = nil
            state.keptAt = nil
        }
        state.save(paths)
    }

    /// `host.update{version, by}`: refused while a chat works here or another update runs;
    /// otherwise `kore-host update --by` runs apart, and only its failure is answered (a success
    /// restarts this daemon: links hear `bye restart`). With `from: mac` the files come from the
    /// Mac first (`receive`).
    func updateNow(_ data: Data, from client: LinkClient) {
        guard let ask = try? JSONDecoder().decode(UpdateWire.Update.self, from: data) else { return }
        func answer(_ outcome: UpdateWire.Result.Outcome, _ line: String) {
            client.sendRaw(StreamWire.encode(UpdateWire.Result(id: ask.id, outcome: outcome, line: line)))
        }
        guard client.current() == .full else {
            client.denied(UpdateWire.update)
            return answer(.failed, "Updating this box needs a grant with full control.")
        }
        let working = chats.filter(\.running).count
        if working > 0 { return answer(.busy, working == 1 ? "1 chat is working" : "\(working) chats are working") }
        // Never down, nor sideways: a dev build as new as the release stays.
        if !ReleaseManifest.newer(ask.version, than: Self.version) { return answer(.current, "kore-host \(Self.version) is current") }
        guard updating == nil, receiving == nil else { return answer(.busy, "an update is already running") }
        let by = Self.oneLine(ask.by)
        if ask.from == UpdateWire.fromMac { return receive(ask, by: by, from: client) }
        HostJournal.note("update asked", ["to": ask.version, "by": by])
        guard runUpdate(["update", "--by", by], id: ask.id, client: client, online: true) else { return answer(.failed, "couldn't start kore-host update") }
        answer(.started, "updating to \(ask.version)")
    }

    /// `kore-host update …` apart from this process. Only a failure comes back: on success the
    /// restart ends this process first. `online`: a GitHub that can't be reached is `offline`, so
    /// the Mac sends the files instead.
    private func runUpdate(_ arguments: [String], id: String, client: LinkClient, online: Bool) -> Bool {
        let out = paths.runtime.appendingPathComponent("update.out")
        guard let pid = updateSpawn(arguments, out) else { return false }
        updating = (id, client)
        let asset = updateAsset, inbox = updateInbox
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            let said = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            let error = said.split(separator: "\n").last { $0.hasPrefix("error: ") }.map { String($0.dropFirst(7)) }
            let code = status
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let asked = self.updating else { return }
                    self.updating = nil
                    let ok = code == 0
                    HostJournal.note(ok ? "update done" : "update failed", ["reason": ok ? nil : error ?? "exit \(code)"])
                    if !online { try? FileManager.default.removeItem(at: inbox) }
                    guard !ok else { return }
                    let offline = online && error?.hasPrefix("can't reach ") == true
                    let result = UpdateWire.Result(
                        id: asked.id, outcome: offline ? .offline : .failed, line: error ?? "the update didn't finish", asset: offline ? asset : nil)
                    asked.client.sendRaw(StreamWire.encode(result))
                }
            }
        }
        return true
    }

    /// The Mac holds the release (the box couldn't reach GitHub): its three files come over the
    /// link into `updateInbox`, one piece at a time, then `kore-host update --file` checks them.
    private func receive(_ ask: UpdateWire.Update, by: String, from client: LinkClient) {
        let files = FileManager.default
        try? files.removeItem(at: updateInbox)
        guard (try? files.createDirectory(at: updateInbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else {
            return client.sendRaw(StreamWire.encode(UpdateWire.Result(id: ask.id, outcome: .failed, line: "no room for the update")))
        }
        receiving = UpdateReceive(id: ask.id, client: client, by: by, names: ["SHA256SUMS", "SHA256SUMS.sig", updateAsset])
        HostJournal.note("update asked", ["to": ask.version, "by": by, "from": "mac"])
        client.sendRaw(StreamWire.encode(UpdateWire.Result(id: ask.id, outcome: .started, line: "updating to \(ask.version) from \(by)")))
        askPiece()
    }

    private func askPiece() {
        guard let at = receiving else { return }
        at.client.sendRaw(StreamWire.encode(UpdateWire.Get(id: at.id, name: at.names[at.index], offset: at.offset)))
    }

    /// The most a Mac may send for one file.
    static let updateFileMax = 256 * 1024 * 1024

    /// `host.update.piece`: the next piece of the file asked for, or the update stops.
    func updatePiece(_ data: Data, from client: LinkClient) {
        guard let piece = try? JSONDecoder().decode(UpdateWire.Piece.self, from: data),
              var at = receiving, at.id == piece.id, at.client === client
        else { return }
        func fail(_ line: String) {
            receiving = nil
            try? FileManager.default.removeItem(at: updateInbox)
            HostJournal.note("update failed", ["reason": line])
            client.sendRaw(StreamWire.encode(UpdateWire.Result(id: at.id, outcome: .failed, line: line)))
        }
        let name = at.names[at.index]
        guard piece.name == name, piece.offset == at.offset else { return fail("\(at.by) sent \(piece.name) out of order") }
        guard piece.total > 0 else { return fail("\(at.by) has no \(name) to send") }
        guard piece.total <= Self.updateFileMax, let bytes = Data(base64Encoded: piece.data), !bytes.isEmpty, bytes.count <= UpdateWire.pieceSize,
              at.offset + bytes.count <= piece.total
        else { return fail("a bad piece of \(name) from \(at.by)") }
        let file = updateInbox.appendingPathComponent(name)
        do {
            if at.offset == 0 { guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) } }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        } catch {
            return fail("couldn't write \(name) here")
        }
        at.offset += bytes.count
        if at.offset == piece.total {
            at.index += 1
            at.offset = 0
        }
        guard at.index == at.names.count else {
            receiving = at
            return askPiece()
        }
        receiving = nil
        let asset = updateInbox.appendingPathComponent(updateAsset).path
        guard runUpdate(["update", "--file", asset, "--by", at.by], id: at.id, client: client, online: false) else { return fail("couldn't start kore-host update") }
    }

    /// A link gone: the files it was sending stop.
    func updateEnded(_ connection: LinkClient) {
        guard receiving?.client === connection else { return }
        receiving = nil
        try? FileManager.default.removeItem(at: updateInbox)
    }

    /// Runs `executable` with `arguments` in a new session: stdin from /dev/null, stdout to `out`,
    /// stderr the daemon's own (the journal). Its pid, or nil when it couldn't start.
    package nonisolated static func spawnDetached(_ executable: String, _ arguments: [String], out: URL) -> pid_t? {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, out.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        #if canImport(Darwin)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        #else
        posix_spawnattr_setflags(&attr, 0x80)  // POSIX_SPAWN_SETSID, glibc's and musl's
        #endif
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for arg in argv + envp { free(arg) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attr, argv, envp) == 0 ? pid : nil
    }

    /// A Mac's name as the box shows it: one line, not too long.
    nonisolated static func oneLine(_ text: String) -> String {
        String(text.filter { !$0.isNewline && $0 != "\t" }.prefix(64))
    }
}
