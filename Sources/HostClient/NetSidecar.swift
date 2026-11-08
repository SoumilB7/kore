import Foundation
import KoreTrust
import Tailnet

/// Kore's own `kore-tailnet` (phase 18 step 5a): started only while KoreNet is on and installed
/// Tailscale is absent or its LocalAPI unreadable, stopped when KoreNet turns off. Its state is
/// sealed under a key from the Keychain, handed over its socket (never argv or env); the
/// connection that sent it keeps the node up, and closing it ends the program.
package final class NetSidecar: @unchecked Sendable {
    /// What the helper is called in `Kore.app/Contents/Helpers`.
    package static let helperName = "kore-tailnet"

    package let tailnet: TailnetSidecar
    private let process: Process
    private let owner: Int32
    private let lock = NSLock()
    private var stopped = false

    private init(tailnet: TailnetSidecar, process: Process, owner: Int32) {
        self.tailnet = tailnet
        self.process = process
        self.owner = owner
    }

    /// The helper to run: Kore.app's, else `KORE_TAILNET_BIN`, else a dev build's output
    /// (`scripts/build-tailnet.sh` → `build/release/kore-tailnet-macos-arm64`, found walking up
    /// from the running binary). Nil when there's none: KoreNet then offers SSH only.
    package static func helper(bundle: URL = Bundle.main.bundleURL, executable: URL? = Bundle.main.executableURL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let files = FileManager.default
        let inApp = bundle.appendingPathComponent("Contents/Helpers/" + helperName)
        if files.isExecutableFile(atPath: inApp.path) { return inApp }
        if let set = environment["KORE_TAILNET_BIN"], files.isExecutableFile(atPath: set) { return URL(fileURLWithPath: set) }
        var dir = executable?.deletingLastPathComponent()
        for _ in 0..<5 {
            guard let here = dir else { break }
            for candidate in [here.appendingPathComponent(helperName), here.appendingPathComponent("build/release/kore-tailnet-macos-arm64")]
            where files.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            dir = here.deletingLastPathComponent()
        }
        return nil
    }

    /// Runs the helper with its socket and state under `folder` (0700), waits for its `ready`,
    /// and brings the node up with `key`. Blocks up to `within`: call it off the main actor.
    package static func start(helper: URL, folder: URL, key: Data, within: TimeInterval = 10) throws -> NetSidecar {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A Unix socket's path is at most 104 bytes.
        let socket = folder.appendingPathComponent("kt.sock").path
        guard socket.utf8.count < 100 else { throw TailnetError.sidecar("socket path too long") }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["-socket", socket, "-state", folder.appendingPathComponent("state").path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let ready = DispatchSemaphore(value: 0)
        let said = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            var seen = Data()
            while true {
                let chunk = said.availableData
                if chunk.isEmpty { break }
                seen.append(chunk)
                if String(decoding: seen, as: UTF8.self).contains("ready") { break }
            }
            ready.signal()
        }
        guard ready.wait(timeout: .now() + within) == .success, process.isRunning else {
            process.terminate()
            throw TailnetError.sidecar("didn't start")
        }
        do {
            let fd = try Sockets.connectUnix(socket)
            guard Sockets.peerIsUser(fd) else {
                Sockets.closeFD(fd)
                throw SocketError.notThisUser
            }
            do {
                let start: [String: JSONValue] = ["v": .int(Int64(TailnetSidecar.version)), "op": .string("start"), "key": .string(key.base64EncodedString())]
                try SidecarWire.send(fd, JSONEncoder().encode(start))
                let (data, passed) = try SidecarWire.receive(fd)
                if let passed { Sockets.closeFD(passed) }
                let reply = try data.map(SidecarWire.decode)
                guard reply?.ok == true else { throw TailnetError.sidecar(reply?.error ?? "start refused") }
            } catch {
                Sockets.closeFD(fd)
                throw error
            }
            return NetSidecar(tailnet: TailnetSidecar(path: socket), process: process, owner: fd)
        } catch {
            process.terminate()
            throw error
        }
    }

    /// The node goes down and the program ends (its owner connection closes). Blocks briefly.
    package func stop() {
        let first = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        Sockets.closeFD(owner)
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }
}
