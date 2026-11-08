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
    /// restarts this daemon: links hear `bye restart`).
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
        if !ReleaseManifest.newer(ask.version, than: Self.version) { return answer(.current, "kore-host \(Self.version) is current") }
        guard updating == nil else { return answer(.busy, "an update is already running") }
        let by = Self.oneLine(ask.by)
        HostJournal.note("update asked", ["to": ask.version, "by": by])
        let out = paths.runtime.appendingPathComponent("update.out")
        guard let pid = updateSpawn(["update", "--by", by], out) else { return answer(.failed, "couldn't start kore-host update") }
        updating = (ask.id, client)
        answer(.started, "updating to \(ask.version)")
        // Only a failure comes back here: on success the restart ends this process first.
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
                    if !ok {
                        asked.client.sendRaw(StreamWire.encode(UpdateWire.Result(id: asked.id, outcome: .failed, line: error ?? "the update didn't finish")))
                    }
                }
            }
        }
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
