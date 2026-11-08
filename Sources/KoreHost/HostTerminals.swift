import Foundation
import KoreCore
import KoreHostSys
import LinkProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Link 1.8's terminals on the box (`LinkTerminal.swift`): each a shell on a pseudo-terminal,
/// held by its grant, so it outlives the link that opened it. Woken only by the shell's output,
/// its exit, or the client: nothing runs while a shell is quiet.
@MainActor
final class HostTerminals {
    private var ptys: [String: HostPty] = [:]
    /// A command was run in a terminal under this folder and its output has settled: git may see
    /// changes there.
    var ran: ((String) -> Void)?
    /// The environment shells start from: the daemon's own unless a test sets another.
    var base: [String: String]?

    /// The upgrade: a grant's shells are its device's from now on.
    func rehome(_ grant: String, to holder: String) {
        for pty in ptys.values where pty.grant == grant { pty.grant = holder }
    }

    /// A new shell for `grant`, attached to `client`; or why not.
    func open(_ ask: PtyOpen, grant: String, client: LinkClient, served: [String]) -> PtyResult {
        guard let cwd = ServedPath.inside(ask.cwd, served: served, folder: true) else {
            return .refused(ask.id, .deniedPath, "Only folders this box serves.")
        }
        guard let shell = Self.shell(ask.shell) else { return .refused(ask.id, .invalid, "That shell isn't one this box lists.") }
        let live = ptys.values.filter { $0.grant == grant && $0.exitCode == nil }
        if live.count >= PtyWire.maxPerGrant {
            // A shell no client shows gives way to the new one; else the cap holds.
            guard let oldest = live.filter({ $0.client == nil }).min(by: { $0.detachedAt ?? .distantFuture < $1.detachedAt ?? .distantFuture }) else {
                return .refused(ask.id, .busy, "\(PtyWire.maxPerGrant) terminals are open on this box already.")
            }
            close(oldest.id)
        }
        let id = "p" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        guard let pty = HostPty(id: id, grant: grant, cwd: cwd, shell: shell, cols: ask.cols, rows: ask.rows, environment: Self.environment(shell: shell, cwd: cwd, base: base ?? ProcessInfo.processInfo.environment)) else {
            return .refused(ask.id, .busy, "The box couldn't start a shell.")
        }
        pty.onExit = { [weak self] pty in self?.exited(pty) }
        pty.onRan = { [weak self] folder in self?.ran?(folder) }
        ptys[id] = pty
        pty.attach(client, after: 0)
        HostJournal.note("pty open", ["grant": grant, "pty": id, "shell": pty.shellName])
        return PtyResult(id: ask.id, ok: true, ptyId: id, shell: pty.shellName)
    }

    /// `client` shows the pty again: the answer, then what it missed.
    func attach(_ ask: PtyAttach, grant: String, client: LinkClient) -> PtyResult {
        guard let pty = ptys[ask.ptyId], pty.grant == grant else {
            return .refused(ask.id, .invalid, "That terminal isn't on the box any more.", gone: true)
        }
        if let cols = ask.cols, let rows = ask.rows { pty.resize(cols: cols, rows: rows) }
        let result = PtyResult(id: ask.id, ok: true, ptyId: pty.id, shell: pty.shellName, exited: pty.exitCode)
        client.sendRaw(StreamWire.encode(result))
        pty.attach(client, after: ask.after)
        // An ended shell, once its last output is shown again, is done with.
        if pty.exitCode != nil { ptys[pty.id] = nil }
        return result
    }

    func input(_ ask: PtyInput, grant: String) {
        guard let pty = ptys[ask.ptyId], pty.grant == grant, let bytes = ask.bytes else { return }
        pty.write(bytes)
    }

    func resize(_ ask: PtyResize, grant: String) {
        guard let pty = ptys[ask.ptyId], pty.grant == grant else { return }
        pty.resize(cols: ask.cols, rows: ask.rows)
    }

    func close(_ ask: PtyClose, grant: String) {
        guard let pty = ptys[ask.ptyId], pty.grant == grant else { return }
        close(pty.id)
    }

    private func close(_ id: String) {
        guard let pty = ptys.removeValue(forKey: id) else { return }
        HostJournal.note("pty close", ["grant": pty.grant, "pty": id])
        // Held until its shell is reaped.
        if pty.exitCode == nil {
            closing[id] = pty
            pty.onExit = { [weak self] pty in self?.closing[pty.id] = nil }
        }
        pty.hangUp()
    }

    /// Hung up, not yet reaped.
    private var closing: [String: HostPty] = [:]

