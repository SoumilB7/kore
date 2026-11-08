import Foundation
import KoreTrust
import Synchronization
import Tailnet

/// Shared pieces: a scratch folder, the v2 fixtures, a hand-turned clock, hex.
enum TestKit {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/link/v2")

    static func fixture(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("net-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func record(
        id: UUID = UUID(), kind: NodeKind, abilities: Ability, key: some IdentitySigner, nodeKeys: [String] = ["nodekey:aa"],
        userId: Int64? = 7, tags: [String] = [], owner: Bool = false, issuedBy: UUID? = nil
    ) -> DeviceRecord {
        DeviceRecord(
            id: id, name: "\(kind.rawValue)-1", kind: kind, abilities: abilities, owner: owner, identityKey: key.publicKey, nodeKeys: nodeKeys,
            userId: userId, tags: tags, fqdn: "\(kind.rawValue)-1.tail.ts.net.", issuedBy: issuedBy, added: Date(timeIntervalSince1970: 1_800_000_000))
    }
}

/// A clock tests move by hand.
final class FakeClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { self.now } }
}

extension Data {
    init(hex: String) {
        var out = Data()
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        self = out
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The far end of a socketpair playing an HTTP server: it reads one request head, answers with
/// `response`, and closes. What it read comes back through `request`.
final class FakeHTTPServer: Sendable {
    private let seen = Mutex<[String]>([])
    var requests: [String] { seen.withLock { $0 } }

    /// The client's end of a fresh pair whose server end answers `response`.
    func connection(answering response: String) throws -> Int32 {
        let (client, server) = try Sockets.pair()
        let thread = Thread { [self] in
            var head = Data()
            while !head.contains(Data("\r\n\r\n".utf8)) {
                guard let more = try? Sockets.read(server, max: 4096), !more.isEmpty else { break }
                head.append(contentsOf: more)
            }
            seen.withLock { $0.append(String(decoding: head, as: UTF8.self)) }
            try? Sockets.writeAll(server, Data(response.utf8))
            Sockets.closeFD(server)
        }
        thread.start()
        return client
    }

    static func ok(_ body: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
    }

    static func chunked(_ parts: [String]) -> String {
        var out = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        for part in parts { out += String(part.utf8.count, radix: 16) + "\r\n" + part + "\r\n" }
        return out + "0\r\n\r\n"
    }

    static let unauthorized = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n"
}
