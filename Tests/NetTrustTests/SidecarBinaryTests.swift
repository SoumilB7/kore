import Foundation
import Synchronization
@testable import Tailnet
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The real `kore-tailnet` (path in `KORE_TAILNET_BIN`, built by scripts/build-tailnet.sh) over
/// its real socket, signed out: it never logs in, and nothing beyond tsnet's own startup touches
/// the network. Skipped when the variable isn't set.
@Suite("kore-tailnet binary", .enabled(if: SidecarRun.binary != nil), .serialized)
struct SidecarBinaryTests {
    @Test func signedOutStatusThenStopThenSealedState() throws {
        let run = try SidecarRun()
        defer { run.clean() }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let car = TailnetSidecar(path: run.socket)
        let owner = try car.start(key: key)
        defer { Sockets.closeFD(owner) }
        #expect(throws: TailnetError.sidecar("started already")) { try car.start(key: key) }

        // The sign-in URL comes once tsnet has reached the control server.
        var status = try car.status()
        let deadline = Date().addingTimeInterval(30)
        while status.authURL == nil, Date() < deadline {
            usleep(100_000)
            status = try car.status()
        }
        #expect(status.backendState == .needsLogin)
        let url = try #require(status.authURL)
        #expect(url.hasPrefix("https://"))

        try car.stop()
        #expect(run.exitCode() == 0)
        #expect(!FileManager.default.fileExists(atPath: run.socket))
        #expect(run.stderr().isEmpty)
        // State only sealed; the URL in no file.
        let files = FileManager.default.enumerator(atPath: run.state)?.compactMap { $0 as? String } ?? []
        #expect(files.contains("state.sealed"))
        #expect(!files.contains("tailscaled.state"))
        for name in files {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: run.state).appendingPathComponent(name))) ?? Data()
            #expect(data.range(of: Data(url.utf8)) == nil, "auth URL in \(name)")
            #expect(data.range(of: Data("privkey:".utf8)) == nil, "plain key in \(name)")
        }

        // Another key doesn't open it; the right one does, and closing the owner ends it.
        let wrong = try SidecarRun(folder: run.folder)
        #expect(throws: TailnetError.sidecar("the state key doesn't open the saved state")) {
            try TailnetSidecar(path: wrong.socket).start(key: Data(repeating: 7, count: 32))
        }
        #expect(wrong.exitCode() == 2)
        let again = try SidecarRun(folder: run.folder)
        let held = try TailnetSidecar(path: again.socket).start(key: key)
        Sockets.closeFD(held)
        #expect(again.exitCode() == 0)
    }

    @Test func anotherUserIsRefused() throws {
        let run = try SidecarRun(uid: getuid() + 1)
        defer { run.clean() }
        #expect(throws: TailnetError.sidecar("not this user")) { try TailnetSidecar(path: run.socket).status() }
        run.process.terminate()
        #expect(run.exitCode() == 0)
    }
}

/// One `kore-tailnet` process in a scratch folder, past its `ready` line.
final class SidecarRun: Sendable {
    static let binary = ProcessInfo.processInfo.environment["KORE_TAILNET_BIN"]

    let folder: URL
    let socket: String
    let state: String
    let process = Process()
    private let errors = Pipe()
    private let exited = DispatchSemaphore(value: 0)

    init(folder: URL? = nil, uid: uid_t? = nil) throws {
        // Short: a socket path has to fit sun_path.
        self.folder = folder ?? URL(fileURLWithPath: "/tmp/kt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socket = self.folder.appendingPathComponent("s").path
        state = self.folder.appendingPathComponent("state").path
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.binary ?? "")
        process.arguments = ["-socket", socket, "-state", state, "-hostname", "kore-test"] + (uid.map { ["-uid", "\($0)"] } ?? [])
        process.standardOutput = out
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let exited = exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let more = out.fileHandleForReading.availableData
            guard !more.isEmpty else { break }
            line.append(more)
        }
        guard String(decoding: line, as: UTF8.self) == "ready\n" else { throw SocketError.closed }
    }

    func exitCode() -> Int32? {
        guard exited.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }

    func stderr() -> String { String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }

    func clean() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: folder)
    }
}