    /// The link went: its shells keep running, held for the next one.
    func detach(_ client: LinkClient) {
        for pty in ptys.values where pty.client === client {
            pty.detach()
            pty.armExpiry { [weak self] in self?.close(pty.id) }
        }
    }

    /// The link drained: shells held back for it read on.
    func drained(_ client: LinkClient) {
        for pty in ptys.values where pty.client === client { pty.resume() }
    }

    /// The client said goodbye (a window closed, Kore quit): its shells end with it, as a Mac's
    /// do. A link that only dropped never says it.
    func closeAll(of client: LinkClient) {
        for pty in ptys.values where pty.client === client { close(pty.id) }
    }

    func stopAll() {
        for id in Array(ptys.keys) { close(id) }
    }

    /// Kept while no client shows it, so its end is shown on the next attach; dropped then.
    private func exited(_ pty: HostPty) {
        HostJournal.note("pty exit", ["grant": pty.grant, "pty": pty.id, "code": "\(pty.exitCode ?? -1)"])
        if pty.client != nil { ptys[pty.id] = nil }
    }

    /// Ptys held now, and those hung up but not yet reaped (tests).
    var count: Int { ptys.count }
    var reaping: Int { closing.count }

    // MARK: The shell

    /// The asked shell when `/etc/shells` lists it, else the user's own (or bash, or sh).
    static func shell(_ asked: String?) -> String? {
        let listed = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") } ?? []
        if let asked {
            return listed.contains(asked) && FileManager.default.isExecutableFile(atPath: asked) ? asked : nil
        }
        if let entry = getpwuid(getuid()), let pw = entry.pointee.pw_shell {
            let own = String(cString: pw)
            if own.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: own) { return own }
        }
        return ["/bin/bash", "/bin/sh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The daemon's environment as a login would see it: without the service's own variables or
    /// a CLI session's, with a terminal's.
    static func environment(shell: String, cwd: String, base: [String: String]) -> [String: String] {
        var env = CLIExecutable.withoutHostSession(base)
        for name in ["CODEX_THREAD_ID", "INVOCATION_ID", "JOURNAL_STREAM", "NOTIFY_SOCKET", "LISTEN_FDS", "LISTEN_PID", "LISTEN_FDNAMES", "MANAGERPID", "SYSTEMD_EXEC_PID"] {
            env[name] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["SHELL"] = shell
        env["PWD"] = cwd
        if env["LANG"] == nil, env["LC_ALL"] == nil, env["LC_CTYPE"] == nil { env["LANG"] = "C.UTF-8" }
        if let entry = getpwuid(getuid()) {
            if env["USER"] == nil, let name = entry.pointee.pw_name { env["USER"] = String(cString: name) }
            if env["LOGNAME"] == nil { env["LOGNAME"] = env["USER"] }
            if env["HOME"] == nil, let dir = entry.pointee.pw_dir { env["HOME"] = String(cString: dir) }
        }
        return env
    }
}

/// One shell on a pseudo-terminal. Its output goes to the client showing it the moment the
/// shell was quiet, else at most one frame each `PtyWire.coalesce`; the last
/// `PtyWire.scrollback` bytes stay for a client attaching again. Reading stops while the link is
/// behind, so a flood waits in the shell, not in memory.
@MainActor
final class HostPty {
    let id: String
    /// Who holds it: a device's id, or a grant's name before its Mac enrolled.
    var grant: String
    let cwd: String
    let shellName: String
    private let pid: pid_t
    private var fd: Int32
    private var reader: DispatchSourceRead?
    private var reading = false
    private var writer: DispatchSourceWrite?
    private var exitWatch: DispatchSourceProtocol?
    private var pidfd: Int32 = -1
    private(set) var exitCode: Int32?
    private(set) weak var client: LinkClient?
    private(set) var detachedAt: Date?
    private var expiry: DispatchWorkItem?
    private var killLater: DispatchWorkItem?

    /// What the shell wrote, the last `scrollback` bytes; `kept` is the stream position of its first.
    private var ring = Data()
    private var kept: Int64 = 0
    /// Bytes the shell has written in all.
    private var written: Int64 = 0
    /// The client's: where it stands, and what waits for the next frame.
    private var sentTo: Int64 = 0
    private var flush: DispatchWorkItem?
    private var lastFlush = DispatchTime(uptimeNanoseconds: 0)
    /// Typed input that the pty hasn't taken yet.
    private var unwritten = Data()
    /// A line was entered: once output settles, git may look again.
    private var ranCommand = false
    private var settle: DispatchWorkItem?
    /// Whether the client was last told a job runs in the foreground.
    private var saidBusy: Bool?

    var onExit: ((HostPty) -> Void)?
    var onRan: ((String) -> Void)?

    init?(id: String, grant: String, cwd: String, shell: String, cols: Int, rows: Int, environment: [String: String]) {
        self.id = id
        self.grant = grant
        self.cwd = cwd
        shellName = (shell as NSString).lastPathComponent
        // A login shell, by the leading "-" every shell reads.
        let argv = ["-" + shellName]
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var master: Int32 = -1
        let child = withCStrings(argv) { argvp in
            withCStrings(envp) { envpp in
                kore_pty_spawn(shell, argvp, envpp, cwd, UInt16(clamping: cols), UInt16(clamping: rows), &master)
            }
        }
        guard child > 0, master >= 0 else { return nil }
        pid = child
        fd = master
        startReading()
        watchExit()
    }

    // MARK: Clients

    func attach(_ client: LinkClient, after: Int64?) {
        self.client = client
        detachedAt = nil
        expiry?.cancel()
        expiry = nil
        // From where the client stands when the box still has it, else afresh from what it kept.
        if let after, after >= kept, after <= written {
            sentTo = after
            send(reset: false)
        } else {
            sentTo = kept
            send(reset: true)
        }
        if let code = exitCode { client.sendRaw(StreamWire.encode(PtyExit(ptyId: id, code: code))) }
        saidBusy = nil
        tellBusy()
        resume()
    }

    /// Tells the client when a foreground job starts or ends: sampled as output goes and when a
    /// command's output settles, never on a timer.
    private func tellBusy() {
        guard let client, exitCode == nil, fd >= 0 else { return }
        let group = tcgetpgrp(fd)
        let busy = group > 0 && group != pid
        guard busy != saidBusy else { return }
        saidBusy = busy
        client.sendRaw(StreamWire.encode(PtyState(ptyId: id, busy: busy)))
    }

    func detach() {
        client = nil
        detachedAt = Date()
        flush?.cancel()
        flush = nil
        resume()
    }

    /// Hung up after `PtyWire.detachedLife` with no client: one timer, only while detached.
    func armExpiry(_ expired: @escaping @MainActor () -> Void) {
        expiry?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { expired() } }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PtyWire.detachedLife, execute: work)
    }

