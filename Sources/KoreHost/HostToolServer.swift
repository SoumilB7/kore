import AgentTools
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import KoreCore
import LinkProtocol

/// `kore-host mcp`: the `kore_app` server a box chat's CLI starts with while its Arsenal is on
/// (link 1.6). The same tools as the Mac's `kore mcp` (`AgentTools`); each call is one connection
/// to the daemon's `agent.sock` with the chat's id and secret (`KORE_AGENT_CHAT`, `KORE_AGENT_PASS`,
/// which kore-host gave the CLI), answered with what Kore on the Mac decided.
package enum HostToolServer {
    package static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        MCPStdio.run(list: { AgentTools.tools(box: true) }, call: { name, args in call(name, args, environment) })
    }

    static func call(_ name: String, _ arguments: AgentTools.Object, _ env: [String: String]) -> AgentTools.Object {
        guard let tool = AgentTools.tool(name, box: true) else { return MCPStdio.failure("No such tool: \(name).") }
        guard let socket = env["KORE_AGENT_SOCKET"], let chat = env[KoreReach.chatVariable], let pass = env["KORE_AGENT_PASS"], !pass.isEmpty else {
            return MCPStdio.failure("This runs only under a chat kore-host started.")
        }
        let given = (try? JSONSerialization.data(withJSONObject: arguments)).flatMap { try? JSONValue.parse($0) }
        let ask = BoxToolAsk(chatId: chat, pass: pass, tool: tool.name, args: given)
        guard let data = exchange(BoxTools.encode(ask), at: socket, wait: BoxTools.timeout(tool.name) + 5),
            let result = try? JSONDecoder().decode(BoxToolResult.self, from: data)
        else { return MCPStdio.failure("kore-host isn't running, or didn't answer.") }
        return result.ok ? MCPStdio.success(result.text) : MCPStdio.failure(result.text)
    }

    /// One frame out and one back on a Unix socket, blocking, `wait` seconds at most for the answer.
    static func exchange(_ payload: Data, at path: String, wait: TimeInterval) -> Data? {
        #if canImport(Glibc) || canImport(Musl)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return nil }
        defer { _ = Calls.close(fd) }
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Calls.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var limit = timeval(tv_sec: Int(wait), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let frame = LinkFrame.frame(payload)
        let sent = frame.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Calls.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        guard sent else { return nil }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let frames = try? LinkFrame.take(&buffer, max: LinkFrame.outboundMax), let first = frames.first { return first }
            let n = Calls.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// The C calls whose names Swift's own shadow here.
private enum Calls {
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(fd, address, length)
        #elseif canImport(Glibc)
        Glibc.connect(fd, address, length)
        #else
        Musl.connect(fd, address, length)
        #endif
    }

    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #elseif canImport(Glibc)
        Glibc.write(fd, buffer, count)
        #else
        Musl.write(fd, buffer, count)
        #endif
    }

    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #elseif canImport(Glibc)
        Glibc.read(fd, buffer, count)
        #else
        Musl.read(fd, buffer, count)
        #endif
    }

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
