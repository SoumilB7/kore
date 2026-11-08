import Foundation

/// Just enough HTTP/1.1 for Tailscale's LocalAPI over a socket descriptor: one GET per connection
/// (`Connection: close`), bodies by length, chunks or close, and a streamed body read line by
/// line (the IPN bus). No URLSession: it isn't there on static musl.
struct HTTP1 {
    static let maxHead = 64 << 10
    static let maxBody = 16 << 20

    static func request(_ path: String, authorization: String?) -> Data {
        var text = "GET \(path) HTTP/1.1\r\nHost: local-tailscaled.sock\r\n"
        if let authorization { text += "Authorization: \(authorization)\r\n" }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    /// Basic auth with an empty user and the `sameuserproof` token.
    static func basic(token: String) -> String { "Basic " + Data(":\(token)".utf8).base64EncodedString() }

    struct Head: Equatable {
        var status: Int
        var headers: [String: String]
    }

    /// Reads one response from a connected descriptor.
    struct Reader {
        private let fd: Int32
        private var buffer: [UInt8] = []
        private var position = 0
        private var mode = Mode.close
        private var remaining = 0
        private var chunkNeedsCRLF = false
        private var finished = false
        private var lineBuffer: [UInt8] = []

        private enum Mode { case length, chunked, close }

        init(fd: Int32) { self.fd = fd }

        private var available: Int { buffer.count - position }

        /// More bytes from the socket; false at its end.
        private mutating func fill() throws -> Bool {
            if position > 0 && position == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                position = 0
            } else if position > 64 << 10 {
                buffer.removeFirst(position)
                position = 0
            }
            let more = try Sockets.read(fd, max: 64 << 10)
            guard !more.isEmpty else { return false }
            buffer.append(contentsOf: more)
            return true
        }

        /// The bytes up to a CRLF (not included), at most `limit`.
        private mutating func crlfLine(limit: Int) throws -> [UInt8] {
            // How far past `position` is already searched. Relative, because `fill()` may move the
            // unread bytes to the front of the buffer (an absolute index would point past its end).
            var scanned = 0
            while true {
                let start = position + scanned
                if start < buffer.count, let i = (start..<buffer.count).first(where: { buffer[$0] == 0x0A && $0 > position && buffer[$0 - 1] == 0x0D }) {
                    let line = Array(buffer[position..<(i - 1)])
                    position = i + 1
                    return line
                }
                scanned = max(0, buffer.count - position - 1)
                guard available <= limit else { throw TailnetError.malformed("line") }
                guard try fill() else { throw SocketError.closed }
            }
        }

        mutating func head() throws -> Head {
            let status = String(decoding: try crlfLine(limit: HTTP1.maxHead), as: UTF8.self)
            let parts = status.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]) else { throw TailnetError.malformed("status line") }
            var headers: [String: String] = [:]
            var total = status.utf8.count
            while true {
                let line = try crlfLine(limit: HTTP1.maxHead)
                total += line.count
                guard total <= HTTP1.maxHead else { throw TailnetError.malformed("headers") }
                if line.isEmpty { break }
                let text = String(decoding: line, as: UTF8.self)
                guard let colon = text.firstIndex(of: ":") else { throw TailnetError.malformed("header") }
                headers[text[..<colon].lowercased()] = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                mode = .chunked
            } else if let length = headers["content-length"] {
                guard let n = Int(length), n >= 0 else { throw TailnetError.malformed("content-length") }
                mode = .length
                remaining = n
                finished = n == 0
            }
            return Head(status: code, headers: headers)
        }

        /// The next body bytes; nil at the body's end.
        mutating func next() throws -> [UInt8]? {
            guard !finished else { return nil }
            switch mode {
            case .close:
                if available == 0, try !fill() {
                    finished = true
                    return nil
                }
                return take(available)
            case .length:
                if available == 0, try !fill() { throw SocketError.closed }
                let bytes = take(min(available, remaining))
                remaining -= bytes.count
                finished = remaining == 0
                return bytes
            case .chunked:
                if remaining == 0 {
                    if chunkNeedsCRLF {
                        guard try crlfLine(limit: 2).isEmpty else { throw TailnetError.malformed("chunk end") }
                        chunkNeedsCRLF = false
                    }
                    let sizeLine = String(decoding: try crlfLine(limit: 1024), as: UTF8.self)
                    let hex = sizeLine.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    guard let size = Int(hex, radix: 16), size >= 0 else { throw TailnetError.malformed("chunk size") }
                    if size == 0 {
                        while try !crlfLine(limit: HTTP1.maxHead).isEmpty {}
                        finished = true
                        return nil
                    }
                    remaining = size
                }
                if available == 0, try !fill() { throw SocketError.closed }
                let bytes = take(min(available, remaining))
                remaining -= bytes.count
                chunkNeedsCRLF = remaining == 0
                return bytes
            }
        }

        private mutating func take(_ n: Int) -> [UInt8] {
            let out = Array(buffer[position..<(position + n)])
            position += n
            return out
        }

        mutating func body(limit: Int = HTTP1.maxBody) throws -> Data {
            var out = Data()
            while let bytes = try next() {
                out.append(contentsOf: bytes)
                guard out.count <= limit else { throw TailnetError.malformed("body size") }
            }
            return out
        }

        /// The body's next line (without its newline); nil at the body's end.
        mutating func line(limit: Int = HTTP1.maxBody) throws -> [UInt8]? {
            while true {
                if let i = lineBuffer.firstIndex(of: 0x0A) {
                    let line = Array(lineBuffer[..<i])
                    lineBuffer.removeFirst(i + 1)
                    return line
                }
                guard lineBuffer.count <= limit else { throw TailnetError.malformed("line size") }
                guard let more = try next() else {
                    guard !lineBuffer.isEmpty else { return nil }
                    defer { lineBuffer.removeAll() }
                    return lineBuffer
                }
                lineBuffer.append(contentsOf: more)
            }
        }
    }
}