    // MARK: Input

    func write(_ bytes: Data) {
        guard exitCode == nil, fd >= 0, !bytes.isEmpty else { return }
        if bytes.contains(13) || bytes.contains(10) { ranCommand = true }
        unwritten.append(bytes)
        drainInput()
    }

    private func drainInput() {
        while !unwritten.isEmpty, fd >= 0 {
            let done = unwritten.withUnsafeBytes { raw in sysWrite(fd, raw.baseAddress!, raw.count) }
            if done > 0 {
                unwritten.removeFirst(done)
                continue
            }
            if done < 0, errno == EINTR { continue }
            if done < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            unwritten = Data()
        }
        if unwritten.isEmpty {
            writer?.cancel()
            writer = nil
        } else if writer == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drainInput() } }
            writer = source
            source.resume()
        }
    }

    func resize(cols: Int, rows: Int) {
        guard fd >= 0, PtyWire.validSize(cols, rows) else { return }
        _ = kore_pty_resize(fd, UInt16(cols), UInt16(rows))
    }

    // MARK: Output

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read() } }
        // The terminal's end closes once nothing watches it any more.
        let fd = fd
        source.setCancelHandler { _ = sysClose(fd) }
        reader = source
        reading = true
        source.resume()
    }

    /// Stops reading while the client's link is behind, or a frame's worth waits already.
    private func pause() {
        guard reading else { return }
        reading = false
        reader?.suspend()
    }

    func resume() {
        guard !reading, let reader, fd >= 0 else { return }
        if let client, client.backlog >= HostSocket.lowWater { return }
        reading = true
        reader.resume()
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var took = 0
        while took < 256 * 1024 {
            let count = buffer.withUnsafeMutableBytes { raw in sysRead(fd, raw.baseAddress, raw.count) }
            if count > 0 {
                took += count
                keep(buffer[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            // EOF or EIO: every holder of the terminal has gone. Its exit says the rest.
            endReading()
            return
        }
        if ranCommand { armSettle() }
        guard let client else { return }
        if written - sentTo >= Int64(PtyWire.chunkMax) * 2 || client.backlog >= HostSocket.lowWater { pause() }
        schedule()
    }

    private func keep(_ bytes: ArraySlice<UInt8>) {
        ring.append(contentsOf: bytes)
        written += Int64(bytes.count)
        // Trimmed a slice at a time, not per read.
        if ring.count > PtyWire.scrollback + 64 * 1024 {
            let drop = ring.count - PtyWire.scrollback
            ring.removeFirst(drop)
            kept += Int64(drop)
        }
    }

    /// The first output after a quiet spell goes now (a key's echo); more within the frame waits.
    private func schedule() {
        guard client != nil, written > sentTo, flush == nil else { return }
        let next = lastFlush.uptimeNanoseconds + UInt64(PtyWire.coalesce * 1_000_000_000)
        let now = DispatchTime.now()
        if now.uptimeNanoseconds >= next { return send(reset: false) }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.flush = nil
                self?.send(reset: false)
            }
        }
        flush = work
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: next), execute: work)
    }

    /// Sends what the client hasn't had, in frames of `PtyWire.chunkMax`.
    private func send(reset: Bool) {
        flush?.cancel()
        flush = nil
        guard let client else { return }
        lastFlush = .now()
        var first = reset
        if sentTo < kept { sentTo = kept }
        while sentTo < written || first {
            let start = Int(sentTo - kept)
            let end = min(ring.count, start + PtyWire.chunkMax)
            let piece = ring.subdata(in: (ring.startIndex + start)..<(ring.startIndex + end))
            client.sendRaw(StreamWire.encode(PtyOutput(ptyId: id, seq: sentTo, data: piece, reset: first)))
            sentTo += Int64(piece.count)
            first = false
            if piece.isEmpty { break }
        }
        tellBusy()
        resume()
    }

    private func armSettle() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settle = nil
                self.ranCommand = false
                self.tellBusy()
                self.onRan?(self.cwd)
            }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + GitWire.settle, execute: work)
    }

    /// Done with the terminal's end: no more reads or writes; it closes as its watch ends.
    private func endReading() {
        writer?.cancel()
        writer = nil
        if !reading { reader?.resume() }
        reading = true
        reader?.cancel()
        reader = nil
        fd = -1
    }

    // MARK: Exit

    private func watchExit() {
        let pid = pid
        #if canImport(Darwin)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reap() } }
        exitWatch = source
        source.resume()
        #else
        let pidfd = kore_pidfd_open(pid)
        if pidfd >= 0 {
            self.pidfd = pidfd
            let source = DispatchSource.makeReadSource(fileDescriptor: pidfd, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reap() } }
            source.setCancelHandler { _ = sysClose(pidfd) }
            exitWatch = source
            source.resume()
        } else {
            // No pidfd (an old kernel): one thread waits on the shell.
            Thread.detachNewThread { [weak self] in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                let code = Self.code(status)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(code) } }
            }
        }
        #endif
    }

    private func reap() {
        var status: Int32 = 0
        let got = waitpid(pid, &status, WNOHANG)
        guard got == pid else { return }
        ended(Self.code(status))
    }

    private func ended(_ code: Int32) {
        guard exitCode == nil else { return }
        exitWatch?.cancel()
        exitWatch = nil
        killLater?.cancel()
        // What the shell wrote last, before its end.
        if fd >= 0, reader != nil { read() }
        exitCode = code
        endReading()
        settle?.cancel()
        if ranCommand { onRan?(cwd) }
        if let client {
            send(reset: false)
            client.sendRaw(StreamWire.encode(PtyExit(ptyId: id, code: code)))
        }
        onExit?(self)
    }

    /// 128 + the signal for a shell a signal ended, as a shell says it.
    nonisolated static func code(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Closed: SIGHUP to the shell's group, SIGKILL 3 s later if it's still there.
    func hangUp() {
        flush?.cancel()
        settle?.cancel()
        expiry?.cancel()
        client = nil
        guard exitCode == nil else { return }
        endReading()
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
        let pid = pid
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.exitCode == nil else { return }
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
        killLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

/// A served folder's path, checked: normalised, inside a served folder, and really there (its
/// links resolved) without leaving it.
enum ServedPath {
    static func inside(_ path: String, served: [String], folder: Bool = false) -> String? {
        guard LinkFiles.plainPath(path) else { return nil }
        let path = LinkFiles.normalised(path)
        let roots = served.map(LinkFiles.normalised).filter { LinkFiles.inside(path, $0) }
        guard !roots.isEmpty, let real = real(path) else { return nil }
        guard roots.contains(where: { LinkFiles.inside(real, Self.real($0) ?? $0) }) else { return nil }
        if folder {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
        }
        return path
    }

    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

private func sysRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { read(fd, buffer, count) }
private func sysWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { write(fd, buffer, count) }
private func sysClose(_ fd: Int32) -> Int32 { close(fd) }
