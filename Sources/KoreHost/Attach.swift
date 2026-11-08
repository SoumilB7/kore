import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import LinkProtocol

/// `kore-host attach --as <name>`: passes frames between stdin/stdout and the socket, so a
/// client on another machine speaks the link through `ssh <box> kore-host attach`. It reads the
/// grant itself: the client's hello goes out with the grant's name and the proof filled in, and
/// the secret never leaves the box.
@MainActor
package final class Attach {
    private let socket: HostSocket
    private let grant: Grant
    private var nonce: String?
    private var helloSent = false
    private var input = Data()
    private var stdinSource: DispatchSourceRead?
    private let done: (Int32) -> Void

    package init(grant: Grant, done: @escaping (Int32) -> Void) throws {
        self.grant = grant
        self.done = done
        socket = try HostListener.connect(to: grant.socket)
    }

    package func start() {
        socket.start(max: LinkFrame.outboundMax, frame: { [weak self] data in self?.fromHost(data) }, ended: { [weak self] in self?.done(0) })
        let source = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(0, &chunk, chunk.count)
                guard count > 0 else {
                    self.socket.close()
                    return self.done(0)
                }
                self.input.append(contentsOf: chunk[0..<count])
                guard let frames = try? LinkFrame.take(&self.input, max: LinkFrame.inboundMax) else { return self.done(1) }
                for frame in frames { self.fromClient(frame) }
            }
        }
        stdinSource = source
        source.resume()
    }

    private func fromHost(_ data: Data) {
        if nonce == nil, case .challenge(let n)? = try? LinkMessage.decode(data) { nonce = n }
        Self.write(LinkFrame.frame(data))
    }

    private func fromClient(_ data: Data) {
        guard !helloSent else {
            socket.send(data)
            return
        }
        helloSent = true
        guard let nonce, let secret = Data(base64Encoded: grant.secret),
            case .hello(let proto, let client, _, let commands, _)? = try? LinkMessage.decode(data)
        else {
            socket.send(data)
            return
        }
        let hello = LinkMessage.hello(
            proto: proto, client: client, proof: LinkProof.proof(secret: secret, nonce: nonce), commands: commands, grant: grant.name)
        socket.send(hello)
    }

    private static func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Glue3.write(1, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }
}

private enum Glue3 {
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #elseif canImport(Glibc)
        Glibc.write(fd, buffer, count)
        #else
        Musl.write(fd, buffer, count)
        #endif
    }
}

/// The systemd user unit, and telling systemd the socket is up (`Type=notify`).
package enum HostService {
    package static let unitName = "kore-host.service"

    package static func unit(executable: String) -> String {
        """
        [Unit]
        Description=kore-host: Kore's chats on this machine, for the Mac over SSH
        After=default.target

        [Service]
        Type=notify
        # The allocator hands freed pages back at once, so an idle box stays small.
        Environment=MIMALLOC_PURGE_DELAY=0
        ExecStart=\(executable) run
        Restart=on-failure
        RestartSec=2

        [Install]
        WantedBy=default.target

        """
    }

    /// Writes the unit under ~/.config/systemd/user and enables it, started now.
    package static func install(executable: String, home: URL) throws -> URL {
        let folder = home.appendingPathComponent(".config/systemd/user")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(unitName)
        try unit(executable: executable).write(to: file, atomically: true, encoding: .utf8)
        try run(["systemctl", "--user", "daemon-reload"])
        try run(["systemctl", "--user", "enable", "--now", unitName])
        return file
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HostSocketError.failed(arguments.joined(separator: " ")) }
    }

    /// `READY=1` to `$NOTIFY_SOCKET`, when systemd set one: the socket is listening by then.
    package static func notifyReady(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard var path = environment["NOTIFY_SOCKET"], !path.isEmpty else { return }
        let abstract = path.hasPrefix("@")
        if abstract { path.removeFirst() }
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        #endif
        guard fd >= 0 else { return }
        defer { _ = Glue4.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count + 1 < MemoryLayout.size(ofValue: address.sun_path) else { return }
        let start = abstract ? 1 : 0
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.storeBytes(of: 0, toByteOffset: 0, as: UInt8.self)
            for (i, b) in bytes.enumerated() { raw[start + i] = b }
            raw[start + bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + start + bytes.count + (abstract ? 0 : 1))
        let message = Array("READY=1".utf8)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, message, message.count, 0, $0, length) }
        }
    }
}

private enum Glue4 {
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Glibc)
        Glibc.close(fd)
        #else
        Musl.close(fd)
        #endif
    }
}
