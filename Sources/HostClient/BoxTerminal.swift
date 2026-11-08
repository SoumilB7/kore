import Foundation
import LinkProtocol

// Link 1.8 on the Mac's side: a box window's terminal runs its shell on the box
// (`LinkTerminal.swift`). Keys go out as they're typed and output is handed on as it comes:
// nothing here gathers or waits, so an echo takes only the network's time.

/// 1.8's pushes, and the reader each goes to.
package enum BoxStreams {
    package static let pushed: Set<String> = [PtyOutput.type, PtyExit.type, GitChanged.type]

    /// The reader's key: its pty's, or its git root's.
    package static func key(_ type: String, _ data: Data) -> String? {
        struct Peek: Decodable {
            var ptyId: String?
            var root: String?
        }
        guard let peek = try? JSONDecoder().decode(Peek.self, from: data) else { return nil }
        if type == GitChanged.type { return peek.root.map(git) }
        return peek.ptyId.map(pty)
    }

    package static func pty(_ id: String) -> String { "pty:" + id }
    package static func git(_ root: String) -> String { "git:" + root }
}

/// One shell on the box, as a terminal tab here shows it. It opens once its view has a size,
/// survives the link dropping (the box keeps it, and sends what it missed when the link is back),
/// and ends when the tab closes.
@MainActor
package final class BoxPty {
    package let connection: HostConnection
    /// The box folder it starts in.
    package let cwd: String
    package private(set) var ptyId: String?
    /// The shell's name ("bash"), as the box says.
    package private(set) var shell: String?
    package private(set) var exitCode: Int32?
    /// Bytes the shell wrote that this side has: where it stands to the box.
    package private(set) var stood: Int64 = 0

    /// The shell's output: `reset` starts the screen afresh first.
    package var output: (@MainActor (Data, _ reset: Bool) -> Void)?
    /// Its end, with the shell's exit code.
    package var exited: (@MainActor (Int32) -> Void)?
    /// It couldn't open, or the box no longer has it.
    package var failed: (@MainActor (String) -> Void)?
    /// It opened (the shell's name).
    package var opened: (@MainActor (String) -> Void)?

    private var size: (cols: Int, rows: Int)
    private var sentSize: (cols: Int, rows: Int)?
    private var opening = false
    private var closed = false
    /// Keys typed before the shell was there.
    private var early = Data()
    /// Its open waits for the link.
    private var waitingKey: String?

    package init(connection: HostConnection, cwd: String, cols: Int = 80, rows: Int = 24) {
        self.connection = connection
        self.cwd = cwd
        size = (cols, rows)
    }

    /// Opens the shell on the box (once): now while linked, else once the link is up.
    package func open() {
        guard ptyId == nil, !opening, !closed else { return }
        let waiting = "pty-open:" + String(UInt(bitPattern: ObjectIdentifier(self).hashValue))
        guard connection.isOnline else {
            waitingKey = waiting
            connection.onSnapshot(waiting) { [weak self] in
                guard let self else { return }
                self.connection.onSnapshot(waiting, nil)
                self.open()
            }
            return
        }
        // A box from before 1.8 would never answer.
        guard connection.caps.contains("pty") else {
            return failed?(connection.control == .full ? "\(connection.alias) needs an update for terminals" : "Terminals need a grant with full control on \(connection.alias)") ?? ()
        }
        opening = true
        Task { await self.opened() }
    }

    private func opened() async {
        let ask = size
        let cwd = cwd
        let (result, raw) = await connection.commandRaw { StreamWire.encode(PtyOpen(id: $0, cwd: cwd, cols: ask.cols, rows: ask.rows)) }
        opening = false
        let answer = raw.flatMap { try? JSONDecoder().decode(PtyResult.self, from: $0) }
        guard result.ok, let id = answer?.ptyId else {
            if !closed { failed?(Self.why(result, answer, alias: connection.alias)) }
            return
        }
        ptyId = id
        sentSize = ask
        guard !closed else { return close() }
        listen(id)
        shell = answer?.shell
        opened?(answer?.shell ?? "shell")
        if !early.isEmpty {
            input(early)
            early = Data()
        }
        if size != ask { resize(cols: size.cols, rows: size.rows) }
    }

    private func listen(_ id: String) {
        connection.boxReaders[BoxStreams.pty(id)] = { [weak self] data in self?.pushed(data) }
        // The link back: what the shell wrote meanwhile, from where this side stood.
        connection.onSnapshot(BoxStreams.pty(id)) { [weak self] in self?.reattach() }
    }

    package func input(_ bytes: Data) {
        guard !closed, exitCode == nil else { return }
        guard let ptyId else {
            if early.count < PtyWire.inputMax { early.append(bytes) }
            return
        }
        var at = bytes.startIndex
        while at < bytes.endIndex {
            let end = bytes.index(at, offsetBy: PtyWire.inputMax, limitedBy: bytes.endIndex) ?? bytes.endIndex
            connection.post(StreamWire.encode(PtyInput(ptyId: ptyId, data: bytes[at..<end])))
            at = end
        }
    }

    /// The view's size: sent once it differs from what the box has.
    package func resize(cols: Int, rows: Int) {
        guard PtyWire.validSize(cols, rows) else { return }
        size = (cols, rows)
        guard let ptyId, exitCode == nil, sentSize.map({ $0 != (cols, rows) }) ?? true else { return }
        if connection.post(StreamWire.encode(PtyResize(ptyId: ptyId, cols: cols, rows: rows))) { sentSize = (cols, rows) }
    }

    /// The tab closed: the box hangs the shell up.
    package func close() {
        closed = true
        if let waitingKey { connection.onSnapshot(waitingKey, nil) }
        guard let ptyId else { return }
        connection.boxReaders[BoxStreams.pty(ptyId)] = nil
        connection.onSnapshot(BoxStreams.pty(ptyId), nil)
        if exitCode == nil { connection.post(StreamWire.encode(PtyClose(ptyId: ptyId))) }
    }

    private func pushed(_ data: Data) {
        guard !closed else { return }
        let decoder = JSONDecoder()
        switch StreamWire.type(data) {
        case PtyOutput.type:
            guard let out = try? decoder.decode(PtyOutput.self, from: data), var bytes = out.bytes else { return }
            let reset = out.reset == true
            if !reset {
                // Already had (a reattach from before what came in meanwhile): only the rest.
                if out.seq < stood { bytes = bytes.dropFirst(Int(min(stood - out.seq, Int64(bytes.count)))) }
                guard !bytes.isEmpty else { return }
            }
            stood = max(stood, out.seq) + Int64(bytes.count)
            if reset { stood = out.seq + Int64(bytes.count) }
            output?(bytes, reset)
        case PtyExit.type:
            guard let end = try? decoder.decode(PtyExit.self, from: data), exitCode == nil else { return }
            exitCode = end.code
            if let ptyId {
                connection.boxReaders[BoxStreams.pty(ptyId)] = nil
                connection.onSnapshot(BoxStreams.pty(ptyId), nil)
            }
            exited?(end.code)
        default:
            break
        }
    }

    private func reattach() {
        guard let ptyId, !closed, exitCode == nil else { return }
        let after = stood
        let size = size
        Task {
            let (result, raw) = await connection.commandRaw {
                StreamWire.encode(PtyAttach(id: $0, ptyId: ptyId, after: after, cols: size.cols, rows: size.rows))
            }
            let answer = raw.flatMap { try? JSONDecoder().decode(PtyResult.self, from: $0) }
            if result.ok { sentSize = size }
            guard !result.ok, answer?.gone == true, !closed, exitCode == nil else { return }
            // The box no longer has it (it restarted): the tab shows it ended.
            exitCode = -1
            connection.boxReaders[BoxStreams.pty(ptyId)] = nil
            connection.onSnapshot(BoxStreams.pty(ptyId), nil)
            failed?("This terminal ended on \(connection.alias)")
            exited?(-1)
        }
    }

    private static func why(_ result: LinkMessage.Result, _ answer: PtyResult?, alias: String) -> String {
        let message = answer?.message ?? result.message
        if result.code == .invalid, message == nil || message == "That message isn't one this box reads." || message == "Unknown command." {
            return "\(alias) needs an update for terminals"
        }
        if result.code == .deniedControl { return "Terminals need a grant with full control on \(alias)" }
        return message ?? "\(alias) couldn't start a shell"
    }
}
