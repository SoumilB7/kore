import Foundation
import KoreCore
import LinkProtocol

/// The one SSH connection a box's sync rounds share. Each round used to run its own ssh (a key
/// exchange, ~5 KB and ~0.2 s, every time); now a master Kore holds (`ssh -M`) carries them all,
/// each round's rsync and shell multiplexed through its socket. The socket lives under Kore's own
/// folder (`Kore/ssh`), its options on the command line only: ~/.ssh is never read for it nor
/// written. Until `kore pipe` (phase 18 §Bulk) gives rounds the link itself, this is the
/// persistent channel.
///
/// The master is dialed by the first round that needs it, not before: a sync that stays quiet
/// costs nothing. It lives as long as a sync on that box runs (its one session a remote `cat`
/// reading Kore's pipe: Kore closing it, or ending, ends the master too, so none outlives Kore),
/// and is dialed again after the link came back (`renew`). A round while it's down connects on its
/// own, as before.
@MainActor
package final class SyncChannel {
    /// `Kore/ssh` (tests: their own).
    package static func folder(root: URL = HostCache.root()) -> URL {
        root.deletingLastPathComponent().appendingPathComponent("ssh", isDirectory: true)
    }

    /// One per box and folder of sockets: every pair on the box shares it.
    private static var open: [String: SyncChannel] = [:]

    package let socket: String
    private let base: SyncBox
    private var master: Process?
    private var feed: FileHandle?
    private var users = 0
    /// When the master was last dialed: a failed one isn't dialed again for `retry`.
    private var dialed: TimeInterval?
    /// A round waited for this dial's master already.
    private var awaited = false
    /// Masters dialed so far (tests).
    package private(set) var dials = 0
    package var retry: TimeInterval = 10
    var now: () -> TimeInterval = SyncClock.now

    private init(base: SyncBox, socket: String) {
        self.base = base
        self.socket = socket
    }

    /// The box's channel, held once more: `close` once per `open`.
    package static func open(_ box: SyncBox, folder: URL) -> SyncChannel {
        let name = StableID.of(box.channelKey, prefix: "m")
        let socket = folder.appendingPathComponent(name + ".sock").path
        let channel = open[socket] ?? SyncChannel(base: box, socket: socket)
        open[socket] = channel
        if channel.users == 0 {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        channel.users += 1
        return channel
    }

    /// Held one less: with the last, the master ends (a round under way finishes first).
    package func close() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        end(now: false)
        if Self.open[socket] === self { Self.open[socket] = nil }
    }

    /// The box as a round reaches it: through the master, dialed now if it isn't up (and waited
    /// for, so the round doesn't make a second connection while the master makes the first).
    package func box() async -> SyncBox {
        dial()
        // Only the first round after a dial waits: a master that never came up costs one wait.
        var waited: TimeInterval = awaited ? Self.patience : 0
        awaited = true
        while let master, master.isRunning, !FileManager.default.fileExists(atPath: socket), waited < Self.patience {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        return base.through(socket: socket)
    }

    /// How long a round waits for a master being dialed (ssh's own ConnectTimeout is 10 s).
    static let patience: TimeInterval = 10

    /// The link came back after a drop: the master's connection may be dead, so the next round
    /// dials a new one.
    package func renew() {
        guard master != nil else { return }
        end(now: true)
        dialed = nil
    }

    /// The master is running.
    package var up: Bool { master?.isRunning == true }

    private func dial() {
        guard users > 0, master == nil else { return }
        let time = now()
        if let dialed, time - dialed < retry { return }
        dialed = time
        // A socket a crash left: nothing listens on it.
        try? FileManager.default.removeItem(atPath: socket)
        let argv = base.masterArgv(socket: socket)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.master === ended else { return }
                    self.master = nil
                    try? self.feed?.close()
                    self.feed = nil
                }
            }
        }
        do {
            try process.run()
        } catch {
            return
        }
        try? pipe.fileHandleForReading.close()
        master = process
        awaited = false
        feed = pipe.fileHandleForWriting
        dials += 1
    }

    /// The master's stdin closes: its remote `cat` ends, and the master once its sessions have.
    /// `now`: ended at once (a dead link), else given a few seconds to finish a round.
    private func end(now: Bool) {
        guard let master else { return }
        self.master = nil
        try? feed?.close()
        feed = nil
        if now {
            master.terminate()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if master.isRunning { master.terminate() } }
        }
    }
}
