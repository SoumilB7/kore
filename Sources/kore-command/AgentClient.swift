import Darwin
import Foundation

/// One connection to Kore's agent channel (`z-docs/agent-protocol.md`): a hello, then commands,
/// one JSON object a line each way. Blocking; `kore` does one thing and exits.
final class AgentClient {
    enum Failure: Error {
        /// No socket: Kore isn't running, or agent control is off.
        case unreachable
        /// Kore said `bye`, or a command failed: its code and words.
        case refused(code: String, message: String)
        case closed
    }

    typealias Object = [String: Any]

    private let fd: Int32
    private var buffer = Data()
    private var serial = 0
    private(set) var welcome: Object = [:]

    /// `~/Library/Application Support/Kore/agent/kore.sock`, or `KORE_AGENT_SOCKET`.
    static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["KORE_AGENT_SOCKET"], !path.isEmpty { return path }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Kore/agent/kore.sock").path
    }

    /// Connects and says hello with the chat's pass, if this runs under one of Kore's chats.
    init() throws(Failure) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(Self.socketPath.utf8)
        guard fd >= 0, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw .unreachable }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw .unreachable
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        timeout(10)
        var hello: Object = ["type": "hello", "proto": 1, "client": "kore"]
        if let pass = ProcessInfo.processInfo.environment["KORE_AGENT_PASS"], !pass.isEmpty { hello["pass"] = pass }
        try write(hello)
        let first = try next()
        if first["type"] as? String == "bye" { throw Self.refusal(first) }
        welcome = first
    }

    deinit { Darwin.close(fd) }

    /// How long a read waits (0: for ever).
    func timeout(_ seconds: Int) {
        var limit = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Runs a command; its `data`, or the refusal.
    @discardableResult
    func run(_ command: String, _ args: Object = [:]) throws(Failure) -> Object {
        serial += 1
        let id = String(serial)
        try write(["type": "cmd", "id": id, "cmd": command, "args": args])
        while true {
            let line = try next()
            switch line["type"] as? String {
            case "bye": throw Self.refusal(line)
            case "result" where line["id"] as? String == id:
                guard line["ok"] as? Bool == true else { throw Self.refusal(line) }
                return line["data"] as? Object ?? [:]
            default: continue
            }
        }
    }

    /// The next line Kore sends, parsed.
    func next() throws(Failure) -> Object {
        guard let raw = try nextRaw(), let object = (try? JSONSerialization.jsonObject(with: raw)) as? Object else { throw .closed }
        return object
    }

    /// The next line as it came (nil at the end).
    func nextRaw() throws(Failure) -> Data? {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private func write(_ object: Object) throws(Failure) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { throw .closed }
        data.append(0x0A)
        let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == data.count else { throw .closed }
    }

    private static func refusal(_ line: Object) -> Failure {
        .refused(code: line["code"] as? String ?? "refused", message: line["message"] as? String ?? "Kore refused.")
    }
}
