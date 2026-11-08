import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import KoreNet
import LinkProtocol
import Tailnet

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

/// `kore-host attach --proto 2 --as <name>`: link 2.0 over SSH. Passes bytes between
/// stdin/stdout and the daemon's `net.sock`, where the session runs with route `ssh`. Like
/// today's `attach` fills in the proof, it fills in the upgrade's `legacyGrant{name, secret}`
/// when the client's hello enrolls, so the secret never crosses the wire from the Mac; the box
/// honours it once.
@MainActor
package final class NetAttach {
    private let grant: Grant
    private let fd: Int32
    private var helloSeen = false
    private var held = Data()
    private var sources: [DispatchSourceRead] = []
    private let done: (Int32) -> Void

    package init(grant: Grant, socket path: URL, done: @escaping (Int32) -> Void) throws {
        self.grant = grant
        self.done = done
        fd = try Sockets.connectUnix(path.path)
    }

    /// Whether `attach --as <grant>` starts at all. An expired grant whose Mac enrolled (`device`)
    /// still carries `--proto 2`: the session then admits only that device's identity proof
    /// against its record (the expired secret is honoured for nothing, `upgrade` refuses it).
    nonisolated package static func admits(_ grant: Grant, proto2: Bool, at now: Date) -> Bool {
        !grant.expired(at: now) || (proto2 && grant.device != nil)
    }

    package func start() {
        let fromHost = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        fromHost.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let bytes = try? Sockets.read(self.fd, max: 64 << 10), !bytes.isEmpty else { return self.done(AttachExit.ended.rawValue) }
                Self.write(1, Data(bytes))
            }
        }
        let fromClient = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
        fromClient.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var chunk = [UInt8](repeating: 0, count: 64 << 10)
                let count = read(0, &chunk, chunk.count)
                guard count > 0 else {
                    Sockets.shutdownBoth(self.fd)
                    return self.done(AttachExit.ended.rawValue)
                }
                self.fromClient(Data(chunk[0..<count]))
            }
        }
        sources = [fromHost, fromClient]
        fromHost.resume()
        fromClient.resume()
    }

    private func fromClient(_ bytes: Data) {
        guard !helloSeen else { return Self.write(fd, bytes) }
        held.append(bytes)
        guard let out = Self.inject(held, grant: grant) else { return }
        helloSeen = true
        held = Data()
        Self.write(fd, out)
    }

    /// The client's bytes with its first frame (the hello) given the grant when it enrolls; nil
    /// while that frame isn't whole. Anything else goes as it came (the daemon judges it).
    nonisolated package static func inject(_ bytes: Data, grant: Grant) -> Data? {
        guard bytes.count >= NetFrame.headerSize else { return nil }
        let base = bytes.startIndex
        let length = (0..<4).reduce(0) { $0 << 8 | Int(bytes[base + $1]) }
        guard length <= NetFrame.preAuthMaxFrame else { return bytes }
        guard bytes.count >= NetFrame.headerSize + length else { return nil }
        let payload = bytes.subdata(in: (base + NetFrame.headerSize)..<(base + NetFrame.headerSize + length))
        let rest = bytes.subdata(in: (base + NetFrame.headerSize + length)..<bytes.endIndex)
        guard case .hello(var hello)? = try? NetControl.decode(payload), hello.enroll != nil, hello.legacyGrant == nil,
              let encoded = try? ({ () throws -> Data in
                  hello.legacyGrant = .init(name: grant.name, secret: grant.secret)
                  return try NetControl.hello(hello).encoded()
              })()
        else { return bytes }
        return NetFrame(queue: .interactive, stream: NetFrame.controlStream, payload: encoded).encoded + rest
    }

    private static func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Glue3.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }
}
