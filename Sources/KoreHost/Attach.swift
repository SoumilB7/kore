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

    /// Connects to the daemon's socket (`paths.socket`, where the running daemon listens, not the
    /// one the grant was made beside); throws when no daemon answers there.
    package init(grant: Grant, socket path: URL, done: @escaping (Int32) -> Void) throws {
        self.grant = grant
        self.done = done
        socket = try HostListener.connect(to: path.path)
    }

    package func start() {
        socket.start(max: LinkFrame.outboundMax, frame: { [weak self] data in self?.fromHost(data) }, ended: { [weak self] in self?.done(AttachExit.ended.rawValue) })
        let source = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(0, &chunk, chunk.count)
                guard count > 0 else {
                    self.socket.close()
                    return self.done(AttachExit.ended.rawValue)
                }
                self.input.append(contentsOf: chunk[0..<count])
                guard let frames = try? LinkFrame.take(&self.input, max: LinkFrame.inboundMax) else { return self.done(AttachExit.broken.rawValue) }
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
