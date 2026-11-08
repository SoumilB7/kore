import Foundation
import Testing
@testable import Tailnet

/// The IPN bus is one long chunked response read line by line. Reading more moves the unread
/// bytes to the front once 64 KiB are behind the reader; a chunk-size line split across that
/// move must still be found (it once read past the buffer's end and trapped).
@Suite("http1 stream")
struct HTTP1StreamTests {
    @Test(arguments: [1, 7, 333, 699, 700, 1021, 1499, 4093, 8191])
    func everyLineSurvivesTheBufferMovingUnderIt(lineLength: Int) throws {
        let lines = (0..<400).map { n in "{\"n\":\(n),\"pad\":\"" + String(repeating: "x", count: lineLength) + "\"}" }
        let response = FakeHTTPServer.chunked(lines.map { $0 + "\n" })
        let fd = try FakeHTTPServer().connection(answering: response)
        defer { Sockets.closeFD(fd) }
        try Sockets.writeAll(fd, Data("GET /localapi/v0/watch-ipn-bus HTTP/1.1\r\n\r\n".utf8))
        var reader = HTTP1.Reader(fd: fd)
        #expect(try reader.head().status == 200)
        var got: [String] = []
        while let line = try reader.line() { got.append(String(decoding: line, as: UTF8.self)) }
        #expect(got == lines)
    }
}
