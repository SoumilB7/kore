import Foundation
import HostClient
import LinkProtocol
import Testing

/// 1.15's `fs.read {offset}` over a scripted box: a file a renderer needs on the Mac comes in
/// pieces, again only when it changed, never past the cap, and only from a box that says it can.
@MainActor
@Suite(.serialized)
struct BoxBytesTests {
    /// A box answering `fs.read` from one file it holds, and the offsets it was asked.
    @MainActor final class Script {
        let host: FakeHost
        var bytes: Data
        var mtime: Int64 = 7
        var asked: [Int64] = []
        /// Runs before the answer to the piece at this offset (a change on the box).
        var before: [Int64: () -> Void] = [:]
        private var pump: Task<Void, Never>?

        init(_ host: FakeHost, bytes: Data) {
            self.host = host
            self.bytes = bytes
            pump = Task { [weak self] in
                while let host = self?.host {
                    let cmd = await host.take("cmd")
                    self?.answer(cmd)
                }
            }
        }

        private func answer(_ cmd: [String: Any]) {
            guard let id = cmd["id"] as? String, let body = cmd["cmd"] as? [String: Any], body["type"] as? String == "fs.read" else { return }
            let offset = Int64((body["offset"] as? Int) ?? 0)
            asked.append(offset)
            before.removeValue(forKey: offset)?()
            let size = Int64(bytes.count)
            if let base = body["base"] as? [String: Any], base["size"] as? Int == bytes.count, (base["mtime"] as? Int).map(Int64.init) == mtime {
                return host.send(json: ["t": "result", "id": id, "ok": true, "size": size, "mtime": mtime, "unchanged": true])
            }
            let piece = bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + LinkFiles.pieceMax))
            host.send(json: ["t": "result", "id": id, "ok": true, "kind": "binary", "size": size, "mtime": mtime, "data": piece.base64EncodedString()])
        }

        func stop() { pump?.cancel() }
    }

    private func linked(caps: [String]) async throws -> (HostConnection, FakeHost) {
        var hosts: [FakeHost] = []
        let connection = HostConnection(alias: "mybox", cache: HostCache(alias: "mybox", root: Fixture.scratch())) {
            let (client, host) = FakeHost.pair()
            hosts.append(host)
            return client
        }
        connection.retain()
        #expect(await until { hosts.count == 1 })
        _ = try #require(await hosts[0].handshake(windows: [], chats: [], caps: caps))
        #expect(await until { connection.isOnline })
        return (connection, hosts[0])
    }

    private func place() throws -> URL {
        let folder = Fixture.scratch()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("circulars.xlsx")
    }

    @Test func aFileComesInPiecesAndAgainOnlyWhenItChanged() async throws {
        let (connection, host) = try await linked(caps: ["tx", "control", LinkFiles.bytesCap])
        defer { connection.release() }
        let whole = Data((0..<(LinkFiles.pieceMax * 2 + 1000)).map { UInt8($0 % 251) })
        let box = Script(host, bytes: whole)
        defer { box.stop() }
        let file = try place()
        let got = try await connection.fetch("/w/circulars.xlsx", to: file, cap: 50 << 20, base: nil).get()
        #expect(got.written && got.stamp == FileStamp(size: Int64(whole.count), mtime: 7))
        #expect(try Data(contentsOf: file) == whole)
        #expect(box.asked == [0, Int64(LinkFiles.pieceMax), Int64(LinkFiles.pieceMax * 2)])
        // The stamp held: one question, nothing written.
        let again = try await connection.fetch("/w/circulars.xlsx", to: file, cap: 50 << 20, base: got.stamp).get()
        #expect(!again.written && box.asked.count == 4)
        // Changed on the box: the new bytes, in the same place.
        box.bytes = Data("new".utf8)
        box.mtime = 9
        let changed = try await connection.fetch("/w/circulars.xlsx", to: file, cap: 50 << 20, base: got.stamp).get()
        #expect(changed.written && changed.stamp == FileStamp(size: 3, mtime: 9))
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        // No part file left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["circulars.xlsx"])
    }

    @Test func aFileThatChangesOnTheWayIsReadAgainFromTheStart() async throws {
        let (connection, host) = try await linked(caps: ["tx", "control", LinkFiles.bytesCap])
        defer { connection.release() }
        let box = Script(host, bytes: Data(repeating: 1, count: LinkFiles.pieceMax + 10))
        defer { box.stop() }
        box.before[Int64(LinkFiles.pieceMax)] = {
            box.bytes = Data(repeating: 2, count: LinkFiles.pieceMax + 20)
            box.mtime = 8
        }
        let file = try place()
        let got = try await connection.fetch("/w/circulars.xlsx", to: file, cap: 50 << 20, base: nil).get()
        #expect(got.stamp == FileStamp(size: Int64(LinkFiles.pieceMax + 20), mtime: 8))
        #expect(try Data(contentsOf: file) == Data(repeating: 2, count: LinkFiles.pieceMax + 20))
        #expect(box.asked == [0, Int64(LinkFiles.pieceMax), 0, Int64(LinkFiles.pieceMax)])
    }

    @Test func pastTheCapNothingIsKept() async throws {
        let (connection, host) = try await linked(caps: ["tx", "control", LinkFiles.bytesCap])
        defer { connection.release() }
        let box = Script(host, bytes: Data(repeating: 3, count: 4096))
        defer { box.stop() }
        let file = try place()
        let result = await connection.fetch("/w/circulars.xlsx", to: file, cap: 1024, base: nil)
        #expect(result.map { $0.written } == .failure(.tooLarge(4096)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(box.asked == [0])
    }

    @Test func aBoxWithoutTheCapIsNeverAsked() async throws {
        let (connection, host) = try await linked(caps: ["tx", "control"])
        defer { connection.release() }
        let box = Script(host, bytes: Data([1, 2, 3]))
        defer { box.stop() }
        let file = try place()
        let result = await connection.fetch("/w/circulars.xlsx", to: file, cap: 1024, base: nil)
        #expect(result.map { $0.written } == .failure(.refused("mybox needs an update to preview this")))
        #expect(box.asked.isEmpty)
    }
}
