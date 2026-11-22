import Foundation
import KoreNet
import KoreTrust
import LinkProtocol
import Synchronization
import Tailnet
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The box's end of rsync over KoreNet (phase 18 §1 "Bulk", link 1.16 `LinkPipe`). A device with
/// a full link asks `pipe.open {argv}`: the remote command is read as rsync's `--server` and
/// nothing else (`PipeArgv`), each path must lead inside this user's home or a served folder
/// (links resolved, as the file commands check), and a ticket comes back. The device's own pipe
/// session (KoreNet service "pipe", its identity proven as any) brings the ticket within
/// `LinkPipe.ticketSeconds`; the rsync it names then runs here niced, with its own I/O timeout
/// and the forced options, its cwd the path, its bytes spliced to the session on a thread of its
/// own. At most `LinkPipe.perDevice` per device, tickets included; a revoked device's pipes end
/// at once (`stop`). Box to box, the Mac hands the receiver a ticket to expect (`expect`): the
/// sending box's command comes with it on the session and its paths must lead inside the
/// expected one.
package final class HostPipes: Sendable {
    package struct Refusal: Error, Equatable {
        package var code: ResultCode
        package var message: String
    }

    /// What a ticket lets its session do.
    package enum Grant: Sendable {
        /// The command `pipe.open` checked, as it runs, and where.
        case open(command: [String], cwd: String)
        /// Box to box: a command the sender brings, received into `path` (with the served
        /// folders as they were when the Mac asked).
        case expect(path: String, served: [String])
    }

    package struct Ticket: Sendable {
        var device: UUID
        var grant: Grant
        var expires: Date
    }

    /// One pipe running: its splice, to stop it.
    final class Run: @unchecked Sendable {
        let device: UUID
        var splice: PipeSplice?
        init(device: UUID) { self.device = device }
    }

    private struct State {
        var tickets: [Data: Ticket] = [:]
        var running: [ObjectIdentifier: Run] = [:]
    }

    private let state = Mutex(State())
    private let home: String
    private let now: @Sendable () -> Date
    /// The box's rsync, found once; nil: no pipes here.
    package let rsync: String?
    /// The options every pipe's rsync runs with (tests on a Mac: openrsync has no `--munge-links`).
    package let forced: [String]

    /// rsync before this has known holes on the receiving side (CVE-2022-29154, fixed in 3.2.5).
    package static let minimumRsync = [3, 2, 5]

    package init(
        home: String, rsync: String? = HostPipes.findRsync(), forced: [String] = PipeArgv.forced,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.forced = forced
        self.rsync = rsync
        self.now = now
    }

    /// Whether this box serves pipes: an rsync new enough.
    package var available: Bool { rsync != nil }

    // MARK: Tickets

    /// `pipe.open`: the remote command checked, a ticket for it. `served`: the box's folders now.
    package func open(argv words: [String], device: UUID, served: [String]) -> Result<Data, Refusal> {
        guard let rsync else { return .failure(Refusal(code: .invalid, message: "This box has no rsync \(Self.minimumRsync.map(String.init).joined(separator: ".")) or newer.")) }
        let parsed: PipeArgv
        do {
            parsed = try PipeArgv.parse(words)
        } catch {
            return .failure(Refusal(code: .invalid, message: error.description))
        }
        let resolved: (paths: [String], cwd: String)
        switch resolve(parsed, within: nil, served: served) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found): resolved = found
        }
        return issue(Ticket(device: device, grant: .open(command: parsed.command(rsync: rsync, paths: resolved.paths, forced: forced), cwd: resolved.cwd), expires: now() + LinkPipe.ticketSeconds))
    }

    /// `pipe.expect` (from an owner Mac): `ticket` for `device`'s pipe into `path`.
    package func expect(ticket: Data, device: UUID, path: String, served: [String]) -> Result<Void, Refusal> {
        guard rsync != nil else { return .failure(Refusal(code: .invalid, message: "This box has no rsync to receive with.")) }
        guard case .success(let place) = HostFiles(home: home, served: served).place(path, .homeOrServed) else {
            return .failure(Refusal(code: .deniedPath, message: "Outside your home and the folders this box serves."))
        }
        let held = Ticket(device: device, grant: .expect(path: place.real, served: served), expires: now() + LinkPipe.ticketSeconds)
        return state.withLock { state -> Result<Void, Refusal> in
            prune(&state)
            guard count(device, in: state) < LinkPipe.perDevice else { return .failure(Self.busy) }
            guard state.tickets[ticket] == nil else { return .failure(Refusal(code: .invalid, message: "That ticket is taken.")) }
            state.tickets[ticket] = held
            return .success(())
        }
    }

    private static let busy = Refusal(code: .rateLimited, message: "Two copies to this box are running already; it takes the next when one ends.")

    private func issue(_ ticket: Ticket) -> Result<Data, Refusal> {
        state.withLock { state -> Result<Data, Refusal> in
            prune(&state)
            guard count(ticket.device, in: state) < LinkPipe.perDevice else { return .failure(Self.busy) }
            let value = secureRandom(16)
            state.tickets[value] = ticket
            return .success(value)
        }
    }

    /// Takes a live ticket of `device`'s (spent either way).
    package func redeem(_ value: Data, device: UUID) -> Ticket? {
        state.withLock { state in
            prune(&state)
            guard let ticket = state.tickets.removeValue(forKey: value), ticket.device == device else { return nil }
            return ticket
        }
    }

    private func prune(_ state: inout State) {
        let now = now()
        state.tickets = state.tickets.filter { $0.value.expires > now }
    }

    private func count(_ device: UUID, in state: State) -> Int {
        state.tickets.values.filter { $0.device == device }.count + state.running.values.filter { $0.device == device }.count
    }

    /// Pipes and tickets a device holds now (tests, `status`).
    package func held(by device: UUID) -> Int { state.withLock { count(device, in: $0) } }

    // MARK: Paths

    /// Each path where it really leads, inside the home or a served folder (and inside `within`
    /// box to box). A path not there yet (what a copy makes) is checked by the deepest folder
    /// above it that is, and what's left of it may not climb out. The cwd: the first path's
    /// folder.
    func resolve(_ argv: PipeArgv, within: String?, served: [String]) -> Result<(paths: [String], cwd: String), Refusal> {
        let files = HostFiles(home: home, served: served)
        var out: [String] = []
        var cwd: String?
        for path in argv.paths {
            let slash = path.hasSuffix("/") ? "/" : ""
            let normal = LinkFiles.normalised(path)
            var real: String
            switch files.place(normal, .homeOrServed) {
            case .success(let place): real = place.real
            case .failure(let refusal) where refusal.code == .goneFile && !argv.sender:
                // Not there yet: the deepest folder above it that is, and the rest as given.
                var above = (normal as NSString).deletingLastPathComponent
                var rest = [(normal as NSString).lastPathComponent]
                while HostFiles.real(above) == nil, above != "/" {
                    rest.insert((above as NSString).lastPathComponent, at: 0)
                    above = (above as NSString).deletingLastPathComponent
                }
                guard case .success(let place) = files.place(above, .homeOrServed), HostFiles.isFolder(place.real) else {
                    return .failure(Refusal(code: .deniedPath, message: "Outside your home and the folders this box serves."))
                }
                real = ([place.real] + rest).joined(separator: "/")
            case .failure(let refusal):
                return .failure(Refusal(code: refusal.code, message: refusal.message))
            }
            if let within, !LinkFiles.inside(real, within) {
                return .failure(Refusal(code: .deniedPath, message: "Outside the folder this copy was meant for."))
            }
            if cwd == nil {
                var folder = real
                while !HostFiles.isFolder(folder), folder != "/" { folder = (folder as NSString).deletingLastPathComponent }
                cwd = folder
            }
            out.append(real + (real == "/" ? "" : slash))
        }
        return .success((out, cwd ?? home))
    }

    // MARK: Sessions

    /// A pipe session, established: its ticket, then the rsync, on a thread of its own.
    package func serve(_ session: NetSession, device: UUID) {
        let carried = Carried(session)
        let thread = Thread { [self] in run(carried.session, device: device) }
        thread.name = "kore.pipe"
        thread.start()
    }

    private final class Carried: @unchecked Sendable {
        let session: NetSession
        init(_ session: NetSession) { self.session = session }
    }

    private func run(_ session: NetSession, device: UUID) {
        let id = device.uuidString.lowercased()
        let control: PipeWire.Control
        do {
            control = try PipeHandshake.ticket(session, within: 10)
        } catch {
            session.close(NetControl.Reason.protocolError)
            return HostJournal.note("pipe refused", ["device": id, "why": error.description])
        }
        guard let value = control.ticketBytes, let ticket = redeem(value, device: device) else {
            session.close(PipeWire.Reason.ticket)
            return HostJournal.note("pipe refused", ["device": id, "why": "ticket"])
        }
        let command: [String], cwd: String
        switch ticket.grant {
        case .open(let words, let folder):
            command = words
            cwd = folder
        case .expect(let path, let served):
            // Box to box: the sender's command, received here, inside the expected path.
            guard let rsync, let words = control.argv, let parsed = try? PipeArgv.parse(words), !parsed.sender,
                  case .success(let found) = resolve(parsed, within: path, served: served)
            else {
                session.close(NetControl.Reason.refused)
                return HostJournal.note("pipe refused", ["device": id, "why": "command"])
            }
            command = parsed.command(rsync: rsync, paths: found.paths, forced: forced)
            cwd = found.cwd
        }
        let run = Run(device: device)
        let key = ObjectIdentifier(run)
        state.withLock { $0.running[key] = run }
        defer { state.withLock { _ = $0.running.removeValue(forKey: key) } }
        let started = now()
        let outcome = spawnAndSplice(session, command: command, cwd: cwd, run: run)
        HostJournal.note("pipe", [
            "device": id, "sender": command.contains("--sender") ? "1" : "0", "outcome": "\(outcome)",
            "ms": String(Int(now().timeIntervalSince(started) * 1000)),
        ])
    }

    private func spawnAndSplice(_ session: NetSession, command: [String], cwd: String, run: Run) -> PipeSplice.Outcome {
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Read as it comes: a chatty rsync must never stall on a full stderr pipe.
        let said = SaidTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { said.add(chunk) }
        }
        defer { stderr.fileHandleForReading.readabilityHandler = nil }
        let status = Mutex<Int32?>(nil)
        let poke = Mutex<PipeSplice?>(nil)
        process.terminationHandler = { ended in
            status.withLock { $0 = ended.terminationStatus }
            poke.withLock { $0 }?.poke()
        }
        do {
            try process.run()
        } catch {
            session.close(PipeWire.Reason.spawn)
            return .broken(PipeWire.Reason.spawn)
        }
        _ = setpriority(PRIO_PROCESS, id_t(process.processIdentifier), 10)
        let first: [NetMessage]
        do {
            first = try PipeHandshake.ready(session, within: 10)
        } catch {
            process.terminate()
            return .broken(error.description)
        }
        // Our ends only: the child has its own (and no other child gets these).
        let input = Sockets.duplicate(stdout.fileHandleForReading.fileDescriptor)
        let output = Sockets.duplicate(stdin.fileHandleForWriting.fileDescriptor)
        try? stdout.fileHandleForReading.close()
        try? stdin.fileHandleForWriting.close()
        let splice = PipeSplice(session: session, input: input, output: output, server: true, first: first) { status.withLock { $0 } }
        poke.withLock { $0 = splice }
        state.withLock { _ in run.splice = splice }
        if status.withLock({ $0 }) != nil { splice.poke() }
        let outcome = splice.run()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        if case .exited(let code) = outcome, code != 0, case let text = said.text, !text.isEmpty {
            HostJournal.note("pipe rsync", ["status": String(code), "said": text])
        }
        return outcome
    }

    /// Ends the pipes of devices `gone` says are (revoked, paused); their tickets go too.
    package func stop(where gone: (UUID) -> Bool, reason: String = NetControl.Reason.revoked) {
        let runs = state.withLock { state -> [Run] in
            state.tickets = state.tickets.filter { !gone($0.value.device) }
            return state.running.values.filter { gone($0.device) }
        }
        for run in runs { state.withLock { _ in run.splice }?.stop(reason) }
    }

    /// Pipes running now (tests).
    package var running: Int { state.withLock { $0.running.count } }

    // MARK: rsync

    /// The rsync on the PATH (or the usual places), when it's at least `minimumRsync`.
    package static func findRsync() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + ["/usr/bin", "/usr/local/bin", "/bin", "/opt/homebrew/bin"]
        guard let found = dirs.map({ $0 + "/rsync" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: found)
        process.arguments = ["--version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile().prefix(4096), as: UTF8.self)
        process.waitUntilExit()
        return version(text).map { $0.lexicographicallyPrecedes(minimumRsync) } == false ? found : nil
    }

    /// `rsync  version 3.2.7  protocol version 31` → [3, 2, 7].
    package static func version(_ text: String) -> [Int]? {
        guard let range = text.range(of: "version ") else { return nil }
        let word = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        let parts = word.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }
}
